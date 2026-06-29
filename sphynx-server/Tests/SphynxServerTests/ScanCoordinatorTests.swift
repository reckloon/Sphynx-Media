import Testing
@testable import SphynxServer

/// The per-source scan lock that prevents overlapping scans of one source from each
/// snapshotting the pre-scan item set and re-inserting every key (which created
/// duplicate items).
@Suite("Scan coordinator")
struct ScanCoordinatorTests {
    @Test("admits one scan per source, rejects a concurrent one, frees on end")
    func serializesPerSource() async {
        let c = ScanCoordinator()
        #expect(await c.begin("src-a") == true)    // first scan reserves it
        #expect(await c.begin("src-a") == false)   // a concurrent scan is rejected
        #expect(await c.begin("src-b") == true)    // a different source is independent
        await c.end("src-a")
        #expect(await c.begin("src-a") == true)    // freed after the scan ends
    }
}
