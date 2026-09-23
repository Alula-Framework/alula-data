import Foundation
import AlulaCore
import Testing

import AlulaCacheTesting

@testable import AlulaCache

/// Serialized: these tests exercise the process-global `AlulaCaches`
/// install seam, so they must not interleave.
@Suite("AlulaCacheModule — wiring", .serialized)
struct ModuleTests {

    /// The adapter-module contract in miniature: *provide* a store. The base
    /// module takes it as its `adapter` — matched by type in composition.
    struct RecordingAdapterModule {
        let cache: any Cache = RecordingCache()
    }

    @Test("without an adapter, the in-memory store is the cache")
    func inMemoryDefault() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            // Building the module installs its runtime into the AlulaCaches
            // seam — the value-model home of what the freeze()-time factory did.
            let module = try AlulaCacheModule(
                configuration: Configuration(values: ["cache.memory.max_entries": "5"]))
            let memory = try #require(module.store as? InMemoryCache)
            #expect(memory.maxEntries == 5)
            #expect(AlulaCaches.isInstalled)
        }
    }

    @Test("a supplied adapter store wins over the in-memory default")
    func adapterComposesByPresence() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            let adapter = RecordingAdapterModule()
            let module = try AlulaCacheModule(
                configuration: Configuration(), adapter: adapter.cache)
            #expect(module.store is RecordingCache)
            #expect(AlulaCaches.isInstalled)
        }
    }

    @Test("a non-positive LRU bound fails composition, not the first request")
    func invalidMaxEntriesFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            #expect(throws: (any Error).self) {
                _ = try AlulaCacheModule(
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
            AlulaCaches.uninstall()
            let executions = try await confirmationFreeCount()
            #expect(executions == 2)
        }
    }

    private func confirmationFreeCount() async throws -> Int {
        var executions = 0
        for _ in 0..<2 {
            let value = try await AlulaCaches.current.cacheable(
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

    @Test("an application's supplied codec is the one the runtime uses")
    func registeredCodecIsUsed() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            let module = try AlulaCacheModule(
                configuration: Configuration(), codec: MarkerCodec())
            _ = try await module.runtime.cacheable(
                namespace: "codec", parts: ["1"], ttl: .seconds(60)) { 42 }

            let stored = await module.store.get(CacheKey(namespace: "codec", parts: ["1"]))
            #expect(stored.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("marker:") == true)
        }
    }

    @Test("no supplied codec still means JSON")
    func defaultCodecIsJSON() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            let module = try AlulaCacheModule(configuration: Configuration())
            _ = try await module.runtime.cacheable(
                namespace: "codec", parts: ["2"], ttl: .seconds(60)) { 42 }

            let stored = await module.store.get(CacheKey(namespace: "codec", parts: ["2"]))
            #expect(stored.map { String(decoding: $0, as: UTF8.self) } == "42")
        }
    }
}

/// The configuration cross-check on the in-memory fallback.
///
/// This is the bug that produced the check: a real application configured
/// `cache.valkey.url`, omitted `AlulaCacheValkeyModule`, and cached
/// per-node with nothing to show for it. Every layer worked; the
/// configuration was read by nobody.
@Suite("AlulaCacheModule — unloaded adapter", .serialized)
struct UnloadedCacheAdapterTests {

    @Test("cache.valkey.url with no adapter refuses to boot in-memory")
    func configuredButNotLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://127.0.0.1:6379"])

            let error = #expect(throws: (any Error).self) {
                try AlulaCacheModule(configuration: configuration)
            }
            let message = String(describing: try #require(error))
            #expect(message.contains("cache.valkey.url"))
            #expect(message.contains("AlulaCacheValkeyModule"))
        }
    }

    @Test("an adapter store present means the configuration has a reader — no cross-check")
    func configuredAndLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            // Same configuration; a supplied store is what the check is about,
            // so the fallback branch never runs.
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://127.0.0.1:6379"])
            let adapter = ModuleTests.RecordingAdapterModule()
            let module = try AlulaCacheModule(configuration: configuration, adapter: adapter.cache)
            #expect(module.store is RecordingCache)
        }
    }

    @Test("no adapter and no configuration is the ordinary in-process cache")
    func neitherConfiguredNorLoaded() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            let module = try AlulaCacheModule(configuration: Configuration())
            #expect(module.store is InMemoryCache)
        }
    }
}
