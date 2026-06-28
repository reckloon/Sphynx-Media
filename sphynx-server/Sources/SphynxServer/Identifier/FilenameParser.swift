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
    static func isJunk(_ token: String) -> Bool {
        let t = token.lowercased()
        if junk.contains(t) { return true }
        // A `WxH` resolution token (`1280x720`, `1920x1080`) is also release junk.
        return t.range(of: #"^\d{3,4}x\d{3,4}$"#, options: .regularExpression) != nil
    }

    /// Year must be plausible (1900 .. nextYear) to avoid matching numbers that
    /// merely look like years (e.g. "2049" in a title).
    private static let maxYear: Int = (Calendar.current.component(.year, from: Date())) + 1

    static func parse(_ key: String) -> Parsed {
        // Last path component, extension stripped.
        let lastComponent = key.split(separator: "/").last.map(String.init) ?? key
        var noExtension = stripSiteTag(stripExtension(lastComponent))

        // Drop leading `[group]` release/fansub tags (`[pcela] Suzume (2022)…`) so
        // the tag never leaks into the title as a bogus first word. Only *leading*
        // groups are stripped, and never the whole name — a bracket later in the
        // string is release metadata the junk filter handles. Mirrors the leading
        // strip `PathParser.cleanSeriesName` already does for series folders.
        while let r = noExtension.range(of: #"^\s*\[[^\]]*\]\s*"#, options: .regularExpression),
              r.upperBound < noExtension.endIndex {
            noExtension.removeSubrange(r)
        }

        // Normalise separators (incl. brackets and CJK punctuation/full-width
        // separators) to spaces, and fold full-width digits to ASCII so a
        // full-width year (`２０１６`) is recognised. CJK titles with no ASCII
        // spaces still tokenise around their year via these separators.
        let normalised = noExtension.map { ch -> Character in
            if "._-+()[]{}·・。、　．".contains(ch) { return " " }
            if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
               (0xFF10...0xFF19).contains(scalar.value) {
                return Character(UnicodeScalar(scalar.value - 0xFF10 + 0x30)!)  // ０-９ → 0-9
            }
            return ch
        }
        let tokens = String(normalised).split(separator: " ").map(String.init).filter { !$0.isEmpty }

        // The release year is the first plausible 4-digit token that is *not* the
        // leading token: a year at index 0 belongs to the title (`1917`,
        // `2001 A Space Odyssey`), not the boundary. Title is what precedes it.
        var year: Int?
        var yearIndex: Int?
        for index in tokens.indices where index >= 1 {
            let token = tokens[index]
            if token.count == 4, let value = Int(token), (1900...maxYear).contains(value) {
                year = value
                yearIndex = index
                break
            }
        }

        let titleTokens = yearIndex.map { Array(tokens[..<$0]) } ?? tokens
        // Drop release junk — but if that leaves nothing, the title *is* a
        // junk-vocabulary word (`Cam`, `Web`, `Cut`), so keep it unfiltered.
        let filtered = titleTokens.filter { !isJunk($0) }
        let kept = filtered.isEmpty ? titleTokens : filtered

        let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return Parsed(title: title.isEmpty ? noExtension : title, year: year)
    }

    /// Drop a leading tracker/site tag a scene release often prepends —
    /// `www.UIndex.org    -    Planes 2013 …` or `[ www.Tracker.to ] Movie …` —
    /// so the domain never becomes the title. Fires only when the tag is clearly a
    /// site reference (a `www.` prefix or a bracketed `host.tld`) and real content
    /// follows, so an ordinary title that merely contains a dot is left untouched.
    static func stripSiteTag(_ name: String) -> String {
        let patterns = [
            // `www.host.tld` optionally bracketed, then separators: `www.X.org - `.
            #"^\s*[\[(]?\s*www\.[a-z0-9.-]+?\.[a-z]{2,6}\s*[\])]?\s*[-–—_:.|]*\s*"#,
            // `[host.tld]` / `(host.tld)` — a bracketed bare domain tag.
            #"^\s*[\[(]\s*[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,6}\s*[\])]\s*[-–—_:.|]*\s*"#,
        ]
        var result = name
        for pattern in patterns {
            if let r = result.range(of: pattern, options: [.regularExpression, .caseInsensitive]),
               r.lowerBound == result.startIndex, r.upperBound < result.endIndex {
                let stripped = String(result[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if !stripped.isEmpty { result = stripped }
            }
        }
        return result
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
