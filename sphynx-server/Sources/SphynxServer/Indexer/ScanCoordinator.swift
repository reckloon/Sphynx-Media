/// Serializes scans **per source**: at most one scan of a given source runs at a
/// time. Concurrent scans of the same source each snapshot the pre-scan item set
/// (`existingByKey`) and both insert, creating duplicate items — so a second scan
/// (a manual "Scan"/"Refresh"/"Scan all", or an auto-refresh tick firing before a
/// slow scan finishes) is rejected while one is in flight. A process-wide actor so
/// every `Indexer` value shares the same in-flight set.
actor ScanCoordinator {
    static let shared = ScanCoordinator()

    private var inFlight: Set<String> = []

    /// Reserve `sourceId` for scanning; returns `false` if a scan is already running
    /// for it (the caller should skip rather than start a duplicate scan).
    func begin(_ sourceId: String) -> Bool { inFlight.insert(sourceId).inserted }

    /// Release the reservation when the scan finishes (success or failure).
    func end(_ sourceId: String) { inFlight.remove(sourceId) }
}
