import Foundation
import FlightDataPostgres

// MARK: - Entities (design, now Hangar @Entity — hangar-design)
//
// Column names are camelCase via @Column overrides because the migrated
// fdp_* schema predates Hangar's snake_case default (it matched
// StructuredQueries' no-conversion mapping).

struct Profile: Codable, Equatable, Sendable {
    var bio: String
    var loginCount: Int
}

/// The design doc's example entity, against the migrated fdp_users table.
@Entity("fdp_users")
struct User: Equatable, Sendable {
    @ID var id: UUID
    var email: String
    @Column("lastName") var lastName: String
    var age: Int
    @Column("createdAt") var createdAt: Date
    @JSONB var profile: Profile?
    var nickname: String?
    @Column("isActive") var isActive: Bool = true
}

@Entity("fdp_accounts")
struct Account: Equatable, Sendable {
    @ID let id: String
    var balance: Int
}

@Entity("fdp_transfers")
struct Transfer: Equatable, Sendable {
    @ID let id: String
    var origin: String
    var destination: String
    var amount: Int
}

// MARK: - Repositories
//
// A repository holds the *pool* and leases a connection per operation through
// `withRepo`. It used to hold a `.scoped` `Repo` and `PostgresConnection`,
// both bound to a connection held for the whole request — which made the
// repository request-scoped, and everything holding it request-scoped too.

@Repository
struct UserRepository {
    @Inject var pool: PostgresDataSource

    func find(byEmail email: String) async throws -> User? {
        try await pool.withRepo { repo in
            try await repo.one(User.where { $0.email == email })
        }
    }

    func recentlyActive(since: Date, limit: Int) async throws -> [User] {
        try await pool.withRepo { repo in
            try await repo.all(
                User.where { $0.createdAt > since }
                    .order { $0.createdAt.desc() }
                    .limit(limit))
        }
    }

    func insert(_ user: User) async throws {
        try await pool.withRepo { repo in
            try await repo.insert(user)
        }
    }
}

enum LedgerError: Error, Equatable {
    case insufficientFunds(account: String)
}

/// The transaction example, executable. Each method that needs atomicity
/// opens the transaction itself, so the boundary is visible in the code that
/// establishes it. `transfer` used to be `@Transactional`, which put the
/// boundary in an annotation and left the reader to know that every Hangar
/// query underneath shared the scope's connection.
@Repository
struct LedgerRepository {
    @Inject var pool: PostgresDataSource

    func balance(of account: String) async throws -> Int? {
        try await pool.withRepo { repo in
            try await repo.one(Account.where { $0.id == account }.select { $0.balance })
        }
    }

    func transfer(_ amount: Int, from origin: String, to destination: String) async throws {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                try await Self.transfer(amount, from: origin, to: destination, in: tx)
            }
        }
    }

    /// The transfer itself, against a repo the caller has already put in a
    /// transaction — so `batchTransfer` can nest several of these under one
    /// outer transaction, each as its own savepoint.
    private static func transfer(
        _ amount: Int, from origin: String, to destination: String, in tx: Repo
    ) async throws {
        guard var debited = try await tx.one(Account.where { $0.id == origin }),
            debited.balance >= amount
        else {
            throw LedgerError.insufficientFunds(account: origin)
        }
        guard var credited = try await tx.one(Account.where { $0.id == destination }) else {
            throw LedgerError.insufficientFunds(account: destination)
        }
        debited.balance -= amount
        credited.balance += amount
        try await tx.update(debited)
        try await tx.update(credited)
        try await tx.insert(
            Transfer(id: UUID().uuidString, origin: origin, destination: destination, amount: amount))
    }

    /// Nested transactions: each inner transfer runs under a savepoint, so a
    /// failed one rolls back to its savepoint without disturbing transfers
    /// already made in this batch. Hangar tracks the nesting depth itself.
    func batchTransfer(
        _ transfers: [(amount: Int, from: String, to: String)]
    ) async throws -> Int {
        try await pool.withRepo { repo in
            try await repo.transaction { outer in
                var applied = 0
                for transfer in transfers {
                    do {
                        try await outer.transaction { inner in
                            try await Self.transfer(
                                transfer.amount, from: transfer.from, to: transfer.to, in: inner)
                        }
                        applied += 1
                    } catch LedgerError.insufficientFunds {
                        continue
                    }
                }
                return applied
            }
        }
    }

    /// Transfers, then fails — rollback demonstration.
    func transferThenFail(_ amount: Int, from origin: String, to destination: String) async throws {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                try await Self.transfer(amount, from: origin, to: destination, in: tx)
                throw LedgerError.insufficientFunds(account: "deliberate-failure")
            }
        }
    }

    func allTransfers() async throws -> [Transfer] {
        try await pool.withRepo { repo in
            try await repo.all(Transfer.all)
        }
    }

    /// Unwrapped debit — no transaction of its own, for tests that drive
    /// transaction control by hand.
    func debit(_ amount: Int, from account: String) async throws {
        try await pool.withRepo { repo in
            guard var debited = try await repo.one(Account.where { $0.id == account }) else {
                throw LedgerError.insufficientFunds(account: account)
            }
            debited.balance -= amount
            try await repo.update(debited)
        }
    }

    func seed(_ account: Account) async throws {
        try await pool.withRepo { repo in
            try await repo.insert(account)
        }
    }
}

// MARK: - The test application module

final class TestAppModule: FlightModule {
    static var dependencies: [any FlightModule.Type] {
        [PostgresDataModule<PrimaryDataSource>.self]
    }

    init() {}

    func configure(_ container: Container) throws {
        try UserRepository._flightRegister(container)
        try LedgerRepository._flightRegister(container)
    }
}
