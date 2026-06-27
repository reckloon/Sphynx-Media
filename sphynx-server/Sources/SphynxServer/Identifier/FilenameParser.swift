import Foundation

/// Parses a filename / source key into a clean title + year for TMDB search.
///
/// This is deliberately heuristic and self-contained (no network) so it can be
/// unit-tested exhaustively — it's part of the load-bearing Identifier, where
/// "why did it match the wrong movie" bugs live.
enum FilenameParser {
    struct Parsed: Equatable, Sendable {
        var title: String
        var year: Int?
    }

    /// Release-junk tokens to drop from a title (lowercased, exact-token match).
    private static let junk: Set<String> = [
        "1080p", "720p", "480p", "2160p", "4k", "uhd", "hd", "sd",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx",
        "bluray", "blu-ray", "brrip", "bdrip", "webrip", "web-dl", "webdl", "web",
        "dvdrip", "dvd", "hdtv", "hdrip", "cam", "ts",
        "aac", "ac3", "dts", "dd5", "ddp5", "flac", "mp3", "atmos", "truehd",
        "remux", "proper", "repack", "extended", "unrated", "remastered",
        "internal", "limited", "directors", "cut", "imax", "hdr", "dv", "sdr",
    ]

    /// Whether a token is release junk (resolution, codec, source tag, …).
    /// Exposed so folder-aware parsing can trim a title at the first junk token.
    static func isJunk(_ token: String) -> Bool { junk.contains(token.lowercased()) }

    /// Year must be plausible (1900 .. nextYear) to avoid matching numbers that
    /// merely look like years (e.g. "2049" in a title).
    private static let maxYear: Int = (Calendar.current.component(.year, from: Date())) + 1

    static func parse(_ key: String) -> Parsed {
        // Last path component, extension stripped.
        let lastComponent = key.split(separator: "/").last.map(String.init) ?? key
        let noExtension = stripExtension(lastComponent)

        // Normalise separators (including bracket characters) to spaces.
        let normalised = noExtension.map { ch -> Character in
            "._-+()[]{}".contains(ch) ? " " : ch
        }
        let tokens = String(normalised).split(separator: " ").map(String.init).filter { !$0.isEmpty }

        // First plausible 4-digit year marks the boundary; title is what precedes it.
        var year: Int?
        var yearIndex: Int?
        for (index, token) in tokens.enumerated() {
            if token.count == 4, let value = Int(token), (1900...maxYear).contains(value) {
                year = value
                yearIndex = index
                break
            }
        }

        let titleTokens = (yearIndex.map { Array(tokens[..<$0]) } ?? tokens)
            .filter { !junk.contains($0.lowercased()) }

        let title = titleTokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Parsed(title: title.isEmpty ? noExtension : title, year: year)
    }

    private static func stripExtension(_ name: String) -> String {
        // Only treat a short alphanumeric trailing token with at least one letter
        // as an extension — so "mp4"/"mkv" strip, but a trailing year ".1999" or
        // a decimal "1.5" does not.
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        let ext = name[name.index(after: dot)...]
        let looksLikeExtension = (1...4).contains(ext.count)
            && ext.allSatisfy { $0.isLetter || $0.isNumber }
            && ext.contains(where: \.isLetter)
        return looksLikeExtension ? String(name[..<dot]) : name
    }
}
