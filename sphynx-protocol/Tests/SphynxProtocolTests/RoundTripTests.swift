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

    @Test("ErrorEnvelope round-trips with a retryAfter hint")
    func errorEnvelopeWithRetryAfter() throws {
        try assertRoundTrips(ErrorEnvelope(code: .rateLimited, message: "Slow down.", retryable: true, retryAfter: 30))
    }

    @Test("retryAfter encodes when set and is omitted when nil")
    func retryAfterEncodingPresence() throws {
        let encoder = JSONEncoder()

        // Present when set.
        let withHint = ErrorEnvelope(code: .unavailable, message: "Down.", retryable: true, retryAfter: 12.5)
        let withJSON = String(data: try encoder.encode(withHint), encoding: .utf8)!
        #expect(withJSON.contains("\"retryAfter\""))
        let withDecoded = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(withJSON.utf8))
        #expect(withDecoded.error.retryAfter == 12.5)

        // Absent on the wire when nil.
        let withoutHint = ErrorEnvelope(code: .notFound, message: "Gone.", retryable: false)
        let withoutJSON = String(data: try encoder.encode(withoutHint), encoding: .utf8)!
        #expect(!withoutJSON.contains("retryAfter"))
        let withoutDecoded = try JSONDecoder().decode(ErrorEnvelope.self, from: Data(withoutJSON.utf8))
        #expect(withoutDecoded.error.retryAfter == nil)
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
