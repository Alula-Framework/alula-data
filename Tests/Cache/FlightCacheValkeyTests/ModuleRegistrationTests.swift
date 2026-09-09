import FlightCacheTesting
import FlightCore
import Testing

@testable import FlightCache
@testable import FlightCacheValkey

/// Serialized: assembling FlightCacheModule installs into the process-global
/// FlightCaches seam.
@Suite("FlightCacheValkeyModule — wiring", .serialized)
struct ModuleRegistrationTests {

    @Test("the Valkey store wins the compose-by-presence choice")
    func adapterChosen() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            // Construction parses eagerly but dials only when the service runs
            // (nothing listens on port 5).
            // The adapter provides the store; the base module takes it —
            // both are built, the direction the inversion established.
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://localhost:5"])
            let valkey = try FlightCacheValkeyModule(configuration: configuration)
            let cacheModule = try FlightCacheModule(configuration: configuration, adapter: valkey.cache)
            let application = try Flight.assemble(
                configuration: configuration,
                modules: [valkey, cacheModule])
            // The base module took the adapter as its store, over the in-memory
            // default — the direction the inversion established.
            #expect(cacheModule.store is ValkeyCache)
            #expect(FlightCaches.isInstalled)
            // The adapter contributed its client service to the group.
            #expect(application.services.contains { $0.moduleName == "FlightCacheValkeyModule" })
        }
    }

    @Test("a malformed URL fails bootstrap, never the first command")
    func badURLFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            // Fails at construction now, which is earlier than the freeze it
            // used to fail at.
            #expect(throws: (any Error).self) {
                _ = try FlightCacheValkeyModule(
                    configuration: Configuration(values: ["cache.valkey.url": "http://nope"]))
            }
        }
    }

    @Test("a missing URL fails bootstrap with a config error")
    func missingURLFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { FlightCaches.uninstall() }
            #expect(throws: (any Error).self) {
                _ = try FlightCacheValkeyModule(configuration: Configuration())
            }
        }
    }
}
