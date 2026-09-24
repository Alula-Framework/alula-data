import AlulaCore

/// A datasource's liveness probe as a component — the store-agnostic surface
/// Alula Actuator reads.
///
/// `register(dataSource:)` registers one of these per named datasource,
/// qualified by the datasource's name, wrapping the pool's `ping()`. Module
/// *health* — did the pool's service start and stay up — is tracked by
/// bootstrap with no per-store instrumentation; this component is the second,
/// complementary signal: is the store on the other end of the pool actually
/// answering right now.
///
/// A datasource module holds one of these (built from its pool's `ping()`)
/// and contributes it to readiness as a `HealthCheck`, through its
/// `healthChecks` property: Actuator's `/actuator/health/ready` answers no
/// while the store is not answering. Liveness is unaffected — a restart does
/// not bring a database back.
public struct DataSourceLiveness: Sendable {
    /// The datasource this probe belongs to — its configured name.
    public let datasourceName: String

    private let probe: @Sendable () async throws -> Void

    public init(datasourceName: String, probe: @escaping @Sendable () async throws -> Void) {
        self.datasourceName = datasourceName
        self.probe = probe
    }

    /// Runs the store's cheap liveness probe (a `SELECT 1`-equivalent).
    /// Returning normally means live; any thrown error means not.
    public func ping() async throws {
        try await probe()
    }

    /// This probe as the readiness check Actuator runs, named
    /// `datasource.<name>` in logs.
    public var healthCheck: HealthCheck {
        HealthCheck(name: "datasource.\(datasourceName)") { [probe] in try await probe() }
    }

}
