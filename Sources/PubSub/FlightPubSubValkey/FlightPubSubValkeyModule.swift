import FlightCore
import FlightPubSub
import Logging
import ServiceLifecycle
import Valkey

/// Provides the Valkey adapter, which is all it takes to make PubSub
/// clustered:
///
/// ```swift
/// try await Flight.run(
///     configuration: try Configuration.load(),
///     modules: [FlightPubSubValkeyModule.self, FlightPubSubModule.self, AppModule.self],
///     composedBy: flightComposeModules)
/// ```
///
/// ```yaml
/// pubsub:
///   valkey:
///     url: valkey://localhost:6379
/// ```
///
/// The composition root builds this module, takes its `adapter`, and hands it
/// to `FlightPubSubModule(configuration:adapter:)`; `flight new` writes that
/// `composedBy:` argument. Nothing that publishes or subscribes changes, which
/// is the whole point of the seam.
///
/// **This module is a dependency of `FlightPubSubModule`, not a dependent.**
/// It used to be the other way around: PubSub composed by *presence*, running
/// its `any PubSub` factory at `freeze()` and asking the container whether
/// anyone had registered a `DistributedPubSubAdapter`. That made this module
/// responsible for three things — register the adapter, declare
/// `FlightPubSubModule` in `dependencies`, and expose `PubSubRelayService`
/// itself — and forgetting the third gave a cluster that relayed nothing,
/// silently. PubSub now takes the adapter and owns the relay, so this module
/// provides an adapter and stops.
public struct FlightPubSubValkeyModule: FlightModule {

    /// What the composition root hands to `FlightPubSubModule`.
    ///
    /// Typed as the existential deliberately. This is the contract — "provides
    /// an adapter" — and it is also what lets the generated composer match
    /// this property to `FlightPubSubModule`'s `adapter:` parameter by type,
    /// which is the only thing connecting the two modules: neither names the
    /// other, and flight cannot name flight-data at all.
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
    public init(configuration: Configuration) throws {
        let client = try ValkeyPubSubClient(
            settings: try ValkeyPubSubSettings.load(from: configuration))
        self.client = client
        let valkey = ValkeyPubSubAdapter(
            client: client.client,
            channel: client.channel,
            retryDelay: client.retryDelay)
        self.valkey = valkey
        self.adapter = valkey
    }

    /// The backstop for a caller writing `FlightPubSubValkeyModule()` directly.
    public init() {
        preconditionFailure(
            "FlightPubSubValkeyModule takes its configuration in init(configuration:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }

    /// The client pool, and nothing else. The relay is `FlightPubSubModule`'s
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
            logger: Logger(label: "flight.pubsub.valkey.client"))
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
/// Now the relay belongs to `FlightPubSubModule` and this module is PubSub's
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
        let pool = Task { await client.client.run() }
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
