import FlightRateLimit
import Logging
import Valkey

/// The Valkey/Redis-backed `RateLimitStore`, so a quota is enforced once
/// across every replica rather than once per replica.
///
/// The whole decision is one `EVAL`. GCRA's state is a single timestamp per
/// key, so deciding and recording is a read, a comparison and a write of one
/// value, and a Lua script performs all three atomically on the server in
/// one round trip. No `WATCH`/`MULTI` retry loop, no lock, and no window in
/// which two replicas both see an under-quota key and both admit a call.
/// That property is the reason the algorithm was chosen.
///
/// **Nothing here fails open.** A failure throws, and the caller decides:
/// `RateLimiting` serves the request and says loudly that it is not
/// enforcing, a login throttle may well refuse. The adapter's job is to be
/// fast about failing, which is what the pool's circuit breaker does, not to
/// have an opinion about what a failure means.
public final class ValkeyRateLimitStore: RateLimitStore, Sendable {
    /// The underlying client, for commands this store does not wrap.
    public let client: ValkeyClient
    private let keyPrefix: String
    private let logger: Logger

    public init(settings: ValkeyRateLimitSettings, logger: Logger? = nil) throws {
        let logger = logger ?? Logger(label: "flight.rate-limit.valkey")
        self.client = ValkeyClient(
            settings.url.address,
            configuration: try settings.clientConfiguration(),
            logger: logger)
        self.keyPrefix = settings.keyPrefix
        self.logger = logger
    }

    public func consume(key: String, cost: Int, quota: RateLimitQuota) async throws
        -> RateLimitDecision
    {
        let fields: [String]
        do {
            let token = try await client.eval(
                script: Self.script,
                keys: [ValkeyKey(keyPrefix + key)],
                args: [
                    String(quota.emissionIntervalMicroseconds),
                    String(quota.burstOffsetMicroseconds),
                    String(cost),
                    String(quota.burst),
                ])
            fields = try token.decode(as: [String].self)
        } catch {
            throw RateLimitStoreError(reason: "\(error)")
        }
        guard fields.count == 4,
            let allowed = Int(fields[0]),
            let remaining = Int(fields[1]),
            let retryAfter = Int64(fields[2]),
            let resetAfter = Int64(fields[3])
        else {
            throw RateLimitStoreError(
                reason: "the limiter script returned \(fields), which is not a decision")
        }
        return RateLimitDecision(
            isAllowed: allowed == 1,
            remaining: remaining,
            // The script says "never" with a negative number, because Lua
            // has no null to put in an array and a missing element would
            // shift the ones after it.
            retryAfter: retryAfter < 0 ? nil : .microseconds(retryAfter),
            resetAfter: .microseconds(max(resetAfter, 0)))
    }

    /// GCRA, on the server.
    ///
    /// Read it beside `GCRA.decide` in flight: the two are deliberately the
    /// same arithmetic in the same order. Two implementations of one
    /// algorithm are only trustworthy if they can be checked against each
    /// other line by line, and the integration suite runs the same scenarios
    /// against both — which is how the original version of this script was
    /// caught reporting one permit fewer than were free.
    ///
    /// **Whole microseconds throughout, and that is load-bearing.** Lua
    /// numbers are doubles, and this subtracts timestamps near 1.8e15. In
    /// fractional seconds that leaves about half a microsecond of error,
    /// enough to floor the permit count to the wrong integer. As integers,
    /// microseconds since the epoch sit well inside a double's exact 53-bit
    /// range, so every value here is exact and nothing needs an epsilon.
    /// `string.format('%d', …)` rather than `tostring` for the same reason:
    /// `tostring` renders a 16-digit number in scientific notation and
    /// throws away the microseconds it is there to carry.
    ///
    /// `TIME` rather than a timestamp from the client: the server's clock is
    /// the only one every replica shares, and a limiter keyed on a client's
    /// idea of now is a limiter with as many opinions as there are pods.
    private static let script = """
        local emission = tonumber(ARGV[1])
        local burst_offset = tonumber(ARGV[2])
        local cost = tonumber(ARGV[3])
        local burst = tonumber(ARGV[4])

        local time = redis.call('TIME')
        local now = tonumber(time[1]) * 1000000 + tonumber(time[2])

        local stored = redis.call('GET', KEYS[1])
        local tat = now
        if stored then
          local parsed = tonumber(stored)
          if parsed and parsed > now then tat = parsed end
        end

        local function permits(level)
          local free = burst_offset - level
          if free <= 0 then return 0 end
          return math.floor(free / emission)
        end

        local function whole(value)
          return string.format('%d', value)
        end

        -- A free probe, and a cost no burst could ever admit, both report
        -- the state and change nothing. The second says "never" with -1.
        if cost == 0 then
          return {'1', whole(permits(tat - now)), '-1', whole(tat - now)}
        end
        if cost > burst then
          return {'0', whole(permits(tat - now)), '-1', whole(tat - now)}
        end

        local new_tat = tat + cost * emission
        local admit_at = new_tat - burst_offset
        if admit_at > now then
          return {'0', whole(permits(tat - now)), whole(admit_at - now), whole(tat - now)}
        end

        -- The key is worth remembering exactly as long as it is not yet back
        -- at full, so the server reclaims idle keys without a sweeper.
        local ttl = math.ceil((new_tat - now) / 1000000)
        if ttl < 1 then ttl = 1 end
        redis.call('SET', KEYS[1], whole(new_tat), 'EX', ttl)
        return {'1', whole(permits(new_tat - now)), '-1', whole(new_tat - now)}
        """
}
