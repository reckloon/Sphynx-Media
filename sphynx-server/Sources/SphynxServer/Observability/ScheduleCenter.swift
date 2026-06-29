import Foundation

/// The canonical scheduled background tasks, so their names/labels are consistent
/// between the services that update the schedule and the Activity panel that shows it.
enum ScheduledTask {
    static let enrich = (name: "enrich", label: "Enrichment refresh")
    static let index = (name: "index", label: "Library index")
    static let blurhash = (name: "blurhash", label: "BlurHash generation")
    static let mediaProbe = (name: "mediaProbe", label: "Media probe")
    /// Display order in the "Next runs" indicator.
    static let order = [enrich.name, index.name, blurhash.name, mediaProbe.name]
}

/// Tracks when each scheduled background task **next runs**, for the Activity panel's
/// "Next runs" indicator. Each background service updates its own entry as it
/// schedules and runs; the status endpoint reads a snapshot. An actor so the
/// services and the admin request never race.
actor ScheduleCenter {
    struct Entry: Sendable {
        var name: String
        var label: String
        /// Cadence in seconds; `nil` ⇒ manual-only / not auto-scheduled.
        var intervalSeconds: Double?
        var lastRunAt: Double?
        /// Absolute epoch of the next scheduled run; `nil` ⇒ manual-only / disabled.
        var nextRunAt: Double?
        var running: Bool
    }

    private var entries: [String: Entry] = [:]

    private func ensure(_ name: String, _ label: String) {
        if entries[name] == nil {
            entries[name] = Entry(name: name, label: label, running: false)
        } else {
            entries[name]?.label = label
        }
    }

    /// The task is scheduled to run again at `nextRunAt`, every `interval` seconds.
    func scheduled(_ name: String, label: String, interval: Double, nextRunAt: Double) {
        ensure(name, label)
        entries[name]?.intervalSeconds = interval
        entries[name]?.nextRunAt = nextRunAt
    }

    /// The task exists but isn't auto-scheduled (interval 0 / extension off): it only
    /// runs on demand. Keeps the row visible so the admin sees "manual only".
    func manualOnly(_ name: String, label: String) {
        ensure(name, label)
        entries[name]?.intervalSeconds = nil
        entries[name]?.nextRunAt = nil
    }

    /// A task driven by an external/heterogeneous cadence (e.g. per-source index),
    /// with a known next run but no single interval. `nextRunAt == nil` ⇒ nothing is
    /// currently auto-scheduled.
    func nextRun(_ name: String, label: String, at nextRunAt: Double?) {
        ensure(name, label)
        entries[name]?.intervalSeconds = nil
        entries[name]?.nextRunAt = nextRunAt
    }

    func started(_ name: String, label: String) {
        ensure(name, label)
        entries[name]?.running = true
    }

    func finished(_ name: String, at: Double = Date().timeIntervalSince1970) {
        entries[name]?.running = false
        entries[name]?.lastRunAt = at
    }

    func snapshot() -> [Entry] {
        // Stable display order; any unregistered tasks (none today) trail behind.
        let known = ScheduledTask.order.compactMap { entries[$0] }
        let extra = entries.values.filter { !ScheduledTask.order.contains($0.name) }
        return known + extra.sorted { $0.name < $1.name }
    }
}

/// The wire view of one scheduled task for `GET /v1/admin/status`. Times are sent
/// **relative** (`nextRunInSeconds`, `lastRunSecondsAgo`) so the client needn't have
/// a clock synced to the server's. `nextRunInSeconds == nil` ⇒ manual-only.
struct ScheduleView: Codable, Sendable {
    var name: String
    var label: String
    var intervalSeconds: Double?
    var running: Bool
    var nextRunInSeconds: Double?
    var lastRunSecondsAgo: Double?

    init(_ entry: ScheduleCenter.Entry, now: Double) {
        name = entry.name
        label = entry.label
        intervalSeconds = entry.intervalSeconds
        running = entry.running
        nextRunInSeconds = entry.nextRunAt.map { max(0, $0 - now) }
        lastRunSecondsAgo = entry.lastRunAt.map { max(0, now - $0) }
    }
}
