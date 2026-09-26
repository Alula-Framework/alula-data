import Foundation
import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import AlulaDataTesting
import PostgresNIO
import ServiceLifecycle
import Testing

/// The service story end to end: the module's service dials the pool,
/// requests are served only once it is live, broken connections are
/// replaced while it runs, and cancellation drains it.
extension PostgresIntegrationSuite {
/// The cross-store contract, run against the real driver.
///
/// `DataSourceConformance` is billed as "the contract every data source must
/// satisfy" and was run by neither driver — which is exactly the failure mode
/// its own doc comment says it exists to end. Both run it now.
@Suite("DataSource conformance — PostgresDataSource")
struct PostgresConformanceTests {
    @Test("the driver satisfies the DataSource contract")
    func conforms() async throws {
        try await DataSourceConformance.verify(
            make: {
                let source = try PostgresDataSource(
                    settings: try TestDatabase.settings(poolSize: 4))
                try await source.start()
                return source
            },
            shutdown: { await $0.shutdown() })
    }
}

@Suite("Pool service lifecycle")
struct PoolLifecycleIntegrationTests {
    @Test func moduleServiceRunsAndDrainsThePool() async throws {
        try await TestSchema.shared.ensure()
        // The module owns the pool; a repository holds it. Built directly,
        // the way the composition root would.
        let module = try PostgresDataModule<PrimaryDataSource>(
            configuration: try TestDatabase.configuration(poolSize: 2))
        // Drive the pool's run() the way bootstrap's ServiceGroup drives the
        // module's service (start → serve → cancel).
        let source = module.dataSource

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }

            // Wait until the pool is live, as bootstrap ordering guarantees.
            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(source.establishedConnections == 2)

            let repo = UserRepository(pool: source)
            #expect(try await repo.find(byEmail: "nobody@example.com") == nil)

            group.cancelAll()
        }
        #expect(source.isClosed)
        #expect(source.establishedConnections == 0)
        #expect(throws: DataSourceError.closed(datasource: "primary")) {
            _ = try source.checkout()
        }
    }

    @Test("a connection returned after the pool closed is closed, not dropped mid-close")
    func releaseAfterShutdownClosesCleanly() async throws {
        // Relay #45: a failed start cancelled a scheduled job holding a
        // connection; released after the pool closed, it was deinitialized
        // before its close finished, and PostgresNIO's debug assertion took the
        // process down — hiding why the start had failed.
        let source = try PostgresDataSource(settings: try TestDatabase.settings(poolSize: 1))
        try await source.start()
        var closing: Task<Void, Never>?
        do {
            let connection = try source.checkout()
            closing = Task { await source.shutdown() }
            while !source.isClosed { try await Task.sleep(for: .milliseconds(5)) }
            source.release(connection)
        }  // the last reference goes here, with the close only just begun
        await closing?.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(source.establishedConnections == 0)
    }

    @Test func brokenConnectionsAreReplacedWhileServiceRuns() async throws {
        try await TestSchema.shared.ensure()
        let source = try PostgresDataSource(settings: try TestDatabase.settings(poolSize: 2))

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await source.run() }
            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }

            // Kill a connection out from under the pool — a server restart
            // in miniature. Release notices, drops it, and the service loop
            // dials a replacement.
            let casualty = try source.checkout()
            try await casualty.close()
            source.release(casualty)

            for _ in 0..<100 where source.establishedConnections < 2 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(source.establishedConnections == 2)

            // And the replacement actually works.
            try await source.withConnection { connection in
                _ = try await connection.query("SELECT 1", logger: .init(label: "test"))
            }
            group.cancelAll()
        }
    }
}
}
