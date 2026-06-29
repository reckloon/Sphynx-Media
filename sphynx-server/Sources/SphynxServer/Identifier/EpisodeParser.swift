import Foundation

/// Detects TV episodes in a filename / source key and extracts the series title,
/// season, and episode numbers. Like `FilenameParser`, this is deliberately
/// heuristic and self-contained (no network) so it can be unit-tested
/// exhaustively — it's part of the load-bearing Identifier.
///
/// Recognised shapes (case-insensitive): `S01E02`, `s1e2`, `1x05`,
/// `S01E02E03` (first episode wins for now). Resolution-like tokens (`1280x720`)
/// are not mistaken for `NxNN` thanks to digit boundaries.
enum EpisodeParser {
    struct Parsed: Equatable, Sendable {
        var seriesTitle: String
        var season: Int
        var episode: Int
    }

    // NSRegularExpression (Foundation) for reliable cross-platform behaviour.
    private static let patterns: [NSRegularExpression] = {
        let raw = [
            // Season/episode allow up to 4 digits so long-running anime
            // (`S01E1071`) and year-as-season daily shows (`S2024E01`) survive.
            "[sS](\\d{1,4})[eE](\\d{1,4})",                 // S01E02 / s1e2 / S01E1071
            "(?<![0-9])(\\d{1,2})[xX](\\d{2})(?![0-9])",    // 1x05 (not 1280x720)
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    static func parse(_ key: String) -> Parsed? {
        let last = key.split(separator: "/").last.map(String.init) ?? key
        let range = NSRange(last.startIndex..<last.endIndex, in: last)

        for regex in patterns {
            guard let match = regex.firstMatch(in: last, range: range),
                  let seasonRange = Range(match.range(at: 1), in: last),
                  let episodeRange = Range(match.range(at: 2), in: last),
                  let season = Int(last[seasonRange]),
                  let episode = Int(last[episodeRange]),
                  let fullRange = Range(match.range, in: last)
            else { continue }

            // The series title is everything before the marker, cleaned by the
            // movie parser (strips release junk, separators, a trailing year).
            let prefix = String(last[last.startIndex..<fullRange.lowerBound])
            let title = FilenameParser.parse(prefix).title
            guard !title.isEmpty else { continue }

            return Parsed(seriesTitle: title, season: season, episode: episode)
        }
        return nil
    }
}
