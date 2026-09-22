import FlightCore
import FlightRateLimit
import Testing

@testable import FlightRateLimitValkey

@Suite("ValkeyRateLimitSettings")
struct SettingsTests {

    @Test("the URL key is the one FlightRateLimitModule probes for")
    func probeKeyMatchesFlight() {
        // FlightRateLimit's `ValkeyRateLimitConfigKeyProbe.url` is the other
        // half of this string, in a package this suite cannot `@testable
        // import`. If either side moves, the base module stops noticing an
        // unloaded adapter — and an unnoticed unloaded adapter is a limiter
        // enforcing once per replica while the configuration says otherwise.
        #expect(ValkeyRateLimitConfigKey.url == "rate-limit.valkey.url")
    }

    @Test("defaults are the limiter's, not the cache's or the session store's")
    func defaults() throws {
        let settings = try ValkeyRateLimitSettings.load(
            from: Configuration(values: ["rate-limit.valkey.url": "valkey://localhost:6379"]))
        #expect(settings.url.host == "localhost")
        #expect(
            settings.commandTimeout == .milliseconds(100),
            "short: every millisecond here is latency on a request that was going to be allowed")
        #expect(settings.unreachableAfter == .milliseconds(100))
        #expect(settings.poolSize == 20)
        #expect(settings.minimumConnections == 1)
        #expect(settings.keyPrefix == "flight-rate-limit:")
    }

    @Test("every key is read")
    func allKeys() throws {
        let settings = try ValkeyRateLimitSettings.load(
            from: Configuration(values: [
                "rate-limit.valkey.url": "rediss://user:secret@limits.example.com:6380/4",
                "rate-limit.valkey.command-timeout": "50ms",
                "rate-limit.valkey.unreachable-after": "500ms",
                "rate-limit.valkey.pool-size": "8",
                "rate-limit.valkey.min-connections": "2",
                "rate-limit.valkey.key-prefix": "app1:",
            ]))
        #expect(settings.url.useTLS)
        #expect(settings.url.database == 4)
        #expect(settings.commandTimeout == .milliseconds(50))
        #expect(settings.unreachableAfter == .milliseconds(500))
        #expect(settings.poolSize == 8)
        #expect(settings.minimumConnections == 2)
        #expect(settings.keyPrefix == "app1:")
    }

    @Test("a missing URL is a configuration error naming the key")
    func missingURL() {
        #expect(throws: (any Error).self) {
            try ValkeyRateLimitSettings.load(from: Configuration())
        }
    }

    @Test("bad values are refused at load")
    func badValues() {
        #expect(
            throws: ValkeyRateLimitConfigurationError.nonPositiveTimeout(
                key: "rate-limit.valkey.command-timeout", value: .zero)
        ) {
            try ValkeyRateLimitSettings.load(
                from: Configuration(values: [
                    "rate-limit.valkey.url": "valkey://localhost",
                    "rate-limit.valkey.command-timeout": "0s",
                ]))
        }
        #expect(throws: ValkeyRateLimitConfigurationError.invalidPoolSize(0)) {
            try ValkeyRateLimitSettings.load(
                from: Configuration(values: [
                    "rate-limit.valkey.url": "valkey://localhost",
                    "rate-limit.valkey.pool-size": "0",
                ]))
        }
    }

    @Test("the driver configuration carries both halves of the timeout budget")
    func clientConfiguration() throws {
        let settings = try ValkeyRateLimitSettings.load(
            from: Configuration(values: [
                "rate-limit.valkey.url": "valkey://localhost",
                "rate-limit.valkey.command-timeout": "30ms",
                "rate-limit.valkey.unreachable-after": "800ms",
            ]))
        let configuration = try settings.clientConfiguration()
        #expect(configuration.commandTimeout == .milliseconds(30))
        #expect(configuration.connectionPool.circuitBreakerTripAfter == .milliseconds(800))
    }
}

@Suite("FlightRateLimitValkeyModule — wiring")
struct ModuleTests {

    @Test("the module provides its store as the seam type and runs the pool as its service")
    func providesStore() throws {
        // Construction parses eagerly but dials only when the service runs
        // (nothing listens on port 5).
        let configuration = Configuration(values: ["rate-limit.valkey.url": "valkey://localhost:5"])
        let module = try FlightRateLimitValkeyModule(configuration: configuration)
        #expect(module.store is ValkeyRateLimitStore)
        #expect(module.service != nil)
        #expect(
            module.serviceShutdownPhase == .infrastructure,
            "a request being limited borrows a connection from it")
        let application = try Flight.assemble(configuration: configuration, modules: [module])
        #expect(application.services.contains { $0.moduleName == "FlightRateLimitValkeyModule" })
    }

    @Test("a malformed URL fails composition, never the first limited request")
    func badURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try FlightRateLimitValkeyModule(
                configuration: Configuration(values: ["rate-limit.valkey.url": "http://nope"]))
        }
    }

    @Test("a missing URL fails composition with a configuration error")
    func missingURLFailsComposition() {
        #expect(throws: (any Error).self) {
            _ = try FlightRateLimitValkeyModule(configuration: Configuration())
        }
    }
}
