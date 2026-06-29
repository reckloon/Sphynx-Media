import Foundation
import Logging

/// Shared scheduling behaviour for the extension backfills (BlurHash generation,
/// media probe). A conformer supplies its work (`runOnce`), its task identity, and
/// the settings key holding its interval; this drives the background loop, reads the
/// interval **live** each cycle, and keeps the `ScheduleCenter` up to date so the
/// Activity panel can show "Next runs". `runTracked` is the single entry point used
/// by both the loop and the Extensions tab's "Run now", so a manual run also shows as
/// running in the schedule indicator.
protocol ScheduledBackfill: Sendable {
    /// Cadence (seconds) used when the interval setting is unset.
    var defaultInterval: Double { get }
    var settings: SettingsStore { get }
    var schedule: ScheduleCenter { get }
    var logger: Logger { get }
    /// Stable name + display label for the schedule indicator.
    var task: (name: String, label: String) { get }
    /// Settings key holding the interval (seconds, fractional allowed; `<= 0` ⇒
    /// manual-only).
    var intervalKey: String { get }

    /// One pass. Should be a no-op when the extension is disabled / not applicable.
    func runOnce() async
}

extension ScheduledBackfill {
    /// How often the idle (manual-only) loop re-checks settings for a newly-set
    /// interval, so enabling a schedule takes effect without a restart.
    var idlePollTick: Double { 30 }

    /// Current interval in seconds: the live setting, else `defaultInterval`. A value
    /// `<= 0` means manual-only.
    func currentInterval() async -> Double {
        await settings.interval(forKey: intervalKey) ?? defaultInterval
    }

    /// Run one pass with schedule "running" bookkeeping — used by both the loop and
    /// the manual "Run now".
    func runTracked() async {
        await schedule.started(task.name, label: task.label)
        await runOnce()
        await schedule.finished(task.name)
    }

    /// The background loop: read the interval live, run (immediately on start when
    /// auto-scheduled), register the next run, sleep, repeat. When the interval is
    /// `<= 0` the task is manual-only — it idles, polling for a later interval change.
    func runSchedule() async {
        while !Task.isCancelled {
            let interval = await currentInterval()
            if interval <= 0 {
                await schedule.manualOnly(task.name, label: task.label)
                do { try await Task.sleep(for: .seconds(idlePollTick)) } catch { break }
                continue
            }
            await runTracked()
            guard !Task.isCancelled else { break }
            await schedule.scheduled(
                task.name, label: task.label, interval: interval,
                nextRunAt: Date().timeIntervalSince1970 + interval)
            do { try await Task.sleep(for: .seconds(interval)) } catch { break }
        }
    }
}
