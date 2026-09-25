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
    var parts = ["\(psql.code)"]
    if let underlying = psql.underlying { parts.append("\(underlying)") }
    return parts.joined(separator: ": ")
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
