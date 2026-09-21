import FlightCore
import FlightSessions
import Testing

@testable import FlightSessionsValkey

@Suite("FlightSessionsValkeyModule — wiring")
struct ModuleTests {

    @Test("the module provides its store as the seam type and runs the pool as its service")
    func providesStore() throws {
        // Construction parses eagerly but dials only when the service runs
        // (nothing listens on port 5).
        let configuration = Configuration(values: ["sessions.valkey.url": "valkey://localhost:5"])
        let module = try FlightSessionsValkeyModule(configuration: configuration)
        #expect(module.store is ValkeySessionStore)
        #expect(module.service != nil)
        #expect(module.serviceShutdownPhase == .infrastructure, "every request with a cookie borrows a connection")
        let application = try Flight.assemble(configuration: configuration, modules: [module])
        #expect(application.services.contains { $0.moduleName == "FlightSessionsValkeyModule" })
    }

    @Test("a malformed URL fails composition, never the first request")
    func badURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try FlightSessionsValkeyModule(
                configuration: Configuration(values: ["sessions.valkey.url": "http://nope"]))
        }
    }

    @Test("a missing URL fails composition with a configuration error")
    func missingURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try FlightSessionsValkeyModule(configuration: Configuration())
        }
    }
}
