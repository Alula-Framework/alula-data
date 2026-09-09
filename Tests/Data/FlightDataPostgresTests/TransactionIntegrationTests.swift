import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import Testing

/// Transactions against a real server: Hangar's `repo.transaction { }` driving
/// BEGIN/COMMIT/ROLLBACK — and SAVEPOINTs when nested — on a leased
/// connection.
///
/// This suite used to cover `@Transactional`'s expansion against the scope's
/// connection. What is under test is unchanged in substance — commit on
/// return, roll back on throw, a nested failure rolling back to its savepoint
/// only — but the boundary is now opened explicitly by the repository (see
/// `LedgerRepository` in Support/Fixtures.swift) rather than implied by an
/// annotation plus an ambient coordinator.
///
/// Two former tests went with the mechanism they covered: one drove
/// transaction control by hand through `PostgresTransactionCoordinator`, and
/// one pinned that an unbound coordinator left `@Transactional` inert. There
/// is no ambient coordinator left to bind or leave unbound. The
/// rollback-on-release property the first of those also touched is covered by
/// `SessionIsolationTests`, which tests `resetOnRelease` directly.
extension PostgresIntegrationSuite {
@Suite("Transactions against Postgres")
struct TransactionIntegrationTests {
    private func seedAccounts(_ app: PostgresTestApp, balances: [String: Int]) async throws {
        let ledger = app.ledger
        for (id, balance) in balances {
            try await ledger.seed(Account(id: id, balance: balance))
        }
    }

    @Test func successfulTransferCommits() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            try await seedAccounts(app, balances: ["checking": 100, "savings": 0])

            let ledger = app.ledger
            try await ledger.transfer(40, from: "checking", to: "savings")

            // Read back on a fresh lease — very likely a different connection
            // — so the commit reached the server rather than being visible
            // only to the connection that wrote it.
            #expect(try await ledger.balance(of: "checking") == 60)
            #expect(try await ledger.balance(of: "savings") == 40)
        }
    }

    @Test func thrownErrorRollsBackEverything() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            try await seedAccounts(app, balances: ["checking": 100, "savings": 0])

            let ledger = app.ledger
            await #expect(throws: LedgerError.insufficientFunds(account: "deliberate-failure")) {
                try await ledger.transferThenFail(40, from: "checking", to: "savings")
            }

            #expect(try await ledger.balance(of: "checking") == 100)
            #expect(try await ledger.balance(of: "savings") == 0)
            #expect(try await ledger.allTransfers().isEmpty)
        }
    }

    @Test func nestedFailureRollsBackToSavepointOnly() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            try await seedAccounts(app, balances: ["checking": 100, "savings": 0])

            let ledger = app.ledger
            // The middle transfer exceeds the balance: its savepoint rolls
            // back while the outer transaction and its siblings commit.
            let applied = try await ledger.batchTransfer([
                (amount: 30, from: "checking", to: "savings"),
                (amount: 1_000, from: "checking", to: "savings"),
                (amount: 20, from: "checking", to: "savings"),
            ])
            #expect(applied == 2)

            #expect(try await ledger.balance(of: "checking") == 50)
            #expect(try await ledger.balance(of: "savings") == 50)
            #expect(try await ledger.allTransfers().count == 2)
        }
    }

    /// Isolation: work inside an open transaction is invisible to anything on
    /// another connection until it commits.
    ///
    /// Worth keeping deliberately. With connections leased per operation
    /// rather than pinned per request, concurrent work lands on different
    /// connections more often than it used to, so this property is exercised
    /// more — not less.
    @Test func uncommittedWorkIsInvisibleToOtherConnections() async throws {
        struct RollbackProbe: Error {}

        try await withPostgresContainer(poolSize: 4) { app, source in
            try await cleanTables(source)
            try await seedAccounts(app, balances: ["checking": 100, "savings": 0])

            let ledger = app.ledger
            let pool = app.pool

            do {
                try await pool.withRepo { repo in
                    try await repo.transaction { tx in
                        var account = try #require(
                            try await tx.one(Account.where { $0.id == "checking" }))
                        account.balance -= 40
                        try await tx.update(account)

                        // `ledger` takes its own lease — a second connection —
                        // which must not see the uncommitted debit.
                        #expect(try await ledger.balance(of: "checking") == 100)

                        // Abandon, so the debit never lands.
                        throw RollbackProbe()
                    }
                }
            } catch is RollbackProbe {
                // Expected: the throw is what triggers the rollback.
            }

            #expect(try await ledger.balance(of: "checking") == 100, "the debit rolled back")
        }
    }
}
}
