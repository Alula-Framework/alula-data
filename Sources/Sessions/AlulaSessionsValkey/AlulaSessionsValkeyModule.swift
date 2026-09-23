import AlulaCore
import AlulaSessions
import ServiceLifecycle

/// The adapter module:
///
/// ```swift
/// await Alula.run(configuration: try .load(), modules: [
///     AlulaWebModule<AlulaTransport>.self,
///     AlulaSessionsModule.self,
///     AlulaSessionsValkeyModule.self,
///     AppModule.self,
/// ], composedBy: alulaComposeModules)
/// ```
///
/// ```yaml
/// sessions:
///   valkey:
///     url: valkey://localhost:6379
/// ```
///
/// Built in `init` — settings read there, so a bad URL fails composition,
/// never the first request — the module provides its `ValkeySessionStore`
/// as `store: any SessionStore`. `AlulaSessionsModule` takes it as its
/// `store`, matched by type in composition, which is all it takes to choose
/// it over the in-memory default. The direction the cache and PubSub
/// adapters established: this module provides a store and stops.
///
/// `service` runs the driver's own client pool, in the infrastructure phase:
/// started before the transport, shut down after it, because every request
/// with a cookie borrows a connection from it.
public struct AlulaSessionsValkeyModule: AlulaModule {

    /// The shared store this module provides. `AlulaSessionsModule` takes it
    /// as its `store` — matched by type in composition.
    public let store: any SessionStore

    /// The same value concretely, for the client-pool service.
    private let valkey: ValkeySessionStore

    public init(configuration: Configuration) throws {
        let valkey = try ValkeySessionStore(
            settings: try ValkeySessionSettings.load(from: configuration))
        self.valkey = valkey
        self.store = valkey
    }

    public init() {
        preconditionFailure(
            "AlulaSessionsValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` "
                + "to Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    public var service: (any Service)? {
        ValkeySessionClientService(store: valkey)
    }

    public var serviceShutdownPhase: ServiceShutdownPhase { .infrastructure }
}

/// Runs the Valkey client pool for the application's lifetime.
struct ValkeySessionClientService: Service {
    let store: ValkeySessionStore

    func run() async throws {
        await store.client.run()
    }
}
