import FlightCore
import FlightDataCore
import FlightDataPostgres
import FlightDataTesting
import PostgresNIO
import Testing

/// Umbrella for every suite that touches the shared fixture tables.
/// `.serialized` is recursive, so nested suites never interleave — each test
/// TRUNCATEs and reseeds, which only works single-file.
@Suite(.serialized, .enabled(if: TestDatabase.isConfigured))
enum PostgresIntegrationSuite {}

/// Ensures the test schema exists — once per process, through the same
/// `flight migrate` path production uses, so the migrations are
/// exercised on every test run.
actor TestSchema {
    static let shared = TestSchema()
    private var prepared = false

    func ensure() async throws {
        guard !prepared else { return }
        try await PostgresMigrations.migrate(
            configuration: try TestDatabase.configuration(),
            migrations: TestMigrations.all
        )
        prepared = true
    }
}

/// The value form of the old test container: the pool the module built and
/// the repositories that hold it, constructed directly rather than resolved.
struct PostgresTestApp {
    let source: PostgresDataSource
    var pool: PostgresDataSource { source }
    let users: UserRepository
    let ledger: LedgerRepository
    /// The datasource's liveness probe — what the module provides and the
    /// composition root aggregates for Actuator.
    let liveness: DataSourceLiveness

    init(source: PostgresDataSource) {
        self.source = source
        self.users = UserRepository(pool: source)
        self.ledger = LedgerRepository(pool: source)
        self.liveness = DataSourceLiveness(datasourceName: PrimaryDataSource.name) { [source] in
            try await source.ping()
        }
    }
}

/// Builds the store module (its pool and repositories), starts the pool by
/// hand — tests drive the lifecycle a `ServiceGroup` would — runs `body`, and
/// drains the pool.
func withPostgresContainer<T>(
    poolSize: Int = 4,
    resetOnRelease: Bool = true,
    _ body: (PostgresTestApp, PostgresDataSource) async throws -> T
) async throws -> T {
    try await TestSchema.shared.ensure()
    let module = try PostgresDataModule<PrimaryDataSource>(
        configuration: try TestDatabase.configuration(
            poolSize: poolSize, resetOnRelease: resetOnRelease))
    let source = module.dataSource
    try await source.start()
    do {
        let result = try await body(PostgresTestApp(source: source), source)
        await source.shutdown()
        return result
    } catch {
        await source.shutdown()
        throw error
    }
}

/// Empties the fixture tables so each test starts from a known state.
func cleanTables(_ source: PostgresDataSource) async throws {
    try await source.withConnection { connection in
        _ = try await connection.query(
            #"TRUNCATE "fdp_transfers", "fdp_accounts", "fdp_users""#,
            logger: .init(label: "test.clean")
        )
    }
}
