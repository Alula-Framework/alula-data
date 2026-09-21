import FlightSessions
import Foundation
import Logging
import Valkey

/// The Valkey/Redis-backed `SessionStore` — working against either server
/// unchanged. One key per session under a fixed prefix, TTL as native expiry
/// (`SET … PX`), so the server drops expired sessions and nothing here
/// polls for them.
///
/// Holds a `ValkeyClient` — the driver's own pool, already a ServiceLifecycle
/// `Service` — the same way the cache adapter does, because the seam is
/// async end to end.
///
/// **Every failure throws.** This is the store behind a middleware that
/// answers 503 rather than guessing, so there is no breaker and no fail-open
/// here: the cache adapter's breaker exists to stop paying a timeout on
/// every request for a store the request could do without, and a session is
/// not that. The pool's own circuit breaker still bounds a down server —
/// `unreachable-after` is what makes the first request against one fail in
/// well under a second rather than after the driver's 60-second default.
public final class ValkeySessionStore: SessionStore, Sendable {
    /// Every stored key: `flight-session:` + the id's cookie value — one
    /// recognizable, greppable prefix in a store that may hold other data.
    public static let keyPrefix = "flight-session:"

    /// The underlying client, for commands this store does not wrap.
    public let client: ValkeyClient
    private let logger: Logger

    public init(settings: ValkeySessionSettings, logger: Logger? = nil) throws {
        let logger = logger ?? Logger(label: "flight.sessions.valkey")
        self.client = ValkeyClient(
            settings.url.address,
            configuration: try settings.clientConfiguration(),
            logger: logger)
        self.logger = logger
    }

    public func load(_ id: SessionID) async throws -> Data? {
        do {
            return try await client.get(key(id)).map { Data($0) }
        } catch {
            throw SessionStoreError(operation: .load, reason: "\(error)")
        }
    }

    public func save(_ id: SessionID, _ record: Data, ttl: Duration) async throws {
        // `PX` with a non-positive timeout is an error from the server, and a
        // TTL that has already run out is a session already gone: delete,
        // which is what the server would have done a moment later.
        guard let milliseconds = ttl.wholeMillisecondsIfPositive else {
            try await delete(id)
            return
        }
        do {
            try await client.set(key(id), value: record, expiration: .milliseconds(milliseconds))
        } catch {
            throw SessionStoreError(operation: .save, reason: "\(error)")
        }
    }

    public func delete(_ id: SessionID) async throws {
        do {
            _ = try await client.unlink(keys: [key(id)])
        } catch {
            throw SessionStoreError(operation: .delete, reason: "\(error)")
        }
    }

    private func key(_ id: SessionID) -> ValkeyKey {
        ValkeyKey(Self.keyPrefix + id.cookieValue)
    }
}

extension Duration {
    /// Whole milliseconds for `PX`, rounded up so a positive sub-millisecond
    /// TTL becomes 1 rather than 0; `nil` when the duration is not positive.
    fileprivate var wholeMillisecondsIfPositive: Int? {
        guard self > .zero else { return nil }
        let (seconds, attoseconds) = components
        let milliseconds = seconds * 1000 + attoseconds / 1_000_000_000_000_000
        let remainder = attoseconds % 1_000_000_000_000_000
        return Int(remainder > 0 ? milliseconds + 1 : max(milliseconds, 1))
    }
}
