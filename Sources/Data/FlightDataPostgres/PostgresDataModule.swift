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
/// `configure(_:)` registers the pool — `PostgresDataSource`, `.singleton`,
/// qualified by `Name.name` — and its `DataSourceLiveness` probe (via
/// `register(dataSource:)`, Flight Data Core). For the `primary` datasource
/// the pool also answers unqualified resolution, so the single-database app
/// never writes a qualifier.
///
/// That is the whole registration. A `PostgresConnection` is not a
/// component: a repository holds the pool and leases a connection per
/// operation through `pool.withConnection { }` or `pool.withRepo { }`.
/// Transactions are Hangar's `repo.transaction { }`, so there is no
/// coordinator either.
///
/// `service` is the pool's `run()`: dial at start (Flight Core step 9 —
/// no request served before the pool is live), replace broken connections
/// while running, drain on graceful shutdown.
public struct PostgresDataModule<Name: DataSourceName>: FlightModule {

    /// The pool. A repository holds this, and so does the component graph —
    /// which is why it is a stored property: the composition root reads it
    /// here and passes it as a graph root.
    public let dataSource: PostgresDataSource

    /// A bad URL or pool size fails composition — earlier than the `freeze()`
    /// factory this used to be, and much earlier than the first query.
    public init(configuration: Configuration) throws {
        let name = Name.name
        let settings = try DataSourceSettings.load(name: name, from: configuration)
        // Defaults on: a pooled connection is a session, and a session that
        // remembers `SET ROLE` across scopes is a cross-tenant read waiting
        // to happen.
        let reset =
            try configuration.getIfPresent(
                "datasource.\(name).reset_on_release", as: Bool.self) ?? true
        self.dataSource = try PostgresDataSource(settings: settings, resetOnRelease: reset)
    }

    /// This module takes its configuration, so it cannot be built from its
    /// type — every supported path checks this and throws first.
    public static var isTypeConstructible: Bool { false }

    public init() {
        preconditionFailure(
            "PostgresDataModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public func configure(_ container: Container) throws {
        let name = Name.name
        let dataSource = self.dataSource
        container.register(dataSource: PostgresDataSource.self, name: name) { _ in dataSource }

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
            container.register(PostgresDataSource.self, scope: .singleton) { _ in dataSource }
        }
    }

    public var service: (any Service)? {
        PostgresPoolService(dataSource: dataSource)
    }

    /// A pool is what everything else borrows from, so it starts first and
    /// closes last. Without saying so, the order came from however the
    /// application listed its modules, and the shape every example uses put
    /// the HTTP transport first — which made the pool close *underneath* a
    /// server still serving requests.
    public var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
}

/// The pool's ServiceLifecycle wrapper: runs it (dial → maintain → drain).
///
/// It used to hold a `Container` and resolve the datasource post-freeze,
/// because the module registered a factory and its service is collected
/// during `configure`. The module owns the pool now, so the service is handed
/// the thing it runs — and no longer needs the `Name` parameter that existed
/// only to rebuild the qualifier for that lookup.
struct PostgresPoolService: Service {
    let dataSource: PostgresDataSource

    func run() async throws {
        try await dataSource.run()
    }
}
