import Foundation

/// A row of the bookkeeping table.
public struct AppliedMigrationRecord: Sendable, Equatable {
    /// The migration's version: its 14-digit timestamp.
    public let version: Int64
    /// The migration's type name when it was applied (or last repaired).
    public let name: String
    /// The source checksum recorded when it was applied.
    public let checksum: String
    /// When it was applied, by the database's clock.
    public let appliedAt: Date

    public init(version: Int64, name: String, checksum: String, appliedAt: Date) {
        self.version = version
        self.name = name
        self.checksum = checksum
        self.appliedAt = appliedAt
    }
}

/// The database operations `AlulaMigrator` needs, on one session.
///
/// A *session* is a single database connection: the advisory lock is
/// session-scoped, and `begin`/`commit`/`rollback` bracket work on the same connection —
/// both are meaningless across a connection pool. The Postgres implementation is
/// ``PostgresMigrationDatabase``; tests substitute an in-memory fake to assert on the
/// exact operation sequence (BEGIN before body, bookkeeping inside the transaction,
/// unlock on every path, ...).
public protocol MigrationSession: Sendable {
    /// Executes one SQL statement, discarding any rows.
    func execute(_ sql: String) async throws

    /// Starts a transaction on this session.
    func begin() async throws
    /// Commits the session's transaction.
    func commit() async throws
    /// Rolls back the session's transaction.
    func rollback() async throws

    /// Acquires the session-scoped migration advisory lock, waiting at most `timeout`.
    ///
    /// A `nil` timeout waits indefinitely. On expiry, throw
    /// ``MigrationError/lockTimeout(key:waited:)`` so the caller can tell a
    /// contended lock from a connection failure.
    func acquireAdvisoryLock(key: Int64, timeout: Duration?) async throws
    /// Releases the lock. The migrator calls it on every path; a session that
    /// ends without it releases the lock when its connection closes.
    func releaseAdvisoryLock(key: Int64) async throws

    /// Whether the bookkeeping table exists.
    func migrationsTableExists(_ table: String) async throws -> Bool

    /// Creates the bookkeeping table. The caller wraps this in a transaction.
    func createMigrationsTable(_ table: String) async throws

    /// All bookkeeping rows, ordered by version ascending.
    func fetchApplied(_ table: String) async throws -> [AppliedMigrationRecord]

    /// Records a migration as applied. Runs inside the migration's transaction when the
    /// migration is wrapped.
    func insertApplied(_ table: String, version: Int64, name: String, checksum: String) async throws

    /// Removes a migration's bookkeeping row, for rollback.
    func deleteApplied(_ table: String, version: Int64) async throws

    /// Re-baselines a recorded name and checksum, for repair.
    func updateApplied(_ table: String, version: Int64, name: String, checksum: String) async throws
}

/// Provides sessions. The Postgres implementation checks a connection out of the
/// `PostgresClient` pool for the duration of `body`.
public protocol MigrationDatabase: Sendable {
    /// Runs `body` on one session — one connection — for its whole duration.
    func withSession<T: Sendable>(
        _ body: @Sendable (any MigrationSession) async throws -> T
    ) async throws -> T
}
