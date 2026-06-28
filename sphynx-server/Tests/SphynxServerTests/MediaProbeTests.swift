import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Extensions: media probe")
struct MediaProbeTests {
    /// A realistic `ffprobe -print_format json -show_streams -show_format` payload:
    /// a video track, two audio tracks (one default 5.1, one stereo commentary),
    /// and a forced Spanish subtitle.
    private var sampleJSON: Data {
        Data("""
        {
          "streams": [
            { "index": 0, "codec_name": "h264", "codec_type": "video", "disposition": { "default": 1, "forced": 0 } },
            { "index": 1, "codec_name": "eac3", "codec_type": "audio", "channels": 6,
              "tags": { "language": "eng", "title": "Surround 5.1" }, "disposition": { "default": 1, "forced": 0 } },
            { "index": 2, "codec_name": "aac", "codec_type": "audio", "channels": 2,
              "tags": { "language": "eng", "title": "Commentary" }, "disposition": { "default": 0, "forced": 0 } },
            { "index": 3, "codec_name": "subrip", "codec_type": "subtitle",
              "tags": { "language": "spa" }, "disposition": { "default": 0, "forced": 1 } }
          ],
          "format": { "format_name": "matroska,webm", "duration": "1234.567" }
        }
        """.utf8)
    }

    @Test("parses streams: language, codec, channels, default/forced, duration")
    func parsesFFprobeJSON() throws {
        let result = try FFprobeParser.parse(sampleJSON, itemId: "it_x",
                                             probedURL: "file:///media/Movie.mkv", prober: "ffprobe 6.1")
        #expect(result.streams.count == 4)
        #expect(result.formatName == "matroska,webm")
        #expect(result.durationSeconds == 1234.567)
        #expect(result.prober == "ffprobe 6.1")

        let video = try #require(result.streams.first { $0.kind == "video" })
        #expect(video.codec == "h264")

        let audio = result.streams.filter { $0.kind == "audio" }
        #expect(audio.count == 2)
        let surround = try #require(audio.first { $0.title == "Surround 5.1" })
        #expect(surround.language == "eng")
        #expect(surround.codec == "eac3")
        #expect(surround.channels == 6)
        #expect(surround.isDefault == true)
        #expect(surround.isForced == false)

        let sub = try #require(result.streams.first { $0.kind == "subtitle" })
        #expect(sub.language == "spa")
        #expect(sub.codec == "subrip")
        #expect(sub.isForced == true)
        #expect(sub.isDefault == false)
    }

    @Test("empty / fieldless ffprobe output decodes without throwing")
    func parsesSparseJSON() throws {
        let result = try FFprobeParser.parse(Data("{}".utf8), itemId: "it_y",
                                             probedURL: "x", prober: "ffprobe")
        #expect(result.streams.isEmpty)
        #expect(result.durationSeconds == nil)
    }

    @Test("sidecar subtitles next to a local file are discovered, language guessed")
    func findsSidecarSubtitles() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sphynx-sub-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for name in ["Movie.mkv", "Movie.en.srt", "Movie.es.srt", "Movie.ass", "Unrelated.srt"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }

        let subs = FFprobeProber.sidecarSubtitles(for: "file://\(dir.path)/Movie.mkv")
        // The three that share the "Movie" stem; "Unrelated.srt" excluded.
        #expect(subs.count == 3)
        #expect(subs.contains { $0.language == "en" && $0.format == "srt" })
        #expect(subs.contains { $0.language == "es" && $0.format == "srt" })
        #expect(subs.contains { $0.language == nil && $0.format == "ass" })   // "Movie.ass" → no language suffix
        #expect(!subs.contains { $0.url.contains("Unrelated") })
    }

    @Test("registry lists diagnostics (on) and media-probe (off by default)")
    func registryListsExtensions() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            let response: ExtensionsResponse = try await client.execute(
                uri: "/v1/admin/extensions", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            let diagnostics = try #require(response.extensions.first { $0.id == "diagnostics" })
            #expect(diagnostics.kind == "builtin")
            #expect(diagnostics.enabled)
            let probe = try #require(response.extensions.first { $0.id == "media-probe" })
            #expect(probe.kind == "optional")
            #expect(probe.configurable)
            #expect(!probe.enabled)   // opt-in: disabled until turned on
        }
    }

    @Test("config PATCH persists enabled + ffprobe path; GET reflects it")
    func updatesProbeConfig() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            let updated: MediaProbeConfig = try await client.execute(
                uri: "/v1/admin/extensions/media-probe", method: .patch, headers: jsonHeaders(bearer: token),
                body: try jsonBody(MediaProbeConfigUpdate(enabled: true, ffprobePath: "/custom/ffprobe"))
            ) { try $0.decoded() }
            #expect(updated.enabled)
            #expect(updated.ffprobePath == "/custom/ffprobe")

            let reread: MediaProbeConfig = try await client.execute(
                uri: "/v1/admin/extensions/media-probe", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(reread.enabled)
            #expect(reread.ffprobePath == "/custom/ffprobe")
        }
    }

    @Test("probe is rejected with 400 while the extension is disabled")
    func probeRejectedWhenDisabled() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token = try await adminToken(client)
            try await client.execute(
                uri: "/v1/admin/extensions/media-probe/probe?itemId=it_anything",
                method: .get, headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("extensions surface requires authentication")
    func requiresAuth() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/admin/extensions", method: .get) {
                #expect($0.status == .unauthorized)
            }
        }
    }

    private func adminToken(_ client: some TestClientProtocol) async throws -> String {
        try await client.execute(
            uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }
}
