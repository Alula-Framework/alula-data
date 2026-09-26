import AlulaMigrate
import Foundation
import Logging
import PostgresNIO

/// Shared execution plumbing for commands that talk to the database: builds the
/// `PostgresClient`, keeps its pool `run()`-ning for the duration of `body`, and tears it
/// down afterwards.
enum Runtime {
    static func withMigrator<T: Sendable>(
        options: DatabaseOptions,
        onEvent: (@Sendable (MigrationEvent) -> Void)? = nil,
        _ body: @Sendable @escaping (AlulaMigrator) async throws -> T
    ) async throws -> T {
        let url = try DatabaseURL.resolve(flag: options.databaseUrl)
        let clientConfiguration = try url.postgresConfiguration()
        try await checkConnection(to: url)

        var logger = Logger(label: "alula-migrate")
        logger.logLevel = options.verbose ? .debug : .warning

        // The pool's *background* chatter is a separate stream from the
        // migration's own, and it is quiet unless asked for. `client.run()`
        // is started as a child task below and the first lease happens on
        // the parent immediately after — a child is not guaranteed to have
        // started by then, so PostgresNIO logs "Trying to lease connection
        // from `PostgresClient`, but `PostgresClient.run()` hasn't been
        // called yet" on essentially every invocation. The lease then
        // succeeds, because the pool queues it. There is no readiness signal
        // to await (nothing on `PostgresClient` reports that `run()` has
        // begun), so the choice is between a spurious warning on every run
        // of a first-party command and keeping the pool's own log to
        // `--verbose`. A warning that is always there is one people learn to
        // scroll past, which costs more than it saves.
        var poolLogger = Logger(label: "alula-migrate.pool")
        poolLogger.logLevel = options.verbose ? .debug : .error

        let client = PostgresClient(
            configuration: clientConfiguration,
            backgroundLogger: poolLogger
        )

        var migratorConfiguration = AlulaMigrator.Configuration()
        migratorConfiguration.migrationsTable = options.migrationsTable
        // 0 means "wait indefinitely", which is the right choice for an
        // interactive run someone is watching — and was unreachable from the
        // CLI, which pinned every run to the 30-second default.
        migratorConfiguration.lockTimeout =
            options.lockTimeout > 0 ? .seconds(options.lockTimeout) : nil
        if let key = options.advisoryLockKey {
            migratorConfiguration.advisoryLockKey = key
        }
        migratorConfiguration.failOnUnknownApplied = options.failOnUnknownApplied
        migratorConfiguration.logger = logger
        migratorConfiguration.onEvent = onEvent

        let migrator = AlulaMigrator(
            client: client,
            migrations: MigrationRegistry.migrations,
            configuration: migratorConfiguration
        )

        return try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await client.run()
            }
            do {
                let result = try await body(migrator)
                group.cancelAll()
                return result
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    /// Dials once, directly, before the pool exists.
    ///
    /// The pool retries a failed connection until its circuit breaker trips —
    /// about a minute of silence, then `ConnectionPoolError(…
    /// connectionCreationCircuitBreakerTripped)`, the same for a wrong
    /// password, a missing database and a closed port (Relay #41). One
    /// direct attempt answers at once, with what the server said.
    static func checkConnection(to url: DatabaseURL) async throws {
        var logger = Logger(label: "alula-migrate.connect")
        logger.logLevel = .critical
        do {
            let connection = try await PostgresConnection.connect(
                configuration: try url.connectionConfiguration(), id: 0, logger: logger)
            try? await connection.close()
        } catch {
            throw CLIError.cannotConnect(
                host: url.host, port: url.port, database: url.database, cause: connectionFailure(error))
        }
    }

    /// What a failed connection came to, without the URL or the password:
    /// the server's own refusal ("password authentication failed for user
    /// …", SQLSTATE 28P01), or the network's ("connection refused").
    static func connectionFailure(_ error: any Error) -> String {
        guard let psql = error as? PSQLError else { return String(describing: error) }
        if let server = psql.serverInfo {
            return "the server refused: \(server[.message] ?? "")"
                + (server[.sqlState].map { " (SQLSTATE \($0))" } ?? "")
        }
        if let underlying = psql.underlying {
            let text = "\(underlying)"
            let readable = readableConnectionFailure(text)
            return readable == text ? "\(psql.code): \(text)" : readable
        }
        return "\(psql.code)"
    }

    /// Formats a duration for human output, e.g. `12 ms` or `3.4 s`.
    static func format(_ duration: Duration) -> String {
        let seconds =
            Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        return String(format: "%.1f s", seconds)
    }
}
