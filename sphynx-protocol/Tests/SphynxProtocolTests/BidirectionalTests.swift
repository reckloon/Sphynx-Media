import Foundation
import Testing
@testable import SphynxProtocol

private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(T.self, from: data) == value)
}

@Suite("Bi-directional metadata")
struct BidirectionalTests {
    @Test("MetadataAccess round-trips, unknown levels tolerated")
    func access() throws {
        try assertRoundTrips(MetadataAccess.none)
        try assertRoundTrips(MetadataAccess.read)
        try assertRoundTrips(MetadataAccess.readWrite)
        try assertRoundTrips(MetadataAccess.unknown("appendOnly"))
        #expect(MetadataAccess.readWrite.allowsWrite)
        #expect(!MetadataAccess.read.allowsWrite)
        #expect(MetadataAccess.read.allowsRead)
        #expect(!MetadataAccess.none.allowsRead)
    }

    @Test("marker contribution + info round-trip")
    func markers() throws {
        let contribution = MarkerContribution(
            markers: Markers(intro: Marker(start: 75, end: 145), credits: Marker(start: 9120)),
            source: "theintrodb", confidence: 0.95
        )
        try assertRoundTrips(contribution)

        let info = MarkersInfo(
            markers: Markers(intro: Marker(start: 75, end: 145)),
            source: "intro-detector", confidence: 0.8, authoritative: true,
            updatedAt: "2026-06-27T12:00:00Z"
        )
        try assertRoundTrips(info)
    }

    @Test("capabilities access() resolves per field with .none default")
    func capabilitiesAccess() throws {
        let caps = Capabilities(playstate: true, metadata: ["markers": .readWrite, "images": .read])
        #expect(caps.access("markers") == .readWrite)
        #expect(caps.access("images") == .read)
        #expect(caps.access("overview") == .none)
    }
}
