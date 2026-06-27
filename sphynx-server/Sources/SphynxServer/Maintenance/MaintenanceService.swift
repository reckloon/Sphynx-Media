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
struct MaintenanceService: Service {
    let interval: Double
    let enrichment: EnrichmentService?
    let playstate: PlaystateService
    let playstateRetention: Double
    let logger: Logger

    func run() async throws {
        logger.info("Maintenance pass scheduled every \(Int(interval))s")
        while true {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break  // cancelled on graceful shutdown
            }
            await runOnce()
        }
    }

    /// One maintenance pass (also callable directly in tests).
    func runOnce() async {
        if let enrichment {
            do {
                let count = try await enrichment.enrichAll(force: false)  // TTL-gated
                if count > 0 { logger.info("Maintenance: re-enriched \(count) stale item(s)") }
            } catch {
                logger.warning("Maintenance enrichment failed: \(error)")
            }
        }
        do {
            let cutoff = Date().timeIntervalSince1970 - playstateRetention
            let purged = try await playstate.purge(before: cutoff)
            if purged > 0 { logger.info("Maintenance: purged \(purged) expired playstate row(s)") }
        } catch {
            logger.warning("Maintenance playstate purge failed: \(error)")
        }
    }
}
