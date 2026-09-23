import AlulaSessions
import Foundation
import Logging
import Valkey

/// The Valkey/Redis-backed `OneTimeTokenStore` — the storage behind
/// password-reset, email-verification and magic-link tokens, shared across
/// every replica.
///
/// `take` is one `GETDEL` (Valkey, Redis 6.2+): the record comes back to
/// exactly one caller and is gone for every other, which is the whole of
/// what makes a link single-use when two requests race with it. Expiry is
/// native (`SET … PX`). Keys are the digests AlulaSecurityCore's
/// `OneTimeTokens` computes, never tokens, under their own prefix.
///
/// Every failure throws, as the session store's do: a reset flow that
/// silently lost its token would tell the user their link is invalid when
/// the store was down.
public final class ValkeyOneTimeTokenStore: OneTimeTokenStore, Sendable {
    public static let keyPrefix = "alula-token:"

    public let client: ValkeyClient

    /// Shares the session store's client and pool — one connection budget
    /// for all of this application's short-lived state.
    public init(sharing sessions: ValkeySessionStore) {
        self.client = sessions.client
    }

    public init(settings: ValkeySessionSettings, logger: Logger? = nil) throws {
        let logger = logger ?? Logger(label: "alula.tokens.valkey")
        self.client = ValkeyClient(
            settings.url.address, configuration: try settings.clientConfiguration(), logger: logger)
    }

    public func put(_ key: String, _ record: Data, ttl: Duration) async throws {
        let milliseconds = max(
            1,
            Int(ttl.components.seconds * 1000 + ttl.components.attoseconds / 1_000_000_000_000_000))
        do {
            try await client.set(
                ValkeyKey(Self.keyPrefix + key), value: record,
                expiration: .milliseconds(milliseconds))
        } catch {
            throw SessionStoreError(operation: .save, reason: "\(error)")
        }
    }

    public func take(_ key: String) async throws -> Data? {
        do {
            return try await client.getdel(ValkeyKey(Self.keyPrefix + key)).map { Data($0) }
        } catch {
            throw SessionStoreError(operation: .load, reason: "\(error)")
        }
    }
}
