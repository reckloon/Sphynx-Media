import Foundation

/// Live progress of a background backfill pass (BlurHash generation, media probe),
/// for the matching Extensions-tab status indicator. An actor so the running pass
/// and the admin request can read/write it without races.
///
/// `total`/`done` count **work units** (images to hash, items to probe). They hold
/// the last pass's figures while idle so the UI can show "complete"; `beginPass`
/// resets them.
actor BackfillProgress {
    private(set) var running = false
    private(set) var total = 0
    private(set) var done = 0
    private(set) var lastCompletedAt: Double?

    struct Snapshot: Sendable {
        var running: Bool
        var total: Int
        var done: Int
        var lastCompletedAt: Double?
    }

    func beginPass(total: Int) {
        running = true
        self.total = total
        done = 0
    }

    func advance(by n: Int = 1) { done += n }

    func endPass() {
        running = false
        lastCompletedAt = Date().timeIntervalSince1970
    }

    func snapshot() -> Snapshot {
        Snapshot(running: running, total: total, done: done, lastCompletedAt: lastCompletedAt)
    }
}

/// The wire view of a backfill's progress, shared by the placeholders and media-probe
/// extension configs. `total`/`done` count work units (images / items).
struct BackfillStatus: Codable, Sendable {
    var running: Bool
    var total: Int
    var done: Int
    /// RFC 3339 time the last pass finished, if one has.
    var lastCompletedAt: String?

    init(_ snapshot: BackfillProgress.Snapshot) {
        running = snapshot.running
        total = snapshot.total
        done = snapshot.done
        lastCompletedAt = snapshot.lastCompletedAt.map {
            ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0))
        }
    }
}

extension SettingsStore {
    /// Read a fractional-seconds interval setting (`ext.*.intervalSeconds`). Returns
    /// `nil` when unset/unparseable so the caller can apply its own default; a stored
    /// value `<= 0` means **manual-only** and is returned verbatim (the caller treats
    /// non-positive as "don't auto-schedule"). Sub-second values are preserved.
    func interval(forKey key: String) async -> Double? {
        guard let raw = (try? await all())?[key], let value = Double(raw) else { return nil }
        return value
    }
}
