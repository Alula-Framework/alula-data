import AlulaCore
import AlulaSessions
import Testing

@testable import AlulaSessionsValkey

@Suite("AlulaSessionsValkeyModule — wiring")
struct ModuleTests {

    @Test("the module provides its store as the seam type and runs the pool as its service")
    func providesStore() throws {
        // Construction parses eagerly but dials only when the service runs
        // (nothing listens on port 5).
        let configuration = Configuration(values: ["sessions.valkey.url": "valkey://localhost:5"])
        let module = try AlulaSessionsValkeyModule(configuration: configuration)
        #expect(module.store is ValkeySessionStore)
        #expect(module.service != nil)
        #expect(module.serviceShutdownPhase == .infrastructure, "every request with a cookie borrows a connection")
        let application = try Alula.assemble(configuration: configuration, modules: [module])
        #expect(application.services.contains { $0.moduleName == "AlulaSessionsValkeyModule" })
    }

    @Test("a malformed URL fails composition, never the first request")
    func badURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try AlulaSessionsValkeyModule(
                configuration: Configuration(values: ["sessions.valkey.url": "http://nope"]))
        }
    }

    @Test("a missing URL fails composition with a configuration error")
    func missingURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try AlulaSessionsValkeyModule(configuration: Configuration())
        }
    }
}
