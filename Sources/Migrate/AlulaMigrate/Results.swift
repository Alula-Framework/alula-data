import Foundation

/// One migration applied by `migrate()`.
public struct AppliedMigration: Sendable {
    /// The migration's version.
    public let version: Int64
    /// The migration's type name.
    public let name: String
    /// How long it took, including its commit.
    public let duration: Duration

    /// A result as the migrator reports it.
    public init(version: Int64, name: String, duration: Duration) {
        self.version = version
        self.name = name
        self.duration = duration
    }
}

/// One migration reverted by `rollback(...)`.
public struct RolledBackMigration: Sendable {
    /// The migration's version.
    public let version: Int64
    /// The migration's type name.
    public let name: String
    /// How long its `down` took, including its commit.
    public let duration: Duration

    /// A result as the migrator reports it.
    public init(version: Int64, name: String, duration: Duration) {
        self.version = version
        self.name = name
        self.duration = duration
    }
}

/// The result of `status()`: applied + pending, with per-migration checksum state.
public struct MigrationStatus: Sendable {
    /// How an applied migration compares with this binary.
    public enum AppliedState: Sendable, Equatable {
        /// Recorded checksum matches the registered migration.
        case ok
        /// Source drift: the run-blocking state `repair()` fixes.
        case checksumMismatch(recorded: String, current: String)
        /// Applied in the database, but not registered in this binary.
        case missingLocally
    }

    /// A migration the ledger records as applied.
    public struct Applied: Sendable {
        /// The migration's version.
        public let version: Int64
        /// The name recorded in the ledger.
        public let name: String
        /// When it was applied, by the database's clock.
        public let appliedAt: Date
        /// Whether this binary still agrees with what was applied.
        public let state: AppliedState

        public init(version: Int64, name: String, appliedAt: Date, state: AppliedState) {
            self.version = version
            self.name = name
            self.appliedAt = appliedAt
            self.state = state
        }
    }

    /// A registered migration the ledger does not record.
    public struct Pending: Sendable {
        /// The migration's version.
        public let version: Int64
        /// The migration's type name.
        public let name: String
        /// Whether it will run in a transaction, and so roll back cleanly if it fails.
        public let transactional: Bool

        public init(version: Int64, name: String, transactional: Bool) {
            self.version = version
            self.name = name
            self.transactional = transactional
        }
    }

    /// Everything the ledger records, in version order.
    public let applied: [Applied]
    /// What `migrate()` would apply, in the order it would apply them.
    public let pending: [Pending]

    public init(applied: [Applied], pending: [Pending]) {
        self.applied = applied
        self.pending = pending
    }

    /// Whether any applied migration has drifted from its recorded checksum.
    public var hasDrift: Bool {
        applied.contains {
            if case .checksumMismatch = $0.state { return true }
            return false
        }
    }

    /// Whether the database is fully migrated for this binary.
    public var isUpToDate: Bool { pending.isEmpty }
}

/// The result of `repair()`.
public struct RepairOutcome: Sendable, Equatable {
    /// One ledger row whose checksum or name was rewritten.
    public struct Repaired: Sendable, Equatable {
        /// The migration's version.
        public let version: Int64
        /// The name now recorded.
        public let name: String
        /// The checksum that was recorded.
        public let oldChecksum: String
        /// The checksum now recorded, matching this binary.
        public let newChecksum: String

        public init(version: Int64, name: String, oldChecksum: String, newChecksum: String) {
            self.version = version
            self.name = name
            self.oldChecksum = oldChecksum
            self.newChecksum = newChecksum
        }
    }

    /// Rows whose recorded checksum (and name, if renamed) was re-baselined.
    public let repaired: [Repaired]
    /// Applied rows with no registered migration — repair cannot help; reported for visibility.
    public let missingLocally: [UnknownApplied]

    public init(repaired: [Repaired], missingLocally: [UnknownApplied]) {
        self.repaired = repaired
        self.missingLocally = missingLocally
    }
}

/// A preview of what `migrate()`/`rollback(...)` would execute, with rendered SQL.
/// Produced by `planMigrate()` / `planRollback(...)`; used by the CLI's `--dry-run`.
public struct MigrationPlan: Sendable {
    /// One migration the plan would run.
    public struct Step: Sendable {
        /// The migration's version.
        public let version: Int64
        /// The migration's type name.
        public let name: String
        /// Whether it would run in a transaction.
        public let transactional: Bool
        /// The statements that would run, in order (bookkeeping writes not included).
        public let statements: [String]

        public init(version: Int64, name: String, transactional: Bool, statements: [String]) {
            self.version = version
            self.name = name
            self.transactional = transactional
            self.statements = statements
        }
    }

    /// `up` for a migrate plan, `down` for a rollback plan.
    public let direction: MigrationDirection
    /// The migrations, in the order they would run.
    public let steps: [Step]

    public init(direction: MigrationDirection, steps: [Step]) {
        self.direction = direction
        self.steps = steps
    }
}
