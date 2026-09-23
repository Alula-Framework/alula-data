import Testing

@testable import AlulaMigrate
import AlulaMigrateCore

/// A database migrated before the rename to Alula keeps its ledger in
/// `flight_migrations` (D45). These pin that it is adopted, not forgotten: forgetting
/// it would re-run every applied migration against a populated schema.
@Suite("Pre-rename ledger")
struct LegacyLedgerTests {
    let lockKey = AlulaMigrator.defaultAdvisoryLockKey
    let rename = "ALTER TABLE \"flight_migrations\" RENAME TO \"alula_migrations\""

    @Test func migrateRenamesTheLegacyLedgerAndAppliesOnlyWhatIsNew() async throws {
        let db = FakeDatabase(legacyTable: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrator = makeMigrator(
            database: db,
            migrations: [
                entry(1, "CreateAlpha", CreateAlpha.self),
                entry(2, "CreateBeta", CreateBeta.self),
            ])

        let applied = try await migrator.migrate()

        #expect(applied.map(\.version) == [2])
        #expect(await db.appliedVersions() == [1, 2])
        #expect(await db.tableCreated)
        #expect(await !db.legacyTable)
        let ops = await db.transcript
        #expect(
            Array(ops.prefix(5)) == [
                .acquireLock(lockKey),
                .tableExists, .tableExists,  // alula_migrations, then flight_migrations
                .execute(rename),
                .fetchApplied,
            ])
        #expect(!ops.contains(.createTable))
    }

    @Test func statusReadsTheLegacyLedgerWithoutMovingIt() async throws {
        let db = FakeDatabase(legacyTable: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        let status = try await migrator.status()

        #expect(status.isUpToDate)
        #expect(await db.legacyTable)
        #expect(await db.transcript == [.tableExists, .tableExists, .fetchApplied])
    }

    @Test func rollbackAndRepairAdoptItToo() async throws {
        for operation in ["rollback", "repair"] {
            let db = FakeDatabase(legacyTable: true, seededRows: [appliedRow(1, "CreateAlpha")])
            let migrator = makeMigrator(
                database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

            if operation == "rollback" {
                _ = try await migrator.rollback()
            } else {
                _ = try await migrator.repair()
            }

            #expect(await !db.legacyTable, "\(operation)")
            #expect(await db.transcript.contains(.execute(rename)), "\(operation)")
        }
    }

    @Test func anExistingAlulaLedgerWins() async throws {
        let db = FakeDatabase(
            tableCreated: true, legacyTable: true, seededRows: [appliedRow(1, "CreateAlpha")])
        let migrator = makeMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)])

        _ = try await migrator.migrate()

        #expect(await db.legacyTable)  // left alone: someone has both, and chose
        #expect(
            await db.transcript == [
                .acquireLock(lockKey), .tableExists, .fetchApplied, .releaseLock(lockKey),
            ])
    }

    @Test func aConfiguredTableNeverLooksForTheLegacyOne() async throws {
        let db = FakeDatabase(legacyTable: true)
        var configuration = AlulaMigrator.Configuration()
        configuration.migrationsTable = "ops.ledger"
        let migrator = AlulaMigrator(
            database: db, migrations: [entry(1, "CreateAlpha", CreateAlpha.self)],
            configuration: configuration)

        _ = try await migrator.migrate()

        #expect(await db.legacyTable)
        let ops = await db.transcript
        #expect(ops.filter { $0 == .tableExists }.count == 1)
        #expect(ops.contains(.createTable))
    }

    /// Both values are what pre-rename versions wrote and waited on; a deploy of
    /// this version must agree with one still running the old.
    @Test func persistedIdentifiersAreFrozen() {
        #expect(MigrationChecksum.domainPrefix == "flight-migrate:v1")
        #expect(AlulaMigrator.defaultAdvisoryLockKey == Int64(0x464C_4947_4854_4D47))
        #expect(AlulaMigrator.legacyMigrationsTable == "flight_migrations")
    }
}

extension IntegrationTests {
    /// The rename is real DDL, so the fake cannot vouch for it: a pre-rename ledger in
    /// Postgres is renamed in place and its rows keep verifying.
    @Test func preRenameLedgerIsAdoptedByADefaultConfiguredRun() async throws {
        try await withTestClient { client in
            let tables = ["it_team_members", "it_teams", "it_users"]
            let legacy = AlulaMigrator.legacyMigrationsTable
            let current = AlulaMigrator.defaultMigrationsTable
            try await cleanup(client, ledger: legacy, tables: tables)
            try await exec(client, "DROP TABLE IF EXISTS \(current) CASCADE")

            // What a pre-rename version left behind: its default ledger, lock and checksums.
            var before = testConfiguration(ledger: legacy)
            before.advisoryLockKey = AlulaMigrator.defaultAdvisoryLockKey
            _ = try await AlulaMigrator(
                client: client, migrations: [entry(1, "ITCreateUsers", ITCreateUsers.self)],
                configuration: before
            ).migrate()

            var after = testConfiguration(ledger: current)
            after.advisoryLockKey = AlulaMigrator.defaultAdvisoryLockKey
            let migrator = AlulaMigrator(
                client: client,
                migrations: [
                    entry(1, "ITCreateUsers", ITCreateUsers.self),
                    entry(2, "ITCreateTeams", ITCreateTeams.self),
                ],
                configuration: after)

            #expect(try await migrator.status().pending.map(\.version) == [2])
            #expect(try await tableExists(client, legacy))  // status did not move it

            let applied = try await migrator.migrate()
            #expect(applied.map(\.version) == [2])
            #expect(try await !tableExists(client, legacy))
            #expect(try await scalarInt(client, "SELECT count(*) FROM \(current)") == 2)
            #expect(try await migrator.status().isUpToDate)

            _ = try await migrator.rollback(to: 0)
            try await cleanup(client, ledger: current, tables: tables)
        }
    }
}
