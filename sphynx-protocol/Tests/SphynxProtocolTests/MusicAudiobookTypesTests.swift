import Foundation
import Testing
@testable import SphynxProtocol

/// The protocol models music + audiobooks (and lossless audio) even though the
/// reference server doesn't produce them. These pin the wire shapes another server
/// would target.
@Suite("Music / audiobooks protocol support")
struct MusicAudiobookTypesTests {
    @Test("new item types and library kinds round-trip by rawValue")
    func enums() {
        for raw in ["artist", "album", "track", "audiobook", "chapter"] {
            #expect(ItemType(rawValue: raw)?.rawValue == raw)
        }
        for raw in ["music", "audiobooks"] {
            #expect(LibraryKind(rawValue: raw)?.rawValue == raw)
        }
        // Still open: an unknown value decodes, never throws.
        #expect(ItemType(rawValue: "podcast") == nil)           // not canonical…
        let decoded = try? JSONDecoder().decode(ItemType.self, from: Data("\"podcast\"".utf8))
        #expect(decoded == .unknown("podcast"))                 // …but rides as .unknown on the wire
    }

    @Test("a track item carries ordering + denormalized album/artist")
    func trackItem() throws {
        let track = Item(
            id: "it_1", type: .track, title: "Black Dog",
            artistName: "Led Zeppelin", albumTitle: "Led Zeppelin IV",
            discNumber: 1, trackNumber: 1, parentId: "it_album")
        let decoded = try JSONDecoder().decode(Item.self, from: try JSONEncoder().encode(track))
        #expect(decoded.type == .track)
        #expect(decoded.artistName == "Led Zeppelin")
        #expect(decoded.albumTitle == "Led Zeppelin IV")
        #expect(decoded.trackNumber == 1)
        #expect(decoded.discNumber == 1)
    }

    @Test("a lossless audio stream is expressible: codec + sampleRate + bitDepth")
    func losslessStream() throws {
        let stream = MediaStream(
            index: 0, kind: "audio", codec: "flac", channels: 2,
            sampleRate: 96000, bitDepth: 24, bitRate: 4_600_000)
        let descriptor = ResolveDescriptor(url: "https://cdn/track.flac", tracks: Tracks(preferredAudio: 0, streams: [stream]))
        let decoded = try JSONDecoder().decode(ResolveDescriptor.self, from: try JSONEncoder().encode(descriptor))
        let s = try #require(decoded.tracks?.streams?.first)
        #expect(s.codec == "flac")
        #expect(s.sampleRate == 96000)
        #expect(s.bitDepth == 24)        // hi-res lossless: a client can show "FLAC 24/96"
        #expect(s.bitRate == 4_600_000)
    }

    @Test("audio detail fields are omitted from the wire when absent (back-compatible)")
    func omittedWhenAbsent() throws {
        let stream = MediaStream(index: 0, kind: "audio", codec: "aac", channels: 2)
        let json = String(data: try JSONEncoder().encode(stream), encoding: .utf8) ?? ""
        #expect(!json.contains("sampleRate"))
        #expect(!json.contains("bitDepth"))
    }
}
