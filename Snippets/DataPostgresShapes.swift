// The API shapes Docs/data-postgres.md shows, compiled by the build.
//
// A page that shows an API is a claim about it. Each block below is the
// page's example as written, wrapped only as far as it takes to compile.
// Where the page leaves a helper to the reader (`debit`, `credit`), a stub
// with a plausible signature stands in. The streamed-response example is
// not here: it needs AlulaWeb, which this package does not depend on.
import AlulaDataPostgres
import AlulaMigrate
import Foundation

// "Using it": an entity.
@Entity("users")
struct User: Encodable, Equatable, Sendable {
    @ID var id: UUID
    var email: String
    @Column("lastName") var lastName: String
    var age: Int
    @Column("createdAt") var createdAt: Date
}

// "Using it": a repository holding the pool.
@Repository
struct UserRepository {
    // alula:hand-registered — the pool comes from PostgresDataModule, which
    // the registration generator cannot see; the marker silences its warning.
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
}

// "Transactions".
@Entity("accounts")
struct Account: Encodable, Equatable, Sendable {
    @ID var id: String
    var balance: Int
}

func debit(_ id: String, _ amount: Int) -> Account { Account(id: id, balance: -amount) }
func credit(_ id: String, _ amount: Int) -> Account { Account(id: id, balance: amount) }

@Repository
struct LedgerRepository {
    @Inject var pool: PostgresDataSource

    func transfer(_ amount: Int, from: String, to: String) async throws {
        try await pool.withRepo { repo in
            try await repo.transaction { tx in
                try await tx.update(debit(from, amount))
                try await tx.update(credit(to, amount))
            }
        }
    }
}

// "Read replicas".
@Entity("posts")
struct Post: Encodable, Equatable, Sendable {
    @ID var id: UUID
    var published: Bool
}

func readReplicaShape(pool: PostgresDataSource) async throws {
    let feed = try await pool.withReadRepo { repo in
        try await repo.all(Post.where { $0.published }.limit(50))
    }
    _ = feed
}

// "Changesets".
struct ProfileInput { var email: String }

func changesetShape(repo: Repo, user: User, input: ProfileInput) async throws {
    let changeset = Changeset(original: user)
        .change(\.email, input.email)
        .validate(\.email, .email)
    try await repo.update(changeset)
}

// "Streaming holds a connection…", without the HTTP response around it.
func streamShape(pool: PostgresDataSource, query: Query<User, User>) async throws {
    _ = try await pool.withRepo { repo in
        try await repo.stream(query) { rows in
            for try await row in rows { _ = row }
        }
    }
}

// "Migrations".
func migrationsShape(_allMigrations: () -> [MigrationEntry]) async throws {
    try await PostgresMigrations.migrate(
        configuration: try Configuration.load(),
        migrations: _allMigrations()
    )
}
