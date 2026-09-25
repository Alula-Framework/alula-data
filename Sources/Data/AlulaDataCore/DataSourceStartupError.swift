import AlulaCore

/// A datasource could not establish its connections at startup.
///
/// Alula prints a startup failure's ``StartupDiagnostic/startupDiagnostic``,
/// and no longer its reflected form — which for a database error can carry
/// secrets. A driver's own error is too quiet on its own: PostgresNIO's
/// `PSQLError` describes itself as a generic "prevent accidental leakage"
/// placeholder, so a refused connection used to print as nothing useful. This
/// says what an operator needs — which datasource, where it was dialling,
/// and what the network or server answered — and never the URL, the
/// username's password, or anything else from the connection string beyond
/// host, port and database.
public struct DataSourceStartupError: Error, StartupDiagnostic, CustomStringConvertible {
    /// The datasource's configured name.
    public let datasource: String
    /// `postgres` or `valkey`.
    public let backend: String
    public let host: String
    public let port: Int
    /// The database name, or a Valkey database number.
    public let database: String
    /// What went wrong, rendered without secrets.
    public let cause: String
    /// The driver's error, for code that wants it deliberately.
    public let underlying: any Error

    public init(
        datasource: String, backend: String, host: String, port: Int, database: String, cause: String,
        underlying: any Error
    ) {
        self.datasource = datasource
        self.backend = backend
        self.host = host
        self.port = port
        self.database = database
        self.cause = cause
        self.underlying = underlying
    }

    public var startupDiagnostic: String {
        "datasource '\(datasource)' could not connect to \(backend) at \(host):\(port), database '\(database)': \(cause)"
    }

    public var description: String { startupDiagnostic }
}
