import AlulaCacheTesting
import AlulaCore
import Testing

@testable import AlulaCache
@testable import AlulaCacheValkey

/// Serialized: assembling AlulaCacheModule installs into the process-global
/// AlulaCaches seam.
@Suite("AlulaCacheValkeyModule — wiring", .serialized)
struct ModuleRegistrationTests {

    @Test("the Valkey store wins the compose-by-presence choice")
    func adapterChosen() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            // Construction parses eagerly but dials only when the service runs
            // (nothing listens on port 5).
            // The adapter provides the store; the base module takes it —
            // both are built, the direction the inversion established.
            let configuration = Configuration(values: ["cache.valkey.url": "valkey://localhost:5"])
            let valkey = try AlulaCacheValkeyModule(configuration: configuration)
            let cacheModule = try AlulaCacheModule(configuration: configuration, adapter: valkey.cache)
            let application = try Alula.assemble(
                configuration: configuration,
                modules: [valkey, cacheModule])
            // The base module took the adapter as its store, over the in-memory
            // default — the direction the inversion established.
            #expect(cacheModule.store is ValkeyCache)
            #expect(AlulaCaches.isInstalled)
            // The adapter contributed its client service to the group.
            #expect(application.services.contains { $0.moduleName == "AlulaCacheValkeyModule" })
        }
    }

    @Test("a malformed URL fails bootstrap, never the first command")
    func badURLFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            // Fails at construction now, which is earlier than the freeze it
            // used to fail at.
            #expect(throws: (any Error).self) {
                _ = try AlulaCacheValkeyModule(
                    configuration: Configuration(values: ["cache.valkey.url": "http://nope"]))
            }
        }
    }

    @Test("a missing URL fails bootstrap with a config error")
    func missingURLFailsBootstrap() async throws {
        try await GlobalCacheSeam.exclusive {
            defer { AlulaCaches.uninstall() }
            #expect(throws: (any Error).self) {
                _ = try AlulaCacheValkeyModule(configuration: Configuration())
            }
        }
    }
}
