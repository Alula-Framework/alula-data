import Foundation
import PostgresNIO
import Testing

@testable import AlulaDataPostgres

/// Relay #34: reconnect warnings logged PostgresNIO's opaque description,
/// so an operator could not tell a refused connection from a failed login
/// from a server still starting up. Driven against real failures, because
/// the point is what an operator reads when one happens.
@Suite("What a Postgres failure logs")
struct LoggableFailureTests {
    private func failure(host: String, port: Int, user: String, password: String, database: String) async -> any Error {
        let source = PostgresDataSource(
            name: "probe",
            configuration: .init(
                host: host, port: port, username: user, password: password, database: database, tls: .disable),
            poolSize: 1)
        do {
            try await source.start()
            Issue.record("the connection should have failed")
            return CancellationError()
        } catch {
            return error
        }
    }

    @Test("a refused connection says so, not the generic placeholder")
    func refused() async {
        // Port 1 on loopback: nothing listens there.
        let logged = loggableFailure(
            await failure(host: "127.0.0.1", port: 1, user: "u", password: "p", database: "d"))
        #expect(!logged.contains("Generic description"), "\(logged)")
        #expect(logged.lowercased().contains("connect"), "\(logged)")
    }

    /// What the reconnect path sees: the raw error from dialling, not the
    /// startup error `start()` wraps it in.
    @Test("a rejected password says authentication failed, with its SQLSTATE and without the text",
          .enabled(if: TestDatabase.isConfigured))
    func badPassword() async throws {
        let url = try #require(URLComponents(string: try TestDatabase.requireURL()))
        let host = try #require(url.host)
        let port = url.port ?? 5432
        do {
            let connection = try await PostgresConnection.connect(
                configuration: .init(
                    host: host, port: port, username: url.user ?? "postgres",
                    password: "definitely-not-the-password", database: String(url.path.dropFirst()),
                    tls: .disable),
                id: 1, logger: Logger(label: "probe"))
            try await connection.close()
            Issue.record("the password should have been refused")
        } catch {
            let logged = loggableFailure(error)
            #expect(logged.hasPrefix("authentication failed"), "\(logged)")
            #expect(logged.contains("28P01"), "\(logged)")
            #expect(!logged.contains("definitely-not-the-password"))
        }
        // And the startup error names the port that was configured.
        let startup = await failure(
            host: host, port: port, user: url.user ?? "postgres", password: "nope",
            database: String(url.path.dropFirst()))
        #expect("\(startup)".contains(":\(port)"), "\(startup)")
    }
}
