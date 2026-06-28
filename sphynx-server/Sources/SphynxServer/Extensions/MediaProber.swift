import Foundation
import Hummingbird

/// One stream inside a media container, as reported by `ffprobe`. This is the data
/// the protocol's bare `Tracks` indices can't express on their own — language,
/// codec, channel layout, and a human label per audio/subtitle track.
struct MediaStream: Codable, Sendable, ResponseEncodable {
    /// Container-relative stream index (matches `Tracks` indices).
    var index: Int
    /// `video` | `audio` | `subtitle` | `data` | … (ffprobe `codec_type`).
    var kind: String
    var codec: String?
    /// ISO 639 language tag when tagged (e.g. `eng`, `spa`).
    var language: String?
    /// Human label (ffprobe `tags.title`, e.g. "Director's commentary").
    var title: String?
    /// Audio channel count (e.g. 2 = stereo, 6 = 5.1).
    var channels: Int?
    var isDefault: Bool?
    var isForced: Bool?
}

/// A subtitle file sitting next to the media (a sidecar `.srt`/`.ass`/…), which the
/// protocol has no field for today. Surfaced here so a client could offer it.
struct ExternalSubtitle: Codable, Sendable, ResponseEncodable {
    var url: String
    /// Language guessed from the filename suffix (e.g. `Movie.en.srt` → `en`).
    var language: String?
    /// File extension without the dot (`srt`, `ass`, `vtt`, …).
    var format: String
}

/// The full result of probing one item: its streams plus any sidecar subtitles.
struct ProbeResult: Codable, Sendable, ResponseEncodable {
    var itemId: String
    /// The location that was probed (the resolved direct URL).
    var probedURL: String
    /// Which prober produced this (e.g. `ffprobe 6.1`).
    var prober: String
    var formatName: String?
    var durationSeconds: Double?
    var streams: [MediaStream]
    var externalSubtitles: [ExternalSubtitle]
}

/// Anything that can probe a media location into typed streams. Abstracted so the
/// controller and tests don't depend on `ffprobe` being installed.
protocol MediaProber: Sendable {
    /// A short identity string for the result (`ffprobe 6.1`), or nil if the tool
    /// isn't available.
    func version() async -> String?
    func probe(url: String, headers: [String: String], itemId: String) async throws -> ProbeResult
}

/// Parses `ffprobe -print_format json -show_streams -show_format` output into
/// `ProbeResult`. **Pure** (no process, no I/O) so it's fully unit-testable with
/// captured ffprobe JSON.
enum FFprobeParser {
    static func parse(_ data: Data, itemId: String, probedURL: String, prober: String,
                      externalSubtitles: [ExternalSubtitle] = []) throws -> ProbeResult {
        let raw = try JSONDecoder().decode(RawFFprobe.self, from: data)
        let streams = (raw.streams ?? []).map { s in
            MediaStream(
                index: s.index,
                kind: s.codec_type ?? "unknown",
                codec: s.codec_name,
                language: s.tags?["language"],
                title: s.tags?["title"],
                channels: s.channels,
                isDefault: s.disposition?["default"].map { $0 == 1 },
                isForced: s.disposition?["forced"].map { $0 == 1 }
            )
        }
        return ProbeResult(
            itemId: itemId,
            probedURL: probedURL,
            prober: prober,
            formatName: raw.format?.format_name,
            durationSeconds: raw.format?.duration.flatMap(Double.init),
            streams: streams,
            externalSubtitles: externalSubtitles
        )
    }

    private struct RawFFprobe: Decodable {
        var streams: [RawStream]?
        var format: RawFormat?
    }
    private struct RawStream: Decodable {
        var index: Int
        var codec_name: String?
        var codec_type: String?
        var channels: Int?
        var tags: [String: String]?
        var disposition: [String: Int]?
    }
    private struct RawFormat: Decodable {
        var format_name: String?
        var duration: String?
    }
}

/// The real prober: shells out to `ffprobe`. Constructed per-request from the
/// extension's stored config so a path change takes effect without a restart.
struct FFprobeProber: MediaProber {
    /// Absolute path to the `ffprobe` binary.
    let ffprobePath: String

    /// Sidecar subtitle extensions recognised next to a local media file.
    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt", "sub", "smi"]

    /// Resolve a usable ffprobe path: the configured one if it's executable, else
    /// the first of the common install locations / `PATH` that exists.
    static func locate(configured: String?) -> String? {
        if let configured, !configured.isEmpty, FileManager.default.isExecutableFile(atPath: configured) {
            return configured
        }
        let candidates = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe", "/bin/ffprobe"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    func version() async -> String? {
        guard let out = try? await ProcessRunner.run(ffprobePath, ["-version"]),
              out.exitCode == 0,
              let text = String(data: out.stdout, encoding: .utf8) else { return nil }
        // First line: "ffprobe version 6.1.1 Copyright …"
        let first = text.split(separator: "\n").first.map(String.init) ?? "ffprobe"
        let parts = first.split(separator: " ")
        if parts.count >= 3, parts[0] == "ffprobe", parts[1] == "version" {
            return "ffprobe \(parts[2])"
        }
        return "ffprobe"
    }

    func probe(url: String, headers: [String: String], itemId: String) async throws -> ProbeResult {
        var args = ["-v", "quiet", "-print_format", "json", "-show_streams", "-show_format"]
        // HTTP(S) sources may need auth headers; ffprobe takes them before the input.
        if !headers.isEmpty, url.hasPrefix("http") {
            let blob = headers.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n"
            args += ["-headers", blob]
        }
        args.append(Self.inputArgument(for: url))

        let out = try await ProcessRunner.run(ffprobePath, args)
        guard out.exitCode == 0, !out.stdout.isEmpty else {
            let err = String(data: out.stderr, encoding: .utf8) ?? ""
            throw SphynxError.serverError("ffprobe failed (exit \(out.exitCode))\(err.isEmpty ? "" : ": \(err)")")
        }
        let proberName = await version() ?? "ffprobe"
        return try FFprobeParser.parse(
            out.stdout, itemId: itemId, probedURL: url, prober: proberName,
            externalSubtitles: Self.sidecarSubtitles(for: url)
        )
    }

    /// ffprobe takes a filesystem path for `file://` inputs, the URL otherwise.
    private static func inputArgument(for url: String) -> String {
        if url.hasPrefix("file://"), let parsed = URL(string: url) { return parsed.path }
        return url
    }

    /// Subtitle files alongside a local media file that share its basename stem.
    /// Only applies to `file://` locations (remote sources have no listable dir).
    static func sidecarSubtitles(for url: String) -> [ExternalSubtitle] {
        guard url.hasPrefix("file://"), let parsed = URL(string: url) else { return [] }
        let path = parsed.path
        let dir = (path as NSString).deletingLastPathComponent
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        guard !stem.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [ExternalSubtitle] = []
        for name in entries {
            let ext = (name as NSString).pathExtension.lowercased()
            guard Self.subtitleExtensions.contains(ext) else { continue }
            let base = (name as NSString).deletingPathExtension          // "Movie.en"
            guard base == stem || base.hasPrefix(stem + ".") else { continue }
            // Language guess: the suffix between the stem and the extension.
            let language = base == stem ? nil : String(base.dropFirst(stem.count + 1))
            result.append(ExternalSubtitle(url: "file://\(dir)/\(name)", language: language, format: ext))
        }
        return result.sorted { $0.url < $1.url }
    }
}
