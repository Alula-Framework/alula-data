import AlulaCore
import AlulaDataCore

/// The reference store module: the exact shape every real store
/// package's `AlulaModule` follows, minus the parts that need a real store.
///
/// - The module owns the datasource, built in `init` (where `Configuration`
///   is read, so a bad value fails composition rather than the first query),
///   and provides it along with its `DataSourceLiveness` probe as values.
/// - `service` is nil: an in-memory pool has no long-running work. A real
///   store module returns its pool's service here, and composition ordering
///   guarantees no request is served before the pool is live.
///
/// The name is carried in the type: one module type instantiation per
/// named datasource —
///
/// ```swift
/// let module = try InMemoryDataModule<PrimaryDataSource>()
/// let pool = module.dataSource
/// ```
///
/// Configuration is optional for the in-memory store — it is "backed by
/// nothing", so there is no URL to require; `datasource.<name>.pool_size`
/// is honored when present and defaults to 4 connections. Real store modules
/// load `DataSourceSettings` instead, whose `url` is required.
public final class InMemoryDataModule<Name: DataSourceName>: AlulaModule {
    /// The pool size used when `datasource.<name>.pool_size` is absent.
    /// Small on purpose: exhaustion bugs should be reachable in tests.
    public static var defaultPoolSize: Int { 4 }

    /// The pool this module owns and provides.
    public let dataSource: InMemoryDataSource

    /// Its liveness probe, provided as a value like the real store modules'.
    public let liveness: DataSourceLiveness

    /// This datasource's contribution to readiness: the liveness probe as a
    /// `HealthCheck`, collected by the composition root for Actuator. Without
    /// it a dead store reported healthy.
    public let healthChecks: [HealthCheck]

    /// Configuration is optional for the in-memory store — it is "backed by
    /// nothing", so there is no URL to require; `datasource.<name>.pool_size`
    /// is honored when present and defaults to 4 connections. A bad pool size
    /// fails composition rather than the first query.
    public init(configuration: Configuration = Configuration()) throws {
        let name = Name.name
        let poolSize =
            try configuration.getIfPresent(
                DataSourceConfigKey.poolSize(datasource: name), as: Int.self
            ) ?? Self.defaultPoolSize
        guard poolSize >= 1 else {
            throw DataSourceConfigurationError.invalidPoolSize(datasource: name, value: poolSize)
        }
        let dataSource = InMemoryDataSource(name: name, poolSize: poolSize)
        self.dataSource = dataSource
        self.liveness = DataSourceLiveness(datasourceName: name) { [dataSource] in
            try await dataSource.ping()
        }
        self.healthChecks = [liveness.healthCheck]
    }
}
