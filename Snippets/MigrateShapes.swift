// The API shapes Docs/migrate.md shows, compiled by the build.
//
// A page that shows an API is a claim about it. Each block below is the
// page's example as written, wrapped only as far as it takes to compile: a
// migration body inside a `Migration`, a library call inside a function.
// Where the page relies on something generated at build time
// (`_allMigrations()`, from AlulaMigratePlugin), a stand-in with the same
// signature takes its place.
import AlulaMigrate
import AlulaMigrateCLI
import PostgresNIO

/// Stands in for the registry AlulaMigratePlugin generates.
func _allMigrations() -> [MigrationEntry] { [] }

// "Installation": the migrate executable. The page marks it `@main`; a
// snippet is compiled as its own executable, so the attribute is left off.
struct Migrate: MigrateTool {
    static var migrations: [MigrationEntry] { _allMigrations() }
}

// "Writing migrations".
struct CreateUsers: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("users") { t in
            t.uuid("id").primaryKey().default(.raw("gen_random_uuid()"))
            t.text("email").notNull().unique()
            t.timestamptz("created_at").notNull().default(.now)
        }
    }

    func down(_ schema: SchemaBuilder) {
        schema.dropTable("users")
    }
}

// "The DSL", every call the page lists.
struct DSLTour: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("teams", ifNotExists: false) { t in
            t.bigint("id").generatedAlwaysAsIdentity().primaryKey()
            t.text("name").notNull().unique()
            t.uuid("owner_id").notNull().references("users", onDelete: .cascade)
            t.jsonb("settings").notNull().default(.raw("'{}'::jsonb"))
            t.integer("seats").notNull().default(5).check("seats > 0")
            t.timestamps()
            t.primaryKey(["a", "b"])
            t.unique(["a", "b"], name: "teams_ab_key")
            t.foreignKey(["a"], references: "other", ["x"], onDelete: .restrict)
        }

        schema.alterTable("users") { t in
            t.text("bio")
            t.dropColumn("legacy", ifExists: true)
            t.renameColumn("email", to: "email_address")
            t.setDefault("bio", .string(""))
            t.setNotNull("bio")
            t.setDataType("count", .bigint, using: "count::bigint")
            t.addUnique(["email_address"])
            t.dropConstraint("old_check", ifExists: true)
        }

        schema.createIndex(on: "users", columns: ["email"], unique: true)
        schema.dropIndex("users_email_idx")
        schema.renameTable("old", to: "new")
        schema.dropTable("users", ifExists: true, cascade: true)
        schema.createExtension("pgcrypto")
    }

    func down(_ schema: SchemaBuilder) {}
}

// The column types the page names.
struct ColumnTypes: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createTable("everything") { t in
            t.uuid("a")
            t.text("b")
            t.varchar("c", limit: 40)
            t.char("d", limit: 2)
            t.smallint("e")
            t.integer("f")
            t.bigint("g")
            t.boolean("h")
            t.real("i")
            t.doublePrecision("j")
            t.numeric("k", precision: 10, scale: 2)
            t.date("l")
            t.time("m")
            t.timestamp("n")
            t.timestamptz("o")
            t.interval("p")
            t.json("q")
            t.jsonb("r")
            t.bytea("s")
            t.inet("u")
            t.column("v", .array(of: .text))
            t.column("w", .custom("tsvector"))
        }
    }

    func down(_ schema: SchemaBuilder) {}
}

// "Raw SQL is first-class, not a leak".
struct BackfillPlan: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.alterTable("users") { t in t.text("plan") }
        schema.raw("UPDATE users SET plan = 'free' WHERE plan IS NULL")
        schema.alterTable("users") { t in t.setNotNull("plan") }
    }

    func down(_ schema: SchemaBuilder) {}
}

// "Migrations that can't run in a transaction".
struct AddUsersEmailIndex: Migration {
    static let wrapInTransaction = false

    func up(_ schema: SchemaBuilder) {
        schema.createIndex(on: "users", columns: ["email"], concurrently: true)
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropIndex("users_email_idx", concurrently: true)
    }
}

// "As a library", and "Testing your migrations".
func migrateLibraryShapes(postgresClient: PostgresClient, testClient: PostgresClient) async throws {
    let migrator = AlulaMigrator(client: postgresClient, migrations: _allMigrations())
    try await migrator.migrate()

    let status = try await migrator.status()
    let plan = try await migrator.planMigrate()
    let undone = try await migrator.rollback(steps: 1)
    let repairs = try await migrator.repair()
    _ = (status, plan, undone, repairs)

    // The Configuration knobs the page lists, by name.
    var configuration = AlulaMigrator.Configuration()
    configuration.migrationsTable = "ops.alula_migrations"
    configuration.advisoryLockKey = AlulaMigrator.defaultAdvisoryLockKey
    configuration.lockTimeout = nil
    configuration.failOnUnknownApplied = true
    configuration.onEvent = { event in _ = event }

    let testMigrator = AlulaMigrator(
        client: testClient,
        migrations: _allMigrations(),
        configuration: .init(migrationsTable: "test_ledger")
    )
    try await testMigrator.migrate()
}
