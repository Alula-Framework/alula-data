import Foundation
import AlulaCore
import AlulaDataCore
import AlulaDataPostgres
import Testing

/// Changesets against a real server — now through Hangar (hangar-design
///): the `Repo` consumes `Changeset` directly, and the `@Entity` macro
/// generates the `TableModel` metadata one type needs to serve both queries
/// and changesets. The repo comes from a `withRepo` bracket, which leases a
/// connection for the bracket's extent; it used to be a `.scoped` component
/// resolved out of the ambient scope.
extension PostgresIntegrationSuite {
@Suite("Changeset writes through a leased Repo")
struct ChangesetIntegrationTests {
    @Test func insertChangesetWritesRow() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let id = UUID()
            let changeset = Changeset(User.self)
                .change(\.id, id)
                .change(\.email, "grace@example.com")
                .change(\.lastName, "Hopper")
                .change(\.age, 45)
                .change(\.createdAt, Date(timeIntervalSince1970: 1_600_000_000))
                .change(\.isActive, true)
                .validate(\.email, .email)
                .validate(\.lastName, .length(1...80))

            let pool = app.pool
            try await pool.withRepo { repo in
                try await repo.insert(changeset)
                let found = try await repo.all(User.where { $0.email == "grace@example.com" })
                #expect(found.count == 1)
                #expect(found.first?.lastName == "Hopper")
                #expect(found.first?.id == id)
            }
        }
    }

    @Test func updateChangesetWritesOnlyDirtyColumns() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let original = User(
                id: UUID(), email: "grace@example.com", lastName: "Hopper", age: 45,
                createdAt: Date(timeIntervalSince1970: 1_600_000_000),
                profile: nil, nickname: "amazing")

            let pool = app.pool
            try await pool.withRepo { repo in
                try await repo.insert(original)

                let changeset = Changeset(original: original)
                    .change(\.email, "grace@navy.mil")
                    .change(\.lastName, "Hopper")  // unchanged → not dirty, not written
                    .change(\.nickname, String?.none)  // explicit set-to-NULL
                    .validate(\.email, .email)
                let changes = try changeset.validatedChanges()
                #expect(Set(changes.changedFields.keys) == ["email", "nickname"])

                try await repo.update(changeset)
                let found = try await repo.one(User.where { $0.id == original.id })
                #expect(found?.email == "grace@navy.mil")
                #expect(found?.nickname == nil)
                #expect(found?.lastName == "Hopper")
            }
        }
    }

    @Test func invalidChangesetNeverReachesTheDriver() throws {
        let changeset = Changeset(User.self)
            .change(\.email, "not-an-email")
            .validate(\.email, .email)
        #expect(!changeset.isValid)
        #expect(throws: ChangesetValidationError.self) {
            _ = try changeset.validatedChanges()
        }
    }

    /// The ambient binding: inside `withRepo`, `Repo.require()` answers with
    /// the repo bound to that bracket's leased connection.
    @Test func ambientRepoIsBoundInsideWithRepo() async throws {
        try await withPostgresContainer { app, source in
            try await cleanTables(source)
            let pool = app.pool
            try await pool.withRepo { _ in
                let repo = try Repo.require()
                try await repo.insert(
                    User(
                        id: UUID(), email: "ambient@example.com", lastName: "Ambient", age: 1,
                        createdAt: Date(), profile: nil, nickname: nil))
                let count = try await repo.count(User.all)
                #expect(count == 1)
            }
        }
    }
}
}
