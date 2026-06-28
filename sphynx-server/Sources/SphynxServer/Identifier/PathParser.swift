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
    /// Which kind of bonus-content bucket a file sits under, mapped to the wire
    /// `ItemType` the caller stores. Trailers → `.trailer`; deleted scenes →
    /// `.deletedScene`; behind-the-scenes → `.behindTheScenes`; everything else
    /// generically bonus (featurettes/extras/bonus/interviews) → `.featurette`.
    enum ExtrasBucket: String, Equatable, Sendable {
        case trailer, featurette, deletedScene, behindTheScenes
    }

    enum Parsed: Equatable, Sendable {
        /// A flat movie: title (folder-preferred) + optional year.
        case movie(title: String, year: Int?)
        /// A TV episode: series title (folder-preferred), season, episode, and a
        /// best-effort episode title (nil → caller falls back to "Episode N").
        case episode(series: String, season: Int, episode: Int, episodeTitle: String?, year: Int?)
        /// A bonus-content clip sitting under an extras bucket (`…/Featurettes/…`,
        /// `…/Extras/…`, `…/Trailers/…`). The caller nests it under the enclosing
        /// movie/show item via `parentId`. `parentTitle`/`parentYear` identify that
        /// enclosing title (the folder above the bucket); `title` is the clip's own
        /// best-effort name (nil → caller falls back to the filename stem). A bucket
        /// carries no year of its own, so `parentYear` distinguishes a movie parent
        /// (`Some Movie (2020)`) from a show parent (`Some Show`).
        case extras(bucket: ExtrasBucket, parentTitle: String, parentYear: Int?, title: String?)
    }

    /// Extras/bonus subfolders that never carry the show title, each mapped to the
    /// `ExtrasBucket` it denotes. A file under one of these is bonus content nested
    /// under the enclosing title, not a standalone movie. (`Specials` is a *season*
    /// folder, handled by `seasonFolderKind` → season 0, and is deliberately absent
    /// here.) Lowercased compare.
    private static let extrasBuckets: [String: ExtrasBucket] = [
        "trailers": .trailer, "trailer": .trailer,
        "featurettes": .featurette, "featurette": .featurette,
        "extras": .featurette, "extra": .featurette,
        "bonus": .featurette, "bonus features": .featurette,
        "interviews": .featurette, "interview": .featurette,
        "deleted scenes": .deletedScene, "deleted scene": .deletedScene,
        "behind the scenes": .behindTheScenes, "behindthescenes": .behindTheScenes,
    ]

    /// The `ExtrasBucket` a directory name denotes, if it is an extras bucket.
    private static func extrasBucket(_ name: String) -> ExtrasBucket? {
        extrasBuckets[name.trimmingCharacters(in: .whitespaces).lowercased()]
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
        // Extras/bonus subfolders that never carry the show title.
        "featurettes", "extras", "deleted scenes", "bonus", "behind the scenes",
        "interviews", "trailers", "samples", "sample",
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

        // --- Extras / bonus content ---
        // A file under an extras bucket (`…/Featurettes/…`, `…/Extras/…`,
        // `…/Trailers/…`) is bonus content nested under the enclosing title, not a
        // standalone movie or a real episode tree. The bucket may itself contain
        // organisational subfolders (`Featurettes/Season 3/clip.mkv`), so scan all
        // ancestors and take the deepest bucket; the title is the folder above it.
        if let extras = extrasParse(dirs: dirs, stem: stem) {
            return extras
        }

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
        // Parse the filename from the extension-stripped stem so a stacked
        // container suffix (`.mkv.strm`) never leaks a `mkv` token into the title.
        let file = FilenameParser.parse(stem)
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
                    // A junk-laden folder that still carries release tokens after
                    // cleaning loses to a clean inner file (`Big Hero 6 2014 UHD …/
                    // Big Hero 6 (2014).mkv`).
                    if titleHasJunk(folder.title), !file.title.isEmpty, !titleHasJunk(file.title) {
                        return .movie(title: file.title, year: file.year ?? folder.year)
                    }
                    return .movie(title: folder.title, year: folder.year ?? file.year)
                }
            }
        }
        return .movie(title: file.title, year: file.year)
    }

    /// Detect a bonus-content clip: the deepest extras-bucket ancestor, with the
    /// enclosing title taken from the nearest informative folder above it. Returns
    /// nil when no ancestor is an extras bucket (the normal movie/episode path).
    private static func extrasParse(dirs: [String], stem: String) -> Parsed? {
        // Deepest bucket wins, so a clip's *own* nested folders don't shadow it.
        guard let bucketIndex = dirs.indices.reversed().first(where: { extrasBucket(dirs[$0]) != nil }),
              let bucket = extrasBucket(dirs[bucketIndex])
        else { return nil }

        // The enclosing title is the nearest informative folder above the bucket,
        // skipping generic library roots and any nested extras buckets. Cleaned via
        // the same series logic so a `Title (Year)` folder yields title + year.
        var parsed: (title: String, year: Int?)?
        if bucketIndex - 1 >= 0 {
            for candidate in dirs[0...(bucketIndex - 1)].reversed()
            where !isGenericBucket(candidate) && extrasBucket(candidate) == nil {
                let clean = cleanSeriesName(candidate)
                if !clean.title.isEmpty { parsed = clean; break }
            }
        }
        guard let parent = parsed, !parent.title.isEmpty else { return nil }

        // The clip's own name (cleaned of release junk); nil → caller uses the stem.
        let file = FilenameParser.parse(stem)
        let title = file.title.isEmpty ? nil : file.title
        return .extras(bucket: bucket, parentTitle: parent.title, parentYear: parent.year, title: title)
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
        // Scan for the folder that carries the show title, nearest-first: the
        // ancestors above a season folder (skipping generic/extras buckets like
        // `Featurettes`), then the season folder itself (a flat `Show … Season 1`
        // pack carries its own title). `cleanSeriesName` strips the season marker,
        // so even a multi-season pack folder (`Show … Season 1-8 …`) yields the
        // clean title — and a pure season folder (`Season 1`) cleans to empty and
        // is skipped.
        var candidates: [String] = []
        if let i = seasonFolderIndex {
            if i - 1 >= 0 { candidates.append(contentsOf: dirs[0...(i - 1)].reversed()) }
            candidates.append(dirs[i])
        } else {
            candidates.append(contentsOf: dirs.reversed())
        }
        for candidate in candidates where !isGenericBucket(candidate) {
            let parsed = cleanSeriesName(candidate)
            if !parsed.title.isEmpty { return parsed }
        }
        // Fall back to the cleaned filename prefix before the marker.
        let prefix = markerStart.map { String(filenameStem[filenameStem.startIndex..<$0]) } ?? filenameStem
        let parsed = cleanSeriesName(prefix)
        return (parsed.title.isEmpty ? prefix.trimmingCharacters(in: .whitespaces) : parsed.title, parsed.year)
    }

    /// A top-level/library or extras bucket that never carries a show title.
    private static func isGenericBucket(_ name: String) -> Bool {
        genericFolders.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Extract a clean series title (and year hint) from a folder or filename
    /// prefix. The series title is the text *before* the first season/episode
    /// marker (`S01`, `Season 1`, `Series 2`), so a scene/pack name collapses to
    /// the real title: `Foundation.S01.2160p.WEB-DL` → `Foundation`, `The Boys S02
    /// Eng Fre …` → `The Boys`, `Show Complete Season 1 (2010–11)` → `Show`.
    /// Curated names with no marker pass through with punctuation intact.
    static func cleanSeriesName(_ raw: String) -> (title: String, year: Int?) {
        var name = raw.trimmingCharacters(in: .whitespaces)
        // Drop a leading `[group]` fansub tag.
        if let r = name.range(of: #"^\s*\[[^\]]+\]\s*"#, options: .regularExpression) {
            name.removeSubrange(r)
        }
        // Cut at the earliest season/episode marker.
        let markers = [
            #"(?i)(?:^|[ ._\-(\[])s\d{1,2}(?:e\d{1,4})?(?=[ ._\-)\]]|$)"#,   // S01 / S01E01 / S01-S08
            #"(?i)(?:^|[ ._\-(\[])seasons?[ ._]+\d"#,                          // Season 1 / Seasons 1-8
            #"(?i)(?:^|[ ._\-(\[])series[ ._]+\d"#,                            // Series 2
        ]
        var cut: String.Index?
        for pattern in markers {
            if let r = name.range(of: pattern, options: .regularExpression) {
                cut = min(cut ?? r.lowerBound, r.lowerBound)
            }
        }
        if let cut { name = String(name[..<cut]) }
        // Trim trailing/leading separators left by the cut or a dotted filename
        // prefix (`Friends.` → `Friends`).
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ._-–·"))
        guard !name.isEmpty else { return ("", nil) }

        // Clean the prefix: release-style → strip junk; else preserve punctuation.
        // For the release case, normalise dot/underscore separators to spaces first
        // so `FilenameParser` doesn't mistake a trailing word for a file extension
        // (`The.Boys` must become `The Boys`, not `The`).
        let cleaned: (title: String, year: Int?)
        if FolderName.looksLikeReleaseName(name) {
            let spaced = name.replacingOccurrences(of: ".", with: " ")
                             .replacingOccurrences(of: "_", with: " ")
            let p = FilenameParser.parse(spaced)
            cleaned = (p.title, p.year)
        } else {
            cleaned = FolderName.parse(name)
        }
        return (trimTrailingJunk(cleaned.title), cleaned.year)
    }

    /// Drop trailing release/pack tokens that survive cleaning (`… Complete`,
    /// `… REPACK`) without disturbing internal punctuation.
    private static func trimTrailingJunk(_ title: String) -> String {
        var tokens = title.split(separator: " ").map(String.init)
        let extra: Set<String> = ["complete", "repack", "multi", "proper", "uncut"]
        while let last = tokens.last, FilenameParser.isJunk(last) || extra.contains(last.lowercased()) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Whether a title still carries a release-junk token (used to prefer a clean
    /// inner filename over a junk folder for movies).
    private static func titleHasJunk(_ title: String) -> Bool {
        title.split(separator: " ").contains { FilenameParser.isJunk(String($0)) }
    }

    private static func isInformativeFolder(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        if genericFolders.contains(trimmed) { return false }
        return seasonFolderKind(name) == nil
    }

    // MARK: - Season folders

    private enum SeasonFolderKind { case numbered(Int); case range; case specials }

    /// Classify a directory name as a season-level folder, if it is one. Matches
    /// both clean folders (`Season 2`, `S02`, `Specials`) and a season marker
    /// embedded in a longer scene/pack name (`Show Complete Season 1 (2010–11)`,
    /// `Foundation.S01.2160p.WEB-DL`, `… Season 1-8 S01-S08 (1080p…)`).
    private static func seasonFolderKind(_ name: String) -> SeasonFolderKind? {
        let s = name.trimmingCharacters(in: .whitespaces)
        // A season *range* anywhere (`Seasons 1-3`, `Season 1-8 S01-S08`) is a
        // multi-season container; the filename's SxxExx supplies the number.
        if matches(s, #"(?i)seasons?\s*\d{1,3}\s*[-–]\s*\d{1,3}"#) { return .range }
        if matches(s, #"(?i)(?:^|[ ._\-(\[])s\d{1,2}\s*[-–]\s*s?\d{1,2}(?=[ ._\-)\]]|$)"#) { return .range }
        if matches(s, #"(?i)(?:^|[ ._\-(\[])specials?(?=[ ._\-)\]]|$)"#) { return .specials }
        if let n = capture(s, #"(?i)(?:^|[ ._\-(\[])seasons?[ ._]+0*(\d{1,3})(?![0-9])"#) { return .numbered(n) }
        if let n = capture(s, #"(?i)(?:^|[ ._\-(\[])series[ ._]+0*(\d{1,3})(?![0-9])"#) { return .numbered(n) }
        if let n = capture(s, #"(?i)(?:^|[ ._\-(\[])s\s*0*(\d{1,2})(?=[ ._\-)\]]|$)"#) { return .numbered(n) }
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

    /// Whether a folder name is a scene release string rather than a curated
    /// `Title (Year)` name. Fires when it carries release junk (resolution, codec,
    /// source/audio tag) *however* it's delimited — `Big Hero 6 2014 UHD BluRay…`
    /// (spaces) as well as `Cars.2006.1080p.x264-GROUP` (dots) — or when it's a
    /// dot/underscore-delimited multi-token name with no spaces (`Maniac.2018`).
    /// A clean, space-delimited name with no junk (`Rogue One - A Star Wars Story
    /// (2016)`) does NOT match, so its punctuation is preserved.
    static func looksLikeReleaseName(_ name: String) -> Bool {
        let tokens = name.lowercased().split(whereSeparator: { "._-+ []()".contains($0) }).map(String.init)
        if tokens.contains(where: { FilenameParser.isJunk($0) }) { return true }
        let dotted = (name.contains(".") || name.contains("_")) && !name.contains(" ")
        return dotted && tokens.count >= 2
    }
}
