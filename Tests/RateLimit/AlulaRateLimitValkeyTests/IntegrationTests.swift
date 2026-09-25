// Integration tests against a real Valkey/Redis — gated per server and run
// against every server configured, the same two-server duality as the cache
// and session suites:
//
//   $ docker run -d --name alula-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
//   $ docker run -d --name alula-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
//   $ export ALULA_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
//   $ export ALULA_REDIS_TEST_URL="redis://127.0.0.1:56380"
//   $ swift test
//
// The suites FLUSHDB between tests — point them at throwaway servers only.

import AlulaCacheValkey
import AlulaRateLimit
import Foundation
import Testing
import Valkey

@testable import AlulaRateLimitValkey

enum TestServer: String, CaseIterable, Sendable, CustomStringConvertible {
    case valkey
    case redis

    var environmentKey: String {
        switch self {
        case .valkey: return "ALULA_VALKEY_TEST_URL"
        case .redis: return "ALULA_REDIS_TEST_URL"
        }
    }

    /// Database 4: the cache suite flushes 1, the data suite 2, the session
    /// suite 3, and a shared index lets one suite wipe another mid-test.
    var url: String? {
        guard let base = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return Self.selectingDatabase(4, in: base)
    }

    static func selectingDatabase(_ index: Int, in url: String) -> String {
        guard let marker = url.range(of: "://") else { return url }
        let afterScheme = url[marker.upperBound...]
        if let slash = afterScheme.firstIndex(of: "/") {
            return String(url[..<slash]) + "/\(index)"
        }
        return url + "/\(index)"
    }

    static let available: [TestServer] = allCases.filter { $0.url != nil }

    var description: String { rawValue }
}

/// Runs `body` with a live, flushed store; the client pool runs for the
/// duration and is cancelled on the way out.
private func withStore<T>(
    _ server: TestServer, keyPrefix: String = ValkeyRateLimitSettings.defaultKeyPrefix,
    _ body: (ValkeyRateLimitStore) async throws -> T
) async throws -> T {
    let store = try ValkeyRateLimitStore(
        settings: ValkeyRateLimitSettings(
            url: ValkeyCacheURL.parse(server.url!), keyPrefix: keyPrefix))
    let runner = Task { await store.client.run() }
    defer { runner.cancel() }
    _ = try await store.client.flushdb()
    return try await body(store)
}

@Suite(.serialized, .enabled(if: !TestServer.available.isEmpty))
struct ValkeyRateLimitStoreIntegrationTests {

    @Test("a key spends its burst, is refused, and recovers", arguments: TestServer.available)
    func spendAndRecover(server: TestServer) async throws {
        try await withStore(server) { store in
            let quota = RateLimitQuota.perSecond(5)
            for expected in stride(from: 4, through: 0, by: -1) {
                let decision = try await store.consume(key: "a", quota: quota)
                #expect(decision.isAllowed)
                #expect(decision.remaining == expected)
            }
            let denied = try await store.consume(key: "a", quota: quota)
            #expect(!denied.isAllowed)
            #expect(denied.remaining == 0)
            let retryAfter = try #require(denied.retryAfter)
            #expect(retryAfter > .zero && retryAfter <= .milliseconds(200))

            try await Task.sleep(for: .milliseconds(250))
            #expect(try await store.consume(key: "a", quota: quota).isAllowed)
        }
    }

    /// The claim the Lua script's doc comment makes: it is the same
    /// arithmetic as `GCRA.decide`. Two implementations of one algorithm are
    /// only trustworthy if something checks them against each other.
    @Test("it decides what alula's in-memory store decides", arguments: TestServer.available)
    func agreesWithTheInMemoryStore(server: TestServer) async throws {
        try await withStore(server) { valkey in
            let memory = InMemoryRateLimitStore()
            let quota = RateLimitQuota.perSecond(5)

            var valkeyDecisions: [(Bool, Int)] = []
            var memoryDecisions: [(Bool, Int)] = []
            for _ in 0..<7 {
                let v = try await valkey.consume(key: "same", quota: quota)
                let m = try await memory.consume(key: "same", quota: quota)
                valkeyDecisions.append((v.isAllowed, v.remaining))
                memoryDecisions.append((m.isAllowed, m.remaining))
            }
            #expect(valkeyDecisions.map(\.0) == memoryDecisions.map(\.0))
            #expect(valkeyDecisions.map(\.1) == memoryDecisions.map(\.1))
            #expect(
                valkeyDecisions.map(\.0) == [true, true, true, true, true, false, false],
                "five then refused, on both")

            try await Task.sleep(for: .milliseconds(250))
            let v = try await valkey.consume(key: "same", quota: quota)
            let m = try await memory.consume(key: "same", quota: quota)
            #expect(v.isAllowed == m.isAllowed)
            #expect(v.isAllowed, "one emission interval buys one permit, on both")
        }
    }

    @Test("a refused call spends nothing on the server either", arguments: TestServer.available)
    func denialDoesNotConsume(server: TestServer) async throws {
        try await withStore(server) { store in
            let quota = RateLimitQuota.perSecond(5)
            for _ in 0..<5 { _ = try await store.consume(key: "a", quota: quota) }
            for _ in 0..<20 { _ = try await store.consume(key: "a", quota: quota) }
            // Twenty refusals later, one emission interval still buys exactly
            // one permit: the retry storm did not push recovery outward.
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await store.consume(key: "a", quota: quota).isAllowed)
            #expect(!(try await store.consume(key: "a", quota: quota).isAllowed))
        }
    }

    @Test(
        "state is one key under the configured prefix, with a TTL", arguments: TestServer.available)
    func keyShape(server: TestServer) async throws {
        try await withStore(server, keyPrefix: "limits:") { store in
            _ = try await store.consume(key: "ada", cost: 5, quota: .perMinute(10))
            let stored = try await store.client.get(ValkeyKey("limits:ada"))
            #expect(stored != nil, "one key, named for the caller's key under the prefix")

            let pttl = try await store.client.pttl(ValkeyKey("limits:ada"))
            #expect(pttl > 0, "the server reclaims idle keys; no sweeper needed")
            #expect(pttl <= 31_000, "and no longer than it takes to be back at full")
        }
    }

    @Test("keys are independent", arguments: TestServer.available)
    func keysAreIndependent(server: TestServer) async throws {
        try await withStore(server) { store in
            let quota = RateLimitQuota.perMinute(1)
            let first = try await store.consume(key: "ada", quota: quota)
            let second = try await store.consume(key: "ada", quota: quota)
            let other = try await store.consume(key: "grace", quota: quota)
            #expect(first.isAllowed)
            #expect(!second.isAllowed)
            #expect(other.isAllowed, "a different key, a different budget")
        }
    }

    /// The script computes `tat + cost * emission`: a negative cost would
    /// have handed permits back rather than failed.
    @Test("a negative cost is refused, not credited back", arguments: TestServer.available)
    func negativeCostRefused(_ server: TestServer) async throws {
        try await withStore(server) { store in
            let quota = RateLimitQuota.perMinute(2)
            _ = try await store.consume(key: "negative", cost: 2, quota: quota)
            await #expect(throws: RateLimitStoreError.self) {
                _ = try await store.consume(key: "negative", cost: -2, quota: quota)
            }
            #expect(try await store.consume(key: "negative", cost: 1, quota: quota).isAllowed == false,
                    "nothing was handed back")
        }
    }

    @Test("a zero cost probes without spending", arguments: TestServer.available)
    func probe(server: TestServer) async throws {
        try await withStore(server) { store in
            let quota = RateLimitQuota.perMinute(10)
            _ = try await store.consume(key: "a", cost: 3, quota: quota)
            let probe = try await store.consume(key: "a", cost: 0, quota: quota)
            #expect(probe.isAllowed)
            #expect(probe.remaining == 7)
            #expect(try await store.consume(key: "a", cost: 0, quota: quota).remaining == 7)
        }
    }

    @Test("a cost over the burst is unsatisfiable, not deferred", arguments: TestServer.available)
    func unsatisfiable(server: TestServer) async throws {
        try await withStore(server) { store in
            let decision = try await store.consume(key: "a", cost: 99, quota: .perMinute(10))
            #expect(!decision.isAllowed)
            #expect(decision.isUnsatisfiable)
            #expect(decision.retryAfter == nil)
        }
    }

    @Test("a downed server throws rather than quietly allowing")
    func downServerThrows() async throws {
        // The policy call belongs to the caller, so the store's job is to
        // report the failure — and to be quick about it, which is the pool
        // breaker's doing.
        let store = try ValkeyRateLimitStore(
            settings: ValkeyRateLimitSettings(
                url: ValkeyCacheURL.parse("valkey://127.0.0.1:1"),
                commandTimeout: .milliseconds(100),
                unreachableAfter: .milliseconds(100),
                minimumConnections: 0))
        let runner = Task { await store.client.run() }
        defer { runner.cancel() }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect(throws: RateLimitStoreError.self) {
                _ = try await store.consume(key: "a", quota: .perMinute(10))
            }
        }
        #expect(elapsed < .seconds(3), "the pool breaker bounds the first call: \(elapsed)")
    }
}
