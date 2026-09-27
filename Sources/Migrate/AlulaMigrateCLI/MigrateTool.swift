import AlulaMigrate

/// The entry point for a project's migrate executable.
///
/// A consumer's whole `main.swift` is:
///
/// ```swift
/// import AlulaMigrate
/// import AlulaMigrateCLI
/// import Migrations   // the target with AlulaMigratePlugin attached
///
/// @main
/// struct Migrate: MigrateTool {
///     static var migrations: [MigrationEntry] { _allMigrations() }
/// }
/// ```
///
/// which yields the full CLI:
///
/// ```
/// migrate                      # apply all pending
/// migrate apply --dry-run      # print the SQL, change nothing
/// migrate status [--json]
/// migrate rollback [--steps N | --to VERSION]
/// migrate create CreateUsers
/// migrate repair
/// ```
///
/// The database URL comes from `--database-url`, `$ALULA_DATABASE_URL`,
/// `$DATABASE_URL`, or else `datasource.primary.url` in the application's
/// `alula.yaml` (`--datasource` and `--config-directory` choose another
/// datasource and directory). Migrations are **not** run automatically at
/// boot; running this binary is a deliberate, observable deploy step.
public protocol MigrateTool {
    /// The registered migrations — normally the generated `_allMigrations()`.
    static var migrations: [MigrationEntry] { get }
}

extension MigrateTool {
    public static func main() async {
        MigrationRegistry.set(migrations)
        await RootCommand.main()
    }
}
