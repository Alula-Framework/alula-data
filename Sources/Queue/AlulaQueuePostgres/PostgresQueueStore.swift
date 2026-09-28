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
///
/// ## What survives a crash
///
/// Every committed row. A claim holds its row lock only for the claiming
/// statement; after that a job belongs to its worker by lease. A worker that
/// dies leaves its jobs `running` until `lease_until` passes, when the next
/// claim takes them with the next attempt number, and the dead attempt's
/// results are fenced out. What that attempt did outside the database is
/// not undone, so a handler can run more than once for one job. Timestamps
/// (`now`, `leaseUntil`, `runAt`) are the callers' clocks, not the
/// database's. See Docs/operations.md.
public struct PostgresQueueStore: QueueStore {
    private let dataSource: PostgresDataSource
    private let table: String
    private let logger: Logger

    /// A store over `table`, borrowing connections from `dataSource` per
    /// operation. Touches nothing until used; the table must already exist.
    ///
    /// - Parameters:
    ///   - dataSource: The pool every operation leases from.
    ///   - table: One table name, quoted as a single identifier —
    ///     `"ops.jobs"` names a table called `ops.jobs` in the search path,
    ///     not `jobs` in schema `ops`.
    ///   - logger: Where the store logs.
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

    /// Writes `job` on a connection of its own, committed when this returns.
    ///
    /// Not tied to any transaction the caller has open; for that, use
    /// ``enqueue(_:in:)``.
    public func enqueue(_ job: NewQueuedJob) async throws -> EnqueueResult {
        try await withRepo { repo in try await enqueue(job, in: repo) }
    }

    /// Writes `job` through `repo` — inside its transaction, when it has one.
    ///
    /// Pass the `tx` of `repo.transaction { tx in … }` and the job commits or
    /// rolls back with everything else in it; no worker can see it before
    /// the commit. A job with a `uniqueKey` that matches one still
    /// `available` or `running` is not written, and the existing job's id is
    /// returned as `.duplicate`.
    ///
    /// - Throws: A database error from the insert, or
    ///   ``PostgresQueueStoreError/uniqueRace(kind:)`` when a duplicate kept
    ///   appearing and disappearing across three tries.
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

    /// Claims up to `limit` due jobs, in priority then `run_at` order.
    ///
    /// Due means `available` with `run_at` at or before `now`, or `running`
    /// with a lease that expired before `now` — a crashed worker's job. Each
    /// claimed row becomes `running` with `lease_until = leaseUntil` and its
    /// attempt incremented, in one statement using `FOR UPDATE SKIP LOCKED`,
    /// so concurrent claims never return the same row. The row lock ends with
    /// the statement; keep the job by renewing its lease with
    /// ``extendLeases(_:until:)``.
    public func claim(
        queue: String, kinds: Set<String>, limit: Int, now: Date, leaseUntil: Date
    ) async throws -> [ClaimedJob] {
        guard limit > 0, !kinds.isEmpty else { return [] }
        return try await withRepo { repo in
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

    /// Moves the lease of each job still `running` under the given attempt
    /// to `until`. A job claimed again since — its lease expired — is left
    /// alone, silently.
    public func extendLeases(_ jobs: [(id: QueuedJobID, attempt: Int)], until: Date) async throws {
        guard !jobs.isEmpty else { return }
        try await withRepo { repo in
            _ = try await repo.execute(
                """
                UPDATE \(raw: name) AS job SET lease_until = \(until)
                FROM unnest(\(jobs.map(\.id.rawValue))::uuid[], \(jobs.map(\.attempt))::bigint[])
                    AS held(id, attempt)
                WHERE job.id = held.id AND job.attempt = held.attempt AND job.state = 'running'
                """)
        }
    }

    /// Marks the job `completed`. Returns `false`, changing nothing, when
    /// `attempt` no longer holds the job — its lease expired and another
    /// claim took it.
    public func complete(_ id: QueuedJobID, attempt: Int, at: Date) async throws -> Bool {
        try await updated(
            """
            UPDATE \(raw: name) SET state = 'completed', finished_at = \(at), lease_until = NULL
            WHERE id = \(id.rawValue) AND attempt = \(attempt) AND state = 'running'
            RETURNING id
            """)
    }

    /// Makes the job `available` again at `runAt`, recording `error`.
    /// Returns `false`, changing nothing, when `attempt` no longer holds it.
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

    /// Makes the job `available` again at `runAt` with its attempt given
    /// back, recording `error`: the worker stopped it at shutdown, which is
    /// not the job failing, so the next claim runs it at the same attempt —
    /// even its last. Returns `false`, changing nothing, when `attempt` no
    /// longer holds it.
    ///
    /// Fencing still holds. Attempts only grow while a job is `running`: the
    /// decrement happens as it leaves `running`, and the next claim takes it
    /// back to this attempt, which only the worker handing it back ever held.
    public func handBack(_ id: QueuedJobID, attempt: Int, runAt: Date, error: String) async throws
        -> Bool
    {
        try await updated(
            """
            UPDATE \(raw: name)
            SET state = 'available', run_at = \(runAt), lease_until = NULL, last_error = \(error),
                attempt = attempt - 1
            WHERE id = \(id.rawValue) AND attempt = \(attempt) AND state = 'running'
            RETURNING id
            """)
    }

    /// Marks the job `discarded` — a dead letter kept until pruned —
    /// recording `error`. Returns `false`, changing nothing, when `attempt`
    /// no longer holds it.
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
        try await withRepo { repo in
            let rows = try await repo.execute(statement)
            for try await _ in rows.decode(UUID.self) { return true }
            return false
        }
    }

    // MARK: Inspection and upkeep

    /// Jobs in `queue` by state, from one `GROUP BY` over the table.
    public func counts(queue: String) async throws -> QueueCounts {
        try await withRepo { repo in
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

    /// Deletes jobs that finished before the given dates, and returns how
    /// many. Jobs still `available` or `running` are never touched.
    public func prune(completedBefore: Date, discardedBefore: Date) async throws -> Int {
        try await withRepo { repo in
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
        try await withRepo { repo in
            let rows = try await repo.execute(
                "SELECT state, last_error FROM \(raw: name) WHERE id = \(id.rawValue)")
            for try await (state, error) in rows.decode((String, String?).self) {
                return (state, error)
            }
            return nil
        }
    }

    // MARK: Schema

    /// Runs ``schema(table:)`` against this store's table.
    ///
    /// Idempotent — every statement is `IF NOT EXISTS` — and not
    /// transactional: a failure partway can leave the table without some of
    /// its indexes, which a rerun adds. It does not alter a table that
    /// already exists in another shape. For tests and deployments without
    /// migrations; otherwise put ``schema(table:)`` in a migration.
    public func createTableIfNeeded() async throws {
        try await withRepo { repo in
            for statement in Self.schema(table: table) {
                try await repo.execute(SQLFragment(stringLiteral: statement))
            }
        }
    }

    /// The statements that create the queue table and its three partial
    /// indexes — for a migration, one `schema.raw(_:)` per statement.
    ///
    /// Every statement is `CREATE … IF NOT EXISTS`, so running them against
    /// an existing table changes nothing, including a table in an older
    /// shape. `table` is quoted as one identifier, as in
    /// ``init(dataSource:table:logger:)``, and the index names are derived
    /// from it.
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

/// A failure the queue store reports itself; database errors pass through.
public enum PostgresQueueStoreError: Error, Sendable, CustomStringConvertible {
    /// A unique job's insert conflicted, but the conflicting job had finished
    /// by the time it was looked up, three times running.
    case uniqueRace(kind: String)

    public var description: String {
        switch self {
        case .uniqueRace(let kind):
            "could not enqueue a unique \(kind) job: its duplicate kept appearing and vanishing"
        }
    }
}

extension PostgresQueueStore {
    /// The pool's `withRepo`, with a connection-level `PSQLError` rethrown as
    /// a ``PostgresFailure`` so the worker's log says what went wrong
    /// (Relay #43).
    fileprivate func withRepo<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Repo) async throws -> T
    ) async throws -> T {
        try await describingPostgresFailures { try await dataSource.withRepo(body) }
    }
}

