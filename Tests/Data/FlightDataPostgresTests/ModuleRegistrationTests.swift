import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import Testing

/// Registration and bootstrap behavior that needs no server: the module's
/// components, the fail-at-freeze posture, and the scope requirement.
@Suite("PostgresDataModule registration")
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

    private func build() throws -> Container {
        try TestContainer.build(configuration: Self.offlineConfiguration) {
            TestAppModule()
            // Both pools take their configuration now, so both are built.
            try PostgresDataModule<PrimaryDataSource>(configuration: Self.offlineConfiguration)
            try PostgresDataModule<Analytics>(configuration: Self.offlineConfiguration)
        }
    }

    @Test func registersPoolLeaseAndLivenessPerDatasource() throws {
        let container = try build()

        let primary = try container.resolve(PostgresDataSource.self, qualifier: "primary")
        #expect(primary.name == "primary")
        #expect(primary.poolSize == DataSourceSettings.defaultPoolSize)

        let analytics = try container.resolve(PostgresDataSource.self, qualifier: "analytics")
        #expect(analytics.name == "analytics")
        #expect(analytics.poolSize == 2)

        let probes = try DataSourceLiveness.all(in: container)
        #expect(Set(probes.map(\.datasourceName)) == ["primary", "analytics"])
    }

    @Test func primaryDatasourceAnswersUnqualifiedResolution() throws {
        let container = try build()
        let primary = try container.resolve(PostgresDataSource.self)
        #expect(primary.name == "primary")

        // The named datasource must be asked for by name.
        let analytics = try container.resolve(PostgresDataSource.self, qualifier: "analytics")
        #expect(analytics.name == "analytics")
    }

    @Test func repositoriesRegisterWithRepositoryStereotype() throws {
        let container = try build()
        let repositories = container.allRegistrations().filter { $0.stereotype == .repository }
        #expect(repositories.contains { $0.typeName.contains("UserRepository") })
        #expect(repositories.contains { $0.typeName.contains("LedgerRepository") })
        #expect(repositories.allSatisfy { $0.scope == .singleton },
                "a repository holds the pool, not a connection, so it is a singleton")
    }

    @Test func malformedURLFailsAtComposition() {
        // posture: a bad URL is a bootstrap failure, not a first-query one —
        // and now it fails when the module is built, which is earlier than
        // the freeze() it used to fail at.
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
        let container = try build()
        let source = try container.resolve(PostgresDataSource.self, qualifier: "primary")
        // The portable vocabulary, not a driver-local twin of it: a
        // store-agnostic caller reacts to `DataSourceError` without knowing
        // which driver it is talking to, and each driver shadowing this case
        // with its own enum defeated exactly that.
        #expect(throws: DataSourceError.notStarted(datasource: "primary")) {
            _ = try source.checkout()
        }
    }

    @Test func connectionIsNotAComponent() throws {
        let container = try build()
        // A connection is leased per operation through `withConnection`, not
        // resolved. Nothing registers one, so asking is an error — which also
        // means the captive-dependency hazard the old `.scoped` registration
        // had to guard against cannot arise.
        #expect(throws: ResolutionError.self) {
            _ = try container.resolve(PostgresConnection.self)
        }
    }

    @Test func moduleProvidesPoolService() throws {
        let module = try PostgresDataModule<PrimaryDataSource>(
            configuration: Self.offlineConfiguration)
        let container = Container()
        container.register(Configuration.self, scope: .singleton) { _ in Self.offlineConfiguration }
        try module.configure(container)
        #expect(module.service != nil)
    }
}
