import AlulaCache

/// Serializes access to the process-global `AlulaCaches` seam.
///
/// `AlulaCaches` is installed by module assembly and torn down afterwards,
/// which makes any test that touches it a test with a global side effect.
/// Marking a suite `.serialized` only orders it against *itself* — two suites
/// in two test targets still interleave, and one's `uninstall()` fires while
/// the other is asserting `isInstalled`.
///
/// That failure is timing-dependent: it passes locally and fails on a loaded
/// CI machine, which is the worst shape a test failure can have. This is the
/// same fix hangar's `DatabaseLock` applies to shared fixture tables, for the
/// same reason.
///
/// ```swift
/// @Test func installs() async throws {
///     try await GlobalCacheSeam.exclusive {
///         defer { AlulaCaches.uninstall() }
///         …
///     }
/// }
/// ```
public actor GlobalCacheSeam {
    private static let instance = GlobalCacheSeam()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }

    private func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    /// Runs `body` once no other `exclusive` body is running, and holds
    /// everyone else off until it returns or throws.
    ///
    /// Callers are admitted in arrival order. Exclusion holds only among
    /// callers of this method — a test that touches `AlulaCaches` without it
    /// is not held off — and calling it again from inside `body` waits for
    /// itself forever.
    public static func exclusive<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await instance.run(body)
    }
}
