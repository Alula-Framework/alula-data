import AlulaDataPostgres
import AlulaQueue
import Foundation
import Hangar
import Logging
import PostgresNIO

/// A durable `QueueStore` in a Postgres table.
///
/// ## Claiming
///
/// One statement: `SELECT … FOR UPDATE SKIP LOCKED` picks due rows that no
/// concurrent claim is looking at, and the `UPDATE` around it marks them
/// running, bumps the attempt and sets the lease. Concurrent workers
/// partition the due rows between them instead of queueing on each other's
/// row locks, and none can take a row another has.
///
/// ## Enqueueing with the change that caused it
///
/// ``enqueue(_:in:)`` writes the job through a Hangar `Repo`, so inside
/// `repo.transaction { }` the job commits or rolls back with the rows beside
/// it:
///
/// ```swift
/// try await pool.withRepo { repo in
///     try await repo.transaction { tx in
///         let order = try await tx.insert(order)
///         try await store.enqueue(jobs.prepare(ShipOrder(id: order.id)), in: tx)
///     }
/// }
/// ```
///
/// That removes the gap every other arrangement has: a job enqueued after the
/// commit is lost if the process dies in between, and one enqueued before it
/// runs against a change that may still roll back.
///
/// ## The table
///
/// ``createTableIfNeeded()`` creates it, for tests and for deployments not
/// using `alula migrate`. A migrated application should own it in a migration
/// instead. ``schema(table:)`` is the SQL to put in one.
public struct PostgresQueueStore: QueueStore {
    private let dataSource: PostgresDataSource
    private let table: String
    private let logger: Logger

    public init(
        dataSource: PostgresDataSource, table: String = "alula_jobs",
        logger: Logger = Logger(label: "alula.queue.postgres")
    ) {
        self.dataSource = dataSource
        self.table = table
        self.logger = logger
    }

    private var name: String { Self.quoted(table) }

    // MARK: Enqueue

    public func enqueue(_ job: NewQueuedJob) async throws -> EnqueueResult {
        try await dataSource.withRepo { repo in try await enqueue(job, in: repo) }
    }

    /// Writes `job` through `repo` — inside its transaction, when it has one.
    public func enqueue(_ job: NewQueuedJob, in repo: Repo) async throws -> EnqueueResult {
        // Twice at most: a duplicate that finishes between our failed insert
        // and our look-up leaves nothing to return, and then an insert wins.
        for _ in 0..<3 {
            let inserted = try await repo.execute(
                """
                INSERT INTO \(raw: name)
                    (id, kind, queue, payload, priority, run_at, max_attempts, unique_key,
                     inserted_at, state, attempt)
                VALUES (\(job.id.rawValue), \(job.kind), \(job.queue),
                        \(String(decoding: job.payload, as: UTF8.self))::jsonb, \(job.priority),
                        \(job.runAt), \(job.maxAttempts), \(job.uniqueKey), \(job.enqueuedAt),
                        'available', 0)
                ON CONFLICT (kind, unique_key)
                    WHERE unique_key IS NOT NULL AND state IN ('available', 'running')
                DO NOTHING
                RETURNING id
                """)
            for try await id in inserted.decode(UUID.self) {
                return .enqueued(QueuedJobID(id))
            }
            let existing = try await repo.execute(
                """
                SELECT id FROM \(raw: name)
                WHERE kind = \(job.kind) AND unique_key = \(job.uniqueKey)
                  AND state IN ('available', 'running')
                LIMIT 1
                """)
            for try await id in existing.decode(UUID.self) {
                return .duplicate(QueuedJobID(id))
            }
        }
        throw PostgresQueueStoreError.uniqueRace(kind: job.kind)
    }

    // MARK: Claim and results

    public func claim(
        queue: String, kinds: Set<String>, limit: Int, now: Date, leaseUntil: Date
    ) async throws -> [ClaimedJob] {
        guard limit > 0, !kinds.isEmpty else { return [] }
        return try await dataSource.withRepo { repo in
            let rows = try await repo.execute(
                """
                WITH picked AS (
                    SELECT id FROM \(raw: name)
                    WHERE queue = \(queue) AND kind = ANY(\(Array(kinds).sorted())::text[])
                      AND ((state = 'available' AND run_at <= \(now))
                        OR (state = 'running' AND lease_until < \(now)))
                    ORDER BY priority, run_at, id
                    LIMIT \(limit)
                    FOR UPDATE SKIP LOCKED
                )
                UPDATE \(raw: name) AS job
                SET state = 'running', attempt = job.attempt + 1, lease_until = \(leaseUntil)
                FROM picked WHERE job.id = picked.id
                RETURNING job.id, job.kind, job.queue, job.payload::text, job.attempt,
                          job.max_attempts, job.inserted_at, job.priority, job.run_at
                """)
            var claimed: [(ClaimedJob, Int, Date)] = []
            for try await (id, kind, queue, payload, attempt, maxAttempts, inserted, priority, runAt)
                in rows.decode((UUID, String, String, String, Int, Int, Date, Int, Date).self)
            {
                claimed.append(
                    (
                        ClaimedJob(
                            id: QueuedJobID(id), kind: kind, queue: queue,
                            payload: Data(payload.utf8), attempt: attempt,
                            maxAttempts: maxAttempts, enqueuedAt: inserted),
                        priority, runAt
                    ))
            }
            // RETURNING does not keep the CTE's order.
            return claimed.sorted { ($0.1, $0.2) < ($1.1, $1.2) }.map(\.0)
        }
    }

    public func extendLeases(_ jobs: [(id: QueuedJobID, attempt: Int)], until: Date) async throws {
        guard !jobs.isEmpty else { return }
        try await dataSource.withRepo { repo in
            _ = try await repo.execute(
                """
                UPDATE \(raw: name) AS job SET lease_until = \(until)
                FROM unnest(\(jobs.map(\.id.rawValue))::uuid[], \(jobs.map(\.attempt))::bigint[])
                    AS held(id, attempt)
                WHERE job.id = held.id AND job.attempt = held.attempt AND job.state = 'running'
                """)
        }
    }

    public func complete(_ id: QueuedJobID, attempt: Int, at: Date) async throws -> Bool {
        try await updated(
            """
            UPDATE \(raw: name) SET state = 'completed', finished_at = \(at), lease_until = NULL
            WHERE id = \(id.rawValue) AND attempt = \(attempt) AND state = 'running'
            RETURNING id
            """)
    }

    public func retry(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws
        -> Bool
    {
        try await updated(
            """
            UPDATE \(raw: name)
            SET state = 'available', run_at = \(runAt), lease_until = NULL, last_error = \(error)
            WHERE id = \(id.rawValue) AND attempt = \(attempt) AND state = 'running'
            RETURNING id
            """)
    }

    public func discard(_ id: QueuedJobID, attempt: Int, at: Date, error: String) async throws
        -> Bool
    {
        try await updated(
            """
            UPDATE \(raw: name)
            SET state = 'discarded', finished_at = \(at), lease_until = NULL, last_error = \(error)
            WHERE id = \(id.rawValue) AND attempt = \(attempt) AND state = 'running'
            RETURNING id
            """)
    }

    /// Runs a fenced result update; whether it matched is whether the attempt
    /// still held the job.
    private func updated(_ statement: SQLFragment) async throws -> Bool {
        try await dataSource.withRepo { repo in
            let rows = try await repo.execute(statement)
            for try await _ in rows.decode(UUID.self) { return true }
            return false
        }
    }

    // MARK: Inspection and upkeep

    public func counts(queue: String) async throws -> QueueCounts {
        try await dataSource.withRepo { repo in
            let rows = try await repo.execute(
                """
                SELECT state, count(*) FROM \(raw: name) WHERE queue = \(queue) GROUP BY state
                """)
            var counts = QueueCounts()
            for try await (state, count) in rows.decode((String, Int).self) {
                switch state {
                case "available": counts.available = count
                case "running": counts.running = count
                case "completed": counts.completed = count
                case "discarded": counts.discarded = count
                default: break
                }
            }
            return counts
        }
    }

    public func prune(completedBefore: Date, discardedBefore: Date) async throws -> Int {
        try await dataSource.withRepo { repo in
            let rows = try await repo.execute(
                """
                WITH pruned AS (
                    DELETE FROM \(raw: name)
                    WHERE (state = 'completed' AND finished_at < \(completedBefore))
                       OR (state = 'discarded' AND finished_at < \(discardedBefore))
                    RETURNING 1
                )
                SELECT count(*) FROM pruned
                """)
            for try await count in rows.decode(Int.self) { return count }
            return 0
        }
    }

    /// The last error recorded for a job, and its state — for an operator
    /// looking at a dead letter.
    public func inspect(_ id: QueuedJobID) async throws -> (state: String, lastError: String?)? {
        try await dataSource.withRepo { repo in
            let rows = try await repo.execute(
                "SELECT state, last_error FROM \(raw: name) WHERE id = \(id.rawValue)")
            for try await (state, error) in rows.decode((String, String?).self) {
                return (state, error)
            }
            return nil
        }
    }

    // MARK: Schema

    /// Creates the table and its indexes if absent.
    public func createTableIfNeeded() async throws {
        try await dataSource.withRepo { repo in
            for statement in Self.schema(table: table) {
                try await repo.execute(SQLFragment(stringLiteral: statement))
            }
        }
    }

    /// The statements that create the queue table — for a migration.
    public static func schema(table: String = "alula_jobs") -> [String] {
        let name = quoted(table)
        return [
            """
            CREATE TABLE IF NOT EXISTS \(name) (
                id uuid PRIMARY KEY,
                kind text NOT NULL,
                queue text NOT NULL,
                payload jsonb NOT NULL,
                state text NOT NULL
                    CHECK (state IN ('available', 'running', 'completed', 'discarded')),
                priority integer NOT NULL DEFAULT 0,
                attempt integer NOT NULL DEFAULT 0,
                max_attempts integer NOT NULL,
                run_at timestamptz NOT NULL,
                lease_until timestamptz,
                unique_key text,
                last_error text,
                inserted_at timestamptz NOT NULL,
                finished_at timestamptz
            )
            """,
            // The claim's access path: only live rows, in claim order.
            """
            CREATE INDEX IF NOT EXISTS \(quoted(table + "_claim_idx"))
            ON \(name) (queue, priority, run_at, id) WHERE state IN ('available', 'running')
            """,
            """
            CREATE UNIQUE INDEX IF NOT EXISTS \(quoted(table + "_unique_idx"))
            ON \(name) (kind, unique_key)
            WHERE unique_key IS NOT NULL AND state IN ('available', 'running')
            """,
            """
            CREATE INDEX IF NOT EXISTS \(quoted(table + "_finished_idx"))
            ON \(name) (finished_at) WHERE state IN ('completed', 'discarded')
            """,
        ]
    }

    /// Identifier quoting, so a configured table name cannot become an
    /// injection point.
    static func quoted(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

public enum PostgresQueueStoreError: Error, Sendable, CustomStringConvertible {
    case uniqueRace(kind: String)

    public var description: String {
        switch self {
        case .uniqueRace(let kind):
            "could not enqueue a unique \(kind) job: its duplicate kept appearing and vanishing"
        }
    }
}
