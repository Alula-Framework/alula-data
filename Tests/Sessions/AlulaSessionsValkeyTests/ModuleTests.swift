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

@Suite("AlulaSessionsValkeyModule — readiness")
struct SessionReadinessTests {
    @Test("the module contributes a sessions.valkey check that fails when Valkey does")
    func unreachableFails() async throws {
        let module = try AlulaSessionsValkeyModule(
            configuration: Configuration(values: ["sessions.valkey.url": "valkey://127.0.0.1:5"]))
        #expect(module.healthChecks.map(\.name) == ["sessions.valkey"])
        let runner = Task { try await module.service?.run() }
        defer { runner.cancel() }
        let result = await module.healthChecks[0].run()
        #expect(!result.passed)
    }

    @Test("and passes against a live server", .enabled(if: !TestServer.available.isEmpty))
    func liveServerPasses() async throws {
        let url = try #require(TestServer.available.first?.url)
        let module = try AlulaSessionsValkeyModule(
            configuration: Configuration(values: ["sessions.valkey.url": url]))
        let runner = Task { try await module.service?.run() }
        defer { runner.cancel() }
        #expect(await module.healthChecks[0].run() == .passed)
    }
}
