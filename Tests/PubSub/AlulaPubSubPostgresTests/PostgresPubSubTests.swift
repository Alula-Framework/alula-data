import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import AlulaPubSub
import Foundation
import Testing

@testable import AlulaPubSubPostgres

/// Two adapters on one database stand in for two nodes.
@Suite("PubSub over LISTEN/NOTIFY", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ALULA_POSTGRES_TEST_DATABASE_URL"] != nil))
struct PostgresPubSubTests {
    private func pool() async throws -> PostgresDataSource {
        let url = try #require(ProcessInfo.processInfo.environment["ALULA_POSTGRES_TEST_DATABASE_URL"])
        let pool = try PostgresDataSource(
            settings: try DataSourceSettings(name: "pubsub-test", url: url, poolSize: 2))
        try await pool.start()
        return pool
    }

    private func first(_ stream: AsyncStream<Message>, within limit: Duration) async -> Message? {
        await withTaskGroup(of: Message?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    @Test("a broadcast from one node arrives at another, metadata intact")
    func roundTrip() async throws {
        let pool = try await pool()
        defer { Task { await pool.shutdown() } }
        let sender = PostgresPubSubAdapter(dataSource: pool, channel: "alula_pubsub_test")
        let receiver = PostgresPubSubAdapter(dataSource: pool, channel: "alula_pubsub_test")
        let listening = Task { await receiver.listen() }
        defer { listening.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        let sent = Message(
            topic: "room:7", payload: Data([0, 1, 2, 255]),
            metadata: ["alula.pubsub.origin": "node-a"])
        try await sender.broadcast(sent)
        #expect(await first(receiver.incoming(), within: .seconds(5)) == sent)
    }

    @Test("a message over NOTIFY's limit is refused with its size, before reaching the database")
    func tooLarge() async throws {
        let pool = try await pool()
        defer { Task { await pool.shutdown() } }
        let adapter = PostgresPubSubAdapter(dataSource: pool, channel: "alula_pubsub_test")
        do {
            try await adapter.broadcast(Message(topic: "big", payload: Data(count: 8000)))
            Issue.record("an 8 KB payload was accepted")
        } catch PostgresPubSubError.payloadTooLarge(let topic, let bytes) {
            #expect(topic == "big")
            #expect(bytes > PostgresPubSubAdapter.maxPayloadBytes)
        }
    }

    @Test("a listener whose connection is killed reconnects and keeps receiving")
    func reconnects() async throws {
        let pool = try await pool()
        defer { Task { await pool.shutdown() } }
        let receiver = PostgresPubSubAdapter(
            dataSource: pool, channel: "alula_pubsub_reconnect", retryDelay: .milliseconds(100))
        let listening = Task { await receiver.listen() }
        defer { listening.cancel() }
        try await Task.sleep(for: .milliseconds(300))

        // Kill every other session listening on this channel's backend.
        try await pool.withConnection { connection in
            _ = try await connection.query(
                """
                SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                WHERE query LIKE 'LISTEN%alula_pubsub_reconnect%' AND pid <> pg_backend_pid()
                """, logger: .init(label: "test"))
        }
        try await Task.sleep(for: .milliseconds(600))

        let sender = PostgresPubSubAdapter(dataSource: pool, channel: "alula_pubsub_reconnect")
        let sent = Message(topic: "after", payload: Data("x".utf8))
        try await sender.broadcast(sent)
        #expect(await first(receiver.incoming(), within: .seconds(5)) == sent)
    }

    @Test("an invalid channel name is refused at composition")
    func channelValidation() {
        #expect(throws: PostgresPubSubConfigurationError.self) {
            _ = try AlulaPubSubPostgresModule(
                configuration: Configuration(values: ["pubsub.postgres.channel": "bad-name; DROP"]),
                dataSource: try PostgresDataSource(
                    settings: try DataSourceSettings(name: "x", url: "postgres://u@localhost/db")))
        }
    }
}
