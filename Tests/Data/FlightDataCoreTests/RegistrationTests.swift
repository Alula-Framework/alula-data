import Testing
import FlightCore
import FlightDataCore
import FlightDataTesting

/// A datasource module provides its pool and a liveness probe as values —
/// what `register(dataSource:)` used to put in the container, held by the
/// module instead. `InMemoryDataModule` is the reference shape every real
/// store module follows.
@Suite("Datasource module provision")
struct RegistrationTests {

    @Test("the module provides a name-qualified pool and its liveness probe")
    func providesPoolAndLiveness() throws {
        let module = try InMemoryDataModule<PrimaryDataSource>()
        #expect(module.liveness.datasourceName == "primary")
        // The pool is a value the module holds — the composition root reads it
        // and passes it as a graph root; a repository takes it by type.
        #expect(module.dataSource.poolSize == InMemoryDataModule<PrimaryDataSource>.defaultPoolSize)
    }

    @Test("the pool size comes from configuration")
    func poolSizeFromConfig() throws {
        let module = try InMemoryDataModule<PrimaryDataSource>(
            configuration: Configuration(values: ["datasource.primary.pool_size": "7"]))
        #expect(module.dataSource.poolSize == 7)
    }

    @Test("an invalid pool size fails composition, not the first query")
    func invalidPoolSizeThrows() {
        #expect(throws: DataSourceConfigurationError.self) {
            _ = try InMemoryDataModule<PrimaryDataSource>(
                configuration: Configuration(values: ["datasource.primary.pool_size": "0"]))
        }
    }

    @Test("two names of one store type are independent pools")
    func namedPoolsAreIndependent() throws {
        let primary = try InMemoryDataModule<PrimaryDataSource>(
            configuration: Configuration(values: ["datasource.primary.pool_size": "1"]))
        let analytics = try InMemoryDataModule<Analytics>(
            configuration: Configuration(values: ["datasource.analytics.pool_size": "3"]))
        #expect(primary.dataSource !== analytics.dataSource)
        #expect((primary.dataSource.poolSize, analytics.dataSource.poolSize) == (1, 3))
    }

    @Test("liveness pings through to the pool")
    func livenessProbe() async throws {
        struct StoreDown: Error {}
        let module = try InMemoryDataModule<PrimaryDataSource>()
        try await module.liveness.ping()

        module.dataSource.failPings(with: StoreDown())
        await #expect(throws: StoreDown.self) { try await module.liveness.ping() }
    }

    @Test("the composition root aggregates every module's liveness probe")
    func livenessAggregation() throws {
        // What `DataSourceLiveness.all(in: container)` used to discover through
        // introspection is now a plain concatenation of what each module
        // provides — the shape the generated composer produces for Actuator.
        let primary = try InMemoryDataModule<PrimaryDataSource>()
        let analytics = try InMemoryDataModule<Analytics>()
        let probes = [primary.liveness, analytics.liveness]
        #expect(probes.map(\.datasourceName).sorted() == ["analytics", "primary"])
    }
}
