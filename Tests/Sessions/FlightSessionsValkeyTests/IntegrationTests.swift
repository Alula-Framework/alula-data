// Integration tests against a real Valkey/Redis — gated per server and run
// against every server configured, the same two-server duality as the cache
// adapter's suite:
//
//   $ docker run -d --name flight-sessions-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
//   $ docker run -d --name flight-sessions-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
//   $ export FLIGHT_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
//   $ export FLIGHT_REDIS_TEST_URL="redis://127.0.0.1:56380"
//   $ swift test
//
// The suites FLUSHDB between tests — point them at throwaway servers only.

import FlightCacheValkey
import FlightSessions
import Foundation
import Testing
import Valkey

@testable import FlightSessionsValkey

enum TestServer: String, CaseIterable, Sendable, CustomStringConvertible {
    case valkey
    case redis

    var environmentKey: String {
        switch self {
        case .valkey: return "FLIGHT_VALKEY_TEST_URL"
        case .redis: return "FLIGHT_REDIS_TEST_URL"
        }
    }

    /// The configured URL, pinned to a database index of this suite's own —
    /// the cache suite flushes 1 and the data suite 2, and a shared index
    /// lets one suite wipe another mid-test.
    var url: String? {
        guard let base = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        return Self.selectingDatabase(3, in: base)
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
    _ server: TestServer, _ body: (ValkeySessionStore) async throws -> T
) async throws -> T {
    let store = try ValkeySessionStore(
        settings: ValkeySessionSettings(url: ValkeyCacheURL.parse(server.url!)))
    let runner = Task { await store.client.run() }
    defer { runner.cancel() }
    _ = try await store.client.flushdb()
    return try await body(store)
}

@Suite(.serialized, .enabled(if: !TestServer.available.isEmpty))
struct ValkeySessionStoreIntegrationTests {
    private let record = Data(#"{"values":{},"flash":{}}"#.utf8)

    @Test("save/load round-trip, under the flight-session: key prefix, with native expiry", arguments: TestServer.available)
    func roundTrip(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            #expect(try await store.load(id) == nil, "absent is nil, not an error")

            try await store.save(id, record, ttl: .seconds(60))
            #expect(try await store.load(id) == record)

            let pttl = try await store.client.pttl(ValkeyKey("flight-session:\(id.cookieValue)"))
            #expect(pttl > 55_000 && pttl <= 60_000, "the TTL is the server's, not polled: \(pttl)")
        }
    }

    @Test("saving again replaces the record and restarts the TTL", arguments: TestServer.available)
    func overwrite(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            try await store.save(id, record, ttl: .seconds(5))
            let replacement = Data("replacement".utf8)
            try await store.save(id, replacement, ttl: .seconds(60))
            #expect(try await store.load(id) == replacement)
            let pttl = try await store.client.pttl(ValkeyKey("flight-session:\(id.cookieValue)"))
            #expect(pttl > 55_000)
        }
    }

    @Test("an expired session reads as absent", arguments: TestServer.available)
    func expiry(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            try await store.save(id, record, ttl: .milliseconds(200))
            #expect(try await store.load(id) == record)
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await store.load(id) == nil)
        }
    }

    @Test("a TTL that has already run out deletes rather than storing", arguments: TestServer.available)
    func nonPositiveTTLDeletes(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            try await store.save(id, record, ttl: .seconds(60))
            try await store.save(id, record, ttl: .zero)
            #expect(try await store.load(id) == nil)
        }
    }

    @Test("delete is idempotent", arguments: TestServer.available)
    func delete(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            try await store.save(id, record, ttl: .seconds(60))
            try await store.delete(id)
            try await store.delete(id)
            #expect(try await store.load(id) == nil)
        }
    }

    @Test("a downed server throws rather than reading as an empty session")
    func downServerThrows() async throws {
        let store = try ValkeySessionStore(
            settings: ValkeySessionSettings(
                url: ValkeyCacheURL.parse("valkey://127.0.0.1:1"),
                commandTimeout: .milliseconds(250),
                unreachableAfter: .milliseconds(250),
                minimumConnections: 0))
        let runner = Task { await store.client.run() }
        defer { runner.cancel() }

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await #expect(throws: SessionStoreError.self) {
                _ = try await store.load(SessionID.generate())
            }
        }
        #expect(elapsed < .seconds(3), "the pool breaker bounds the first call: \(elapsed)")
    }
}
