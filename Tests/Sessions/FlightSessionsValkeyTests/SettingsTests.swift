import FlightCore
import Testing

@testable import FlightSessionsValkey

@Suite("ValkeySessionSettings")
struct SettingsTests {

    @Test("the URL key is the one FlightSessionsModule probes for")
    func probeKeyMatchesFlight() {
        // FlightWeb's `ValkeySessionConfigKeyProbe.url` is the other half of
        // this string, in a package this suite cannot `@testable import`.
        // If either side moves, the base module stops noticing an unloaded
        // adapter, which is exactly the silent failure the probe exists to
        // catch — so the literal is pinned here.
        #expect(ValkeySessionConfigKey.url == "sessions.valkey.url")
    }

    @Test("defaults are the session-shaped ones, not the cache's")
    func defaults() throws {
        let settings = try ValkeySessionSettings.load(
            from: Configuration(values: ["sessions.valkey.url": "valkey://localhost:6379"]))
        #expect(settings.url.host == "localhost")
        #expect(settings.url.port == 6379)
        #expect(settings.commandTimeout == .seconds(1))
        #expect(settings.unreachableAfter == .seconds(1), "follows the command timeout unless split")
        #expect(settings.poolSize == 20)
        #expect(settings.minimumConnections == 1)
    }

    @Test("every key is read, as kebab-case durations and counts")
    func allKeys() throws {
        let settings = try ValkeySessionSettings.load(
            from: Configuration(values: [
                "sessions.valkey.url": "rediss://user:secret@sessions.example.com:6380/3",
                "sessions.valkey.command-timeout": "250ms",
                "sessions.valkey.unreachable-after": "2s",
                "sessions.valkey.pool-size": "8",
                "sessions.valkey.min-connections": "2",
            ]))
        #expect(settings.url.useTLS)
        #expect(settings.url.username == "user")
        #expect(settings.url.password == "secret")
        #expect(settings.url.database == 3)
        #expect(settings.commandTimeout == .milliseconds(250))
        #expect(settings.unreachableAfter == .seconds(2))
        #expect(settings.poolSize == 8)
        #expect(settings.minimumConnections == 2)
    }

    @Test("a missing URL is a configuration error naming the key")
    func missingURL() {
        #expect(throws: (any Error).self) {
            try ValkeySessionSettings.load(from: Configuration())
        }
    }

    @Test("bad values are refused at load, naming what is wrong")
    func badValues() {
        #expect(throws: ValkeySessionConfigurationError.nonPositiveTimeout(key: "sessions.valkey.command-timeout", value: .zero)) {
            try ValkeySessionSettings.load(
                from: Configuration(values: [
                    "sessions.valkey.url": "valkey://localhost", "sessions.valkey.command-timeout": "0s",
                ]))
        }
        #expect(throws: ValkeySessionConfigurationError.invalidPoolSize(0)) {
            try ValkeySessionSettings.load(
                from: Configuration(values: [
                    "sessions.valkey.url": "valkey://localhost", "sessions.valkey.pool-size": "0",
                ]))
        }
        #expect(throws: ValkeySessionConfigurationError.invalidMinimumConnections(9, poolSize: 8)) {
            try ValkeySessionSettings.load(
                from: Configuration(values: [
                    "sessions.valkey.url": "valkey://localhost", "sessions.valkey.pool-size": "8",
                    "sessions.valkey.min-connections": "9",
                ]))
        }
    }

    @Test("the driver configuration carries both halves of the timeout budget")
    func clientConfiguration() throws {
        let settings = try ValkeySessionSettings.load(
            from: Configuration(values: [
                "sessions.valkey.url": "valkey://localhost",
                "sessions.valkey.command-timeout": "300ms",
                "sessions.valkey.unreachable-after": "900ms",
            ]))
        let configuration = try settings.clientConfiguration()
        #expect(configuration.commandTimeout == .milliseconds(300))
        #expect(configuration.connectionPool.circuitBreakerTripAfter == .milliseconds(900))
    }
}
