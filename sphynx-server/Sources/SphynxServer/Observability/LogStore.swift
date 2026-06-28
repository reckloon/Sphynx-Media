import Foundation
import Logging

/// A bounded, in-memory ring buffer of recent log lines, surfaced by the web
/// admin **Logs** tab for basic diagnostics. Process-global (the logging system
/// is bootstrapped once per process), thread-safe via a plain lock so the
/// synchronous `LogHandler.log` path never has to hop to an actor.
final class LogStore: @unchecked Sendable {
    /// The shared store the logging system feeds and the admin API reads.
    static let shared = LogStore()

    struct Line: Codable, Sendable {
        /// Monotonic id so a client can poll incrementally (`?after=`).
        var seq: Int
        /// RFC 3339 wall-clock time.
        var time: String
        var level: String
        var label: String
        var message: String
    }

    private let lock = NSLock()
    private var buffer: [Line]
    private let capacity: Int
    private var nextSeq = 1
    /// Sendable value-type formatter (unlike `ISO8601DateFormatter`).
    private static let iso = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(capacity: Int = 1000) {
        self.capacity = capacity
        self.buffer = []
        self.buffer.reserveCapacity(capacity)
    }

    /// Append a line, dropping the oldest once at capacity.
    func append(level: Logger.Level, label: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = Line(
            seq: nextSeq,
            time: Self.iso.format(Date()),
            level: level.rawValue,
            label: label,
            message: message
        )
        nextSeq += 1
        buffer.append(line)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
    }

    /// Recent lines, newest last. `after` returns only lines with a higher seq
    /// (incremental polling); `limit` caps how many of the tail are returned.
    func snapshot(after: Int? = nil, limit: Int = 200) -> [Line] {
        lock.lock()
        defer { lock.unlock() }
        var lines = buffer
        if let after { lines = lines.filter { $0.seq > after } }
        if lines.count > limit { lines = Array(lines.suffix(limit)) }
        return lines
    }

    /// The highest seq currently issued (so a client can start tailing from now).
    var latestSeq: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextSeq - 1
    }
}

/// A `LogHandler` that mirrors every record into `LogStore` in addition to
/// whatever else the logging system does (we multiplex it alongside the normal
/// stdout handler). Metadata is folded into the message text so the admin view
/// stays a flat, readable line.
struct CapturingLogHandler: LogHandler {
    let label: String
    let store: LogStore
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .info

    init(label: String, store: LogStore) {
        self.label = label
        self.store = store
    }

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata explicit: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        let merged = explicit.map { self.metadata.merging($0) { _, new in new } } ?? self.metadata
        var text = message.description
        if !merged.isEmpty {
            let rendered = merged.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            text += " · \(rendered)"
        }
        store.append(level: level, label: label, message: text)
    }
}
