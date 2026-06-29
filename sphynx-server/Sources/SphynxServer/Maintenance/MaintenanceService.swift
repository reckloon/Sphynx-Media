import Foundation
import Logging
import ServiceLifecycle

/// Periodic background maintenance: re-fetch **stale server-owned** enrichment
/// (posters, overview, … — TTL-gated inside `enrichAll`) and purge expired
/// playstate (retention).
///
/// Client-owned data (intro/credit markers) is deliberately **not** touched here:
/// only a client can fetch it (e.g. from TheIntroDB), so the server merely
/// reports it `stale` and the client refreshes + contributes it back. This keeps
/// server refresh from ever clobbering client contributions.
struct MaintenanceService: Service, ScheduledBackfill {
    /// Default cadence when `maintenanceInterval` is unset (seconds).
    let defaultInterval: Double
    let enrichment: EnrichmentService?
    let playstate: PlaystateService
    let playstateRetention: Double
    let settings: SettingsStore
    let schedule: ScheduleCenter
    let logger: Logger

    var task: (name: String, label: String) { ScheduledTask.enrich }
    /// The maintenance interval is read live, so a Settings-tab change to "Run
    /// background cleanup every" takes effect without a restart.
    var intervalKey: String { SettingKey.maintenanceInterval.rawValue }

    func run() async throws {
        logger.info("Maintenance pass registered")
        await runSchedule()
    }

    /// One maintenance pass (also callable directly in tests).
    ///
    /// Checks for cancellation before each database step, so a shutdown that
    /// arrives mid-pass stops cleanly instead of issuing work against a database
    /// that's being torn down.
    func runOnce() async {
        guard !Task.isCancelled else { return }
        if let enrichment {
            do {
                let count = try await enrichment.enrichAll(force: false)  // TTL-gated
                if count > 0 { logger.info("Maintenance: re-enriched \(count) stale item(s)") }
            } catch {
                logger.warning("Maintenance enrichment failed: \(error)")
            }
        }

        guard !Task.isCancelled else { return }
        do {
            let cutoff = Date().timeIntervalSince1970 - playstateRetention
            let purged = try await playstate.purge(before: cutoff)
            if purged > 0 { logger.info("Maintenance: purged \(purged) expired playstate row(s)") }
        } catch {
            logger.warning("Maintenance playstate purge failed: \(error)")
        }
    }
}
