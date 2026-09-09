import FlightCache
import FlightCore
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// await Flight.run(configuration: try .load(), modules: [
///     FlightCacheModule.self,          // pulled in via dependencies anyway
///     FlightCacheValkeyModule.self,
/// ], composedBy: flightComposeModules)
/// ```
///
/// Built in `init` (settings read there — a bad URL fails composition, never
/// the first request), the module provides its `ValkeyCache` as `cache: any
/// Cache`. `FlightCacheModule` takes it as its `adapter`, matched by type in
/// composition, which is all it takes to choose it over the in-memory default.
///
/// `service` runs the driver's own client pool — `ValkeyClient` is already
/// a ServiceLifecycle `Service` whose `run()` handles graceful shutdown.
/// Its health rides the module row in Actuator ( R5).
public struct FlightCacheValkeyModule: FlightModule {

    /// The distributed cache this module provides. `FlightCacheModule` takes
    /// it as its `adapter` — matched by type in composition — and wraps its
    /// runtime around it. It used to be *registered* under a well-known
    /// qualifier for the base module to discover; providing it is the reverse
    /// direction, the one the PubSub inversion established (D12).
    public let cache: any Cache

    /// The same value concretely, for the client-pool service.
    private let valkey: ValkeyCache

    public init(configuration: Configuration) throws {
        let valkey = try ValkeyCache(settings: try ValkeyCacheSettings.load(from: configuration))
        self.valkey = valkey
        self.cache = valkey
    }

    public init() {
        preconditionFailure(
            "FlightCacheValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        ValkeyCacheClientService(cache: valkey)
    }
}

/// Runs the Valkey client pool for the application's lifetime.
/// Resolves the cache post-freeze and runs its client pool.
struct ValkeyCacheClientService: Service {
    let cache: ValkeyCache

    func run() async throws {
        await cache.client.run()
    }
}
