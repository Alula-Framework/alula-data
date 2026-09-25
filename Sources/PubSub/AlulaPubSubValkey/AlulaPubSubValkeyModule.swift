import AlulaCore
import AlulaPubSub
import Logging
import ServiceLifecycle
import Valkey

/// Provides the Valkey adapter, which is all it takes to make PubSub
/// clustered:
///
/// ```swift
/// try await Alula.run(
///     configuration: try Configuration.load(),
///     modules: [AlulaPubSubValkeyModule.self, AlulaPubSubModule.self, AppModule.self],
///     composedBy: alulaComposeModules)
/// ```
///
/// ```yaml
/// pubsub:
///   valkey:
///     url: valkey://localhost:6379
/// ```
///
/// The composition root builds this module, takes its `adapter`, and hands it
/// to `AlulaPubSubModule(configuration:adapter:)`; `alula new` writes that
/// `composedBy:` argument. Nothing that publishes or subscribes changes, which
/// is the whole point of the seam.
///
/// **This module is a dependency of `AlulaPubSubModule`, not a dependent.**
/// It used to be the other way around: PubSub composed by *presence*, running
/// its `any PubSub` factory at `freeze()` and asking the container whether
/// anyone had registered a `DistributedPubSubAdapter`. That made this module
/// responsible for three things — register the adapter, declare
/// `AlulaPubSubModule` in `dependencies`, and expose `PubSubRelayService`
/// itself — and forgetting the third gave a cluster that relayed nothing,
/// silently. PubSub now takes the adapter and owns the relay, so this module
/// provides an adapter and stops.
public struct AlulaPubSubValkeyModule: AlulaModule {

    /// What the composition root hands to `AlulaPubSubModule`.
    ///
    /// Typed as the existential deliberately. This is the contract — "provides
    /// an adapter" — and it is also what lets the generated composer match
    /// this property to `AlulaPubSubModule`'s `adapter:` parameter by type,
    /// which is the only thing connecting the two modules: neither names the
    /// other, and alula cannot name alula-data at all.
    public let adapter: any DistributedPubSubAdapter

    /// The same adapter, concretely, for `drainSubscriptions()` — which is
    /// this package's own shutdown concern and not part of the seam above.
    private let valkey: ValkeyPubSubAdapter

    /// Held so `configure` can register the same instance the service runs,
    /// rather than constructing a second client that dials Valkey again.
    private let client: ValkeyPubSubClient

    /// Reads `pubsub.valkey.*` and dials nothing — building the client is
    /// pool setup, and connecting is the service's job.
    ///
    /// Throwing, because building the TLS context can fail: a `valkeys://` URL
    /// whose TLS cannot be configured must fail bootstrap rather than quietly
    /// connecting in the clear.
    /// `pubsub.valkey`, for readiness: a `PING` on the publishing client.
    /// Without it, messages published here reach no other node, and realtime
    /// quietly became single-node.
    public let healthChecks: [HealthCheck]

    public init(configuration: Configuration) throws {
        let client = try ValkeyPubSubClient(
            settings: try ValkeyPubSubSettings.load(from: configuration))
        self.client = client
        self.healthChecks = [
            HealthCheck(name: "pubsub.valkey") { [valkey = client.client] in
                _ = try await valkey.ping()
            }
        ]
        let valkey = ValkeyPubSubAdapter(
            client: client.client,
            channel: client.channel,
            retryDelay: client.retryDelay)
        self.valkey = valkey
        self.adapter = valkey
    }

    /// The backstop for a caller writing `AlulaPubSubValkeyModule()` directly.
    public init() {
        preconditionFailure(
            "AlulaPubSubValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: alulaComposeModules` "
                + "to Alula.run — `alula new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// The client pool, and nothing else. The relay is `AlulaPubSubModule`'s
    /// now — see `ValkeyPubSubService` for why that ordering is no longer this
    /// module's problem to arrange.
    public var service: (any Service)? {
        ValkeyPubSubService(client: client, adapter: valkey)
    }
}

/// Holds the client so the module can register it once and the service can
/// run it, without constructing two clients that each dial Valkey.
public final class ValkeyPubSubClient: Sendable {
    public let client: ValkeyClient
    public let channel: String
    public let retryDelay: Duration

    init(settings: ValkeyPubSubSettings) throws {
        self.client = ValkeyClient(
            .hostname(settings.host, port: settings.port),
            configuration: try settings.clientConfiguration(),
            logger: Logger(label: "alula.pubsub.valkey.client"))
        self.channel = settings.channel
        self.retryDelay = settings.retryDelay
    }
}

/// Runs the client pool for the application's lifetime, and makes sure the
/// adapter's subscribe loops have finished before the pool goes away.
///
/// Shutdown ordering used to be hand-arranged inside this service, because it
/// ran both halves: the relay's subscription must unwind *before* the client
/// pool is cancelled, since releasing a subscription connection while it is
/// still initializing trips a fatal assertion inside valkey-swift's
/// subscription state machine and takes the process down during what should be
/// a graceful stop. (Found by a test crashing at teardown.)
///
/// Now the relay belongs to `AlulaPubSubModule` and this module is PubSub's
/// dependency, so it starts first — and `ServiceGroup` shuts services down in
/// reverse start order, which stops the relay before this. The ordering falls
/// out of the module graph instead of being reproduced by hand here. What
/// remains is the wait: the relay returning means it stopped *reading*, while
/// the subscribe loop behind `incoming()` is a separate task that may still be
/// unwinding, so this waits for the thing itself before releasing the pool.
struct ValkeyPubSubService: Service {
    let client: ValkeyPubSubClient
    let adapter: ValkeyPubSubAdapter

    func run() async throws {
        // Detached, deliberately. `ValkeyClient.run()` wraps itself in
        // `cancelWhenGracefulShutdown`, and an ordinary `Task` inherits this
        // service's task-locals — the graceful-shutdown manager among them.
        // The pool then shut itself down on this service's own shutdown
        // signal, at the same moment as the drain below instead of after it,
        // and when the pool won (a third of timed-out shutdowns in Relay
        // Lab) the subscription's release found its connection already
        // shut down and valkey-swift trapped: SIGILL instead of an exit.
        // Detached, only the `pool.cancel()` below stops it.
        let pool = Task.detached { await client.client.run() }
        defer { pool.cancel() }

        // Hold the pool open until the group shuts down or this task is
        // cancelled. `cancelWhenGracefulShutdown` turns the shutdown signal
        // into cancellation, which is what unblocks the sleep below.
        //
        // It must be that function and not `withGracefulShutdownHandler`,
        // which only *registers* a callback. This used to call the latter with
        // an empty handler, on the premise that "the enclosing group cancels
        // this task" — but the group is what awaits this task's exit, so
        // nothing cancelled it, `Task.isCancelled` never became true, and
        // graceful shutdown blocked here forever. Every SIGTERM deploy path
        // runs through this. Both data-source pools already call the right
        // one (PostgresDataSource.swift, ValkeyDataSource.swift).
        await cancelWhenGracefulShutdown {
            // Sleeps until cancelled; the pool runs in its own task.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        await adapter.drainSubscriptions()
    }
}
