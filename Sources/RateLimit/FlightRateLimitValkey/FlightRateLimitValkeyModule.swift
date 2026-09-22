import FlightCore
import FlightRateLimit
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// await Flight.run(configuration: try .load(), modules: [
///     FlightWebModule<FlightTransport>.self,
///     FlightRateLimitModule.self,
///     FlightRateLimitValkeyModule.self,
///     AppModule.self,
/// ], composedBy: flightComposeModules)
/// ```
///
/// ```yaml
/// rate-limit:
///   valkey:
///     url: valkey://localhost:6379
/// ```
///
/// Built in `init` — settings read there, so a bad URL fails composition,
/// never the first request that gets limited — the module provides its
/// `ValkeyRateLimitStore` as `store: any RateLimitStore`.
/// `FlightRateLimitModule` takes it as its `store`, matched by type in
/// composition, which is all it takes to choose it over the per-process
/// default. The direction the cache, PubSub and session adapters
/// established: this module provides a store and stops.
///
/// Listing it is what makes a quota mean the same thing across every
/// replica. Without it each replica enforces the quota separately, so a
/// client spreading calls across four pods gets four times the allowance,
/// which is why configuring the URL without the module is refused at
/// startup rather than quietly under-enforcing.
///
/// `service` runs the driver's own client pool, in the infrastructure
/// phase: started before the transport, shut down after it, because a
/// request being limited borrows a connection from it.
public struct FlightRateLimitValkeyModule: FlightModule {

    /// The shared store this module provides.
    public let store: any RateLimitStore

    /// The same value concretely, for the client-pool service.
    private let valkey: ValkeyRateLimitStore

    public init(configuration: Configuration) throws {
        let valkey = try ValkeyRateLimitStore(
            settings: try ValkeyRateLimitSettings.load(from: configuration))
        self.valkey = valkey
        self.store = valkey
    }

    public init() {
        preconditionFailure(
            "FlightRateLimitValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        ValkeyRateLimitClientService(store: valkey)
    }

    public var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
}

/// Runs the Valkey client pool for the application's lifetime.
struct ValkeyRateLimitClientService: Service {
    let store: ValkeyRateLimitStore

    func run() async throws {
        await store.client.run()
    }
}
