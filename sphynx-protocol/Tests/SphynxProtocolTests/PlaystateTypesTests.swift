import Foundation
import Testing
@testable import SphynxProtocol

private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(T.self, from: data) == value)
}

@Suite("Playstate types")
struct PlaystateTypesTests {
    @Test("request bodies round-trip")
    func bodies() throws {
        try assertRoundTrips(PlaystateStartBody(position: 12.5))
        try assertRoundTrips(PlaystateProgressBody(position: 1342.5, paused: true))
        try assertRoundTrips(PlaystateStopBody(position: 0, failed: true))
    }

    @Test("responses round-trip")
    func responses() throws {
        let single = PlaystateResponse(position: 1342.5, updatedAt: "2026-06-27T12:00:00Z")
        try assertRoundTrips(single)
        try assertRoundTrips(PlaystateBatchResponse(states: ["it_1": single]))
    }
}
