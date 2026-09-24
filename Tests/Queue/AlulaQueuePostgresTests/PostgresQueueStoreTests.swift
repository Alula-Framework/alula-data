import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import AlulaQueue
import Foundation
import Hangar
import Testing

@testable import AlulaQueuePostgres

enum QueueTestDatabase {
    static var url: String? {
        let value = ProcessInfo.processInfo.environment["ALULA_POSTGRES_TEST_DATABASE_URL"]
        return (value?.isEmpty == false) ? value : nil
    }

    static var isConfigured: Bool { url != nil }

    /// One pool for every suite here. The start is shared as a task:
    /// checking a stored pool and storing it after `await start()` let two
    /// suites' first calls each build one, and the one overwritten was freed
    /// with its connections open, which PostgresNIO traps on.
    actor Pool {
        static let shared = Pool()
        private var starting: Task<PostgresDataSource, any Error>?

        func dataSource() async throws -> PostgresDataSource {
            if let starting { return try await starting.value }
            let task = Task {
                guard let url = QueueTestDatabase.url else { throw Missing() }
                let dataSource = try PostgresDataSource(
                    settings: try DataSourceSettings(name: "queue-test", url: url, poolSize: 16))
                try await dataSource.start()
                return dataSource
            }
            starting = task
            return try await task.value
        }
    }

    struct Missing: Error {}

    static let table = "alula_jobs_test"

    /// A fresh, empty table. Suites run in parallel, so each suite passes
    /// its own: two truncating and creating one table race each other.
    static func store(table: String = table) async throws -> PostgresQueueStore {
        let dataSource = try await Pool.shared.dataSource()
        let store = PostgresQueueStore(dataSource: dataSource, table: table)
        try await store.createTableIfNeeded()
        try await dataSource.withRepo { repo in
            try await repo.execute("TRUNCATE \(raw: PostgresQueueStore.quoted(table))")
        }
        return store
    }
}

/// Every scenario runs against the in-memory store and Postgres, and they must
/// agree. When one algorithm has two implementations, a differential test is
/// the only thing that checks them against each other.
@Suite(
    "Queue store contract, in memory and in Postgres", .serialized,
    .enabled(if: QueueTestDatabase.isConfigured))
struct PostgresQueueStoreTests {
    // Whole seconds: timestamptz keeps microseconds, and a fractional Date
    // would come back a hair different from the one sent.
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func stores() async throws -> [(String, any QueueStore)] {
        [("memory", InMemoryQueueStore()), ("postgres", try await QueueTestDatabase.store())]
    }

    func job(
        _ kind: String = "Greet", queue: String = "default", priority: Int = 0,
        runAt offset: TimeInterval = 0, maxAttempts: Int = 3, unique: String? = nil
    ) -> NewQueuedJob {
        NewQueuedJob(
            kind: kind, queue: queue, payload: Data(#"{"name":"ada"}"#.utf8), priority: priority,
            runAt: t0 + offset, maxAttempts: maxAttempts, uniqueKey: unique, enqueuedAt: t0)
    }

    @Test("claim order: priority, then due time; a future job waits; payload round-trips")
    func claimOrder() async throws {
        for (label, store) in try await stores() {
            let later = try await store.enqueue(job(runAt: 60)).id
            let low = try await store.enqueue(job(priority: 5)).id
            let high = try await store.enqueue(job(priority: -5)).id
            // Leased past the second claim, so only the delayed job is new then.
            let claimed = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 10, now: t0, leaseUntil: t0 + 300)
            #expect(claimed.map(\.id) == [high, low], "\(label)")
            #expect(claimed.first?.attempt == 1, "\(label)")
            let payload = try JSONSerialization.jsonObject(
                with: try #require(claimed.first).payload) as? [String: String]
            #expect(payload == ["name": "ada"], "\(label)")

            let due = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 10, now: t0 + 60, leaseUntil: t0 + 90)
            #expect(due.map(\.id) == [later], "\(label)")
        }
    }

    @Test("lease expiry hands a job to the next claim, and fences the old attempt")
    func leaseAndFence() async throws {
        for (label, store) in try await stores() {
            let id = try await store.enqueue(job()).id
            _ = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
            let held = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 10, leaseUntil: t0 + 40)
            #expect(held.isEmpty, "\(label)")

            try await store.extendLeases([(id, 1)], until: t0 + 50)
            let stillHeld = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 45, leaseUntil: t0 + 75)
            #expect(stillHeld.isEmpty, "\(label): a renewed lease must hold")

            let taken = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 51, leaseUntil: t0 + 81)
            #expect(taken.map(\.attempt) == [2], "\(label)")
            #expect(try await store.complete(id, attempt: 1, at: t0 + 52) == false, "\(label)")
            #expect(try await store.complete(id, attempt: 2, at: t0 + 53), "\(label)")
            #expect(
                try await store.counts(queue: "default") == QueueCounts(completed: 1), "\(label)")
        }
    }

    @Test("retry returns a job at its new time; discard keeps it as a dead letter")
    func retryAndDiscard() async throws {
        for (label, store) in try await stores() {
            let id = try await store.enqueue(job()).id
            _ = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
            #expect(try await store.retry(id, attempt: 1, runAt: t0 + 100, error: "boom"))
            #expect(
                try await store.claim(
                    queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 99,
                    leaseUntil: t0 + 129
                ).isEmpty, "\(label)")
            let second = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0 + 100, leaseUntil: t0 + 130)
            #expect(second.map(\.attempt) == [2], "\(label)")
            #expect(try await store.discard(id, attempt: 2, at: t0 + 101, error: "gave up"))
            #expect(
                try await store.counts(queue: "default") == QueueCounts(discarded: 1), "\(label)")
        }
    }

    @Test("a unique key dedupes while live, and frees once finished")
    func uniqueness() async throws {
        for (label, store) in try await stores() {
            let first = try await store.enqueue(job(unique: "room-7"))
            let second = try await store.enqueue(job(unique: "room-7"))
            #expect(second == .duplicate(first.id), "\(label)")
            // A different kind with the same key is a different job.
            guard case .enqueued = try await store.enqueue(job("Other", unique: "room-7")) else {
                Issue.record("\(label): kind is part of uniqueness")
                continue
            }
            _ = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
            try await store.complete(first.id, attempt: 1, at: t0 + 1)
            guard case .enqueued = try await store.enqueue(job(unique: "room-7")) else {
                Issue.record("\(label): a finished job must not block a new one")
                continue
            }
        }
    }

    @Test("only the asked-for kinds and queue are claimed")
    func filters() async throws {
        for (label, store) in try await stores() {
            _ = try await store.enqueue(job("Unknown"))
            _ = try await store.enqueue(job(queue: "mail"))
            #expect(
                try await store.claim(
                    queue: "default", kinds: ["Greet"], limit: 10, now: t0, leaseUntil: t0 + 30
                ).isEmpty, "\(label)")
        }
    }

    @Test("prune removes only finished jobs past retention")
    func prune() async throws {
        for (label, store) in try await stores() {
            let done = try await store.enqueue(job()).id
            _ = try await store.enqueue(job(runAt: 1000))
            _ = try await store.claim(
                queue: "default", kinds: ["Greet"], limit: 1, now: t0, leaseUntil: t0 + 30)
            try await store.complete(done, attempt: 1, at: t0 + 1)
            #expect(
                try await store.prune(completedBefore: t0 + 2, discardedBefore: t0 + 2) == 1,
                "\(label)")
            #expect(
                try await store.counts(queue: "default") == QueueCounts(available: 1), "\(label)")
        }
    }

    @Test("concurrent claims never hand one job to two workers")
    func concurrentClaims() async throws {
        let store = try await QueueTestDatabase.store()
        for _ in 0..<200 { _ = try await store.enqueue(job()) }
        let claimed = try await withThrowingTaskGroup(of: [QueuedJobID].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var mine: [QueuedJobID] = []
                    while true {
                        let batch = try await store.claim(
                            queue: "default", kinds: ["Greet"], limit: 7, now: t0,
                            leaseUntil: t0 + 300)
                        if batch.isEmpty { return mine }
                        mine += batch.map(\.id)
                    }
                }
            }
            var all: [QueuedJobID] = []
            for try await batch in group { all += batch }
            return all
        }
        #expect(claimed.count == 200)
        #expect(Set(claimed).count == 200)
    }

    @Test("a job enqueued in a rolled-back transaction does not exist")
    func transactionalEnqueue() async throws {
        let store = try await QueueTestDatabase.store()
        let dataSource = try await QueueTestDatabase.Pool.shared.dataSource()
        struct Abort: Error {}
        await #expect(throws: Abort.self) {
            try await dataSource.withRepo { repo in
                try await repo.transaction { tx in
                    _ = try await store.enqueue(job(), in: tx)
                    throw Abort()
                }
            }
        }
        #expect(try await store.counts(queue: "default") == QueueCounts())

        try await dataSource.withRepo { repo in
            try await repo.transaction { tx in
                _ = try await store.enqueue(job(), in: tx)
            }
        }
        #expect(try await store.counts(queue: "default") == QueueCounts(available: 1))
    }
}
