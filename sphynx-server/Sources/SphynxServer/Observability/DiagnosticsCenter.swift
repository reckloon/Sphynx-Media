import Foundation

/// In-process activity tracker behind the web admin **Activity** tab: a live view
/// of items being parsed/enriched (a small work queue), aggregate counters, and a
/// log of recent scans. Process-global, like `LogStore`, so the indexer and
/// enrichment service can report to it without being re-plumbed.
///
/// The reference server enriches items sequentially, so "active" is usually 0 or
/// 1; the model is a queue (queued → active → done) so it still reads correctly if
/// processing ever fans out.
actor DiagnosticsCenter {
    static let shared = DiagnosticsCenter()

    /// How a single parse/enrich attempt resolved.
    enum JobResult: String, Sendable {
        case enriched         // identified + metadata written
        case alreadyComplete  // already identified + still fresh — re-fetch correctly skipped
        case skipped          // unidentifiable (no TMDB match) — left as a skeleton
        case failed           // an error was caught (see the log for detail)
    }

    private struct ActiveJob {
        var itemId: String
        var title: String
        var kind: String      // "movie" | "tv"
        var startedAt: Date
    }

    private let startedAt = Date()
    private var nextToken = 1
    private var queued = 0
    private var scanningSources: [String: String] = [:]   // sourceId → label, in flight
    private var active: [Int: ActiveJob] = [:]

    // Lifetime counters.
    private var processed = 0
    private var enriched = 0
    private var alreadyComplete = 0
    private var skipped = 0
    private var failed = 0

    private var recentJobs: [JobView] = []     // newest first, capped
    private var recentScans: [ScanView] = []   // newest first, capped
    private let jobCap = 60
    private let scanCap = 20

    /// Sendable value-type formatter (unlike `ISO8601DateFormatter`).
    private static let iso = Date.ISO8601FormatStyle()

    // MARK: Reporting (called by the indexer + enrichment service)

    /// Note that `n` items are about to be considered for enrichment.
    func enqueue(_ n: Int) {
        guard n > 0 else { return }
        queued += n
    }

    /// Mark one item as actively being worked. Returns a token to pass to `finish`.
    func begin(itemId: String, title: String, kind: String) -> Int {
        let token = nextToken
        nextToken += 1
        if queued > 0 { queued -= 1 }
        active[token] = ActiveJob(itemId: itemId, title: title, kind: kind, startedAt: Date())
        return token
    }

    /// Mark a previously-begun job done with its result.
    func finish(_ token: Int, result: JobResult) {
        guard let job = active.removeValue(forKey: token) else { return }
        processed += 1
        switch result {
        case .enriched: enriched += 1
        case .alreadyComplete: alreadyComplete += 1
        case .skipped: skipped += 1
        case .failed: failed += 1
        }
        let durationMs = Date().timeIntervalSince(job.startedAt) * 1000
        recentJobs.insert(
            JobView(itemId: job.itemId, title: job.title, kind: job.kind,
                    result: result.rawValue, durationMs: durationMs,
                    at: Self.iso.format(Date())),
            at: 0
        )
        if recentJobs.count > jobCap { recentJobs.removeLast(recentJobs.count - jobCap) }
    }

    func scanBegan(sourceId: String, label: String) { scanningSources[sourceId] = label }

    /// A scan threw before completing — clear its in-flight flag (no summary).
    func scanFailed(sourceId: String) { scanningSources[sourceId] = nil }

    func scanEnded(sourceId: String, scanned: Int, added: Int, updated: Int,
                   removed: Int, enriched: Int, durationMs: Double) {
        scanningSources[sourceId] = nil
        recentScans.insert(
            ScanView(sourceId: sourceId, scanned: scanned, added: added, updated: updated,
                     removed: removed, enriched: enriched, durationMs: durationMs,
                     at: Self.iso.format(Date())),
            at: 0
        )
        if recentScans.count > scanCap { recentScans.removeLast(recentScans.count - scanCap) }
    }

    // MARK: Read

    func snapshot() -> ActivitySnapshot {
        let now = Date()
        let activeViews = active.values
            .sorted { $0.startedAt < $1.startedAt }
            .map { JobView(itemId: $0.itemId, title: $0.title, kind: $0.kind,
                           result: nil, durationMs: now.timeIntervalSince($0.startedAt) * 1000,
                           at: Self.iso.format($0.startedAt)) }
        let phase: String
        if !active.isEmpty { phase = "enriching" }
        else if !scanningSources.isEmpty { phase = "scanning" }
        else { phase = "idle" }
        let scanning = scanningSources
            .map { ScanningSourceView(id: $0.key, label: $0.value) }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
        return ActivitySnapshot(
            phase: phase,
            scanning: !scanningSources.isEmpty,
            scanningSources: scanning,
            active: active.count,
            queued: queued,
            processed: processed,
            enriched: enriched,
            alreadyComplete: alreadyComplete,
            skipped: skipped,
            failed: failed,
            uptimeSeconds: now.timeIntervalSince(startedAt),
            jobs: activeViews,
            recent: recentJobs,
            scans: recentScans
        )
    }
}

/// One parse/enrich job — either in flight (`result == nil`, `durationMs` is its
/// current age) or finished (`result` set, `durationMs` is how long it took).
struct JobView: Codable, Sendable {
    var itemId: String
    var title: String
    var kind: String
    var result: String?
    var durationMs: Double
    var at: String
}

/// A completed scan of one source.
struct ScanView: Codable, Sendable {
    var sourceId: String
    var scanned: Int
    var added: Int
    var updated: Int
    var removed: Int
    var enriched: Int
    var durationMs: Double
    var at: String
}

/// The live activity snapshot the Activity tab polls.
/// A source currently being scanned (for the live "Scanning <name>" indicator and
/// per-source spinners in the admin UI).
struct ScanningSourceView: Codable, Sendable {
    var id: String
    var label: String
}

struct ActivitySnapshot: Codable, Sendable {
    var phase: String          // "idle" | "scanning" | "enriching"
    var scanning: Bool
    /// The sources scanning right now, by id + label.
    var scanningSources: [ScanningSourceView]
    var active: Int
    var queued: Int
    var processed: Int
    var enriched: Int
    var alreadyComplete: Int
    var skipped: Int
    var failed: Int
    var uptimeSeconds: Double
    var jobs: [JobView]        // currently active
    var recent: [JobView]      // recently finished, newest first
    var scans: [ScanView]      // recent scans, newest first
    /// Next-run schedule for each background task (filled in by the controller from
    /// the `ScheduleCenter`); absent when no scheduler is wired (e.g. some tests).
    var schedule: [ScheduleView]? = nil
}
