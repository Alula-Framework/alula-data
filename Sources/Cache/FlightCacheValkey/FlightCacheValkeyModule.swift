import FlightCache
import FlightCore
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// try await Flight.bootstrap(configuration: .load(), modules: [
///     FlightCacheModule.self,          // pulled in via dependencies anyway
///     FlightCacheValkeyModule.self,
/// ])
/// ```
///
/// `configure(_:)` registers `ValkeyCache` (settings read at the factory,
/// which runs at `freeze()` — a bad URL fails bootstrap, never the first
/// request) and exposes it as `(any Cache)` under
/// `FlightCacheModule.storeQualifier`, which is all it takes for
/// `FlightCacheModule` to choose it over the in-memory default ('s
/// compose-by-presence).
///
/// `service` runs the driver's own client pool — `ValkeyClient` is already
/// a ServiceLifecycle `Service` whose `run()` handles graceful shutdown.
/// Its health rides the module row in Actuator ( R5).
public struct FlightCacheValkeyModule: FlightModule {

    /// The distributed cache this module provides. `FlightCacheModule` takes
    /// it as its `adapter` — matched by type in composition — and wraps its
    /// runtime around it. It used to be *registered* under
    /// `FlightCacheModule.storeQualifier` for the base module to discover;
    /// providing it is the reverse direction, the one the PubSub inversion
    /// established (D12).
    public let cache: any Cache

    /// The same value concretely, for the client-pool service.
    private let valkey: ValkeyCache

    public init(configuration: Configuration) throws {
        let valkey = try ValkeyCache(settings: try ValkeyCacheSettings.load(from: configuration))
        self.valkey = valkey
        self.cache = valkey
    }

    /// This module takes its configuration, so it cannot be built from its
    /// type — every supported path checks this and throws first.
    public static var isTypeConstructible: Bool { false }

    public init() {
        preconditionFailure(
            "FlightCacheValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// Projects the cache under the store qualifier the base module reads, and
    /// as the concrete `ValkeyCache` a test might resolve. The base module
    /// takes the adapter directly now, so the qualified registration is a
    /// courtesy rather than the wiring path.
    public func configure(_ container: Container) throws {
        let valkey = self.valkey
        container.register(ValkeyCache.self, scope: .singleton) { _ in valkey }
        container.register(
            (any Cache).self, qualifier: FlightCacheModule.storeQualifier, scope: .singleton
        ) { _ in valkey }
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
