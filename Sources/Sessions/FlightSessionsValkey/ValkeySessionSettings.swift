import FlightCacheValkey
import FlightCore
import Valkey

/// The `sessions.valkey.*` config vocabulary — its own root, not
/// `cache.valkey.*` or `datasource.*`: choosing Valkey for sessions does not
/// require adopting it for caching, and the two may well be different
/// servers with different durability settings.
///
/// Kebab-case, with durations as duration strings (`250ms`, `1s`), matching
/// the `sessions.*` keys on the flight side that these sit beside — rather
/// than the cache adapter's `command_timeout_ms` integers, which predate the
/// convention.
public enum ValkeySessionConfigKey {
    public static let root = "sessions.valkey"
    /// `sessions.valkey.url` — required, and the key `FlightSessionsModule`
    /// probes for to refuse a configuration nobody loaded a module for.
    /// `valkey://` and `redis://` are exact synonyms (`valkeys://`/`rediss://`
    /// for TLS), same as the cache adapter.
    public static let url = "sessions.valkey.url"
    /// `sessions.valkey.command-timeout` — bounds a command once a connection
    /// is leased.
    public static let commandTimeout = "sessions.valkey.command-timeout"
    /// `sessions.valkey.unreachable-after` — how long the pool keeps trying
    /// to connect before declaring the server unreachable and failing fast.
    /// Defaults to the command timeout.
    public static let unreachableAfter = "sessions.valkey.unreachable-after"
    /// `sessions.valkey.pool-size` — maximum connections.
    public static let poolSize = "sessions.valkey.pool-size"
    /// `sessions.valkey.min-connections` — connections kept warm.
    public static let minimumConnections = "sessions.valkey.min-connections"
}

/// Loaded, validated settings — read at composition, so a bad URL fails
/// startup, never the first request with a cookie.
///
/// The URL grammar and the driver configuration are the cache adapter's
/// (`ValkeyCacheURL`, `ValkeyCacheSettings.clientConfiguration()`), reused
/// rather than copied a third time; this type owns only the keys and the
/// defaults that differ.
public struct ValkeySessionSettings: Sendable, Equatable {
    /// A second, not the cache's quarter-second. A session load is on the
    /// path of every request that carries a cookie and there is nothing to
    /// fall back to, so a slow server costs latency here where it would cost
    /// a miss there. A *down* server is the pool breaker's job either way.
    public static let defaultCommandTimeout: Duration = .seconds(1)
    public static let defaultPoolSize = 20
    public static let defaultMinimumConnections = 1

    public let url: ValkeyCacheURL
    public let commandTimeout: Duration
    public let unreachableAfter: Duration
    public let poolSize: Int
    public let minimumConnections: Int

    public init(
        url: ValkeyCacheURL,
        commandTimeout: Duration = ValkeySessionSettings.defaultCommandTimeout,
        unreachableAfter: Duration? = nil,
        poolSize: Int = ValkeySessionSettings.defaultPoolSize,
        minimumConnections: Int = ValkeySessionSettings.defaultMinimumConnections
    ) {
        self.url = url
        self.commandTimeout = commandTimeout
        self.unreachableAfter = unreachableAfter ?? commandTimeout
        self.poolSize = poolSize
        self.minimumConnections = minimumConnections
    }

    public static func load(from configuration: Configuration) throws -> ValkeySessionSettings {
        let urlString: String = try configuration.get(ValkeySessionConfigKey.url)
        let url = try ValkeyCacheURL.parse(urlString)

        let commandTimeout =
            try positiveDuration(ValkeySessionConfigKey.commandTimeout, from: configuration)
            ?? Self.defaultCommandTimeout
        let unreachableAfter = try positiveDuration(
            ValkeySessionConfigKey.unreachableAfter, from: configuration)

        let poolSize =
            try configuration.getIfPresent(ValkeySessionConfigKey.poolSize, as: Int.self)
            ?? Self.defaultPoolSize
        guard poolSize > 0 else {
            throw ValkeySessionConfigurationError.invalidPoolSize(poolSize)
        }
        let minimumConnections =
            try configuration.getIfPresent(ValkeySessionConfigKey.minimumConnections, as: Int.self)
            ?? min(Self.defaultMinimumConnections, poolSize)
        guard minimumConnections >= 0, minimumConnections <= poolSize else {
            throw ValkeySessionConfigurationError.invalidMinimumConnections(
                minimumConnections, poolSize: poolSize)
        }

        return ValkeySessionSettings(
            url: url,
            commandTimeout: commandTimeout,
            unreachableAfter: unreachableAfter,
            poolSize: poolSize,
            minimumConnections: minimumConnections)
    }

    private static func positiveDuration(
        _ key: String, from configuration: Configuration
    ) throws -> Duration? {
        guard let duration = try configuration.getIfPresent(key, as: Duration.self) else {
            return nil
        }
        guard duration > .zero else {
            throw ValkeySessionConfigurationError.nonPositiveTimeout(key: key, value: duration)
        }
        return duration
    }

    /// The driver's client configuration — auth, database, TLS, both halves
    /// of the timeout budget — built by the cache adapter's settings type,
    /// which already knows how.
    public func clientConfiguration() throws -> ValkeyClientConfiguration {
        try ValkeyCacheSettings(
            url: url,
            commandTimeout: commandTimeout,
            unreachableAfter: unreachableAfter,
            poolSize: poolSize,
            minimumConnections: minimumConnections
        ).clientConfiguration()
    }
}

public enum ValkeySessionConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case nonPositiveTimeout(key: String, value: Duration)
    case invalidPoolSize(Int)
    case invalidMinimumConnections(Int, poolSize: Int)

    public var description: String {
        switch self {
        case .nonPositiveTimeout(let key, let value):
            return "\(key) is \(value) — a timeout must be positive."
        case .invalidPoolSize(let size):
            return
                "\(ValkeySessionConfigKey.poolSize) is \(size) — the session connection pool needs at least one connection."
        case .invalidMinimumConnections(let minimum, let poolSize):
            return
                "\(ValkeySessionConfigKey.minimumConnections) is \(minimum), which must be between 0 and \(ValkeySessionConfigKey.poolSize) (\(poolSize))."
        }
    }
}
