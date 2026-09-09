import FlightCore

/// Module wiring, following PubSub's compose-by-presence
/// pattern:
///
/// ```swift
/// try await Flight.bootstrap(configuration: .load(), modules: [
///     FlightCacheModule.self,
///     FlightCacheValkeyModule.self,   // optional adapter; omit for in-memory
/// ])
/// ```
///
/// `configure(_:)` registers:
///
/// 1. `InMemoryCache` — the default store, `.singleton`, its LRU
///    bound read from `cache.memory.max_entries` at `freeze()` so a bad
///    value fails bootstrap;
/// 2. the unqualified `(any Cache)` — resolves an adapter registered under
///    `storeQualifier` if one is present (catching only
///    `ResolutionError.notRegistered`), else the in-memory store. Absent
///    adapter module = single-instance deployment, the common case;
/// 3. `CacheRuntime` — store + TTL policy + codec + single-flight +
///    metrics. Its factory **installs the runtime into the `FlightCaches`
///    seam** — the factory runs at `freeze()`, so annotated methods
///    are served from the first request.
///
/// No `service`: the in-memory store has no long-running work. Adapter
/// modules with a connection (the Valkey client) expose their own.
public struct FlightCacheModule: FlightModule {
    /// Adapter modules expose their store; this module takes it. It used to
    /// be registered under this qualifier for the base module to *discover* by
    /// catching `.notRegistered` — the compose-by-presence anti-pattern PubSub
    /// and Presence shed. Kept only because a stored `(any Cache)` is a
    /// separate registration a hand-wired test might still reach for.
    public static let storeQualifier = "flight.cache.store"

    /// The process-wide runtime `@Cacheable` methods are served from — store,
    /// TTL policy, codec, single-flight, metrics. The one public value this
    /// module provides; typed distinctly from `(any Cache)` on purpose, so it
    /// does not collide in composition with an adapter module that provides a
    /// store (the Presence lesson, D17).
    public let runtime: CacheRuntime

    /// The store the runtime wraps — the adapter when one was supplied, the
    /// in-memory LRU otherwise. Internal so a test can confirm which store the
    /// module chose, the way it used to resolve `(any Cache)` from the container.
    let store: any Cache

    /// The in-memory store, always built so a bad LRU bound fails composition
    /// regardless of the adapter.
    let inMemory: InMemoryCache

    /// - Parameters:
    ///   - adapter: A distributed cache, from an adapter module. Nil means the
    ///     in-memory store — the single-instance case, and the default.
    ///   - codec: The wire format, when the deployment chose one.
    ///
    /// Whether there is an adapter is a fact about how the application was
    /// composed, so it is a parameter rather than a container probe.
    public init(
        configuration: Configuration,
        adapter: (any Cache)? = nil,
        codec: (any CacheCodec)? = nil
    ) throws {
        // Always built — a bad `cache.memory.max_entries` fails composition
        // whether or not an adapter is present, exactly as the eager
        // freeze()-time factory used to. It is the store when no adapter was
        // supplied, and the value the `InMemoryCache` registration serves
        // either way.
        let maxEntries =
            try configuration.getIfPresent(CacheConfigKey.memoryMaxEntries, as: Int.self)
            ?? InMemoryCache.defaultMaxEntries
        guard maxEntries > 0 else {
            throw CacheConfigurationError.invalidMaxEntries(maxEntries)
        }
        let inMemory = InMemoryCache(maxEntries: maxEntries)
        self.inMemory = inMemory

        if adapter == nil {
            // Configuration naming an adapter nobody loaded would otherwise
            // give every instance its own private cache, the fallback working
            // per node until two users read different numbers.
            try configuration.requireNoUnloadedAdapter(
                feature: "the cache",
                candidates: [
                    AdapterCandidate(
                        configurationKey: ValkeyCacheConfigKeyProbe.url,
                        module: "FlightCacheValkeyModule")
                ])
        }
        let store: any Cache = adapter ?? inMemory
        self.store = store
        let runtime = try CacheRuntime(
            store: store, configuration: configuration, codec: codec ?? JSONCacheCodec())
        self.runtime = runtime
        // Install the runtime into the process-wide `FlightCaches` seam that
        // `@Cacheable` reads. This used to happen in the `freeze()`-time
        // factory; with no container it happens when the module is built,
        // which is still before any request — the composition root constructs
        // every module ahead of starting services.
        FlightCaches.install(runtime)
    }

    public init() {
        preconditionFailure(
            "FlightCacheModule takes its configuration in init(configuration:adapter:), so it "
                + "cannot be instantiated from its type. Pass `composedBy: flightComposeModules` "
                + "to Flight.run — `flight new` writes that argument — or construct the module "
                + "yourself and use the entry point taking module instances.")
    }
}

/// The adapter's required key, spelled here so the base module can notice a
/// configuration block its own build may not contain code for.
///
/// FlightCache cannot import FlightCacheValkey — the dependency runs the
/// other way, which is what makes the adapter optional. A string constant is
/// the whole coupling, and ``ValkeyCacheConfigKey/url`` is pinned equal to it
/// by a test in the adapter's own suite, so the two cannot drift.
enum ValkeyCacheConfigKeyProbe {
    static let url = "cache.valkey.url"
}
