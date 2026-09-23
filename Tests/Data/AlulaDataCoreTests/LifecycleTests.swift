import Testing
import AlulaCore
import AlulaDataCore
import AlulaDataTesting
import ServiceLifecycle

/// Every store module follows one shape: it holds the pool, the pool's
/// long-running work is a Service, and module health falls out of assembly
/// with no per-store instrumentation.
@Suite("Module lifecycle and health")
struct LifecycleTests {

    @Test("assemble wires a store module: module running, pool built from config")
    func assembleStoreModule() throws {
        let configuration = Configuration(values: ["datasource.primary.pool_size": "2"])
        let module = try InMemoryDataModule<PrimaryDataSource>(configuration: configuration)
        let app = try Alula.assemble(configuration: configuration, modules: [module])

        #expect(app.moduleOrder == ["InMemoryDataModule<PrimaryDataSource>"])
        // The pool is the module's own value, built from configuration.
        #expect(module.dataSource.poolSize == 2)

        let status = try #require(app.health.statuses().first)
        guard case .running = status.health else {
            Issue.record("expected .running, got \(status.health)")
            return
        }
    }

    @Test("bad datasource config fails when the module is built, not at first query")
    func configFailureAtBootstrap() {
        // Earlier than the old `freeze()`-time factory: the module reads and
        // validates its configuration in `init`, so a bad pool size throws at
        // composition.
        #expect(throws: DataSourceConfigurationError.self) {
            _ = try InMemoryDataModule<PrimaryDataSource>(
                configuration: Configuration(values: ["datasource.primary.pool_size": "0"]))
        }
    }

    @Test("one module type, instantiated per named datasource")
    func modulePerNamedDataSource() throws {
        let primary = try InMemoryDataModule<PrimaryDataSource>(
            configuration: Configuration(values: ["datasource.primary.pool_size": "2"]))
        let analytics = try InMemoryDataModule<Analytics>(
            configuration: Configuration(values: ["datasource.analytics.pool_size": "3"]))
        let app = try Alula.assemble(
            configuration: Configuration(), modules: [primary, analytics])

        #expect(app.moduleOrder == [
            "InMemoryDataModule<PrimaryDataSource>",
            "InMemoryDataModule<Analytics>",
        ])
        #expect(primary.dataSource !== analytics.dataSource)
        #expect((primary.dataSource.poolSize, analytics.dataSource.poolSize) == (2, 3))
    }

    @Test("a store module's service runs under assemble and can wind the pool down")
    func serviceOwningStoreModule() async throws {
        let store = try InMemoryDataModule<PrimaryDataSource>()
        let app = try Alula.assemble(
            configuration: Configuration(),
            modules: [store, PoolServiceModule(pool: store.dataSource)]
        )
        let entry = try #require(app.services.first { $0.moduleName == "PoolServiceModule" })
        #expect(entry.completion == .endsApp)

        // Run the (health-wrapped) service directly — deterministic, no
        // ServiceGroup; Core's own suite covers the group mapping.
        try await entry.service.run()

        #expect(store.dataSource.isClosed, "the service closed the pool on completion")
        #expect(store.dataSource.totalCheckouts == 1, "the service did one unit of pooled work")
        #expect(store.dataSource.activeCheckouts == 0)
    }

    @Test("a store service failure flips its module to .failed with zero instrumentation")
    func serviceFailureHealth() async throws {
        let store = try InMemoryDataModule<PrimaryDataSource>()
        let app = try Alula.assemble(
            configuration: Configuration(),
            modules: [store, FailingPoolServiceModule()]
        )
        let entry = try #require(app.services.first { $0.moduleName == "FailingPoolServiceModule" })

        await #expect(throws: PoolStartupError.self) {
            try await entry.service.run()
        }

        let status = try #require(app.health.statuses().first {
            $0.moduleName == "FailingPoolServiceModule"
        })
        guard case .failed = status.health else {
            Issue.record("expected .failed, got \(status.health)")
            return
        }
    }

    @Test("full bootstrap: a one-shot store service ends the app gracefully")
    func fullBootstrap() async throws {
        let store = try InMemoryDataModule<PrimaryDataSource>()
        try await Alula.bootstrap(
            configuration: Configuration(),
            modules: [store, PoolServiceModule(pool: store.dataSource)]
        )
    }
}

// MARK: - Service-owning fixtures

/// The shape: a module whose service does the pool's "long-running" work.
/// It is handed the pool the store module owns, rather than resolving it.
/// Bounded (.endsApp) so tests and bootstrap can run it to completion.
final class PoolServiceModule: AlulaModule {
    let pool: InMemoryDataSource
    init(pool: InMemoryDataSource) { self.pool = pool }

    var service: (any Service)? { PoolService(pool: pool) }
    var serviceCompletion: ServiceCompletionPolicy { .endsApp }
}

struct PoolService: Service {
    let pool: InMemoryDataSource

    func run() async throws {
        try await pool.withConnection { $0.perform("startup probe") }
        pool.close()
    }
}

struct PoolStartupError: Error {}

final class FailingPoolServiceModule: AlulaModule {
    var service: (any Service)? { FailingPoolService() }
}

struct FailingPoolService: Service {
    func run() async throws {
        throw PoolStartupError()
    }
}
