import Foundation
import Testing
@testable import SphynxProtocol

/// Re-encodes a value to JSON and decodes it back, asserting it survives the
/// trip unchanged. This is the core guardrail: every wire type must round-trip.
private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value, "\(T.self) did not survive a JSON round-trip")
}

@Suite("Round-trip")
struct RoundTripTests {
    @Test("ServerInfo round-trips")
    func serverInfo() throws {
        let info = ServerInfo(
            serverName: "Mike's Library",
            id: "srv_abc123",
            version: "1.0",
            protocols: ["v1"],
            capabilities: Capabilities(
                search: true,
                playstate: true,
                candidates: false,
                metadata: ["markers": .readWrite, "images": .read]
            )
        )
        try assertRoundTrips(info)
    }

    @Test("Capabilities round-trips")
    func capabilities() throws {
        try assertRoundTrips(Capabilities(search: true, playstate: false, candidates: true, metadata: ["markers": .readWrite]))
    }

    @Test("ErrorEnvelope round-trips")
    func errorEnvelope() throws {
        try assertRoundTrips(ErrorEnvelope(code: .unauthorized, message: "Token expired.", retryable: false))
    }

    @Test("Open enums round-trip their known cases")
    func openEnumsKnown() throws {
        try assertRoundTrips(ItemType.movie)
        try assertRoundTrips(LibraryKind.tvShows)
        try assertRoundTrips(ErrorCode.noMediaSource)
    }

    @Test("Open enums round-trip unknown values verbatim")
    func openEnumsUnknown() throws {
        try assertRoundTrips(ItemType.unknown("hologram"))
        try assertRoundTrips(LibraryKind.unknown("podcasts"))
        try assertRoundTrips(ErrorCode.unknown("teapot"))
    }
}
