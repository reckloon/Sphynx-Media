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
    let defaultInterval: Double
    let catalog: Catalog
    let resolver: Resolver
    let settings: SettingsStore
    let progress: BackfillProgress
    let schedule: ScheduleCenter
    let logger: Logger
    /// Concurrent probes ⇒ concurrent `ffprobe` processes / resolves. Small on purpose.
    var maxConcurrentItems = 2

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
        // sourceKey. Probe each item at most once (until its tracks are cached).
        let work = items.filter { !$0.sourceKey.isEmpty && $0.probedTracksJSON == nil }
        guard !work.isEmpty else { return }

        await progress.beginPass(total: work.count)
        logger.info("Media-probe backfill: probing \(work.count) item(s)")

        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            var active = 0
            for _ in 0 ..< maxConcurrentItems where !Task.isCancelled {
                guard let next = iterator.next() else { break }
                group.addTask { await self.probe(next, with: prober) }
                active += 1
            }
            while active > 0 {
                _ = await group.next()
                active -= 1
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { await self.probe(next, with: prober) }
                active += 1
            }
        }

        await progress.endPass()
    }

    /// Resolve + probe one item and cache the result. Best-effort: a bad/offline
    /// location is logged and left for a future pass. Like the manual probe, this does
    /// not bump `updatedAt` (it adds cached detail, not a content change).
    private func probe(_ item: ItemRecord, with prober: FFprobeProber) async {
        guard !Task.isCancelled else { return }
        do {
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
        } catch {
            logger.debug("Media-probe backfill: \(item.id) skipped: \(error)")
        }
        await progress.advance()
    }
}
