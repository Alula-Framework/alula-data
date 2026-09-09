import FlightCore
import FlightDataCore
import FlightDataTesting
import Testing

/// Per-operation connection leasing — the architecturally significant part of
/// the package: a connection is checked out for the duration of one operation
/// and returned when it ends, with neither Flight Core nor the consumer
/// holding one across operations.
///
/// This replaces the scope-bound suite. A connection used to be a `.scoped`
/// component held for a whole request and returned by ARC when the scope
/// dropped it, which made every repository holding one request-scoped and
/// every service holding such a repository request-scoped in turn. The
/// invariants that mattered there matter here too — a connection returns on
/// both the success and error paths, nothing leaves the pool until work
/// actually runs, and concurrent work does not share a connection — so they
/// are carried over, re-expressed against `withConnection`.
@Suite("Leased connections")
struct LeasedConnectionTests {

    private func makeSource(poolSize: Int = 4) -> InMemoryDataSource {
        InMemoryDataSource(poolSize: poolSize)
    }

    // MARK: Lease lifetime

    @Test("nothing leaves the pool until an operation runs")
    func checkoutIsDeferredUntilWork() async throws {
        let source = makeSource()
        #expect(source.activeCheckouts == 0)
        #expect(source.totalCheckouts == 0)

        try await source.withConnection { _ in }

        #expect(source.totalCheckouts == 1, "the operation took one connection")
        #expect(source.activeCheckouts == 0, "and gave it back")
    }

    @Test("the connection returns when the body returns")
    func connectionReturnsOnSuccess() async throws {
        let source = makeSource()

        try await source.withConnection { connection in
            #expect(source.activeCheckouts == 1, "held for the duration of the body")
            connection.perform("SELECT 1")
        }

        #expect(source.activeCheckouts == 0)
        #expect(source.availableConnections >= 1, "the connection went back to the pool")
    }

    /// The invariant that most needs defending: a throwing operation must not
    /// leak its connection. Under the old model this was the lease's `deinit`;
    /// now it is `withConnection`'s error path.
    @Test("the connection returns even when the body throws")
    func connectionReturnsOnThrow() async throws {
        let source = makeSource()

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await source.withConnection { _ in throw Boom() }
        }

        #expect(source.activeCheckouts == 0, "a throwing operation still returns its connection")
        #expect(source.availableConnections >= 1, "the connection went back to the pool")
    }

    @Test("a returned connection is reused rather than a new one created")
    func returnedConnectionIsReused() async throws {
        let source = makeSource()

        try await source.withConnection { _ in }
        let afterFirst = source.connectionsCreated
        try await source.withConnection { _ in }

        #expect(source.connectionsCreated == afterFirst, "the pool handed back the same connection")
        #expect(source.totalCheckouts == 2, "but counted two leases")
    }

    // MARK: Operation boundaries

    /// The behavioral change this model makes: two operations are two leases,
    /// and may land on different connections. Work that must share one says so
    /// with a single `withConnection` — or a transaction.
    @Test("two operations are two leases; one bracket is one lease")
    func operationsDoNotShareImplicitly() async throws {
        let source = makeSource()

        try await source.withConnection { _ in }
        try await source.withConnection { _ in }
        #expect(source.totalCheckouts == 2)

        try await source.withConnection { connection in
            connection.perform("A")
            connection.perform("B")
        }
        #expect(source.totalCheckouts == 3, "both statements shared the one lease")
    }

    @Test("concurrent operations get distinct connections")
    func concurrentOperationsAreIsolated() async throws {
        let source = makeSource(poolSize: 4)

        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    try await source.withConnection { connection in
                        // Hold the lease long enough that the others must take
                        // their own rather than reusing this one.
                        try await Task.sleep(for: .milliseconds(30))
                        return connection.id
                    }
                }
            }
            var ids: Set<Int> = []
            for try await id in group { ids.insert(id) }
            #expect(ids.count == 3, "three concurrent operations, three connections")
        }

        #expect(source.activeCheckouts == 0, "all three returned")
    }

    // MARK: Through a repository

    @Test("a repository leases per operation and holds nothing between them")
    func repositoryLeasesPerOperation() async throws {
        let source = makeSource()
        let repository = UserRepository(pool: source)

        try await repository.save("ada")
        #expect(source.activeCheckouts == 0, "nothing held between operations")

        try await repository.save("grace")
        #expect(source.totalCheckouts == 2, "one lease each")
    }

    @Test("work through a repository lands on the connection it leased")
    func repositoryWorkLandsOnItsLease() async throws {
        let source = makeSource(poolSize: 1)
        let repository = UserRepository(pool: source)

        try await repository.saveBoth("ada", "grace")

        // Pool of one, so there is exactly one connection to have written to.
        try await source.withConnection { connection in
            #expect(connection.journal.contains("INSERT ada"))
            #expect(connection.journal.contains("INSERT grace"))
        }
    }

    // MARK: Several datasources

    @Test("two named datasources lease independently")
    func namedDatasourcesAreIndependent() async throws {
        let primary = InMemoryDataSource(name: PrimaryDataSource.name, poolSize: 2)
        let analytics = InMemoryDataSource(name: Analytics.name, poolSize: 2)

        try await primary.withConnection { p in
            #expect(primary.activeCheckouts == 1)
            #expect(analytics.activeCheckouts == 0, "the other pool is untouched")
            try await analytics.withConnection { a in
                #expect(a.datasourceName != p.datasourceName)
                #expect(analytics.activeCheckouts == 1)
            }
        }

        #expect(primary.activeCheckouts == 0)
        #expect(analytics.activeCheckouts == 0)
    }
}
