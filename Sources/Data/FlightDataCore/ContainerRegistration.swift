import FlightCore

extension Container {
    /// Registers one named datasource — called by each store's
    /// `FlightModule` from `configure(_:)`. Two components, both qualified by
    /// `name`:
    ///
    /// 1. **The pool** — `D` as `.singleton`. `factory` runs at `freeze()`
    ///    (Flight Core's eager singleton construction), which is where
    ///    it reads `Configuration` — module `configure` bodies run during the
    ///    registration phase, where resolution is not yet legal.
    /// 2. **The liveness probe** — `DataSourceLiveness` as `.singleton`,
    ///    wrapping the pool's `ping()` for Actuator.
    ///
    /// A connection is deliberately **not** a component. It is leased for the
    /// duration of one operation and returned when that operation ends, so a
    /// repository holds the *pool* and brackets each query:
    ///
    /// ```swift
    /// @Repository final class UserRepository {
    ///     @Inject var pool: PostgresDataSource        // singleton
    ///
    ///     func find(_ id: UUID) async throws -> User? {
    ///         try await pool.withConnection { connection in
    ///             try await Repo(connection: connection).one(User.where { $0.id == id })
    ///         }
    ///     }
    /// }
    /// ```
    ///
    /// Names are always explicit qualifiers, including `"primary"` — one
    /// convention whether an app has one datasource or five; resolution
    /// disambiguates the same way any multi-binding does (Flight Core).
    public func register<D: DataSource>(
        dataSource type: D.Type,
        name: String = PrimaryDataSource.name,
        factory: @escaping @Sendable (Container) throws -> D
    ) {
        register(type, qualifier: name, scope: .singleton, factory: factory)

        // There used to be a `.scoped` `ScopedConnection<D>` lease here, held
        // for a whole request and returned by ARC when the scope dropped it.
        // It made every repository holding a connection request-scoped, and
        // every service holding such a repository request-scoped in turn —
        // lifetime propagating up the graph from a pooling concern. It also
        // required `PendingConnections`, because a synchronous factory cannot
        // queue for a busy pool. `withConnection` is async and queues
        // natively, so both are gone.

        register(DataSourceLiveness.self, qualifier: name, scope: .singleton) { container in
            let source = try container.resolve(D.self, qualifier: name)
            return DataSourceLiveness(datasourceName: name) {
                try await source.ping()
            }
        }
    }

    /// Instance form, for callers that already hold a constructed pool —
    /// tests wiring an `InMemoryDataSource` by hand, or a module whose
    /// settings don't come from `Configuration`. Registers exactly the same
    /// two components.
    public func register<D: DataSource>(
        dataSource: D,
        name: String = PrimaryDataSource.name
    ) {
        register(dataSource: D.self, name: name) { _ in dataSource }
    }
}
