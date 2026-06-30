import Foundation
import Logging
import ServiceLifecycle

/// Background **media probe** for the media-probe extension: probes items that have
/// never been probed (no cached `probedTracksJSON`) and caches their streams /
/// sidecar subtitles / chapters back onto the item, exactly like the per-item manual
/// probe — so [resolve](x) and item detail then serve rich tracks without re-probing.
///
/// Mirrors the BlurHash backfill's shape: a lazy pass that does only what's still
/// missing, with **bounded concurrency** (each probe resolves the item and spawns an
/// `ffprobe`, so this is deliberately smaller than the image backfill's), gated on the
/// extension being **enabled** and `ffprobe` being **available**. The interval is read
/// **live** from `ext.mediaProbe.intervalSeconds` (seconds, fractional allowed);
/// **off (`<= 0`) by default**, so probing only runs in the background once an admin
/// sets an interval — "Run now" works regardless. Registers its next run with the
/// `ScheduleCenter`.
struct MediaProbeBackfillService: Service, ScheduledBackfill {
    /// Default cap on per-item resolves a minute when the admin hasn't set one. Each
    /// probed item costs one source resolve (a TorBox `requestdl` is one of 300/min),
    /// so this stays well under that and leaves headroom for live playback.
    static let defaultMaxPerMinute = 120.0

    let defaultInterval: Double
    let catalog: Catalog
    let resolver: Resolver
    let settings: SettingsStore
    let progress: BackfillProgress
    let schedule: ScheduleCenter
    let logger: Logger
    /// Concurrent probes ⇒ concurrent `ffprobe` processes / resolves. Small on purpose.
    var maxConcurrentItems = 4
    /// Hard cap per item (resolve + ffprobe). A stuck remote source can't park a
    /// worker beyond this — the item is dropped to a future pass instead of freezing
    /// the whole backfill. Comfortably above a healthy resolve+probe.
    var perItemTimeout: Double = 90
    /// After an item fails to resolve/probe, skip it for this long. Without it a
    /// persistently-failing item (a source that keeps returning no URL) is re-attempted
    /// every single pass, so a short interval hammers the provider with doomed resolves
    /// and starves the items that *can* be probed. 24h ⇒ at most one retry a day.
    var failureCooldown: Double = 86_400
    /// Tracks recent per-item failures so cooled-down items are skipped. Reference type
    /// shared across passes for the lifetime of the (long-lived) service.
    let cooldown = ProbeCooldown()

    var task: (name: String, label: String) { ScheduledTask.mediaProbe }
    var intervalKey: String { "ext.mediaProbe.intervalSeconds" }

    func run() async throws {
        logger.info("Media-probe backfill registered (≤\(maxConcurrentItems) concurrent)")
        await runSchedule()
    }

    /// One probe pass (also "Run now" / tests). No-op unless the extension is enabled
    /// and `ffprobe` is available.
    func runOnce() async {
        guard !Task.isCancelled else { return }
        let all = (try? await settings.all()) ?? [:]
        guard all[ExtensionsController.Key.probeEnabled] == "true" else { return }
        guard let path = FFprobeProber.locate(configured: all[ExtensionsController.Key.probePath] ?? "") else {
            return  // ffprobe not installed / not found
        }
        let prober = FFprobeProber(ffprobePath: path)

        let items: [ItemRecord]
        do {
            items = try await catalog.allItems()
        } catch {
            logger.warning("Media-probe backfill: could not list items: \(error)")
            return
        }
        // Playable leaves only: containers (collection/series/season) carry an empty
        // sourceKey. Probe each item at most once (until its tracks are cached), and
        // skip items still in their post-failure cooldown so a doomed source isn't
        // re-resolved every pass.
        let now = Date().timeIntervalSince1970
        let candidates = items.filter { !$0.sourceKey.isEmpty && $0.probedTracksJSON == nil }
        var work: [ItemRecord] = []
        for item in candidates where !(await cooldown.shouldSkip(item.id, now: now, window: failureCooldown)) {
            work.append(item)
        }
        let cooling = candidates.count - work.count
        guard !work.isEmpty else {
            if cooling > 0 { logger.info("Media-probe backfill: \(cooling) item(s) cooling down after failure — nothing to probe") }
            return
        }

        // Rate-limit the per-item source resolves so the pass stays under the
        // provider's request budget (TorBox: 300/min, shared with playback). Read
        // live; `0` ⇒ unlimited; unset ⇒ the conservative default.
        let perMinute = all[ExtensionsController.Key.probeMaxPerMinute].flatMap(Double.init) ?? Self.defaultMaxPerMinute
        let limiter = RateLimiter(perMinute: perMinute)

        await progress.beginPass(total: work.count)
        let coolingNote = cooling > 0 ? " (\(cooling) cooling down)" : ""
        logger.info("Media-probe backfill: probing \(work.count) item(s) at ≤\(Int(perMinute))/min\(coolingNote)")

        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            var active = 0
            for _ in 0 ..< maxConcurrentItems where !Task.isCancelled {
                guard let next = iterator.next() else { break }
                group.addTask { await self.probe(next, with: prober, limiter: limiter) }
                active += 1
            }
            while active > 0 {
                _ = await group.next()
                active -= 1
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { await self.probe(next, with: prober, limiter: limiter) }
                active += 1
            }
        }

        await progress.endPass()
    }

    /// Resolve + probe one item and cache the result. Best-effort: a bad/offline
    /// location is logged and left for a future pass. Like the manual probe, this does
    /// not bump `updatedAt` (it adds cached detail, not a content change).
    private func probe(_ item: ItemRecord, with prober: FFprobeProber, limiter: RateLimiter) async {
        guard !Task.isCancelled else { return }
        // Wait for a rate-limit slot before the resolve (a source request). Outside the
        // per-item timeout, so queue time isn't charged against the probe budget.
        await limiter.acquire()
        guard !Task.isCancelled else { return }
        do {
            // Bound the whole item (resolve + ffprobe). On timeout the operation task
            // is cancelled (resolve back-off is cancellable; the ffprobe watchdog kills
            // the process), so the worker slot is always freed.
            try await withTimeout(perItemTimeout) {
                let descriptor = try await resolver.resolve(itemId: item.id)
                let result = try await prober.probe(url: descriptor.url, headers: descriptor.headers, itemId: item.id)
                var updated = item
                let stored = StoredProbe(
                    streams: result.streams, externalSubtitles: result.externalSubtitles,
                    chapters: result.chapters, probedAt: Date().timeIntervalSince1970)
                if let data = try? JSONEncoder().encode(stored) {
                    updated.probedTracksJSON = String(data: data, encoding: .utf8)
                    try await catalog.updateItem(updated)
                }
            }
            await cooldown.clearFailure(item.id)
        } catch is ProbeTimedOut {
            // Visible (not .debug): a slow/offline source is the usual reason a pass
            // doesn't reach 100%, so surface it rather than hide it.
            await cooldown.recordFailure(item.id, now: Date().timeIntervalSince1970)
            logger.info("Media-probe backfill: \(item.id) timed out after \(Int(perItemTimeout))s — cooling down for \(Int(failureCooldown / 3600))h")
        } catch {
            await cooldown.recordFailure(item.id, now: Date().timeIntervalSince1970)
            logger.info("Media-probe backfill: \(item.id) skipped: \(error) — cooling down for \(Int(failureCooldown / 3600))h")
        }
        await progress.advance()
    }
}

/// In-memory per-item failure cooldown for the media-probe backfill. An item that
/// fails to resolve/probe is parked here so subsequent passes skip it until the window
/// elapses — stopping a short interval from re-resolving a doomed item every pass (which
/// floods the provider and starves probeable items). Cleared on a later success.
actor ProbeCooldown {
    private var failedAt: [String: Double] = [:]

    /// True while `id` is within `window` seconds of its last failure. Expired entries
    /// are pruned on read so the map doesn't grow once a source recovers.
    func shouldSkip(_ id: String, now: Double, window: Double) -> Bool {
        guard let at = failedAt[id] else { return false }
        if now - at >= window { failedAt[id] = nil; return false }
        return true
    }

    func recordFailure(_ id: String, now: Double) { failedAt[id] = now }
    func clearFailure(_ id: String) { failedAt[id] = nil }
}

/// Raised when an operation overruns its deadline in `withTimeout`.
private struct ProbeTimedOut: Error {}

/// Run `operation`, throwing `ProbeTimedOut` (and cancelling it) if it doesn't finish
/// within `seconds`. The loser of the race is cancelled, so a cancellation-aware
/// operation stops promptly.
private func withTimeout(_ seconds: Double, _ operation: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw ProbeTimedOut()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

/// A spacing rate limiter shared across the probe workers: each `acquire()` reserves
/// the next slot `60 / perMinute` seconds after the previous one and sleeps until then,
/// so concurrent callers are paced to at most `perMinute` grants a minute. `perMinute
/// <= 0` ⇒ unlimited (a no-op).
actor RateLimiter {
    private let interval: Double
    private var nextAt: Double = 0

    init(perMinute: Double) {
        interval = perMinute > 0 ? 60.0 / perMinute : 0
    }

    func acquire() async {
        guard interval > 0 else { return }
        let now = Date().timeIntervalSince1970
        let scheduled = max(now, nextAt)
        nextAt = scheduled + interval
        let wait = scheduled - now
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
}
