import ExampleMigrations
import AlulaMigrate
import AlulaMigrateCLI

// A complete migrate executable — this is all a consumer writes.
// `_allMigrations()` is generated at build time by AlulaMigratePlugin from the
// ExampleMigrations target.
@main
struct ExampleMigrateTool: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}
