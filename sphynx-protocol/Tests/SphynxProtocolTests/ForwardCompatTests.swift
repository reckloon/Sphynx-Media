import Foundation
import Testing
@testable import SphynxProtocol

/// The forward-compatibility guarantee from the protocol doc:
/// "Unknown fields are ignored; new optional fields and new enum-like string
///  values may appear at any time. Clients must not break on values they don't
///  recognize."
///
/// These tests feed deliberately "future" JSON to today's decoders and assert
/// nothing throws — and that recognised data still lands where it should.
@Suite("Forward compatibility")
struct ForwardCompatTests {

    @Test("Decoding ignores unknown top-level and nested fields")
    func ignoresUnknownFields() throws {
        let json = """
        {
          "product": "Sphynx",
          "serverName": "Future Library",
          "id": "srv_future",
          "version": "9.9",
          "protocol": ["v1", "v2"],
          "capabilities": {
            "search": true,
            "playstate": true,
            "candidates": true,
            "teleportation": true,
            "metadata": { "markers": "readwrite", "images": "read", "futureField": "appendOnly" }
          },
          "somethingBrandNew": { "nested": [1, 2, 3] },
          "anUnexpectedArray": ["a", "b"]
        }
        """.data(using: .utf8)!

        let info = try JSONDecoder().decode(ServerInfo.self, from: json)
        #expect(info.serverName == "Future Library")
        #expect(info.protocols == ["v1", "v2"])
        #expect(info.capabilities.search == true)
        #expect(info.capabilities.candidates == true)
        // The unknown "teleportation" capability is simply dropped, not fatal.
        // The access map decodes, including an unknown access level → .unknown.
        #expect(info.capabilities.access("markers") == .readWrite)
        #expect(info.capabilities.access("images") == .read)
        #expect(info.capabilities.access("futureField") == .unknown("appendOnly"))
        #expect(info.capabilities.access("nope") == .none)  // unlisted ⇒ none
    }

    @Test("Missing capability keys decode to false")
    func missingCapabilitiesDefaultFalse() throws {
        let json = """
        { "search": true }
        """.data(using: .utf8)!

        let caps = try JSONDecoder().decode(Capabilities.self, from: json)
        #expect(caps.search == true)
        #expect(caps.playstate == false)
        #expect(caps.candidates == false)
        // A server that predates the event stream omits the key ⇒ client polls.
        #expect(caps.events == false)
        #expect(caps.metadata.isEmpty)
    }

    @Test("The fields coverage list round-trips; absent ⇒ supportsField is permissive")
    func fieldsCapability() throws {
        // Advertised coverage: a listed field is supported, an omitted one is not.
        let caps = Capabilities(fields: ["title", "overview", "cast"])
        let decoded = try JSONDecoder().decode(Capabilities.self, from: JSONEncoder().encode(caps))
        #expect(decoded.fields == ["title", "overview", "cast"])
        #expect(decoded.supportsField("overview"))
        #expect(!decoded.supportsField("trailers"))   // advertised list omits it ⇒ unsupported

        // No coverage advertised ⇒ unknown, so supportsField is permissive (assume it might).
        let none = try JSONDecoder().decode(Capabilities.self, from: #"{ "playstate": true }"#.data(using: .utf8)!)
        #expect(none.fields.isEmpty)
        #expect(none.supportsField("trailers"))
    }

    @Test("The events capability round-trips and is read when advertised")
    func eventsCapabilityRoundTrips() throws {
        let caps = Capabilities(playstate: true, events: true)
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(Capabilities.self, from: data)
        #expect(decoded.events == true)
        #expect(decoded.playstate == true)

        // And it decodes from a raw server payload.
        let json = #"{ "playstate": true, "events": true }"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(Capabilities.self, from: json).events == true)
    }

    @Test("Unknown enum string values decode without throwing")
    func unknownEnumValues() throws {
        // An ItemType the server invented after this client shipped.
        let itemJSON = "\"interactive_experience\"".data(using: .utf8)!
        let itemType = try JSONDecoder().decode(ItemType.self, from: itemJSON)
        #expect(itemType == .unknown("interactive_experience"))

        // An error code we don't know about must still be readable.
        let errJSON = """
        { "error": { "code": "quota_exceeded", "message": "Slow down.", "retryable": true } }
        """.data(using: .utf8)!
        let envelope = try JSONDecoder().decode(ErrorEnvelope.self, from: errJSON)
        #expect(envelope.error.code == .unknown("quota_exceeded"))
        #expect(envelope.error.retryable == true)
    }

    @Test("Known enum values still decode to their cases")
    func knownEnumValues() throws {
        #expect(try JSONDecoder().decode(ItemType.self, from: "\"movie\"".data(using: .utf8)!) == .movie)
        #expect(try JSONDecoder().decode(LibraryKind.self, from: "\"movies\"".data(using: .utf8)!) == .movies)
        #expect(try JSONDecoder().decode(ErrorCode.self, from: "\"not_found\"".data(using: .utf8)!) == .notFound)
    }
}
