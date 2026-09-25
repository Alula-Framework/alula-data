import AlulaCore

extension Configuration {
    /// Reads a kebab-case key, or the snake_case spelling it shipped with.
    ///
    /// One internal copy per target: the targets that read configuration
    /// share no alula-data module, and depending on AlulaDataCore for eight
    /// lines would bring swift-changeset into a cache or a rate limiter.
    ///
    /// alula-data's keys were snake_case — `datasource.primary.pool_size`,
    /// `cache.valkey.command_timeout_ms` — where Alula's are kebab-case
    /// (`queue.lease-seconds`), so one application's `alula.yaml` mixed the
    /// two by package. The kebab-case spelling is the one documented; the
    /// snake_case one is still read, and loses when both are set.
    func getIfPresent<T: ConfigDecodable>(
        allowingSnakeCase key: String, as type: T.Type = T.self
    ) throws -> T? {
        if let value = try getIfPresent(key, as: type) { return value }
        let snake = key.replacingOccurrences(of: "-", with: "_")
        guard snake != key else { return nil }
        return try getIfPresent(snake, as: type)
    }
}
