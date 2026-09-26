import AlulaDataCore
import AlulaMigrateCore
import Testing

@testable import AlulaDataValkey

/// Relay #47: the Valkey pool's reconnect warning printed the raw nested
/// text around "(errno: 111)", where the Postgres pool says "connection
/// refused (127.0.0.1:5432)". Driven against a real refusal — port 1 on
/// loopback — because what matters is what an operator reads.
@Suite("A Valkey connection failure reads as the Postgres one does")
struct ConnectionFailureTextTests {
    @Test("a refused dial reads as `connection refused (address)`")
    func refused() async throws {
        let source = try ValkeyDataSource(
            settings: DataSourceSettings(name: "probe", url: "valkey://127.0.0.1:1", poolSize: 1))
        do {
            try await source.start()
            Issue.record("port 1 should refuse")
        } catch let error as DataSourceStartupError {
            let readable = readableConnectionFailure("\(error.underlying)")
            #expect(readable.lowercased().contains("connection refused"), "\(readable)")
            #expect(!readable.contains("SingleConnectionFailure"), "\(readable)")
        }
    }
}
