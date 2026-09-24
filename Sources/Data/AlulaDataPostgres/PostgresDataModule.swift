import AlulaCore
import AlulaDataCore
import Logging
import PostgresNIO
import ServiceLifecycle

/// The Postgres store module: one generic instantiation per named
/// datasource, exactly as `InMemoryDataModule<Name>` models it —
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     PostgresDataModule<PrimaryDataSource>.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// A second instantiation is a second pool. Both provide `PostgresDataSource`,
/// so the application nominates one with `AlulaModule.defaultProviders` and
/// the consumer that wants the other names it with `@Inject(from:)`. Requires
/// alula 0.21.0; see `DataSourceName`.
///
/// The module owns the pool — `PostgresDataSource`, built in `init` from
/// configuration — and provides it, along with its `DataSourceLiveness`
/// probe, as values. The composition root reads them and wires the pool to
/// whatever injects `PostgresDataSource`; a bad URL or pool size fails there,
/// much earlier than the first query.
///
/// A `PostgresConnection` is not a component: a repository holds the pool and
/// leases a connection per operation through `pool.withConnection { }` or
/// `pool.withRepo { }`. Transactions are Hangar's `repo.transaction { }`, so
/// there is no coordinator either.
///
/// `service` is the pool's `run()`: dial at start (no request served before
/// the pool is live), replace broken connections while running, drain on
/// graceful shutdown.
public struct PostgresDataModule<Name: DataSourceName>: AlulaModule {

    /// The pool. A repository holds this, and so does the component graph —
    /// which is why it is a stored property: the composition root reads it
    /// here and passes it as a graph root.
    public let dataSource: PostgresDataSource

    /// This datasource's liveness probe — "is the store answering right now",
    /// wrapping the pool's `ping()`. Readiness gets it through
    /// ``healthChecks``.
    public let liveness: DataSourceLiveness

    /// This datasource's contribution to readiness: the liveness probe as a
    /// `HealthCheck`, collected by the composition root for Actuator. Without
    /// it a dead store reported healthy.
    public let healthChecks: [HealthCheck]

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
        let dataSource = try PostgresDataSource(settings: settings, resetOnRelease: reset)
        self.dataSource = dataSource
        if let replicaURL = try configuration.getIfPresent(
            DataSourceConfigKey.replicaURL(datasource: name), as: String.self)
        {
            let replicaSettings = try DataSourceSettings(
                name: "\(name)-replica", url: replicaURL,
                poolSize: try configuration.getIfPresent(
                    DataSourceConfigKey.replicaPoolSize(datasource: name), as: Int.self)
                    ?? settings.poolSize,
                checkoutTimeout: settings.checkoutTimeout)
            let replica = try PostgresDataSource(settings: replicaSettings, resetOnRelease: reset)
            dataSource.attach(
                replica: ReplicaAttachment(
                    pool: replica,
                    fallbackToPrimary: try configuration.getIfPresent(
                        DataSourceConfigKey.replicaFallback(datasource: name), as: Bool.self)
                        ?? true,
                    logger: Logger(label: "alula.data.postgres.\(name)")))
        }
        self.liveness = DataSourceLiveness(datasourceName: name) { [dataSource] in
            try await dataSource.ping()
        }
        self.healthChecks = [liveness.healthCheck]
    }

    public init() {
        preconditionFailure(
            "PostgresDataModule takes its configuration in init(configuration:), so it cannot be "
                + "instantiated from its type. Pass `composedBy: alulaComposeModules` to "
                + "Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    // A `PostgresConnection` is not a component: it is leased for one
    // operation through `pool.withConnection { }` and returned when that
    // operation ends. The module holds only the pool (and its liveness probe);
    // a consumer takes the pool by type from the composition graph.

    public var service: (any Service)? {
        PostgresPoolService(dataSource: dataSource)
    }

    /// The replica's pool runs beside the primary's and shuts down with it.

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
        guard let replica = dataSource.replica else {
            try await dataSource.run()
            return
        }
        // A replica failing to start must not take the primary down with it:
        // reads fall back, so the service is still whole.
        // The primary decides when this service ends; the replica rides along.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await replica.run()
                } catch {
                    if Task.isCancelled { return }
                    Logger(label: "alula.data.postgres").error(
                        "read replica pool stopped; reads use the primary",
                        metadata: ["datasource": "\(replica.name)", "error": "\(error)"])
                    // Parked until shutdown: returning would end nothing,
                    // and throwing would end the primary too.
                    while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
                }
            }
            defer { group.cancelAll() }
            try await dataSource.run()
        }
    }
}
