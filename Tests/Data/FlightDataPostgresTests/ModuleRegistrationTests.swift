import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import Testing

/// Module provision and composition-failure posture that needs no server: the
/// values a module provides, and the fail-at-construction behavior.
@Suite("PostgresDataModule provision")
struct ModuleRegistrationTests {
    /// A syntactically valid URL for a server that is never dialed —
    /// construction parses eagerly but connects only when the service runs.
    static let offlineConfiguration = Configuration(values: [
        DataSourceConfigKey.url(datasource: "primary"): "postgres://postgres@localhost:5/nowhere?sslmode=disable",
        DataSourceConfigKey.url(datasource: "analytics"): "postgres://postgres@localhost:5/elsewhere?sslmode=disable",
        DataSourceConfigKey.poolSize(datasource: "analytics"): "2",
    ])

    enum Analytics: DataSourceName {
        static let name = "analytics"
    }

    @Test func providesPoolAndLivenessPerDatasource() throws {
        let primary = try PostgresDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        #expect(primary.dataSource.name == "primary")
        #expect(primary.dataSource.poolSize == DataSourceSettings.defaultPoolSize)
        #expect(primary.liveness.datasourceName == "primary")

        let analytics = try PostgresDataModule<Analytics>(
            configuration: Self.offlineConfiguration)
        #expect(analytics.dataSource.name == "analytics")
        #expect(analytics.dataSource.poolSize == 2)
        #expect(analytics.liveness.datasourceName == "analytics")

        // Independent pools — two names of one store type.
        #expect(primary.dataSource !== analytics.dataSource)
    }

    @Test func malformedURLFailsAtComposition() {
        // Posture: a bad URL is a composition failure, not a first-query one —
        // it fails when the module is built, earlier than the `freeze()` it
        // used to fail at.
        let configuration = Configuration(values: [
            DataSourceConfigKey.url(datasource: "primary"): "postgres://localhost:5432"
        ])
        #expect(throws: PostgresDataSourceURLError.missingDatabase(datasource: "primary")) {
            try PostgresDataModule<PrimaryDataSource>(configuration: configuration)
        }
    }

    @Test func missingURLFailsAtComposition() {
        #expect(throws: (any Error).self) {
            try PostgresDataModule<PrimaryDataSource>(configuration: Configuration())
        }
    }

    @Test func checkoutBeforeServiceStartThrows() throws {
        let module = try PostgresDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        // The portable vocabulary, not a driver-local twin of it: a
        // store-agnostic caller reacts to `DataSourceError` without knowing
        // which driver it is talking to.
        #expect(throws: DataSourceError.notStarted(datasource: "primary")) {
            _ = try module.dataSource.checkout()
        }
    }

    @Test func moduleProvidesPoolService() throws {
        let module = try PostgresDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        #expect(module.service != nil)
    }
}
