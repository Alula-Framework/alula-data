import AlulaCore
import AlulaDataCore
import Foundation
import Hangar
import PostgresNIO
import Testing

@testable import AlulaDataPostgres

/// Routing, proven with a second database on the same server standing in for
/// the replica: which rows come back says which pool answered. Replication
/// itself is Postgres's to test.
@Suite("Read replicas", .serialized, .enabled(if: TestDatabase.isConfigured))
struct ReadReplicaTests {
    static let replicaDatabase = "alula_replica_test"

    /// The test URL with its database swapped.
    private func url(database: String) throws -> String {
        let base = try #require(TestDatabase.url)
        var components = try #require(URLComponents(string: base))
        components.path = "/\(database)"
        return try #require(components.string)
    }

    private func primaryDatabase() throws -> String {
        let base = try #require(TestDatabase.url)
        return try #require(URLComponents(string: base)).path.trimmingCharacters(in: ["/"])
    }

    /// One `marker` row per database, saying which one it is.
    private func prepare() async throws {
        let admin = try PostgresDataSource(
            settings: try DataSourceSettings(name: "admin", url: try #require(TestDatabase.url), poolSize: 1))
        try await admin.start()
        try await admin.withRepo { repo in
            let exists = try await repo.execute(
                "SELECT 1 FROM pg_database WHERE datname = \(Self.replicaDatabase)")
            var found = false
            for try await _ in exists.decode(Int.self) { found = true }
            if !found { try await repo.execute("CREATE DATABASE \(raw: Self.replicaDatabase)") }
        }
        await admin.shutdown()
        for database in [try primaryDatabase(), Self.replicaDatabase] {
            let pool = try PostgresDataSource(
                settings: try DataSourceSettings(name: database, url: try url(database: database), poolSize: 1))
            try await pool.start()
            try await pool.withRepo { repo in
                try await repo.execute("CREATE TABLE IF NOT EXISTS replica_marker (source text)")
                try await repo.execute("TRUNCATE replica_marker")
                try await repo.execute("INSERT INTO replica_marker VALUES (\(database))")
            }
            await pool.shutdown()
        }
    }

    private func source(_ repo: Repo) async throws -> String {
        let rows = try await repo.execute("SELECT source FROM replica_marker")
        for try await source in rows.decode(String.self) { return source }
        return "none"
    }

    @Test("reads that opt in go to the replica; everything else stays on the primary")
    func routing() async throws {
        try await prepare()
        var values = try TestDatabase.values()
        values[DataSourceConfigKey.replicaURL(datasource: "primary")] = try url(database: Self.replicaDatabase)
        let module = try PostgresDataModule<PrimaryDataSource>(configuration: Configuration(values: values))
        let pool = module.dataSource
        let replica = try #require(pool.replica)
        try await pool.start()
        try await replica.start()
        defer { Task { await pool.shutdown(); await replica.shutdown() } }

        #expect(try await pool.withReadRepo { try await source($0) } == Self.replicaDatabase)
        #expect(try await pool.withRepo { try await source($0) } == (try primaryDatabase()))
    }

    @Test("a replica that cannot give a connection falls back to the primary, unless told not to")
    func fallback() async throws {
        try await prepare()
        var values = try TestDatabase.values()
        values[DataSourceConfigKey.replicaURL(datasource: "primary")] =
            "postgres://postgres:alula@127.0.0.1:1/nowhere?sslmode=disable"
        values[DataSourceConfigKey.checkoutTimeout(datasource: "primary")] = "200"
        let module = try PostgresDataModule<PrimaryDataSource>(configuration: Configuration(values: values))
        let pool = module.dataSource
        try await pool.start()
        defer { Task { await pool.shutdown() } }
        // The replica pool is never started: it has nothing to give.
        #expect(try await pool.withReadRepo { try await source($0) } == (try primaryDatabase()))

        values[DataSourceConfigKey.replicaFallback(datasource: "primary")] = "false"
        let strict = try PostgresDataModule<PrimaryDataSource>(configuration: Configuration(values: values))
            .dataSource
        try await strict.start()
        defer { Task { await strict.shutdown() } }
        await #expect(throws: (any Error).self) {
            _ = try await strict.withReadRepo { try await source($0) }
        }
    }

    @Test("without a replica, withReadRepo is withRepo")
    func noReplica() async throws {
        try await prepare()
        let pool = try PostgresDataModule<PrimaryDataSource>(configuration: try TestDatabase.configuration())
            .dataSource
        #expect(pool.replica == nil)
        try await pool.start()
        defer { Task { await pool.shutdown() } }
        #expect(try await pool.withReadRepo { try await source($0) } == (try primaryDatabase()))
    }
}
