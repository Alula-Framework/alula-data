import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import AlulaMigrate
import AlulaDataTesting
import PostgresNIO
import Testing

/// Umbrella for every suite that touches the shared fixture tables.
/// `.serialized` is recursive, so nested suites never interleave — each test
/// TRUNCATEs and reseeds, which only works single-file.
@Suite(.serialized, .enabled(if: TestDatabase.isConfigured))
enum PostgresIntegrationSuite {}

/// Ensures the test schema exists — once per process, through the same
/// `alula migrate` path production uses, so the migrations are
/// exercised on every test run.
actor TestSchema {
    static let shared = TestSchema()
    private var prepared = false

    /// The fixtures' own ledger and lock. They used the default
    /// `alula_migrations`, which `LegacyLedgerTests` drops and recreates on
    /// purpose to stand in for a pre-rename install — in parallel with this
    /// suite, and across runs against a kept database. The fixtures' rows went
    /// with it, the tables stayed, and the next migrate re-created `fdp_users`
    /// and failed with 42P07.
    static let migratorConfiguration: AlulaMigrator.Configuration = {
        var configuration = AlulaMigrator.Configuration()
        configuration.migrationsTable = "fdp_fixture_migrations"
        configuration.advisoryLockKey = 0x6664_705F_6669_7874  // "fdp_fixt"
        return configuration
    }()

    func ensure() async throws {
        guard !prepared else { return }
        // Fixture tables with no ledger of their own were left by a run that
        // recorded them in the shared default one: start them over.
        let source = try PostgresDataSource(settings: try TestDatabase.settings(poolSize: 1))
        try await source.start()
        do {
            try await source.withRepo { repo in
                _ = try await repo.execute(
                    #"""
                    DO $$ BEGIN
                      IF to_regclass('fdp_fixture_migrations') IS NULL THEN
                        DROP TABLE IF EXISTS "fdp_transfers", "fdp_accounts", "fdp_users" CASCADE;
                      END IF;
                    END $$
                    """#)
            }
        } catch {
            await source.shutdown()
            throw error
        }
        await source.shutdown()
        try await PostgresMigrations.migrate(
            configuration: try TestDatabase.configuration(),
            migrations: TestMigrations.all,
            migratorConfiguration: Self.migratorConfiguration
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
