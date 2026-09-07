import FlightCore
import FlightDataCore
import FlightDataPostgres
import Foundation
import Testing

extension PostgresIntegrationSuite {
/// A pool at capacity is a queue, not a wall.
///
/// `checkout()` is synchronous — scoped components are built inside
/// synchronous factory bodies — and a synchronous checkout cannot wait, so it
/// throws the moment the pool is empty. For a server that made `pool_size` a
/// hard concurrency ceiling: the (pool_size + 1)th simultaneous request
/// failed rather than waiting a few milliseconds for the request ahead of it.
///
/// Found by an application test that created eight issues at once against a
/// pool of four. Four succeeded; four returned 500 immediately.
///
/// Nested inside `PostgresIntegrationSuite` for its `.enabled(if:)`: declared
/// at file scope it *failed* rather than skipped without a database, which is
/// the one thing the contributing guide asks an integration suite not to do.
@Suite("Waiting for a connection", .serialized)
struct PoolWaitingTests {

    @Test("the non-waiting checkout still fails immediately at capacity")
    func syncCheckoutStillFailsFast() async throws {
        try await withPostgresContainer(poolSize: 2) { _, source in
            let first = try source.checkout()
            let second = try source.checkout()
            defer {
                source.release(first)
                source.release(second)
            }

            // Unchanged on purpose: a synchronous caller has no way to wait,
            // and pretending otherwise would mean blocking a thread.
            #expect(throws: DataSourceError.self) {
                _ = try source.checkout()
            }
        }
    }

    @Test("the waiting checkout gets the connection the moment it comes back")
    func waitsForARelease() async throws {
        try await withPostgresContainer(poolSize: 1) { _, source in
            let held = try source.checkout()

            async let waited = source.checkout(waitingUpTo: .seconds(5))

            // Give the waiter time to park before handing it back, so this
            // exercises the wake path rather than the fast path.
            try await Task.sleep(for: .milliseconds(50))
            source.release(held)

            let connection = try await waited
            source.release(connection)
        }
    }

    @Test("more callers than connections all get served, one after another")
    func everyWaiterIsServed() async throws {
        try await withPostgresContainer(poolSize: 2) { _, source in
            let served = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<10 {
                    group.addTask {
                        do {
                            let connection = try await source.checkout(waitingUpTo: .seconds(10))
                            // Hold it briefly, as a request would.
                            try? await Task.sleep(for: .milliseconds(5))
                            source.release(connection)
                            return true
                        } catch {
                            return false
                        }
                    }
                }
                return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
            }
            #expect(served == 10)
        }
    }

    @Test("waiting gives up at the timeout rather than hanging")
    func timesOut() async throws {
        try await withPostgresContainer(poolSize: 1) { _, source in
            let held = try source.checkout()
            defer { source.release(held) }

            let started = ContinuousClock.now
            await #expect(throws: DataSourceError.self) {
                _ = try await source.checkout(waitingUpTo: .milliseconds(200))
            }
            let elapsed = started.duration(to: .now)

            // It waited, and it stopped waiting. A pool that queues forever
            // turns a slow query into an unbounded backlog.
            #expect(elapsed >= .milliseconds(150))
            #expect(elapsed < .seconds(5))
        }
    }

    @Test("a timed-out waiter leaves no entry behind")
    func waiterBookkeepingIsCleanedUp() async throws {
        try await withPostgresContainer(poolSize: 1) { _, source in
            let held = try source.checkout()

            _ = try? await source.checkout(waitingUpTo: .milliseconds(100))
            _ = try? await source.checkout(waitingUpTo: .milliseconds(100))

            // Both gave up. An entry left in the waiter table would be a slow
            // leak on every timeout, and a wake delivered to nobody.
            #expect(source.waitingCallers.now == 0)
            #expect(source.waitingCallers.peak >= 1)

            source.release(held)
        }
    }
}
}
