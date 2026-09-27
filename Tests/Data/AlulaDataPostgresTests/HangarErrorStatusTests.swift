import AlulaCore
import AlulaDataPostgres
import Hangar
import Logging
import PostgresNIO
import Testing

@Suite("Hangar's errors as HTTP statuses")
struct HangarErrorStatusTests {
    @Test("a bad dynamic filter is the request's fault, told without the table")
    func filterErrorsAreRejectedInput() {
        let unknown = HangarError.unknownFilterField(table: "internal_incidents", field: "sevrity")
        #expect(unknown.isRejectedInput)
        #expect(unknown.rejectionMessage == "\"sevrity\" is not a field that can be filtered on")
        #expect(!unknown.rejectionMessage.contains("internal_incidents"))
        let wrongType = HangarError.invalidFilterValue(table: "internal_incidents", field: "severity")
        #expect(wrongType.isRejectedInput)
        #expect(!HangarError.staleModel(table: "incidents").isRejectedInput, "the server's problem: 500")
    }

    @Test("a database that cannot be reached is temporarily unavailable")
    func unreachableIsTemporarilyUnavailable() async throws {
        var logger = Logger(label: "test")
        logger.logLevel = .critical
        do {
            _ = try await PostgresConnection.connect(
                configuration: .init(host: "127.0.0.1", port: 1, username: "u", password: nil, database: "d", tls: .disable),
                id: 1, logger: logger)
            Issue.record("connected to a closed port")
        } catch {
            let connection = try #require(DatabaseConnectionError(error))
            #expect(connection.isTemporarilyUnavailable)
            #expect(connection.retryAfter == .seconds(5))
        }
    }
}
