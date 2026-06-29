import Foundation
import Testing
@testable import SphynxProtocol

@Suite("Tracks: described streams + external subtitles")
struct TracksStreamsTests {
    @Test("a resolve descriptor round-trips streams + external subtitles")
    func roundTrip() throws {
        let tracks = Tracks(
            preferredAudio: 1,
            preferredSubtitle: 3,
            streams: [
                MediaStream(index: 1, kind: "audio", codec: "eac3", language: "eng",
                            title: "Surround 5.1", channels: 6, isDefault: true, isForced: false),
                MediaStream(index: 3, kind: "subtitle", codec: "subrip", language: "spa", isForced: true),
            ],
            externalSubtitles: [ExternalSubtitle(url: "file:///m/Movie.en.srt", language: "en", format: "srt")]
        )
        let descriptor = ResolveDescriptor(url: "https://cdn/x.mkv", tracks: tracks)

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ResolveDescriptor.self, from: data)
        #expect(decoded == descriptor)
        #expect(decoded.tracks?.streams?.count == 2)
        #expect(decoded.tracks?.streams?.first?.language == "eng")
        #expect(decoded.tracks?.streams?.first?.channels == 6)
        #expect(decoded.tracks?.externalSubtitles?.first?.language == "en")
        #expect(decoded.tracks?.preferredAudio == 1)
    }

    @Test("a probe-less descriptor omits streams (back-compatible)")
    func omittedWhenAbsent() throws {
        let descriptor = ResolveDescriptor(url: "https://cdn/x.mkv", tracks: Tracks(preferredAudio: 0))
        let json = String(data: try JSONEncoder().encode(descriptor), encoding: .utf8) ?? ""
        #expect(!json.contains("streams"))
        #expect(!json.contains("externalSubtitles"))
    }

    @Test("unknown stream fields decode without throwing (forward-compatible)")
    func forwardCompatible() throws {
        let json = Data("""
        { "url": "https://cdn/x.mkv", "headers": {}, "tracks": { "streams": [
            { "index": 1, "kind": "audio", "language": "eng", "bitRate": 640000, "newField": "ok" }
        ] } }
        """.utf8)
        let decoded = try JSONDecoder().decode(ResolveDescriptor.self, from: json)
        #expect(decoded.tracks?.streams?.first?.index == 1)
        #expect(decoded.tracks?.streams?.first?.language == "eng")
    }
}
