import AlulaCore
import AlulaDataCore
import Foundation
import Hangar
import PostgresNIO
import Testing

@testable import AlulaDataPostgres

// A connection returned to the pool while a transaction is still open must
// not reach the next borrower with it. The pool had the machinery — roll such
// a connection back before reuse — but nothing told it a transaction was
// open once transactions moved into Hangar, so with reset_on_release: false
// the next scope inherited the open transaction (found by an external audit).
// Hangar's TransactionObserver is the seam; withRepo wires it.

private func waitForFreeConnection(_ source: PostgresDataSource) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while source.availableConnections == 0 {
        guard ContinuousClock.now < deadline else {
            Issue.record("pool never returned a connection")
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
}

extension PostgresIntegrationSuite {
    @Suite("An open transaction never reaches the next borrower")
    struct TransactionLeakTests {
        @Test("a connection released mid-transaction is rolled back first, even without the session reset")
        func leakedTransactionIsRolledBack() async throws {
            try await withPostgresContainer(poolSize: 1, resetOnRelease: false) { _, source in
                let key = "leak-\(UUID().uuidString)"
                // A scope that dies between BEGIN and COMMIT: the observer has
                // heard "began" and never "ended".
                let connection = try await source.checkout(waitingUpTo: .seconds(5))
                source.transactionObserver(for: connection).began()
                _ = try await connection.query("BEGIN", logger: .init(label: "t"))
                _ = try await connection.query(
                    """
                    INSERT INTO fdp_users (id, email, "lastName", age, "createdAt")
                    VALUES (\(UUID()), \(key), 'leaked', 1, now())
                    """, logger: .init(label: "t"))
                source.release(connection)
                try await waitForFreeConnection(source)

                // Pool of one: the next scope gets the same connection.
                try await source.withRepo { repo in
                    for try await xid in try await repo.execute(
                        "SELECT count(*)::int FROM pg_stat_activity WHERE pid = pg_backend_pid() AND backend_xid IS NOT NULL"
                    ).decode(Int.self) {
                        #expect(xid == 0, "the next borrower is inside the previous scope's transaction")
                    }
                    for try await rows in try await repo.execute(
                        "SELECT count(*)::int FROM fdp_users WHERE email = \(key)"
                    ).decode(Int.self) {
                        #expect(rows == 0, "the leaked transaction's write survived")
                    }
                }
            }
        }

        @Test("withRepo's transactions are reported to the pool, and closed when they end")
        func withRepoReportsTransactions() async throws {
            try await withPostgresContainer(poolSize: 1, resetOnRelease: false) { _, source in
                try await source.withRepo { repo in
                    try await repo.transaction { tx in
                        #expect(source.openTransactionCount == 1)
                        _ = try await tx.execute("SELECT 1").collect()
                    }
                    #expect(source.openTransactionCount == 0)
                    await #expect(throws: (any Error).self) {
                        try await repo.transaction { tx in
                            _ = try await tx.execute("SELECT 1/0").collect()
                        }
                    }
                    #expect(source.openTransactionCount == 0, "a failed transaction is closed too")
                }
            }
        }
    }
}
