import Foundation
import FlightCore
import FlightDataCore
import FlightDataPostgres
import Testing

/// The properties that only a live pool can prove: per-operation lease and
/// return-to-pool, pool exhaustion, liveness, and repositories wired through
/// the real `@Repository`/`@Inject` macro path.
extension PostgresIntegrationSuite {
@Suite("Pooled connections against Postgres")
struct ScopingIntegrationTests {
    @Test func repositoryFindsInsertedRows() async throws {
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            let user = User(
                id: UUID(), email: "ada@example.com", lastName: "Lovelace", age: 36,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                profile: Profile(bio: "first programmer", loginCount: 1),
                nickname: nil)

            try await container.withScope { scope in
                let repo = try container.resolve(UserRepository.self, in: scope)
                try await repo.insert(user)
                let found = try await repo.find(byEmail: "ada@example.com")
                #expect(found == user)
                #expect(try await repo.find(byEmail: "nobody@example.com") == nil)
            }
        }
    }

    @Test func designDocExampleTest() async throws {
        // example test, verbatim in behavior: unknown email → nil.
        try await withPostgresContainer { container, source in
            try await cleanTables(source)
            try await container.withScope { scope in
                let repo = try container.resolve(UserRepository.self, in: scope)
                #expect(try await repo.find(byEmail: "nobody@example.com") == nil)
            }
        }
    }

    @Test func scopeCloseReturnsConnectionToPool() async throws {
        try await withPostgresContainer { container, source in
            try container.withScope { scope in
                _ = try container.resolve(UserRepository.self, in: scope)
                #expect(source.activeCheckouts == 1)
            }
            #expect(source.activeCheckouts == 0)

            // The returned connection is reused, not replaced.
            let before = source.totalCheckouts
            try container.withScope { scope in
                _ = try container.resolve(UserRepository.self, in: scope)
            }
            #expect(source.totalCheckouts == before + 1)
            #expect(source.establishedConnections == source.poolSize)
        }
    }

    @Test func exhaustedPoolThrowsPromptly() async throws {
        try await withPostgresContainer(poolSize: 1) { container, source in
            try container.withScope { holder in
                _ = try container.resolve(UserRepository.self, in: holder)
                _ = container.withScope { starved in
                    // Prompt error, never parking (Flight Data Core D1).
                    #expect(throws: DataSourceError.poolExhausted(datasource: "primary", poolSize: 1)) {
                        _ = try container.resolve(UserRepository.self, in: starved)
                    }
                }
            }
        }
    }

    @Test func livenessProbeAnswers() async throws {
        try await withPostgresContainer { container, _ in
            let probes = try DataSourceLiveness.all(in: container)
            let primary = try #require(probes.first { $0.datasourceName == "primary" })
            try await primary.ping()
        }
    }

    @Test func closedPoolRefusesCheckout() async throws {
        try await withPostgresContainer { container, source in
            await source.shutdown()
            #expect(throws: DataSourceError.closed(datasource: "primary")) {
                _ = try source.checkout()
            }
        }
    }
}
}
