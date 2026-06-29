import Foundation
import Logging
import ServiceLifecycle

/// Re-scans each source on **its own** `refreshInterval`. Ticks on a fixed
/// cadence (the granularity of "due"); each tick scans the sources whose interval
/// has elapsed since their last scan. Sources with `refreshInterval == 0` are
/// manual-only and never auto-scanned.
struct SourceRefreshService: Service {
    /// How often to check for due sources (seconds). The effective per-source
    /// resolution — a 5-minute source scans within one tick of becoming due.
    let tick: Double
    let catalog: Catalog
    let indexer: Indexer
    let schedule: ScheduleCenter
    let logger: Logger

    func run() async throws {
        logger.info("Per-source auto-refresh checking every \(Int(tick))s")
        await publishNextRun()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(tick)) } catch { break }  // cancelled on shutdown
            await runOnce()
            await publishNextRun()
        }
    }

    /// One sweep: scan every source that's due. Also callable directly in tests.
    func runOnce(now: Double = Date().timeIntervalSince1970) async {
        guard !Task.isCancelled else { return }
        let due: [SourceRecord]
        do { due = try await catalog.dueSources(now: now) } catch {
            logger.warning("Auto-refresh: could not list due sources: \(error)"); return
        }
        if !due.isEmpty { await schedule.started(ScheduledTask.index.name, label: ScheduledTask.index.label) }
        for source in due {
            guard !Task.isCancelled else { return }
            do {
                let summary = try await indexer.scan(sourceId: source.id)
                logger.info("Auto-refresh scanned '\(source.label)': scanned \(summary.scanned), +\(summary.added) -\(summary.removed)")
            } catch {
                logger.warning("Auto-refresh scan of '\(source.label)' failed: \(error)")
            }
            // Stamp the scan time either way, so a persistently-broken source
            // retries after its interval, not every tick.
            try? await catalog.markSourceScanned(id: source.id)
        }
        if !due.isEmpty { await schedule.finished(ScheduledTask.index.name) }
    }

    /// Publish the soonest upcoming source scan to the schedule indicator. Index has
    /// no single interval (each source has its own), so we report the next due time
    /// across all auto-refresh sources; `nil` when none auto-refresh.
    private func publishNextRun(now: Double = Date().timeIntervalSince1970) async {
        let next: Double?
        do {
            next = try await catalog.sources()
                .filter { $0.refreshInterval > 0 }
                .map { ($0.lastScannedAt ?? 0) + $0.refreshInterval }
                .min()
        } catch {
            next = nil
        }
        // Clamp to "now" so an overdue source reads as "due now" rather than negative.
        await schedule.nextRun(ScheduledTask.index.name, label: ScheduledTask.index.label,
                               at: next.map { max($0, now) })
    }
}
