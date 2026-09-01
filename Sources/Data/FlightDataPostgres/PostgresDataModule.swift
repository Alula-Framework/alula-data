import FlightCore
import FlightDataCore
import Logging
import PostgresNIO
import ServiceLifecycle

/// The Postgres store module: one generic instantiation per named
/// datasource, exactly as `InMemoryDataModule<Name>` models it —
///
/// ```swift
/// try await Flight.bootstrap(configuration: .load(), modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
///     PostgresDataModule<Analytics>.self,
/// ])
/// ```
///
/// `configure(_:)` registers, all qualified by `Name.name`:
///
/// 1. the pool — `PostgresDataSource`, `.singleton`, plus the scope-bound
///    `ScopedConnection<PostgresDataSource>` lease and the
///    `DataSourceLiveness` probe (via `register(dataSource:)`, Flight Data
///    Core /);
/// 2. the raw connection — `PostgresConnection`, `.scoped`, borrowed from
///    the scope's lease so repositories can say
///    `@Inject var connection: PostgresConnection`. For the
///    `primary` datasource it is *also* registered unqualified, so the
///    single-database app never writes a qualifier;
/// 3. the transaction coordinator — `PostgresTransactionCoordinator`,
///    `.singleton`, unqualified alias for `primary` likewise.
///
/// `service` is the pool's `run()`: dial at start (Flight Core step 9 —
/// no request served before the pool is live), replace broken connections
/// while running, drain on graceful shutdown.
public final class PostgresDataModule<Name: DataSourceName>: FlightModule {
    /// Stashed during `configure` so `service` can resolve the pool lazily —
    /// the same pattern as `FlightWebModule` (modules cannot resolve during
    /// the registration phase, Flight Core).
    private var container: Container?

    public init() {}

    public func configure(_ container: Container) throws {
        self.container = container
        let name = Name.name

        // The pool + lease + liveness triple. The factory runs at freeze(),
        // where Configuration is readable — a bad URL or pool size fails
        // bootstrap, never the first query (Flight Data Core).
        container.register(dataSource: PostgresDataSource.self, name: name) { container in
            let configuration = try container.resolve(Configuration.self)
            let settings = try DataSourceSettings.load(name: name, from: configuration)
            // Defaults on: a pooled connection is a session, and a session
            // that remembers `SET ROLE` across scopes is a cross-tenant read
            // waiting to happen.
            let reset =
                try configuration.getIfPresent(
                    "datasource.\(name).reset_on_release", as: Bool.self) ?? true
            return try PostgresDataSource(settings: settings, resetOnRelease: reset)
        }

        // Only the pool is a component. A `PostgresConnection` is not: it is
        // leased for one operation through `pool.withConnection { }` and
        // returned when that operation ends.
        //
        // There used to be a `.scoped` `PostgresConnection` here — a view onto
        // a request-held lease — plus a `PostgresTransactionCoordinator` that
        // located that connection through the ambient scope, and a `.scoped`
        // Hangar `Repo` bound to it. All three are gone: a repository holds
        // the pool and brackets each operation, and transactions are Hangar's
        // `repo.transaction { }`.

        // The conventional default datasource also answers unqualified
        // resolution, so `@Inject var pool: PostgresDataSource` works without
        // ceremony in the one-database app. The scoped `PostgresConnection`
        // registration used to extend that courtesy; it moves to the pool,
        // because the pool is what a repository now holds. Named datasources
        // must still be asked for by name — with several pools, silence would
        // be guessing (Flight Core's qualifier posture).
        if name == PrimaryDataSource.name {
            container.register(PostgresDataSource.self, scope: .singleton) { c in
                try c.resolve(PostgresDataSource.self, qualifier: name)
            }
        }
    }

    public var service: (any Service)? {
        container.map { PostgresPoolService<Name>(container: $0) }
    }
}

/// The pool's ServiceLifecycle wrapper: resolves the datasource post-freeze
/// and runs it (dial → maintain → drain).
struct PostgresPoolService<Name: DataSourceName>: Service {
    let container: Container

    func run() async throws {
        let source = try container.resolve(PostgresDataSource.self, qualifier: Name.name)
        try await source.run()
    }
}
