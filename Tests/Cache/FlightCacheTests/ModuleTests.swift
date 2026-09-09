import Foundation
import FlightCore
import Testing

import FlightCacheTesting

@testable import FlightCache

/// Serialized: these tests exercise the process-global `FlightCaches`
/// install seam, so they must not interleave.
@Suite("FlightCacheModule — wiring", .serialized)
struct ModuleTests {

    /// The adapter-module contract in miniature: *provide* a store. It used
    /// to register one under the well-known qualifier for FlightCacheModule
    /// to discover; now FlightCacheModule takes it.
    struct RecordingAdapterModule: FlightModule {
        let cache: any Cache = RecordingCache()
        func configure(_ container: Container) throws {}
    }

    @Test("without an adapter module, the in-memory store is the cache")
    func inMemoryDefault() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration(values: ["cache.memory.max_entries": "5"])
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [try FlightCacheModule(configuration: configuration)])
            let store = try application.container.resolve((any Cache).self)
            let memory = try #require(store as? InMemoryCache)
            #expect(memory.maxEntries == 5)
            #expect(FlightCaches.isInstalled)
        }
    }

    @Test("a registered adapter store wins over the in-memory default")
    func adapterComposesByPresence() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration()
            let adapter = RecordingAdapterModule()
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [
                    adapter,
                    try FlightCacheModule(configuration: configuration, adapter: adapter.cache),
                ])
            let store = try application.container.resolve((any Cache).self)
            #expect(store is RecordingCache)
            #expect(FlightCaches.isInstalled)
        }
    }

    @Test("a non-positive LRU bound fails bootstrap, not the first request")
    func invalidMaxEntriesFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            #expect(throws: (any Error).self) {
                _ = try FlightCacheModule(
                    configuration: Configuration(values: ["cache.memory.max_entries": "0"]))
            }
        }
    }

    @Test("without any install, annotations run against the no-op runtime")
    func unwiredFailsOpen() async throws {
        // Under the lock like every other seam-touching test: `uninstall()`
        // mutates process-global state, and this target's suites run in
        // parallel with each other by default. Uninstalling underneath a test
        // that had just installed a runtime is a failure that reproduces only
        // sometimes, which is the worst kind to be handed.
        try await GlobalCacheSeam.exclusive {
            FlightCaches.uninstall()
            let executions = try await confirmationFreeCount()
            #expect(executions == 2)
        }
    }

    private func confirmationFreeCount() async throws -> Int {
        var executions = 0
        for _ in 0..<2 {
            let value = try await FlightCaches.current.cacheable(
                namespace: "unwired", parts: ["1"], ttl: nil, as: Int.self
            ) {
                executions += 1
                return 7
            }
            #expect(value == 7)
        }
        return executions
    }
}

/// The codec seam, which the module used to leave unreachable.
@Suite("CacheCodec is resolvable")
struct CacheCodecSeamTests {

    /// Encodes to a marker no JSON encoder would produce, so a test can tell
    /// which codec actually ran.
    struct MarkerCodec: CacheCodec {
        func encode(_ value: some Encodable) throws -> Data {
            Data("marker:".utf8) + (try JSONCacheCodec().encode(value))
        }
        func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try JSONCacheCodec().decode(type, from: data.dropFirst("marker:".count))
        }
    }

    /// Provides a codec the way an application would: its own module.
    struct MarkerCodecModule: FlightModule {
        let codec: any CacheCodec = MarkerCodec()
        func configure(_ container: Container) throws {}
    }

    @Test("an application's registered codec is the one the runtime uses")
    func registeredCodecIsUsed() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration()
            let codecModule = MarkerCodecModule()
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [
                    codecModule,
                    try FlightCacheModule(configuration: configuration, codec: codecModule.codec),
                ])
            let runtime = try application.container.resolve(CacheRuntime.self)
            _ = try await runtime.cacheable(namespace: "codec", parts: ["1"], ttl: .seconds(60)) { 42 }

            let store = try application.container.resolve((any Cache).self)
            let stored = await store.get(CacheKey(namespace: "codec", parts: ["1"]))
            #expect(stored.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("marker:") == true)
        }
    }

    @Test("no registered codec still means JSON")
    func defaultCodecIsJSON() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration()
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [try FlightCacheModule(configuration: configuration)])
            let runtime = try application.container.resolve(CacheRuntime.self)
            _ = try await runtime.cacheable(namespace: "codec", parts: ["2"], ttl: .seconds(60)) { 42 }

            let store = try application.container.resolve((any Cache).self)
            let stored = await store.get(CacheKey(namespace: "codec", parts: ["2"]))
            #expect(stored.map { String(decoding: $0, as: UTF8.self) } == "42")
        }
    }
}

/// The configuration cross-check on the in-memory fallback.
///
/// This is the bug that produced the check: a real application configured
/// `cache.valkey.url`, omitted `FlightCacheValkeyModule`, and cached
/// per-node with nothing to show for it. Every layer worked; the
/// configuration was read by nobody.
@Suite("FlightCacheModule — unloaded adapter", .serialized)
struct UnloadedCacheAdapterTests {

    @Test("cache.valkey.url with no adapter module refuses to boot in-memory")
    func configuredButNotLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://127.0.0.1:6379"])

            let error = #expect(throws: (any Error).self) {
                try FlightCacheModule(configuration: configuration)
            }
            let message = String(describing: try #require(error))
            #expect(message.contains("cache.valkey.url"))
            #expect(message.contains("FlightCacheValkeyModule"))
        }
    }

    @Test("an adapter store present means the configuration has a reader — no cross-check")
    func configuredAndLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            // Same configuration; a registered store is what the check is
            // about, so the fallback branch never runs.
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://127.0.0.1:6379"])
            let adapter = ModuleTests.RecordingAdapterModule()
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [
                    adapter,
                    try FlightCacheModule(configuration: configuration, adapter: adapter.cache),
                ])
            #expect(try application.container.resolve((any Cache).self) is RecordingCache)
        }
    }

    @Test("no adapter and no configuration is the ordinary in-process cache")
    func neitherConfiguredNorLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            let configuration = Configuration()
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [try FlightCacheModule(configuration: configuration)])
            #expect(try application.container.resolve((any Cache).self) is InMemoryCache)
        }
    }
}
