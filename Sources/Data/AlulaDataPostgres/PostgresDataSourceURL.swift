import Foundation
import NIOSSL
import PostgresNIO

/// The parsed form of `datasource.<name>.url` (Alula Data Core). Alula
/// Data Core has no opinion about URL format; this package's is:
///
///     postgres://user:password@host:5432/database?sslmode=prefer
///
/// - Schemes: `postgres` or `postgresql`.
/// - Port defaults to 5432; user to `postgres`; password to none.
/// - `sslmode`: `disable`, `prefer` (default), `require`, `verify-ca` or
///   `verify-full`, with libpq's meanings (see ``SSLMode``); libpq's `allow`
///   is not accepted. The `verify-*` modes check against the system's trust
///   roots. A private CA bundle does not fit in a URL, and neither does a
///   unix domain socket: both go through
///   `PostgresDataSource(name:configuration:…)`, which takes a
///   `PostgresConnection.Configuration` you built yourself.
///
/// Parsing is eager and loud: a malformed URL throws when the module is built
/// at composition, failing bootstrap before any request is served.
public struct PostgresDataSourceURL: Sendable, Equatable {
    /// `sslmode`, with libpq's meanings.
    ///
    /// These used to be libpq's *names* over different behaviour: `prefer`
    /// and `require` both performed full certificate and hostname
    /// verification. That is stricter than libpq, which is not automatically
    /// better when the name is a promise — `prefer` is the default, so the
    /// out-of-the-box configuration failed against any server with a
    /// self-signed certificate, which is most development and staging
    /// Postgres. Anyone who read the URL and expected libpq got something
    /// else.
    ///
    /// The names mean what they mean everywhere else now, and the two modes
    /// that actually authenticate the server have their real names.
    public enum SSLMode: String, Sendable, Equatable, CaseIterable {
        /// No TLS.
        case disable
        /// TLS if the server offers it, plaintext otherwise. **The server is
        /// not authenticated** — an interceptor can present any certificate.
        case prefer
        /// TLS required. **The server is still not authenticated**, which is
        /// libpq's own long-standing footgun: `require` protects against a
        /// passive listener, not an active one. Use `verify-full` to
        /// authenticate.
        case require
        /// TLS required, and the certificate must chain to a trusted root.
        case verifyCA = "verify-ca"
        /// TLS required, the certificate must chain to a trusted root, and
        /// its name must match the host. The only mode that authenticates the
        /// server; the right choice for anything crossing a network.
        case verifyFull = "verify-full"
    }

    /// The server's host name or address.
    public let host: String
    /// The server's port; 5432 when the URL names none.
    public let port: Int
    /// The role to log in as; `postgres` when the URL names none.
    public let username: String
    /// The password, already percent-decoded; `nil` when the URL has none.
    /// This type has no custom description, so interpolating a whole
    /// `PostgresDataSourceURL` into a log line prints it.
    public let password: String?
    /// The database, from the URL's path.
    public let database: String
    /// How TLS is negotiated and verified.
    public let sslMode: SSLMode

    /// A URL built from its parts, without parsing. The defaults are the
    /// ones ``parse(_:datasource:)`` applies to a URL that omits them.
    public init(
        host: String,
        port: Int = 5432,
        username: String = "postgres",
        password: String? = nil,
        database: String,
        sslMode: SSLMode = .prefer
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.sslMode = sslMode
    }

    /// Parses `datasource.<name>.url`.
    ///
    /// Strict on purpose: an unknown query parameter is an error rather than
    /// ignored, so a misspelled `sslmode` cannot quietly fall back to the
    /// default.
    ///
    /// - Parameters:
    ///   - string: The URL, `postgres://` or `postgresql://`.
    ///   - name: The datasource's name, used only in error messages.
    /// - Throws: `PostgresDataSourceURLError` naming the configuration key.
    public static func parse(_ string: String, datasource name: String) throws -> PostgresDataSourceURL {
        guard let components = URLComponents(string: string) else {
            throw PostgresDataSourceURLError.unparseable(datasource: name)
        }
        guard let scheme = components.scheme?.lowercased(), scheme == "postgres" || scheme == "postgresql" else {
            throw PostgresDataSourceURLError.unsupportedScheme(
                datasource: name, scheme: components.scheme ?? "<none>")
        }
        guard let host = components.host, !host.isEmpty else {
            throw PostgresDataSourceURLError.missingHost(datasource: name)
        }
        let database = String(components.path.dropFirst())
        guard !database.isEmpty, !database.contains("/") else {
            throw PostgresDataSourceURLError.missingDatabase(datasource: name)
        }

        var sslMode = SSLMode.prefer
        for item in components.queryItems ?? [] {
            switch item.name {
            case "sslmode":
                guard let value = item.value, let mode = SSLMode(rawValue: value) else {
                    throw PostgresDataSourceURLError.invalidSSLMode(
                        datasource: name, value: item.value ?? "<none>")
                }
                sslMode = mode
            default:
                // Unknown parameters are rejected rather than ignored: a typo'd
                // `sslmode` must not silently downgrade to the default.
                throw PostgresDataSourceURLError.unsupportedParameter(datasource: name, parameter: item.name)
            }
        }

        return PostgresDataSourceURL(
            host: host,
            port: components.port ?? 5432,
            // `URLComponents.user`/`.password` are already percent-decoded —
            // `percentEncodedUser` is the raw spelling. Decoding again turned
            // a password that legitimately *contains* a percent escape into a
            // different password: `pa%41ss` (written `pa%2541ss` in the URL)
            // silently became `paAss`, and the resulting failure blamed the
            // server. The Valkey parser never had this; this is its reading.
            username: components.user ?? "postgres",
            password: components.password,
            database: database,
            sslMode: sslMode
        )
    }

    /// The single-connection configuration the pool dials with.
    public func connectionConfiguration() throws -> PostgresConnection.Configuration {
        PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: try connectionTLS()
        )
    }

    /// The pooled-client configuration used by the migrate wiring.
    public func clientConfiguration() throws -> PostgresClient.Configuration {
        var configuration = PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: try clientTLS()
        )
        configuration.options.minimumConnections = 0
        return configuration
    }

    /// The TLS settings each mode implies.
    ///
    /// `prefer` and `require` disable verification, matching libpq. The
    /// `verify-*` modes are the ones that check anything.
    private func tlsConfiguration() -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch sslMode {
        case .disable, .prefer, .require:
            configuration.certificateVerification = .none
        case .verifyCA:
            configuration.certificateVerification = .noHostnameVerification
        case .verifyFull:
            configuration.certificateVerification = .fullVerification
        }
        return configuration
    }

    private func connectionTLS() throws -> PostgresConnection.Configuration.TLS {
        switch sslMode {
        case .disable:
            return .disable
        case .prefer:
            return .prefer(try NIOSSLContext(configuration: tlsConfiguration()))
        case .require, .verifyCA, .verifyFull:
            return .require(try NIOSSLContext(configuration: tlsConfiguration()))
        }
    }

    private func clientTLS() throws -> PostgresClient.Configuration.TLS {
        switch sslMode {
        case .disable:
            return .disable
        case .prefer:
            return .prefer(tlsConfiguration())
        case .require, .verifyCA, .verifyFull:
            return .require(tlsConfiguration())
        }
    }
}

/// A `datasource.<name>.url` that resolved from configuration but cannot
/// describe a Postgres connection — the store-specific counterpart of
/// `DataSourceConfigurationError` (Alula Data Core): loud at bootstrap,
/// never at first query.
public enum PostgresDataSourceURLError: Error, Sendable, Equatable, CustomStringConvertible {
    case unparseable(datasource: String)
    case unsupportedScheme(datasource: String, scheme: String)
    case missingHost(datasource: String)
    case missingDatabase(datasource: String)
    case invalidSSLMode(datasource: String, value: String)
    case unsupportedParameter(datasource: String, parameter: String)

    public var description: String {
        let key = { (name: String) in "datasource.\(name).url" }
        switch self {
        case .unparseable(let name):
            return "Configuration key '\(key(name))' is not a parseable URL."
        case .unsupportedScheme(let name, let scheme):
            return "Configuration key '\(key(name))' has scheme '\(scheme)'; expected 'postgres' or 'postgresql'."
        case .missingHost(let name):
            return "Configuration key '\(key(name))' has no host."
        case .missingDatabase(let name):
            return "Configuration key '\(key(name))' has no database path segment (postgres://host:5432/<database>)."
        case .invalidSSLMode(let name, let value):
            return "Configuration key '\(key(name))' has sslmode '\(value)'; expected disable, prefer, require, verify-ca, or verify-full."
        case .unsupportedParameter(let name, let parameter):
            return "Configuration key '\(key(name))' has unsupported query parameter '\(parameter)'; only 'sslmode' is recognized."
        }
    }
}
