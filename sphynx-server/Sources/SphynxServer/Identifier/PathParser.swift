import Foundation

/// Folder-aware media identification from a source-relative path.
///
/// Where `FilenameParser` / `EpisodeParser` look at a single filename, this looks
/// at the **whole relative path** so the cleaner, canonical identity carried by
/// folders wins over a messy or foreign-language filename. In a real library the
/// folder is `Big Hero 6 (2014)` while the file is `Тачки.2006…mkv` — the folder
/// is authoritative.
///
/// It builds on the filename primitives rather than replacing them, so their
/// focused unit tests stay valid. Unicode-aware throughout (Cyrillic, accents).
enum PathParser {
    enum Parsed: Equatable, Sendable {
        /// A flat movie: title (folder-preferred) + optional year.
        case movie(title: String, year: Int?)
        /// A TV episode: series title (folder-preferred), season, episode, and a
        /// best-effort episode title (nil → caller falls back to "Episode N").
        case episode(series: String, season: Int, episode: Int, episodeTitle: String?, year: Int?)
    }

    /// Container folders that never carry a title (top-level library buckets),
    /// across the languages a real library is organised in. A bucket here is
    /// skipped so the *real* title (folder-below or filename) is used instead of
    /// the library root. Lowercased compare; see `isInformativeFolder`.
    private static let genericFolders: Set<String> = [
        // English + common organisational folders
        "movies", "movie", "films", "film", "video", "videos", "media",
        "tv", "shows", "show", "series", "tv shows", "tvshows", "tv series",
        "anime", "cartoons", "kids", "documentaries", "documentary",
        "downloads", "download", "complete", "incoming", "library",
        "plex", "jellyfin", "emby", "collections", "collection",
        // Other languages (фильмы=ru, 映画/ドラマ/アニメ=ja, 电影/电视剧=zh, 영화/드라마=ko, …)
        "películas", "peliculas", "filmes", "filme", "cine", "videos",
        "фильмы", "кино", "сериалы", "мультфильмы",
        "映画", "ドラマ", "アニメ", "番組",
        "电影", "电视剧", "剧集", "动漫", "综艺",
        "영화", "드라마", "예능",
    ]

    static func parse(_ key: String) -> Parsed {
        let comps = key.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let filename = comps.last ?? key
        let dirs = Array(comps.dropLast())
        let stem = stripExtensions(filename)

        // --- Episode detection ---
        // An explicit SxxExx / NxNN in the filename is authoritative for
        // season+episode. Otherwise a season-folder ancestor plus a loose episode
        // number in the filename identifies an episode.
        let marker = episodeMarker(in: stem)
        let seasonFolder = nearestSeasonFolder(dirs)

        if let marker {
            let series = seriesTitle(dirs: dirs, seasonFolderIndex: seasonFolder?.index, filenameStem: stem, markerStart: marker.range.lowerBound)
            // Only the curated ` - Title - ` form carries a real episode title;
            // a dotted release tail (`.2160p.WEB-DL`) or a multi-episode range
            // (`E01-02`) is just metadata, so leave it for the "Episode N" default.
            let title = dashDelimitedTitle(stem: stem, markerEnd: marker.range.upperBound)
            return .episode(series: series.title, season: marker.season, episode: marker.episode, episodeTitle: title, year: series.year)
        }

        if let seasonFolder, let season = seasonFolder.season, let loose = looseEpisode(in: stem) {
            let series = seriesTitle(dirs: dirs, seasonFolderIndex: seasonFolder.index, filenameStem: stem, markerStart: nil)
            return .episode(series: series.title, season: season, episode: loose.episode, episodeTitle: loose.title, year: series.year)
        }

        // Date-stamped episode (daily/talk/news): `Show/2024-01-15.mkv`. Season is
        // the air year, episode a stable MMDD ordinal so same-year airings sort.
        if let date = dateEpisode(in: stem) {
            let series = seriesTitle(dirs: dirs, seasonFolderIndex: seasonFolder?.index, filenameStem: stem, markerStart: date.range.lowerBound)
            return .episode(series: series.title, season: date.season, episode: date.episode, episodeTitle: nil, year: series.year)
        }

        // Absolute-numbered episode (anime): `One Piece - 1071`. Gated to avoid
        // hijacking a movie that merely ends in a number (`Ocean's 11`).
        if let abs = absoluteEpisode(in: stem, hasSeasonFolder: seasonFolder != nil) {
            let series = seriesTitle(dirs: dirs, seasonFolderIndex: seasonFolder?.index, filenameStem: stem, markerStart: abs.range.lowerBound)
            return .episode(series: series.title, season: seasonFolder?.season ?? 1, episode: abs.episode, episodeTitle: abs.title, year: series.year)
        }

        // --- Movie ---
        // Prefer the immediate parent folder when it's informative; the folder
        // carries the clean, canonical title even when the filename is foreign.
        let file = FilenameParser.parse(filename)
        if let parent = dirs.last, isInformativeFolder(parent) {
            let folder = FolderName.parse(parent)
            if !folder.title.isEmpty {
                // Guard against an unlisted localized library root masquerading as
                // a title folder: if it carries no year, is unrelated to the
                // filename's own title, and the filename *does* carry a year, the
                // file is the richer source — use it. Otherwise the folder wins
                // (and can borrow the file's year when it has none of its own).
                let bucketish = folder.year == nil && file.year != nil
                    && !file.title.isEmpty && !related(folder.title, file.title)
                if !bucketish {
                    return .movie(title: folder.title, year: folder.year ?? file.year)
                }
            }
        }
        return .movie(title: file.title, year: file.year)
    }

    /// Plausible upper bound for a year token (next calendar year).
    private static let maxYear: Int = Calendar.current.component(.year, from: Date()) + 1

    // MARK: - Series title

    /// Derive the series title (and a year hint) from the show folder, preferring
    /// it over the filename because the folder is clean and language-canonical.
    /// The show folder is the directory above the season folder, or — when there's
    /// no season folder — the deepest informative directory. Falls back to the
    /// filename prefix before the episode marker.
    private static func seriesTitle(dirs: [String], seasonFolderIndex: Int?, filenameStem: String, markerStart: String.Index?) -> (title: String, year: Int?) {
        var showFolder: String?
        if let i = seasonFolderIndex {
            showFolder = (i - 1 >= 0) ? dirs[i - 1] : nil
        } else {
            showFolder = dirs.last
        }
        if let showFolder, isInformativeFolder(showFolder) {
            let parsed = FolderName.parse(showFolder)
            if !parsed.title.isEmpty { return (parsed.title, parsed.year) }
        }
        // Fall back to the cleaned filename prefix before the marker, dropping a
        // leading `[group]` fansub tag (`[SubsPlease] One Piece` → `One Piece`).
        var prefix = markerStart.map { String(filenameStem[filenameStem.startIndex..<$0]) } ?? filenameStem
        if let r = prefix.range(of: #"^\s*\[[^\]]+\]\s*"#, options: .regularExpression) {
            prefix.removeSubrange(r)
        }
        let parsed = FilenameParser.parse(prefix)
        return (parsed.title.isEmpty ? prefix : parsed.title, parsed.year)
    }

    private static func isInformativeFolder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        if genericFolders.contains(trimmed) { return false }
        return seasonFolderKind(name) == nil
    }

    // MARK: - Season folders

    private enum SeasonFolderKind { case numbered(Int); case range; case specials }

    /// Classify a directory name as a season-level folder, if it is one.
    private static func seasonFolderKind(_ name: String) -> SeasonFolderKind? {
        let s = name.trimmingCharacters(in: .whitespaces)
        // Range, e.g. "Seasons 1-3" / "Season 1 - 3" → a season-level container
        // with no single number (the SxxExx in the filename supplies it).
        if matches(s, #"^seasons?\s+\d{1,3}\s*[-–]\s*\d{1,3}$"#) { return .range }
        if matches(s, #"^specials?$"#) { return .specials }
        if let n = capture(s, #"^season\s+0*(\d{1,3})$"#) { return .numbered(n) }
        if let n = capture(s, #"^series\s+0*(\d{1,3})$"#) { return .numbered(n) }
        if let n = capture(s, #"^s\s*0*(\d{1,2})$"#) { return .numbered(n) }
        return nil
    }

    /// The deepest season-folder ancestor and its single season number (nil for a
    /// range/specials, where the number comes from elsewhere).
    private static func nearestSeasonFolder(_ dirs: [String]) -> (index: Int, season: Int?)? {
        for i in dirs.indices.reversed() {
            switch seasonFolderKind(dirs[i]) {
            case .numbered(let n): return (i, n)
            case .specials: return (i, 0)
            case .range: return (i, nil)
            case nil: continue
            }
        }
        return nil
    }

    // MARK: - Episode markers

    private struct Marker { var season: Int; var episode: Int; var range: Range<String.Index> }

    /// Explicit `SxxExx` / `s1e2` / `1x05` in the filename. The `NxNN` form guards
    /// digit boundaries so a resolution (`1280x720`) is never mistaken for it.
    private static func episodeMarker(in stem: String) -> Marker? {
        for pattern in ["[sS](\\d{1,4})[eE](\\d{1,4})", "(?<![0-9])(\\d{1,2})[xX](\\d{2})(?![0-9])"] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            guard let m = regex.firstMatch(in: stem, range: range),
                  let s = Range(m.range(at: 1), in: stem).flatMap({ Int(stem[$0]) }),
                  let e = Range(m.range(at: 2), in: stem).flatMap({ Int(stem[$0]) }),
                  let full = Range(m.range, in: stem)
            else { continue }
            return Marker(season: s, episode: e, range: full)
        }
        return nil
    }

    /// A loose episode number when the season comes from a folder: `Episode 1`,
    /// `Ep 01`, `E01`, or a leading bare number (`01 Title`).
    private static func looseEpisode(in stem: String) -> (episode: Int, title: String?)? {
        let patterns = [
            #"[Ee]pisode\s*0*(\d{1,3})"#,
            #"(?<![A-Za-z])[Ee]p\.?\s*0*(\d{1,3})"#,
            #"(?<![A-Za-z0-9])[Ee]0*(\d{1,3})(?![0-9])"#,
            #"^\s*0*(\d{1,3})(?![0-9])"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
            guard let m = regex.firstMatch(in: stem, range: range),
                  let n = Range(m.range(at: 1), in: stem).flatMap({ Int(stem[$0]) }),
                  let full = Range(m.range, in: stem)
            else { continue }
            // The text after a loose number is the title (`Episode 1 Beware…`).
            let title = cleanTitleTail(String(stem[full.upperBound...]))
            return (n, title)
        }
        return nil
    }

    // MARK: - Date-stamped & absolute-numbered episodes

    private struct DateEp { var season: Int; var episode: Int; var range: Range<String.Index> }

    /// A `YYYY-MM-DD` / `YYYY.MM.DD` air date (daily shows). Season = year,
    /// episode = `MM*100 + DD` so same-year airings keep their calendar order.
    private static func dateEpisode(in stem: String) -> DateEp? {
        let pattern = #"(?<![0-9])((?:19|20)\d{2})[-._](0[1-9]|1[0-2])[-._](0[1-9]|[12]\d|3[01])(?![0-9])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let m = regex.firstMatch(in: stem, range: ns),
              let y = Range(m.range(at: 1), in: stem).flatMap({ Int(stem[$0]) }),
              let mo = Range(m.range(at: 2), in: stem).flatMap({ Int(stem[$0]) }),
              let d = Range(m.range(at: 3), in: stem).flatMap({ Int(stem[$0]) }),
              let full = Range(m.range, in: stem)
        else { return nil }
        return DateEp(season: y, episode: mo * 100 + d, range: full)
    }

    private struct AbsEp { var episode: Int; var title: String?; var range: Range<String.Index> }

    /// An absolute episode number behind a ` - N` delimiter (`One Piece - 1071`).
    /// The space-dash-space requirement keeps a movie's trailing number
    /// (`Ocean's 11`, `Blade Runner 2049`) out. It only fires with positive TV
    /// signal: a season-folder ancestor, a leading `[group]` fansub tag, or a
    /// multi-digit number that isn't a plausible release year.
    private static func absoluteEpisode(in stem: String, hasSeasonFolder: Bool) -> AbsEp? {
        let pattern = #"\s[-–]\s0*(\d{1,4})(?=[\s_.\[\(]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        guard let m = regex.firstMatch(in: stem, range: ns),
              let r = Range(m.range(at: 1), in: stem), let n = Int(stem[r]), n > 0,
              let full = Range(m.range, in: stem)
        else { return nil }

        let digits = stem.distance(from: r.lowerBound, to: r.upperBound)
        // A 4-digit value in year range is a release year, not an episode.
        if digits == 4 && (1900...maxYear).contains(n) { return nil }

        let hasGroupTag = matches(stem, #"^\s*\[[^\]]+\]"#)
        guard hasSeasonFolder || hasGroupTag || digits >= 2 else { return nil }

        let title = cleanTitleTail(String(stem[full.upperBound...]))
        return AbsEp(episode: n, title: title, range: full)
    }

    /// Whether two titles plainly refer to the same thing (containment or a shared
    /// word after normalisation) — used to tell a real title folder from a library
    /// bucket when neither carries a year.
    private static func related(_ a: String, _ b: String) -> Bool {
        let na = normalizeForCompare(a), nb = normalizeForCompare(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let ta = Set(na.split(separator: " ")), tb = Set(nb.split(separator: " "))
        return !ta.intersection(tb).isEmpty
    }

    private static func normalizeForCompare(_ s: String) -> String {
        s.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map(Character.init).reduce(into: "") { $0.append($1) }
            .split(separator: " ").joined(separator: " ")
    }

    /// Episode title from a curated ` - SxxExx - Title [junk]` filename. Requires
    /// a space-dash-space delimiter after the marker so dotted release tails
    /// (`.2160p.WEB-DL`) and multi-episode ranges (`E01-02`) don't masquerade as
    /// titles. Returns nil when there's no clean title (caller uses "Episode N").
    private static func dashDelimitedTitle(stem: String, markerEnd: String.Index) -> String? {
        let raw = String(stem[markerEnd...])
        guard matches(raw, #"^\s*-\s"#) else { return nil }
        return cleanTitleTail(raw)
    }

    /// Strip a release-junk tail from a title fragment: cut at bracketed tags,
    /// then keep words up to the first junk token. A token may itself be dotted
    /// (`Terror.1080p.H265`) — cut at the first junk sub-token and join the rest
    /// with spaces (`The.Emperors.Peace` → `The Emperors Peace`), while a dotted
    /// fragment with no junk is kept verbatim (`M.E. Time`).
    private static func cleanTitleTail(_ text: String) -> String? {
        var rest = text
        if let cut = rest.firstIndex(where: { $0 == "[" || $0 == "(" }) {
            rest = String(rest[..<cut])
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -–._"))
        guard !rest.isEmpty else { return nil }

        var kept: [String] = []
        outer: for token in rest.split(separator: " ").map(String.init) {
            if token.contains(".") {
                let subs = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                if let j = subs.firstIndex(where: { FilenameParser.isJunk($0) }) {
                    let head = subs[..<j].joined(separator: " ")
                    if !head.isEmpty { kept.append(head) }
                    break outer
                }
                kept.append(token)
            } else if FilenameParser.isJunk(token) {
                break
            } else {
                kept.append(token)
            }
        }
        let title = kept.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    // MARK: - Helpers

    /// Strip up to two trailing extensions, so `Name.mkv.strm` → `Name`.
    private static func stripExtensions(_ name: String) -> String {
        var result = name
        for _ in 0..<2 {
            guard let dot = result.lastIndex(of: "."), dot != result.startIndex else { break }
            let ext = result[result.index(after: dot)...]
            let looksLikeExt = (1...4).contains(ext.count)
                && ext.allSatisfy { $0.isLetter || $0.isNumber }
                && ext.contains(where: \.isLetter)
            if looksLikeExt { result = String(result[..<dot]) } else { break }
        }
        return result
    }

    private static func matches(_ string: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }

    private static func capture(_ string: String, _ pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
              let r = Range(m.range(at: 1), in: string)
        else { return nil }
        return Int(string[r])
    }
}

/// A clean folder name of the canonical form `Title (Year)`. Unlike the release
/// filename, a folder is curator-clean, so punctuation is preserved (only a
/// trailing year marker is lifted out) — `Rogue One - A Star Wars Story (2016)`
/// stays intact.
enum FolderName {
    static func parse(_ name: String) -> (title: String, year: Int?) {
        // A scene-style dotted release folder (`Cars.2006.1080p.BluRay.x264-GROUP`)
        // is not curator-clean — parse it like a release filename instead.
        if looksLikeReleaseName(name) {
            let p = FilenameParser.parse(name)
            return (p.title, p.year)
        }

        let maxYear = Calendar.current.component(.year, from: Date()) + 1
        var title = name
        var year: Int?

        // A parenthesised / bracketed year anywhere: `Big Hero 6 (2014)`.
        if let regex = try? NSRegularExpression(pattern: #"[\(\[]\s*((?:19|20)\d{2})\s*[\)\]]"#) {
            let range = NSRange(name.startIndex..., in: name)
            if let m = regex.firstMatch(in: name, range: range),
               let yr = Range(m.range(at: 1), in: name).flatMap({ Int(name[$0]) }),
               (1900...maxYear).contains(yr), let full = Range(m.range, in: name) {
                year = yr
                title = String(name[name.startIndex..<full.lowerBound]) + String(name[full.upperBound...])
            }
        }

        // Otherwise a trailing bare year token: `Big Hero 6 2014`.
        if year == nil {
            let tokens = title.split(separator: " ").map(String.init)
            if let last = tokens.last, last.count == 4, let yr = Int(last), (1900...maxYear).contains(yr) {
                year = yr
                title = tokens.dropLast().joined(separator: " ")
            }
        }

        title = title
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–·"))
            .trimmingCharacters(in: .whitespaces)
        return (title, year)
    }

    /// A dot/underscore-delimited folder carrying release junk (resolution, codec,
    /// source tag). A curated `Title (Year)` folder uses spaces, so this never
    /// fires on `Rogue One - A Star Wars Story (2016)` or `Big Hero 6 (2014)`.
    private static func looksLikeReleaseName(_ name: String) -> Bool {
        guard name.contains("."), !name.contains(" ") else { return false }
        let tokens = name.lowercased().split(whereSeparator: { "._-+".contains($0) }).map(String.init)
        return tokens.contains { FilenameParser.isJunk($0) }
    }
}
