import AlulaCore
import AlulaDataCore
import Hangar
import PostgresNIO

// The Hangar adapter: what makes `repo.all(...)` work inside an Alula
// application. Deliberately thin — Hangar knows nothing about Alula, and
// this file is the entire coupling.
//
// A `Repo` is bound to a connection, and a connection is leased for one
// operation, so a `Repo` is constructed per operation too. `withRepo` is the
// one-liner for that: `withConnection` plus a constructor.
//
// ## What this file used to be, and why it isn't
//
// `Repo` was a `.scoped` component bound to a request-held connection, so a
// Hangar query inside a `@Transactional` method ran *inside* that transaction
// rather than beside it on a different pool connection. That coupling had a
// sharp edge, documented here at length: a `Repo`'s `inTransaction` is fixed
// when the repo is *constructed*, and the ambient repo for a unit of work was
// constructed before the body ran — so it always believed
// `inTransaction == false`, emitted a literal `BEGIN`/`COMMIT` when nested,
// and that `COMMIT` ended the enclosing transaction. Writes the caller
// intended to roll back became durable, silently, with no error anywhere.
// This file's own header called the fix "consult the coordinator per call
// rather than snapshot at construction."
//
// Constructing the repo per operation *is* that fix. There is no ambient repo
// to go stale, and nesting is Hangar's own `transaction { }`, which tracks
// depth itself and emits savepoints. The caution that used to need stating
// twice — never drive transactions through two mechanisms in one unit of work
// — no longer has a second mechanism to warn about.

extension DataSource where Connection == PostgresConnection {
    /// Leases a connection for the duration of `body` and hands it to a
    /// Hangar `Repo`.
    ///
    /// ```swift
    /// let user = try await pool.withRepo { repo in
    ///     try await repo.one(User.where { $0.id == id })
    /// }
    /// ```
    ///
    /// For several statements that must share a transaction, use Hangar's own
    /// bracket inside this one — it owns nesting, isolation level, and
    /// serialization-failure retry:
    ///
    /// ```swift
    /// try await pool.withRepo { repo in
    ///     try await repo.transaction { tx in
    ///         try await tx.insert(order)
    ///         try await tx.update(account)
    ///     }
    /// }
    /// ```
    /// Hangar's ambient `Repo.require()` is bound for the duration of `body`,
    /// so code that cannot take a repo parameter can still reach one. The
    /// binding's extent is exactly this bracket — visible in the code that
    /// opens it, unlike the old arrangement, where a unit of work bound the
    /// ambient repo for its whole duration from inside the framework.
    public func withRepo<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        try await withConnection { connection in
            let repo = Repo(connection: connection)
            return try await Repo.with(repo) {
                try await body(repo)
            }
        }
    }
}
