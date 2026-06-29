import Foundation
import Testing
@testable import SphynxProtocol

/// Proves the protocol's open-metadata guarantee: a server (or extension) can
/// serve whatever metadata it wants, and a client reads what it understands and
/// ignores the rest — every canonical field being neutral and optional.
@Suite("Extensibility / open metadata")
struct ExtensibilityTests {

    @Test("JSONValue round-trips every shape, preserving int vs double")
    func jsonValueRoundTrips() throws {
        let value = JSONValue.object([
            "tagline": .string("In space no one can hear you scream."),
            "imdbRating": .double(8.5),
            "ratingCount": .int(1_200_000),
            "is4K": .bool(true),
            "missing": .null,
            "altTitles": .array([.string("Alien"), .string("Alien: 40th Anniversary")]),
            "nested": .object(["studio": .string("Brandywine")]),
        ])
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == value)
        // Integers must not drift into doubles.
        if case .object(let o) = decoded { #expect(o["ratingCount"] == .int(1_200_000)) }
    }

    @Test("Item.extra round-trips arbitrary server metadata")
    func itemExtraRoundTrips() throws {
        let item = Item(
            id: "it_1", type: .movie, title: "Alien",
            extra: ["tagline": .string("In space…"), "imdbId": .string("tt0078748"), "trailerCount": .int(3)]
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(Item.self, from: data)
        #expect(decoded == item)
        #expect(decoded.extra?["imdbId"] == .string("tt0078748"))
    }

    @Test("extra is omitted from the wire when empty")
    func extraOmittedWhenNil() throws {
        let json = String(data: try JSONEncoder().encode(Item(id: "x", type: .movie, title: "Y")), encoding: .utf8)!
        #expect(!json.contains("extra"))
    }

    @Test("a server's custom fields are consumable via extra; unknown top-level keys are ignored")
    func serverDefinedMetadata() throws {
        // A response from some future/third-party server: canonical fields, an
        // `extra` bag of server-defined metadata, AND an unrecognised top-level
        // field + an unknown enum value. None of it should break decoding.
        let json = """
        {
          "id": "it_42",
          "type": "experience",
          "title": "Some Future Format",
          "overview": "…",
          "extra": {
            "spatialAudio": true,
            "hdrFormat": "Dolby Vision",
            "chapters": [ { "start": 0.0, "title": "Intro" } ]
          },
          "aBrandNewTopLevelField": { "whatever": [1, 2, 3] }
        }
        """.data(using: .utf8)!

        let item = try JSONDecoder().decode(Item.self, from: json)
        // Unknown enum value tolerated.
        #expect(item.type == .unknown("experience"))
        // Canonical fields read normally.
        #expect(item.title == "Some Future Format")
        #expect(item.overview == "…")
        // Server-defined metadata is available to clients that understand it.
        #expect(item.extra?["spatialAudio"] == .bool(true))
        #expect(item.extra?["hdrFormat"] == .string("Dolby Vision"))
        // The unknown top-level field was ignored (didn't throw, isn't surfaced).
    }
}
