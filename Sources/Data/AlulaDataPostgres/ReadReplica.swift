import AlulaCore
import AlulaDataCore
import Hangar
import Logging
import PostgresNIO
import Synchronization

/// A read replica's pool, attached to its primary by `PostgresDataModule`.
final class ReplicaAttachment: Sendable {
    let pool: PostgresDataSource
    let fallbackToPrimary: Bool
    let logger: Logger
    private let degraded = Atomic(false)

    init(pool: PostgresDataSource, fallbackToPrimary: Bool, logger: Logger) {
        self.pool = pool
        self.fallbackToPrimary = fallbackToPrimary
        self.logger = logger
    }

    /// Logs the move to and from reading off the primary once each, not per
    /// request.
    func note(available: Bool, error: (any Error)? = nil) {
        let wasDegraded = degraded.exchange(!available, ordering: .relaxed)
        if available, wasDegraded {
            logger.info("read replica available again", metadata: ["datasource": "\(pool.name)"])
        } else if !available, !wasDegraded {
            logger.warning(
                "read replica unavailable; reading from the primary",
                metadata: ["datasource": "\(pool.name)", "error": "\(error.map { "\($0)" } ?? "")"])
        }
    }
}

extension PostgresDataSource {
    /// This pool's read replica, when `datasource.<name>.replica.url` configured one.
    public var replica: PostgresDataSource? {
        replicaSlot.withLock { $0?.pool }
    }

    func attach(replica: ReplicaAttachment) {
        replicaSlot.withLock { $0 = replica }
    }

    /// Runs `body` with a repository for **reads that can tolerate
    /// replication lag**, on the read replica when one is configured and on
    /// this pool otherwise.
    ///
    /// ```swift
    /// let recent = try await pool.withReadRepo { repo in
    ///     try await repo.all(Post.where { $0.published }.order(by: \.date, .descending).limit(20))
    /// }
    /// ```
    ///
    /// Opt-in per call, never routed automatically. A read that must see the
    /// request's own write (signup, then show the profile) stays on
    /// `withRepo`, the primary. When the replica cannot give a connection
    /// (down, or its pool exhausted), the read falls back to the primary
    /// unless `datasource.<name>.replica.fallback: false`. The move is logged
    /// once, and so is the recovery.
    ///
    /// Writes through this repo reach the replica, which a hot standby
    /// refuses. Use `withRepo` for writes.
    public func withReadRepo<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        guard let attachment = replicaSlot.withLock({ $0 }) else {
            return try await withRepo(body)
        }
        let connection: PostgresConnection
        do {
            connection = try await attachment.pool.checkout(
                waitingUpTo: attachment.pool.checkoutTimeout)
        } catch {
            attachment.note(available: false, error: error)
            guard attachment.fallbackToPrimary else { throw error }
            return try await withRepo(body)
        }
        attachment.note(available: true)
        do {
            // Handed over, not bound as the ambient `Repo.current`: a read
            // repo is for the reads written in `body`, and binding it would
            // route any code reaching for the ambient repo, writes included,
            // to a replica that refuses them.
            let result = try await body(Repo(connection: connection))
            attachment.pool.release(connection)
            return result
        } catch {
            attachment.pool.release(connection)
            throw error
        }
    }
}
