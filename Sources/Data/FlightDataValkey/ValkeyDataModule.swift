import FlightCore
import FlightDataCore
import Logging
import ServiceLifecycle
import Valkey

/// The Valkey store module: one generic instantiation per named
/// datasource, exactly as `PostgresDataModule<Name>` models it —
///
/// ```swift
/// try await Flight.bootstrap(configuration: .load(), modules: [
///     ValkeyDataModule<PrimaryDataSource>.self,
///     PostgresDataModule<PrimaryDataSource>.self,   // coexists under names
/// ])
/// ```
///
/// `configure(_:)` registers the pool — `ValkeyDataSource`, `.singleton`,
/// qualified by `Name.name` — and its `DataSourceLiveness` probe (via
/// `register(dataSource:)`, Flight Data Core). For the `primary` datasource
/// the pool also answers unqualified resolution, so the single-store app
/// never writes a qualifier.
///
/// A `ValkeyConnection` is not a component: a repository holds the pool and
/// leases one per operation through `pool.withConnection { }`.
///
/// Deliberately absent: no migration runner (schemaless store) and no
/// transaction coordinator — `MULTI`/`EXEC` is not a transaction in the
/// sense a relational store means, so the capability ships as `multi` under
/// its own honest name.
///
/// `service` is the pool's `run()`: dial at start (Flight Core — no
/// request served before the pool is live), replace broken connections while
/// running, drain on graceful shutdown.
public final class ValkeyDataModule<Name: DataSourceName>: FlightModule {
    /// The pool. A repository holds this; the composition root reads it here
    /// and passes it as a graph root.
    public let dataSource: ValkeyDataSource

    /// This datasource's liveness probe (the pool's `ping()`), provided as a
    /// value for the composition root to aggregate for Actuator.
    public let liveness: DataSourceLiveness

    /// A bad URL or pool size fails composition — earlier than the `freeze()`
    /// factory this used to be, and much earlier than the first command.
    public init(configuration: Configuration) throws {
        let name = Name.name
        let settings = try DataSourceSettings.load(name: name, from: configuration)
        // Defaults on, same key and same reasoning as the Postgres twin: a
        // pooled connection is a session, and a session that remembers
        // `SELECT 5` across scopes reads the wrong database.
        let reset =
            try configuration.getIfPresent(
                "datasource.\(name).reset_on_release", as: Bool.self) ?? true
        let dataSource = try ValkeyDataSource(settings: settings, resetOnRelease: reset)
        self.dataSource = dataSource
        self.liveness = DataSourceLiveness(datasourceName: name) { [dataSource] in
            try await dataSource.ping()
        }
    }

    public init() {
        preconditionFailure(
            "ValkeyDataModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: flightComposeModules` to "
                + "Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    // A `ValkeyConnection` is not a component: it is leased for one operation
    // through `pool.withConnection { }` and returned when that operation ends.
    // The module holds only the pool (and its liveness probe).

    public var service: (any Service)? {
        ValkeyPoolService(dataSource: dataSource)
    }
}

/// The pool's ServiceLifecycle wrapper: runs it (dial → maintain → drain).
/// Handed the pool the module owns, rather than resolving it post-freeze.
struct ValkeyPoolService: Service {
    let dataSource: ValkeyDataSource

    func run() async throws {
        try await dataSource.run()
    }
}
