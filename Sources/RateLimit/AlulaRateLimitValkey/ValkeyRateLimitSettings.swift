import AlulaCacheValkey
import AlulaCore
import Valkey

/// The `rate-limit.valkey.*` config vocabulary. Its own root, not
/// `cache.valkey.*`: a limiter and a cache may well point at different
/// servers, and one of them losing its data matters much more than the
/// other.
public enum ValkeyRateLimitConfigKey {
    public static let root = "rate-limit.valkey"
    /// `rate-limit.valkey.url` — required, and the key `AlulaRateLimitModule`
    /// probes for to refuse a configuration nobody loaded a module for.
    public static let url = "rate-limit.valkey.url"
    /// `rate-limit.valkey.command-timeout` — bounds a command once a
    /// connection is leased.
    public static let commandTimeout = "rate-limit.valkey.command-timeout"
    /// `rate-limit.valkey.unreachable-after` — how long the pool keeps
    /// trying to connect before declaring the server unreachable and failing
    /// fast. Defaults to the command timeout.
    public static let unreachableAfter = "rate-limit.valkey.unreachable-after"
    /// `rate-limit.valkey.pool-size` — maximum connections.
    public static let poolSize = "rate-limit.valkey.pool-size"
    /// `rate-limit.valkey.min-connections` — connections kept warm.
    public static let minimumConnections = "rate-limit.valkey.min-connections"
    /// `rate-limit.valkey.key-prefix` — what every key is stored under.
    public static let keyPrefix = "rate-limit.valkey.key-prefix"
}

/// Loaded, validated settings — read at composition, so a bad URL fails
/// startup rather than the first request that gets limited.
///
/// The URL grammar and the driver configuration are the cache adapter's,
/// reused rather than written a third time; this type owns the keys and the
/// defaults that differ.
public struct ValkeyRateLimitSettings: Sendable, Equatable {
    /// Short, and shorter than the session store's second. A limiter sits in
    /// front of work the caller wants done, so every millisecond it spends
    /// is latency added to a request that was going to be allowed anyway.
    /// When it cannot answer in time the middleware fails open, which is a
    /// survivable outcome; making the caller wait a second first is not.
    public static let defaultCommandTimeout: Duration = .milliseconds(100)
    public static let defaultPoolSize = 20
    public static let defaultMinimumConnections = 1
    public static let defaultKeyPrefix = "alula-rate-limit:"

    public let url: ValkeyCacheURL
    public let commandTimeout: Duration
    public let unreachableAfter: Duration
    public let poolSize: Int
    public let minimumConnections: Int
    public let keyPrefix: String

    public init(
        url: ValkeyCacheURL,
        commandTimeout: Duration = ValkeyRateLimitSettings.defaultCommandTimeout,
        unreachableAfter: Duration? = nil,
        poolSize: Int = ValkeyRateLimitSettings.defaultPoolSize,
        minimumConnections: Int = ValkeyRateLimitSettings.defaultMinimumConnections,
        keyPrefix: String = ValkeyRateLimitSettings.defaultKeyPrefix
    ) {
        self.url = url
        self.commandTimeout = commandTimeout
        self.unreachableAfter = unreachableAfter ?? commandTimeout
        self.poolSize = poolSize
        self.minimumConnections = minimumConnections
        self.keyPrefix = keyPrefix
    }

    public static func load(from configuration: Configuration) throws -> ValkeyRateLimitSettings {
        let urlString: String = try configuration.get(ValkeyRateLimitConfigKey.url)
        let url = try ValkeyCacheURL.parse(urlString)

        let commandTimeout =
            try positiveDuration(ValkeyRateLimitConfigKey.commandTimeout, from: configuration)
            ?? Self.defaultCommandTimeout
        let unreachableAfter = try positiveDuration(
            ValkeyRateLimitConfigKey.unreachableAfter, from: configuration)

        let poolSize =
            try configuration.getIfPresent(allowingSnakeCase: ValkeyRateLimitConfigKey.poolSize, as: Int.self)
            ?? Self.defaultPoolSize
        guard poolSize > 0 else {
            throw ValkeyRateLimitConfigurationError.invalidPoolSize(poolSize)
        }
        let minimumConnections =
            try configuration.getIfPresent(
                allowingSnakeCase: ValkeyRateLimitConfigKey.minimumConnections, as: Int.self)
            ?? min(Self.defaultMinimumConnections, poolSize)
        guard minimumConnections >= 0, minimumConnections <= poolSize else {
            throw ValkeyRateLimitConfigurationError.invalidMinimumConnections(
                minimumConnections, poolSize: poolSize)
        }
        let keyPrefix =
            try configuration.getIfPresent(allowingSnakeCase: ValkeyRateLimitConfigKey.keyPrefix, as: String.self)
            ?? Self.defaultKeyPrefix

        return ValkeyRateLimitSettings(
            url: url,
            commandTimeout: commandTimeout,
            unreachableAfter: unreachableAfter,
            poolSize: poolSize,
            minimumConnections: minimumConnections,
            keyPrefix: keyPrefix)
    }

    private static func positiveDuration(
        _ key: String, from configuration: Configuration
    ) throws -> Duration? {
        guard let duration = try configuration.getIfPresent(allowingSnakeCase: key, as: Duration.self) else {
            return nil
        }
        guard duration > .zero else {
            throw ValkeyRateLimitConfigurationError.nonPositiveTimeout(key: key, value: duration)
        }
        return duration
    }

    /// The driver's client configuration, built by the cache adapter's
    /// settings type, which already knows how.
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

public enum ValkeyRateLimitConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case nonPositiveTimeout(key: String, value: Duration)
    case invalidPoolSize(Int)
    case invalidMinimumConnections(Int, poolSize: Int)

    public var description: String {
        switch self {
        case .nonPositiveTimeout(let key, let value):
            return "\(key) is \(value) — a timeout must be positive."
        case .invalidPoolSize(let size):
            return
                "\(ValkeyRateLimitConfigKey.poolSize) is \(size) — the connection pool needs at least one connection."
        case .invalidMinimumConnections(let minimum, let poolSize):
            return
                "\(ValkeyRateLimitConfigKey.minimumConnections) is \(minimum), which must be between 0 and \(ValkeyRateLimitConfigKey.poolSize) (\(poolSize))."
        }
    }
}
