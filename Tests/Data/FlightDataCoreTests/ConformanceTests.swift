import FlightDataCore
import FlightDataTesting
import Testing

/// The reference driver runs the same conformance suite the real drivers do.
///
/// If `InMemoryDataSource` can drift from the contract, so can anything a
/// user writes against it — and the in-memory source is what
/// `InMemoryDataModule` substitutes into tests, so a divergence here makes
/// every downstream test lie about production behaviour.
@Suite("DataSource conformance — InMemoryDataSource")
struct InMemoryConformanceTests {

    @Test("the reference driver satisfies the DataSource contract")
    func conforms() async throws {
        try await DataSourceConformance.verify(
            make: { InMemoryDataSource(poolSize: 4) },
            shutdown: { $0.close() })
    }
}

/// A pool at capacity is a queue, not a wall — against the reference driver,
/// so the property is checked on every machine rather than only where a live
/// database happens to be configured.
@Suite("Queueing for a connection")
struct QueueingTests {

    @Test("the waiting checkout is served by a release")
    func waitsForARelease() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()

        async let queued = source.checkout(waitingUpTo: .seconds(5))
        try await Task.sleep(for: .milliseconds(50))
        #expect(source.waitingCallers.now == 1, "the caller should be parked, not spinning")
        source.release(held)

        let served = try await queued
        source.release(served)
        #expect(source.waitingCallers.now == 0, "a served waiter must not stay on the books")
    }

    @Test("waiting gives up at its deadline")
    func timesOut() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()
        defer { source.release(held) }

        let started = ContinuousClock.now
        await #expect(throws: DataSourceError.self) {
            _ = try await source.checkout(waitingUpTo: .milliseconds(200))
        }
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= .milliseconds(150))
        #expect(elapsed < .seconds(5))
        #expect(source.waitingCallers.now == 0, "a timed-out waiter must clean itself up")
    }

    @Test("every caller past the ceiling is eventually served")
    func everyWaiterIsServed() async throws {
        let source = InMemoryDataSource(poolSize: 2)
        let served = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    guard let connection = try? await source.checkout(waitingUpTo: .seconds(10))
                    else { return false }
                    try? await Task.sleep(for: .milliseconds(5))
                    source.release(connection)
                    return true
                }
            }
            return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
        }
        #expect(served == 10, "the (pool_size + 1)th caller must queue, not fail")
    }

    @Test("a cancelled waiter gives up at once rather than spinning out its timeout")
    func cancellationIsPrompt() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()
        defer { source.release(held) }

        let task = Task {
            try await source.checkout(waitingUpTo: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(50))

        let started = ContinuousClock.now
        task.cancel()
        _ = try? await task.value
        // Without a cancellation check the loop re-registers a waiter at full
        // speed for the remaining thirty seconds, burning a core for an answer
        // nobody is waiting for.
        #expect(started.duration(to: .now) < .seconds(1))
    }

    @Test("a closed pool refuses immediately instead of queueing")
    func closedPoolDoesNotQueue() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        source.close()

        let started = ContinuousClock.now
        await #expect(throws: DataSourceError.self) {
            _ = try await source.checkout(waitingUpTo: .seconds(30))
        }
        #expect(started.duration(to: .now) < .seconds(1), "waiting cannot fix a closed pool")
    }

    @Test("withConnection queues rather than failing at capacity")
    func withConnectionQueues() async throws {
        let source = InMemoryDataSource(poolSize: 1)
        let held = try source.checkout()

        async let work: Void = source.withConnection { connection in
            connection.perform("queued")
        }
        try await Task.sleep(for: .milliseconds(50))
        source.release(held)
        try await work

        #expect(source.activeCheckouts == 0)
    }
}
