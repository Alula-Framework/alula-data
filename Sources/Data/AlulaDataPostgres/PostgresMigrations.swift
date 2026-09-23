import AlulaCore
import AlulaDataCore
import AlulaMigrate
import Logging
import PostgresNIO

/// The wiring — and nothing more. Migrations themselves are Alula
/// Migrate's: plain `Migration` types, each applied in its own transaction,
/// tracked in `alula_migrations`, run as a deliberate step (`alula
/// migrate` / a migrate binary), never automatically at boot. This package
/// only connects that machinery to the datasource URL resolved from Alula
/// Config.
///
/// The test suite uses the same path to prepare its schema: migrations
/// are exercised on every test run, with no separate schema-setup mechanism.
public enum PostgresMigrations {
    /// Runs `body` with a `AlulaMigrator` wired to the datasource's URL. A
    /// short-lived `PostgresClient` runs for the duration — the migrator is
    /// a deploy-step tool, deliberately independent of the serving pool.
    public static func withMigrator<T: Sendable>(
        settings: DataSourceSettings,
        migrations: [MigrationEntry],
        configuration: AlulaMigrator.Configuration = AlulaMigrator.Configuration(),
        _ body: @Sendable @escaping (AlulaMigrator) async throws -> T
    ) async throws -> T {
        let url = try PostgresDataSourceURL.parse(settings.url, datasource: settings.name)
        let client = PostgresClient(configuration: try url.clientConfiguration())
        return try await withThrowingTaskGroup(of: Void.self, returning: T.self) { group in
            group.addTask { await client.run() }
            defer { group.cancelAll() }
            let migrator = AlulaMigrator(
                client: client, migrations: migrations, configuration: configuration)
            return try await body(migrator)
        }
    }

    /// Applies all pending migrations for a configured datasource:
    ///
    /// ```swift
    /// try await PostgresMigrations.migrate(
    ///     configuration: try Configuration.load(),
    ///     migrations: _allMigrations()   // the AlulaMigratePlugin registry
    /// )
    /// ```
    @discardableResult
    public static func migrate(
        configuration: Configuration,
        datasource name: String = PrimaryDataSource.name,
        migrations: [MigrationEntry],
        migratorConfiguration: AlulaMigrator.Configuration = AlulaMigrator.Configuration()
    ) async throws -> [AppliedMigration] {
        let settings = try DataSourceSettings.load(name: name, from: configuration)
        return try await withMigrator(
            settings: settings, migrations: migrations, configuration: migratorConfiguration
        ) { migrator in
            try await migrator.migrate()
        }
    }
}
