import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import Foundation
import ServiceLifecycle
import Synchronization
import Testing

// Alula prints a startup failure's `startupDiagnostic` and no longer its
// reflected form, which can carry secrets — so a Postgres pool that could not
// start used to print PostgresNIO's generic "prevent accidental leakage"
// placeholder and nothing else. It has to say where it was dialling and what
// came back, without the URL or the password.

@Suite("A datasource that cannot start says why, without secrets")
struct StartupDiagnosticTests {
    @Test("a refused connection names the target and the network error")
    func refused() async throws {
        let settings = try DataSourceSettings(
            name: "primary", url: "postgres://app:hunter2-secret@127.0.0.1:1/appdb", poolSize: 1)
        let source = try PostgresDataSource(settings: settings)
        await #expect {
            try await source.start()
        } throws: { error in
            guard let startup = error as? DataSourceStartupError else { return false }
            let text = startup.startupDiagnostic
            return text.contains("'primary'") && text.contains("127.0.0.1:1") && text.contains("'appdb'")
                && text.lowercased().contains("refused") && !text.contains("hunter2-secret")
                && !text.contains("postgres://")
        }
        #expect(source.isClosed)
    }

    /// Would log if it ever started — which it must not, when the pool
    /// cannot connect.
    struct Worker: AlulaModule {
        final class Started: Sendable {
            let flag = Mutex(false)
        }
        struct Run: Service {
            let started: Started
            func run() async throws {
                started.flag.withLock { $0 = true }
                try? await gracefulShutdown()
            }
        }
        let started: Started
        var service: (any Service)? { Run(started: started) }
    }

    @Test("the pool dials before any service starts, so its refusal is the only report")
    func dialsBeforeServices() async throws {
        // Relay #44: the listener announced itself and ten errors about a
        // closed pool came before the one line saying why.
        let module = try PostgresDataModule<PrimaryDataSource>(
            configuration: Configuration(values: [
                "datasource.primary.url": "postgres://app:hunter2-secret@127.0.0.1:1/appdb",
                "datasource.primary.pool-size": "1",
            ]))
        #expect(module.lifecycleHooks.map(\.moment) == [.beforeStart])
        let started = Worker.Started()
        await #expect(throws: DataSourceStartupError.self) {
            try await Alula.bootstrap(
                configuration: Configuration(), modules: [module, Worker(started: started)])
        }
        #expect(!started.flag.withLock { $0 }, "no other service started")
    }
}

extension PostgresIntegrationSuite {
    @Suite("Startup diagnostics against Postgres")
    struct StartupDiagnosticIntegrationTests {
        @Test("a wrong password gets the server's answer and SQLSTATE, not the password")
        func wrongPassword() async throws {
            let real = try #require(URLComponents(string: try TestDatabase.requireURL()))
            var wrong = real
            wrong.password = "hunter2-secret"
            let settings = try DataSourceSettings(name: "primary", url: try #require(wrong.string), poolSize: 1)
            let source = try PostgresDataSource(settings: settings)
            await #expect {
                try await source.start()
            } throws: { error in
                guard let startup = error as? DataSourceStartupError else { return false }
                let text = startup.startupDiagnostic
                return text.contains("28P01") && !text.contains("hunter2-secret")
            }
        }
    }
}
