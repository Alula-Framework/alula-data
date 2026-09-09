import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import Testing

/// The properties that only a live pool can prove: per-operation lease and
/// return-to-pool, pool exhaustion, liveness, and repositories wired through
/// the real `@Repository`/`@Inject` macro path.
///
/// This suite used to open a `Scope` per test and resolve the repository in
/// it, because resolving was what checked a connection out. Resolving a
/// repository now takes nothing from the pool — it is a singleton holding the
/// pool — so the lease boundary is the operation, and the assertions move to
/// where the work actually happens.
extension PostgresIntegrationSuite {
@Suite("Pooled connections against Postgres")
struct ScopingIntegrationTests {
    @Test func repositoryFindsInsertedRows() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let user = User(
                id: UUID(), email: "ada@example.com", lastName: "Lovelace", age: 36,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                profile: Profile(bio: "first programmer", loginCount: 1),
                nickname: nil)

            let repo = app.users
            try await repo.insert(user)
            let found = try await repo.find(byEmail: "ada@example.com")
            #expect(found == user)
            #expect(try await repo.find(byEmail: "nobody@example.com") == nil)
        }
    }

    @Test func designDocExampleTest() async throws {
        // example test, verbatim in behavior: unknown email → nil. It is
        // shorter now — no scope to open, because there is no lifetime to
        // manage on the way to a repository.
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let repo = app.users
            #expect(try await repo.find(byEmail: "nobody@example.com") == nil)
        }
    }

    /// What `scopeCloseReturnsConnectionToPool` was really defending, at its
    /// new boundary: the lease is the operation, and it ends when the
    /// operation does.
    @Test func operationReturnsConnectionToPool() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let repo = app.users

            #expect(source.activeCheckouts == 0, "resolving a repository takes nothing")

            _ = try await repo.find(byEmail: "nobody@example.com")
            #expect(source.activeCheckouts == 0, "the operation gave its connection back")

            // The returned connection is reused, not replaced.
            let before = source.totalCheckouts
            _ = try await repo.find(byEmail: "nobody@example.com")
            #expect(source.totalCheckouts == before + 1, "one lease per operation")
            #expect(source.establishedConnections == source.poolSize)
        }
    }

    /// One bracket is one lease however many statements run inside it — the
    /// replacement for what request-scoped pinning used to give implicitly,
    /// now said out loud by the code that wants it.
    @Test func oneBracketIsOneLease() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let pool = app.pool
            let before = source.totalCheckouts

            try await pool.withRepo { repo in
                _ = try await repo.count(User.all)
                _ = try await repo.count(User.all)
                #expect(source.activeCheckouts == 1)
            }

            #expect(source.totalCheckouts == before + 1, "two queries, one lease")
            #expect(source.activeCheckouts == 0)
        }
    }

    @Test func exhaustedPoolThrowsPromptly() async throws {
        try await withPostgresContainer(poolSize: 1) { app, source in
            let pool = app.pool
            // Hold the only connection, then ask for another from inside the
            // bracket. Prompt error, never parking (Flight Data Core D1).
            try await pool.withConnection { _ in
                #expect(source.activeCheckouts == 1)
                #expect(throws: DataSourceError.poolExhausted(datasource: "primary", poolSize: 1)) {
                    _ = try source.checkout()
                }
            }
            #expect(source.activeCheckouts == 0)
        }
    }

    @Test func livenessProbeAnswers() async throws {
        try await withPostgresContainer { app, _ in
            // The value form: the probe the module provides, rather than one
            // discovered through container introspection.
            #expect(app.liveness.datasourceName == "primary")
            try await app.liveness.ping()
        }
    }

    @Test func closedPoolRefusesCheckout() async throws {
        try await withPostgresContainer { app, source in
            await source.shutdown()
            #expect(throws: DataSourceError.closed(datasource: "primary")) {
                _ = try source.checkout()
            }
        }
    }
}
}
