import AlulaPubSub
import Foundation
import Logging
import Metrics
import Testing

@testable import AlulaPubSubPostgres

// The relay buffer is bounded on purpose — PubSub is at-most-once — but the
// adapters ignored what `yield` returned, so a full buffer dropped messages
// with no metric and no log line (found by an external audit).

private final class Recorder: MetricsFactory, CounterHandler, LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int64] = [:]
    private var warnings: [Logger.Metadata] = []
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }
    func log(event: LogEvent) {
        guard event.level == .warning else { return }
        lock.withLock { warnings.append(event.metadata ?? [:]) }
    }
    func makeCounter(label: String, dimensions: [(String, String)]) -> any CounterHandler {
        CounterBox(recorder: self, key: label + dimensions.map { "|\($0)=\($1)" }.joined())
    }
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> any RecorderHandler { NOOPMetricsHandler.instance }
    func makeTimer(label: String, dimensions: [(String, String)]) -> any TimerHandler { NOOPMetricsHandler.instance }
    func destroyCounter(_ handler: any CounterHandler) {}
    func destroyRecorder(_ handler: any RecorderHandler) {}
    func destroyTimer(_ handler: any TimerHandler) {}
    func increment(by: Int64) {}
    func reset() {}
    func add(_ key: String, _ amount: Int64) { lock.withLock { counts[key, default: 0] += amount } }
    func count(_ key: String) -> Int64 { lock.withLock { counts[key, default: 0] } }
    var warningLog: [Logger.Metadata] { lock.withLock { warnings } }

    final class CounterBox: CounterHandler, @unchecked Sendable {
        let recorder: Recorder
        let key: String
        init(recorder: Recorder, key: String) {
            self.recorder = recorder
            self.key = key
        }
        func increment(by amount: Int64) { recorder.add(key, amount) }
        func reset() {}
    }
}

@Suite("PubSub drops are observable")
struct DropReportingTests {
    @Test("each dropped message is counted, and the warning is rate-limited")
    func countsAndWarns() {
        let recorder = Recorder()
        let logger = Logger(label: "test") { _ in recorder }
        // The stream must stay alive: dropping it terminates the continuation,
        // and a terminated yield is not a drop.
        let (stream, continuation) = AsyncStream<Message>.makeStream(bufferingPolicy: .bufferingNewest(2))
        defer { withExtendedLifetime(stream) {} }
        var drops = PubSubDropReporter(adapter: "postgres", logger: logger, metrics: recorder)
        for index in 0..<7 {
            drops.record(continuation.yield(Message(topic: "t", payload: Data([UInt8(index)]))))
        }
        #expect(recorder.count("alula.pubsub.dropped|adapter=postgres") == 5)
        // The first drop warns; the next four fall inside the ten-second window.
        #expect(recorder.warningLog.count == 1)
        #expect(recorder.warningLog.first?["dropped"]?.description == "1")
    }
}
