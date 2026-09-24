import AlulaDataPostgres
import AlulaPubSub
import AlulaQueue
import Foundation
import Hangar
import Testing

@testable import AlulaQueuePostgres

@Suite("Outbox", .serialized, .enabled(if: QueueTestDatabase.isConfigured))
struct OutboxTests {
    struct OrderPlaced: Codable, Equatable {
        let id: Int
    }

    struct Abort: Error {}

    /// Claims every outbox job and runs it as the worker would.
    func relay(_ store: PostgresQueueStore, _ outbox: Outbox) async throws -> [QueueAttemptOutcome]
    {
        let jobs = try await store.claim(
            queue: Outbox.Envelope.queue, kinds: [Outbox.Envelope.kind], limit: 100, now: Date(),
            leaseUntil: Date().addingTimeInterval(60))
        var outcomes: [QueueAttemptOutcome] = []
        for job in jobs {
            outcomes.append(await QueueRunner(store: store).run(job, handler: outbox.handler))
        }
        return outcomes
    }

    @Test("a committed message is published once the worker runs it")
    func committed() async throws {
        let store = try await QueueTestDatabase.store(table: "alula_jobs_outbox_test")
        let dataSource = try await QueueTestDatabase.Pool.shared.dataSource()
        let bus = LocalPubSub()
        let outbox = Outbox(queue: JobQueue(store: store), store: store, bus: bus)
        var received = bus.subscribe("orders").makeAsyncIterator()

        let id = try await dataSource.withRepo { repo in
            try await repo.transaction { tx in
                try await outbox.publish(OrderPlaced(id: 7), to: "orders", in: tx)
            }
        }
        #expect(try await relay(store, outbox) == [.completed])

        let message = try #require(await received.next())
        #expect(
            try JSONDecoder().decode(OrderPlaced.self, from: message.payload) == OrderPlaced(id: 7))
        #expect(message.metadata["outbox-id"] == id.uuidString)
        #expect(try await store.counts(queue: Outbox.Envelope.queue).available == 0)
    }

    @Test("a rolled-back message is never published")
    func rolledBack() async throws {
        let store = try await QueueTestDatabase.store(table: "alula_jobs_outbox_test")
        let dataSource = try await QueueTestDatabase.Pool.shared.dataSource()
        let outbox = Outbox(queue: JobQueue(store: store), store: store, bus: LocalPubSub())

        await #expect(throws: Abort.self) {
            try await dataSource.withRepo { repo in
                try await repo.transaction { tx in
                    try await outbox.publish(OrderPlaced(id: 8), to: "orders", in: tx)
                    throw Abort()
                }
            }
        }
        #expect(try await store.counts(queue: Outbox.Envelope.queue) == QueueCounts())
        #expect(try await relay(store, outbox).isEmpty)
    }

    @Test("the module provides the outbox and registers its handler")
    func module() async throws {
        let store = try await QueueTestDatabase.store(table: "alula_jobs_outbox_test")
        let module = AlulaOutboxModule(
            jobQueue: JobQueue(store: store), postgresQueueStore: store, bus: LocalPubSub())
        #expect(module.queueHandlers.map(\.kind) == [Outbox.Envelope.kind])
        #expect(module.queueHandlers.map(\.queue) == ["outbox"])
    }
}
