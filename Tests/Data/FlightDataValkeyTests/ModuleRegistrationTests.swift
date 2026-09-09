import FlightCore
import FlightDataCore
import FlightDataTesting
import FlightDataValkey
import Testing

/// Module provision and composition-failure posture that needs no server: the
/// values a module provides, the fail-at-construction behavior, and the
/// deliberate absence of a transaction coordinator.
@Suite("ValkeyDataModule provision")
struct ModuleRegistrationTests {
    /// A syntactically valid URL for a server that is never dialed —
    /// construction parses eagerly but connects only when the service runs.
    static let offlineConfiguration = Configuration(values: [
        DataSourceConfigKey.url(datasource: "primary"): "valkey://localhost:5",
        DataSourceConfigKey.url(datasource: "ephemeral"): "redis://localhost:5/2",
        DataSourceConfigKey.poolSize(datasource: "ephemeral"): "2",
    ])

    enum Ephemeral: DataSourceName {
        static let name = "ephemeral"
    }

    @Test func providesPoolAndLivenessPerDatasource() throws {
        let primary = try ValkeyDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        #expect(primary.dataSource.name == "primary")
        #expect(primary.dataSource.poolSize == DataSourceSettings.defaultPoolSize)
        #expect(primary.dataSource.url.database == 0)
        #expect(primary.liveness.datasourceName == "primary")

        let ephemeral = try ValkeyDataModule<Ephemeral>(
            configuration: Self.offlineConfiguration)
        #expect(ephemeral.dataSource.name == "ephemeral")
        #expect(ephemeral.dataSource.poolSize == 2)
        #expect(ephemeral.dataSource.url.database == 2)
        #expect(ephemeral.liveness.datasourceName == "ephemeral")

        #expect(primary.dataSource !== ephemeral.dataSource)
    }

    @Test func checkoutBeforeServiceStartFailsLoudly() throws {
        let module = try ValkeyDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        // The portable vocabulary, not a driver-local twin of it: a
        // store-agnostic caller reacts to `DataSourceError` without knowing
        // which driver it is talking to.
        #expect(throws: DataSourceError.notStarted(datasource: "primary")) {
            _ = try module.dataSource.checkout()
        }
    }

    @Test func malformedURLFailsAtComposition() {
        // A bad URL is a composition failure, not a first-command one — it
        // fails when the module is built.
        let configuration = Configuration(values: [
            DataSourceConfigKey.url(datasource: "primary"): "postgres://localhost:5432/app"
        ])
        #expect(throws: ValkeyDataSourceURLError.unsupportedScheme(datasource: "primary", scheme: "postgres")) {
            try ValkeyDataModule<PrimaryDataSource>(configuration: configuration)
        }
    }

    @Test func missingURLFailsAtComposition() {
        #expect(throws: (any Error).self) {
            try ValkeyDataModule<PrimaryDataSource>(configuration: Configuration())
        }
    }

    /// The module has no transaction coordinator to provide — there is no such
    /// property. (`@Transactional` on a Valkey-only repository has no
    /// coordinator to find; the honest alternative, `multi`, lives on the
    /// connection.) Structural now, rather than an assertion on a registry.
    @Test func noTransactionCoordinator() throws {
        // Nothing to assert against a container; the absence is that
        // ValkeyDataModule exposes a pool and a liveness probe, and nothing
        // resembling a transaction coordinator. This test stands as the
        // documented intent.
        let module = try ValkeyDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        #expect(module.liveness.datasourceName == "primary")
    }
}
