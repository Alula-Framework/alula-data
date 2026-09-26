import AlulaMigrate
import Hangar
import PostgresNIO

/// What is safe and useful to log about a failure talking to Postgres.
///
/// `"\(error)"` on a `PSQLError` is PostgresNIO's deliberately opaque
/// "Generic description to prevent accidental leakage of sensitive data",
/// so a reconnect warning could not say whether the server refused the
/// connection, rejected the password, or was still starting up (Relay #34).
/// This says, without the parts that can carry data:
///
/// - a server error as Hangar's ``DatabaseError`` describes it — SQLSTATE,
///   kind, table, constraint and column names, never the server's text —
///   plus the plain meaning of the SQLSTATEs a connection meets;
/// - a connection failure as PostgresNIO's error code and the underlying
///   system error (`connection refused`, `connection reset by peer`).
package func loggableFailure(_ error: any Error) -> String {
    guard let psql = error as? PSQLError else { return "\(error)" }
    if let database = DatabaseError(psql) {
        guard let meaning = connectionMeaning[database.sqlState] else { return database.description }
        return "\(meaning): \(database.description)"
    }
    guard let underlying = psql.underlying else { return "\(psql.code)" }
    let text = "\(underlying)"
    let readable = readableConnectionFailure(text)
    return readable == text ? "\(psql.code): \(text)" : readable
}

/// SQLSTATEs a connection or a pooled session meets, in words an operator
/// acts on. Anything else is described by its SQLSTATE and kind alone.
private let connectionMeaning: [String: String] = [
    "28P01": "authentication failed",
    "28000": "authorization failed",
    "3D000": "the database does not exist",
    "57P03": "the database is starting up",
    "57P01": "the server is shutting down",
    "53300": "too many connections",
    "08006": "the connection failed",
    "08001": "the server refused the connection",
]

/// A `PSQLError` rethrown with a description worth reading.
///
/// Hangar turns a failed statement into its `DatabaseError`, but an error
/// raised while rows stream, or by the connection itself, reaches the caller
/// as PostgresNIO's `PSQLError`, whose description is deliberately opaque. The
/// queue worker logged exactly that — "Generic description to prevent
/// accidental leakage…" — for "could not claim jobs" (Relay #43). Framework
/// code that owns such a call and only reports its failure throws this
/// instead: the same safe summary as ``loggableFailure(_:)``, with the
/// original kept for anyone who needs to match on it.
package struct PostgresFailure: Error, CustomStringConvertible {
    package let underlying: PSQLError
    package var description: String { loggableFailure(underlying) }
}

/// Runs `body`, rethrowing a `PSQLError` as a ``PostgresFailure``.
package func describingPostgresFailures<T>(
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async throws -> T {
    do {
        return try await body()
    } catch let psql as PSQLError {
        throw PostgresFailure(underlying: psql)
    }
}
