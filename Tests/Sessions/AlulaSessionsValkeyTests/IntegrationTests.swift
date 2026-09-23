// Integration tests against a real Valkey/Redis — gated per server and run
// against every server configured, the same two-server duality as the cache
// adapter's suite:
//
//   $ docker run -d --name alula-sessions-valkey -p 127.0.0.1:56379:6379 valkey/valkey:8-alpine
//   $ docker run -d --name alula-sessions-redis  -p 127.0.0.1:56380:6379 redis:7-alpine
//   $ export ALULA_VALKEY_TEST_URL="valkey://127.0.0.1:56379"
//   $ export ALULA_REDIS_TEST_URL="redis://127.0.0.1:56380"
//   $ swift test
//
// The suites FLUSHDB between tests — point them at throwaway servers only.

import AlulaCacheValkey
import AlulaSessions
import Foundation
import Testing
import Valkey

@testable import AlulaSessionsValkey

enum TestServer: String, CaseIterable, Sendable, CustomStringConvertible {
    case valkey
    case redis

    var environmentKey: String {
        switch self {
        case .valkey: return "ALULA_VALKEY_TEST_URL"
        case .redis: return "ALULA_REDIS_TEST_URL"
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

    @Test(
        "save/load round-trip, under the alula-session: key prefix, with native expiry",
        arguments: TestServer.available)
    func roundTrip(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            #expect(try await store.load(id) == nil, "absent is nil, not an error")

            try await store.save(id, record, ttl: .seconds(60))
            #expect(try await store.load(id) == record)

            let pttl = try await store.client.pttl(ValkeyKey("alula-session:\(id.cookieValue)"))
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
            let pttl = try await store.client.pttl(ValkeyKey("alula-session:\(id.cookieValue)"))
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

    @Test(
        "a TTL that has already run out deletes rather than storing",
        arguments: TestServer.available)
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

// Extensions of the one serialized suite, not suites of their own: every
// suite here FLUSHDBs the same database, and two suites run in parallel with
// each other would wipe each other's keys mid-test.
extension ValkeySessionStoreIntegrationTests {
    private func encodedRecord(owner: String?) throws -> Data {
        try SessionRecord(
            createdAt: Date(), expiresAt: Date().addingTimeInterval(60), owner: owner
        ).encoded()
    }

    @Test(
        "revoking by owner ends that owner's other sessions and no one else's",
        arguments: TestServer.available)
    func revokes(server: TestServer) async throws {
        try await withStore(server) { store in
            let (laptop, phone, grace) = (
                SessionID.generate(), SessionID.generate(), SessionID.generate()
            )
            try await store.save(
                laptop, try encodedRecord(owner: "ada"), ttl: .seconds(60), owner: "ada")
            try await store.save(
                phone, try encodedRecord(owner: "ada"), ttl: .seconds(60), owner: "ada")
            try await store.save(
                grace, try encodedRecord(owner: "grace"), ttl: .seconds(60), owner: "grace")

            #expect(try await store.deleteSessions(ownedBy: "ada", keeping: laptop) == 1)
            #expect(try await store.load(laptop) != nil)
            #expect(try await store.load(phone) == nil)
            #expect(try await store.load(grace) != nil)
        }
    }

    @Test(
        "a stale index entry never ends a session whose owner has changed",
        arguments: TestServer.available)
    func staleEntryIsHarmless(server: TestServer) async throws {
        try await withStore(server) { store in
            let id = SessionID.generate()
            try await store.save(
                id, try encodedRecord(owner: "ada"), ttl: .seconds(60), owner: "ada")
            // Re-saved with no owner — the index still lists it under ada.
            try await store.save(id, try encodedRecord(owner: nil), ttl: .seconds(60), owner: nil)
            #expect(try await store.deleteSessions(ownedBy: "ada", keeping: nil) == 0)
            #expect(try await store.load(id) != nil)
            // And the stale entry was pruned.
            let members = try await store.client.smembers(ValkeyKey("alula-session-owner:ada"))
                .decode(as: [String].self)
            #expect(members.isEmpty)
        }
    }

    @Test(
        "the owner index gets an expiry on first save and is only ever extended",
        arguments: TestServer.available)
    func indexExpires(server: TestServer) async throws {
        try await withStore(server) { store in
            let index = ValkeyKey("alula-session-owner:ada")
            try await store.save(
                SessionID.generate(), try encodedRecord(owner: "ada"), ttl: .seconds(60),
                owner: "ada")
            let first = try await store.client.pttl(index)
            #expect(first > 55_000 && first <= 60_000, "a fresh set has an expiry: \(first)")
            try await store.save(
                SessionID.generate(), try encodedRecord(owner: "ada"), ttl: .seconds(5),
                owner: "ada")
            #expect(try await store.client.pttl(index) > 55_000, "a shorter save never shortens it")
        }
    }
}

extension ValkeySessionStoreIntegrationTests {
    private func withTokens<T>(
        _ server: TestServer, _ body: (ValkeyOneTimeTokenStore) async throws -> T
    ) async throws -> T {
        try await withStore(server) { sessions in
            try await body(ValkeyOneTimeTokenStore(sharing: sessions))
        }
    }

    @Test(
        "take returns the record once, under the alula-token: prefix, with native expiry",
        arguments: TestServer.available)
    func takeOnce(server: TestServer) async throws {
        try await withTokens(server) { tokens in
            try await tokens.put("digest-1", Data("record".utf8), ttl: .seconds(60))
            let pttl = try await tokens.client.pttl(ValkeyKey("alula-token:digest-1"))
            #expect(pttl > 55_000 && pttl <= 60_000)
            #expect(try await tokens.take("digest-1") == Data("record".utf8))
            #expect(try await tokens.take("digest-1") == nil)
        }
    }

    @Test("twenty racing takes of one record get it exactly once", arguments: TestServer.available)
    func racingTakes(server: TestServer) async throws {
        try await withTokens(server) { tokens in
            try await tokens.put("digest-race", Data("record".utf8), ttl: .seconds(60))
            let winners = await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<20 {
                    group.addTask { (try? await tokens.take("digest-race")) != nil }
                }
                return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
            }
            #expect(winners == 1)
        }
    }

    @Test("an expired record is gone", arguments: TestServer.available)
    func expires(server: TestServer) async throws {
        try await withTokens(server) { tokens in
            try await tokens.put("digest-short", Data("record".utf8), ttl: .milliseconds(200))
            try await Task.sleep(for: .milliseconds(400))
            #expect(try await tokens.take("digest-short") == nil)
        }
    }
}
