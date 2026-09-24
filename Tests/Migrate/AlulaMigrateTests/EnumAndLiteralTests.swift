import Foundation
import Logging
import PostgresNIO
import Testing

@testable import AlulaMigrate

// Migrations could not declare an enum type except through raw SQL, nor add
// a value — the operation sql-kit gets wrong by keeping only the last of
// several (#138) — and nothing tested that Postgres refuses to use a value
// added in the same transaction. A `.double` default of NaN or infinity
// rendered as `nan`/`inf`, which is not SQL. And a string literal holding a
// backslash meant different text depending on standard_conforming_strings.

@Suite("SchemaBuilder: enums, float defaults, literals")
struct EnumDSLTests {
    @Test func enumStatements() {
        let schema = SchemaBuilder()
        schema.createEnum("mood", values: ["happy", "it's"])
        schema.addEnumValues("mood", ["sad", "calm"])
        schema.addEnumValue("mood", "ok", ifNotExists: false, before: "sad")
        schema.renameEnumValue("mood", from: "calm", to: "serene")
        schema.dropEnum("mood", ifExists: true, cascade: true)
        #expect(
            schema.statements == [
                #"CREATE TYPE "mood" AS ENUM ('happy', 'it''s')"#,
                #"ALTER TYPE "mood" ADD VALUE IF NOT EXISTS 'sad'"#,
                #"ALTER TYPE "mood" ADD VALUE IF NOT EXISTS 'calm'"#,
                #"ALTER TYPE "mood" ADD VALUE 'ok' BEFORE 'sad'"#,
                #"ALTER TYPE "mood" RENAME VALUE 'calm' TO 'serene'"#,
                #"DROP TYPE IF EXISTS "mood" CASCADE"#,
            ])
    }

    @Test func floatDefaults() {
        #expect(DefaultValue.double(.nan).sql == "'NaN'")
        #expect(DefaultValue.double(.infinity).sql == "'Infinity'")
        #expect(DefaultValue.double(-.infinity).sql == "'-Infinity'")
        #expect(DefaultValue.double(1.5).sql == "1.5")
    }

    @Test func backslashLiterals() {
        #expect(SQL.stringLiteral("plain") == "'plain'")
        #expect(SQL.stringLiteral("it's") == "'it''s'")
        #expect(SQL.stringLiteral(#"a\b"#) == #"E'a\\b'"#)
    }
}

struct ITMoodCreate: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.createEnum("it_mood", values: ["happy"])
        schema.createTable("it_moods") { t in
            t.integer("id").primaryKey()
            t.column("mood", .enumeration("it_mood")).notNull()
            t.doublePrecision("score").notNull().default(.double(.nan))
        }
    }
    func down(_ schema: SchemaBuilder) {
        schema.dropTable("it_moods")
        schema.dropEnum("it_mood")
    }
}

struct ITMoodAdd: Migration {
    func up(_ schema: SchemaBuilder) { schema.addEnumValues("it_mood", ["sad", "calm"]) }
    func down(_ schema: SchemaBuilder) {}
}

struct ITMoodUseNew: Migration {
    func up(_ schema: SchemaBuilder) { schema.raw("INSERT INTO it_moods (id, mood) VALUES (1, 'calm')") }
    func down(_ schema: SchemaBuilder) { schema.raw("DELETE FROM it_moods") }
}

struct ITMoodAddAndUse: Migration {
    func up(_ schema: SchemaBuilder) {
        schema.addEnumValue("it_mood", "angry")
        schema.raw("INSERT INTO it_moods (id, mood) VALUES (2, 'angry')")
    }
    func down(_ schema: SchemaBuilder) {}
}

extension IntegrationTests {
    @Test func enumLifecycleAndTheSameTransactionTrap() async throws {
        try await withTestClient { client in
            let ledger = scopedLedger("enums")
            try await cleanup(client, ledger: ledger, tables: ["it_moods"])
            try await exec(client, "DROP TYPE IF EXISTS it_mood")
            let configuration = testConfiguration(ledger: ledger)
            let migrations = [
                entry(1, "ITMoodCreate", ITMoodCreate.self),
                entry(2, "ITMoodAdd", ITMoodAdd.self),
                entry(3, "ITMoodUseNew", ITMoodUseNew.self),
            ]
            _ = try await AlulaMigrator(client: client, migrations: migrations, configuration: configuration).migrate()
            #expect(try await scalarInt(client, "SELECT count(*) FROM pg_enum e JOIN pg_type t ON t.oid = e.enumtypid WHERE t.typname = 'it_mood'") == 3)
            #expect(try await scalarBool(client, "SELECT score = 'NaN' FROM it_moods WHERE id = 1"), "the NaN default applied")

            // Adding a value and using it in one wrapped migration is the trap:
            // Postgres refuses the use until the addition commits.
            let trap = migrations + [entry(4, "ITMoodAddAndUse", ITMoodAddAndUse.self)]
            await #expect(throws: (any Error).self) {
                _ = try await AlulaMigrator(client: client, migrations: trap, configuration: configuration).migrate()
            }
            #expect(try await scalarInt(client, "SELECT count(*) FROM it_moods") == 1, "the failed migration left nothing")

            try await exec(client, "DROP TABLE it_moods")
            try await exec(client, "DROP TYPE it_mood")
            try await exec(client, "DROP TABLE IF EXISTS \(ledger)")
        }
    }

    @Test func literalsMeanTheSameWhateverStandardConformingStringsSays() async throws {
        try await withTestClient { client in
            // Exhaustive rather than sampled: every string of up to five
            // characters over backslash, quote and a letter — 364 of them.
            var texts = [""]
            var frontier = [""]
            for _ in 0..<5 {
                frontier = frontier.flatMap { prefix in ["\\", "'", "a"].map { prefix + $0 } }
                texts += frontier
            }
            for text in texts {
                for setting in ["on", "off"] {
                    let back: String = try await client.withConnection { connection in
                        _ = try await connection.query(PostgresQuery(unsafeSQL: "SET standard_conforming_strings = \(setting)"), logger: Logger(label: "test"))
                        let rows = try await connection.query(PostgresQuery(unsafeSQL: "SELECT \(SQL.stringLiteral(text))::text"), logger: Logger(label: "test"))
                        var value = "<none>"
                        for try await decoded in rows.decode(String.self) { value = decoded }
                        _ = try await connection.query("RESET standard_conforming_strings", logger: Logger(label: "test"))
                        return value
                    }
                    #expect(back == text, "standard_conforming_strings = \(setting)")
                }
            }
        }
    }
}
