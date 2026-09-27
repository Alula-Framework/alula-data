import AlulaCore
import AlulaDataCore
import Foundation
import NIOSSL
import PostgresNIO

/// Parses `postgres://` connection URLs into `PostgresClient` configurations (
/// the CLI reads a connection URL directly — env var or flag — precisely so Alula Migrate
/// stays standalone).
struct DatabaseURL: Equatable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var database: String
    var sslMode: SSLMode

    /// libpq-compatible `sslmode` values.
    enum SSLMode: String, Equatable {
        case disable
        case allow
        case prefer
        case require
        case verifyCA = "verify-ca"
        case verifyFull = "verify-full"
    }

    /// Resolution order: explicit flag, then `$ALULA_DATABASE_URL`, then `$DATABASE_URL`.
    static func resolve(
        flag: String?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DatabaseURL {
        guard
            let raw = flag ?? environment["ALULA_DATABASE_URL"] ?? environment["DATABASE_URL"]
        else {
            throw CLIError.missingDatabaseURL(datasource: "primary")
        }
        return try parse(raw)
    }

    /// Where a resolved URL came from — printed before a run, because the
    /// failure #29 is about is migrating one database while the application
    /// uses another.
    enum Source: Equatable, CustomStringConvertible {
        case flag
        case environment(String)
        case configuration(key: String, directory: String)

        var description: String {
            switch self {
            case .flag: "--database-url"
            case .environment(let name): "$\(name)"
            case .configuration(let key, let directory): "\(key) in \(directory)/alula.yaml"
            }
        }
    }

    /// The flag and the environment variables first, as before; then the
    /// datasource's url in `alula.yaml`, read with the application's own
    /// loader — the environment overlay (`alula-{env}.yaml`) and
    /// `ALULA_DATASOURCE_<NAME>_URL` apply exactly as they do when it runs.
    /// The database used to be configured twice, once for the application
    /// and once for this tool, and the two could drift (Relay #29).
    static func resolve(
        flag: String?, datasource: String, configDirectory: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (url: DatabaseURL, source: Source) {
        if let flag { return (try parse(flag), .flag) }
        for name in ["ALULA_DATABASE_URL", "DATABASE_URL"] {
            if let raw = environment[name] { return (try parse(raw), .environment(name)) }
        }
        let directory = configDirectory ?? FileManager.default.currentDirectoryPath
        let base = URL(fileURLWithPath: directory).appendingPathComponent(Configuration.baseFileName)
        guard FileManager.default.fileExists(atPath: base.path) else {
            throw CLIError.missingDatabaseURL(datasource: datasource)
        }
        let configuration = try Configuration.load(
            from: URL(fileURLWithPath: directory), processEnvironment: environment)
        let key = "datasource.\(datasource).url"
        let settings: DataSourceSettings
        do {
            settings = try DataSourceSettings.load(name: datasource, from: configuration)
        } catch {
            throw CLIError.noDatasourceInConfiguration(key: key, directory: directory, reason: "\(error)")
        }
        return (try parse(settings.url), .configuration(key: key, directory: directory))
    }

    static func parse(_ raw: String) throws -> DatabaseURL {
        guard let components = URLComponents(string: raw) else {
            throw CLIError.invalidDatabaseURL(raw, reason: "not a valid URL")
        }
        guard let scheme = components.scheme, scheme == "postgres" || scheme == "postgresql"
        else {
            throw CLIError.invalidDatabaseURL(
                raw, reason: "scheme must be postgres:// or postgresql://")
        }
        guard let username = components.user, !username.isEmpty else {
            throw CLIError.invalidDatabaseURL(
                raw, reason: "a username is required (postgres://USER@host/db)")
        }
        let host = components.host.flatMap { $0.isEmpty ? nil : $0 } ?? "localhost"
        if host.hasPrefix("/") || host.hasPrefix("%2F") {
            throw CLIError.invalidDatabaseURL(
                raw,
                reason: """
                    unix domain socket hosts are not supported by the CLI. Use the library \
                    API: build a PostgresClient.Configuration yourself and hand it to \
                    AlulaMigrator(client:migrations:configuration:)
                    """)
        }

        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        if database.isEmpty { database = username }

        var sslMode = SSLMode.prefer
        for item in components.queryItems ?? [] where item.name == "sslmode" {
            guard let value = item.value, let mode = SSLMode(rawValue: value) else {
                throw CLIError.invalidDatabaseURL(
                    raw,
                    reason: """
                        unknown sslmode '\(item.value ?? "")' (expected disable, allow, prefer, \
                        require, verify-ca, or verify-full)
                        """)
            }
            sslMode = mode
        }

        return DatabaseURL(
            host: host,
            port: components.port ?? 5432,
            username: username,
            password: components.password,
            database: database,
            sslMode: sslMode
        )
    }

    /// Maps to a `PostgresClient.Configuration`, with libpq-parity TLS semantics:
    /// `prefer`/`require` encrypt without verifying certificates; use `verify-full` for
    /// certificate and hostname verification in production over untrusted networks.
    func postgresConfiguration() throws -> PostgresClient.Configuration {
        let tls: PostgresClient.Configuration.TLS
        switch tlsPolicy {
        case nil: tls = .disable
        case .prefer(let configuration)?: tls = .prefer(configuration)
        case .require(let configuration)?: tls = .require(configuration)
        }
        return PostgresClient.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: tls
        )
    }

    /// The same settings for one direct `PostgresConnection`: what the
    /// connection check before a run dials, to report a refusal at once.
    func connectionConfiguration() throws -> PostgresConnection.Configuration {
        let tls: PostgresConnection.Configuration.TLS
        switch tlsPolicy {
        case nil: tls = .disable
        case .prefer(let configuration)?: tls = .prefer(try NIOSSLContext(configuration: configuration))
        case .require(let configuration)?: tls = .require(try NIOSSLContext(configuration: configuration))
        }
        return PostgresConnection.Configuration(
            host: host, port: port, username: username, password: password, database: database, tls: tls)
    }

    private enum TLSPolicy {
        case prefer(TLSConfiguration)
        case require(TLSConfiguration)
    }

    /// libpq-parity TLS semantics, shared by both configurations.
    private var tlsPolicy: TLSPolicy? {
        var configuration = TLSConfiguration.makeClientConfiguration()
        switch sslMode {
        case .disable:
            return nil
        case .allow, .prefer:
            configuration.certificateVerification = .none
            return .prefer(configuration)
        case .require:
            configuration.certificateVerification = .none
            return .require(configuration)
        case .verifyCA:
            configuration.certificateVerification = .noHostnameVerification
            return .require(configuration)
        case .verifyFull:
            configuration.certificateVerification = .fullVerification
            return .require(configuration)
        }
    }
}
