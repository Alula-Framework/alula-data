import AlulaCache
import AlulaCore
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     AlulaCacheModule.self,          // takes the Valkey store as its adapter
///     AlulaCacheValkeyModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// Built in `init` (settings read there — a bad URL fails composition, never
/// the first request), the module provides its `ValkeyCache` as `cache: any
/// Cache`. `AlulaCacheModule` takes it as its `adapter`, matched by type in
/// composition, which is all it takes to choose it over the in-memory default.
///
/// `service` runs the driver's own client pool — `ValkeyClient` is already
/// a ServiceLifecycle `Service` whose `run()` handles graceful shutdown.
/// Its health rides the module row in Actuator ( R5).
public struct AlulaCacheValkeyModule: AlulaModule {

    /// The distributed cache this module provides. `AlulaCacheModule` takes
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

    /// Unavailable: a hand-written call is a compile error saying how to
    /// build this module, and the composer never counts it as a candidate.
    @available(*, unavailable, message: "AlulaCacheValkeyModule takes its configuration in init(configuration:), so it cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` to Alula.run — `alula new` writes that argument — or construct the module yourself and use the entry point taking module instances.")
    public init() { fatalError("unavailable") }

    public var service: (any Service)? {
        ValkeyCacheClientService(cache: valkey)
    }
}

/// Runs the Valkey client pool for the application's lifetime. Handed the
/// cache the module built, rather than resolving it after composition.
struct ValkeyCacheClientService: Service {
    let cache: ValkeyCache

    func run() async throws {
        await cache.client.run()
    }
}
