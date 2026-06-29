import Foundation
import Hummingbird

/// Walks each source's driver to produce raw entries, then reconciles them into
/// the catalog. Movies are flat; TV episodes build a series → season → episode
/// tree (deduping shared series/seasons). Metadata-only — never touches media
/// bytes. Movie identification/enrichment runs via `EnrichmentService`; TV is
/// identified + enriched here as the tree is built (`TVEnricher`).
struct Indexer: Sendable {
    let catalog: Catalog
    let drivers: DriverFactory
    /// Present when TMDB is configured; movie identify + enrich after reconcile.
    let enrichment: EnrichmentService?
    /// Present when TMDB is configured; TV identify + enrich during reconcile.
    let tv: TVEnricher?

    /// Container/leaf types enriched inline during reconcile (not via the movie
    /// pass). Used to exclude them from the post-reconcile `EnrichmentService` loop.
    static let tvTypes: Set<String> = ["series", "season", "episode"]

    /// Scan one source, reporting scan activity to the diagnostics center (the web
    /// admin Activity tab) and ensuring the in-flight flag is cleared even on error.
    func scan(sourceId: String) async throws -> IndexSummary {
        let startedAt = Date()
        await DiagnosticsCenter.shared.scanBegan()
        do {
            let summary = try await runScan(sourceId: sourceId)
            await DiagnosticsCenter.shared.scanEnded(
                sourceId: summary.sourceId, scanned: summary.scanned, added: summary.added,
                updated: summary.updated, removed: summary.removed, enriched: summary.enriched,
                durationMs: Date().timeIntervalSince(startedAt) * 1000)
            return summary
        } catch {
            await DiagnosticsCenter.shared.scanFailed()
            throw error
        }
    }

    private func runScan(sourceId: String) async throws -> IndexSummary {
        guard let source = try await catalog.source(id: sourceId) else {
            throw SphynxError.notFound("No source '\(sourceId)'")
        }
        let driver = try drivers.makeDriver(for: source)
        let entries = try await driver.list()
        let now = Date().timeIntervalSince1970

        // One walk, fan out by type: movies and TV route to their own libraries
        // (falling back to the source's single library when unmapped).
        let movieLib = source.libraryId(for: "movie")
        let tvLib = source.libraryId(for: "tv")

        // Existing media items (episodes + movies) keyed by their stable
        // sourceKey. Containers (series/season, empty sourceKey) are excluded —
        // they're found via dedicated lookups so they don't collide on "".
        var existingByKey: [String: ItemRecord] = [:]
        for record in try await catalog.itemsBySource(sourceId: sourceId) where !record.sourceKey.isEmpty {
            existingByKey[record.sourceKey] = record
        }

        // Per-scan caches to dedupe containers and avoid refetching seasons.
        var seriesCache: [String: ItemRecord] = [:]                 // normalized series title
        var movieParentCache: [String: ItemRecord] = [:]            // "normTitle|year" → movie parent for extras
        var seasonCache: [String: ItemRecord] = [:]                 // "seriesId|season"
        var seasonDetailsCache: [String: TMDBSeasonDetails] = [:]   // "tmdbId|season"
        var touchedContainers: Set<String> = []

        var added = 0, updated = 0, removed = 0
        var tvEnriched = 0
        // Movies are grouped into one item per (title, year); multiple files of the
        // same title collapse into selectable versions instead of duplicate tiles.
        var movieGroups: [String: (title: String, year: Int?, files: [SourceEntry])] = [:]

        // TV (re-)enrichment freshness: a known item is re-fetched from TMDB only when
        // it has never been enriched or has gone stale, so a re-scan of an unchanged,
        // fresh library makes **zero** TMDB calls.
        let ttl = enrichment?.ttl ?? .greatestFiniteMagnitude

        // --- nested helpers (capture the caches above) ---

        /// Whether a TV row is due for (re-)enrichment — never enriched, or stale.
        func needsEnrich(_ record: ItemRecord) -> Bool {
            guard let at = record.enrichedAt else { return true }
            return now - at >= ttl
        }

        // Report one TV row (series/season/episode) enriched during reconcile to
        // the diagnostics center, so the Activity tab counts TV work instead of
        // only movies. TV enriches inline here (not via EnrichmentService), so
        // without this it never registers as "enriched" and later shows "skipped".
        func noteTVEnriched(_ record: ItemRecord) async {
            tvEnriched += 1
            let token = await DiagnosticsCenter.shared.begin(
                itemId: record.id, title: record.title, kind: "tv")
            await DiagnosticsCenter.shared.finish(token, result: .enriched)
        }

        func cachedSeason(tmdbId: Int, season: Int) async -> TMDBSeasonDetails? {
            let key = "\(tmdbId)|\(season)"
            if let cached = seasonDetailsCache[key] { return cached }
            guard let tv else { return nil }
            guard let details = try? await tv.season(tmdbId: tmdbId, season: season) else { return nil }
            seasonDetailsCache[key] = details
            return details
        }

        func ensureSeries(_ title: String, year: Int?) async throws -> ItemRecord {
            let cacheKey = HeuristicIdentifier.normalize(title)
            if let cached = seriesCache[cacheKey] { return cached }

            var record: ItemRecord
            var changed = false
            if let existing = try await catalog.seriesItem(title: title) {
                record = existing
                if record.year == nil, let year { record.year = year; changed = true }
            } else {
                record = try await catalog.createItem(
                    type: "series", title: title, sourceId: source.id, sourceKey: "",
                    container: nil, tmdbId: nil, libraryId: tvLib,
                    parentId: nil, year: year, seriesTitle: title
                )
            }
            // Identify when not yet identified (heals a series first scanned before
            // TMDB was configured). A *known* series is never re-identified — only its
            // fields are refreshed, and only when stale, so a re-scan hits no TMDB.
            if let tv {
                if record.tmdbId == nil,
                   let tmdbId = try? await tv.identifySeries(title: record.seriesTitle ?? title) {
                    record.tmdbId = String(tmdbId)
                    if let fields = try? await tv.seriesFields(tmdbId: tmdbId) {
                        apply(fields, to: &record, now: now)
                    }
                    changed = true
                    await noteTVEnriched(record)
                } else if let id = record.tmdbId.flatMap(Int.init), needsEnrich(record),
                          let fields = try? await tv.seriesFields(tmdbId: id) {
                    apply(fields, to: &record, now: now)   // refresh stale metadata in place
                    changed = true
                    await noteTVEnriched(record)
                }
            }
            if changed {
                record.updatedAt = now
                try await catalog.updateItem(record)
            }
            seriesCache[cacheKey] = record
            return record
        }

        func ensureSeason(series: ItemRecord, season: Int) async throws -> ItemRecord {
            let cacheKey = "\(series.id)|\(season)"
            if let cached = seasonCache[cacheKey] { return cached }

            var record: ItemRecord
            if let existing = try await catalog.seasonItem(seriesItemId: series.id, seasonNumber: season) {
                record = existing
            } else {
                record = try await catalog.createItem(
                    type: "season", title: "Season \(season)", sourceId: source.id, sourceKey: "",
                    container: nil, tmdbId: series.tmdbId, libraryId: tvLib,
                    parentId: series.id, year: nil,
                    seriesId: series.id, seriesTitle: series.title,   // display name (normalized)
                    seasonIndex: season
                )
            }
            var changed = false
            // Keep the season's displayed series name in sync with the series'
            // (normalized) title — cheap, no TMDB. This heals seasons created with the
            // source-language name before the series title was normalized.
            if record.seriesTitle != series.title { record.seriesTitle = series.title; changed = true }
            if record.tmdbId == nil, series.tmdbId != nil { record.tmdbId = series.tmdbId; changed = true }

            // Enrich the season row from TMDB only when it actually needs it (never
            // enriched, or stale) — so a re-scan of a fresh season fetches nothing.
            if let tmdbId = series.tmdbId.flatMap(Int.init), needsEnrich(record),
               let details = await cachedSeason(tmdbId: tmdbId, season: season) {
                record.tmdbId = series.tmdbId
                record.primaryImage = TMDBImage.url(details.posterPath, size: "w500")
                record.placeholderURL = TMDBImage.url(details.posterPath, size: "w92")
                // Seasons have no landscape art of their own — inherit the show's
                // wide art for both `backdrop` (full-bleed) and `thumb` (the
                // horizontal card image), so `thumb` is landscape, not a poster.
                record.backdropImage = series.backdropImage
                record.thumbImage = series.backdropImage
                record.overview = details.overview
                record.enrichedAt = now
                changed = true
                await noteTVEnriched(record)
            }
            if changed {
                record.updatedAt = now
                try await catalog.updateItem(record)
            }
            seasonCache[cacheKey] = record
            return record
        }

        /// Resolve (or create) the flat movie item an extras clip nests under,
        /// matching an existing movie by title (+ optional year) in the movie
        /// library so a curated `Some Movie (2020)/Extras/…` attaches to the movie.
        /// Creates a lightweight placeholder movie only if none exists yet, so a
        /// bonus clip is still browsable; a later scan of the feature heals it.
        func ensureMovieParent(_ title: String, year: Int?) async throws -> ItemRecord {
            let cacheKey = "\(HeuristicIdentifier.normalize(title))|\(year.map(String.init) ?? "")"
            if let cached = movieParentCache[cacheKey] { return cached }
            let record: ItemRecord
            if let existing = try await catalog.movieItem(title: title, year: year) {
                record = existing
            } else {
                record = try await catalog.createItem(
                    type: "movie", title: title, sourceId: source.id, sourceKey: "",
                    container: nil, tmdbId: nil, libraryId: movieLib,
                    parentId: nil, year: year
                )
            }
            movieParentCache[cacheKey] = record
            return record
        }

        // --- reconcile each entry ---
        for entry in entries {
            switch Self.classify(entry) {
            case .episode(let ep):
                let series = try await ensureSeries(ep.series, year: ep.year)
                let season = try await ensureSeason(series: series, season: ep.season)
                touchedContainers.insert(series.id)
                touchedContainers.insert(season.id)

                // Fetch this episode's TMDB metadata **lazily** — only the callers
                // below that actually need to enrich invoke it, so a fresh episode on
                // a re-scan triggers no season fetch. `cachedSeason` dedupes the fetch
                // per scan, so siblings in a season share one call.
                func episodeMeta() async -> TMDBEpisode? {
                    guard let tmdbId = series.tmdbId.flatMap(Int.init) else { return nil }
                    return (await cachedSeason(tmdbId: tmdbId, season: ep.season))?
                        .episodes.first { $0.episodeNumber == ep.episode }
                }

                // Apply episode enrichment from TMDB (also heals an episode first
                // scanned before TMDB / before the series had an id). `primary` is
                // the still (already landscape); `backdrop` carries the show's wide
                // art for a hero image on the episode screen.
                func applyEpisode(_ record: inout ItemRecord, _ meta: TMDBEpisode) {
                    record.tmdbId = series.tmdbId
                    if record.title.hasPrefix("Episode "), let name = meta.name, !name.isEmpty {
                        record.title = name
                    }
                    record.overview = meta.overview
                    record.runtime = meta.runtimeMinutes.map { Double($0) * 60 }
                    record.primaryImage = TMDBImage.url(meta.stillPath, size: "w780")
                    record.thumbImage = TMDBImage.url(meta.stillPath, size: "w300")
                    record.backdropImage = series.backdropImage
                    record.placeholderURL = TMDBImage.url(meta.stillPath, size: "w92")
                    // Episode people = its guest stars (series regulars live on the series).
                    if !meta.guestStars.isEmpty {
                        record.castJSON = (try? JSONEncoder().encode(Enricher.storedCast(meta.guestStars))).flatMap { String(data: $0, encoding: .utf8) }
                    }
                    record.enrichedAt = now
                }

                if let current = existingByKey.removeValue(forKey: entry.key) {
                    var record = current
                    var changed = false
                    var didEnrich = false
                    if record.parentId != season.id || record.seasonIndex != ep.season || record.episodeIndex != ep.episode {
                        record.parentId = season.id
                        record.seriesId = series.id
                        record.seasonIndex = ep.season
                        record.episodeIndex = ep.episode
                        changed = true
                    }
                    // Cheap display heal — keep the series name (normalized) in sync; no TMDB.
                    if record.seriesTitle != series.title { record.seriesTitle = series.title; changed = true }
                    // Enrich from TMDB only when due (never enriched, or stale).
                    if needsEnrich(record), let meta = await episodeMeta() {
                        applyEpisode(&record, meta)
                        changed = true
                        didEnrich = true
                    }
                    if changed {
                        record.updatedAt = now
                        try await catalog.updateItem(record)
                        updated += 1
                    }
                    if didEnrich { await noteTVEnriched(record) }
                } else {
                    // A new episode always needs its metadata (for the name + enrichment).
                    let meta = await episodeMeta()
                    let episodeTitle = entry.title ?? meta?.name ?? ep.episodeTitle ?? "Episode \(ep.episode)"
                    var record = try await catalog.createItem(
                        type: "episode", title: episodeTitle, sourceId: source.id, sourceKey: entry.key,
                        container: entry.container, tmdbId: series.tmdbId, libraryId: tvLib,
                        parentId: season.id, year: entry.year,
                        seriesId: series.id, seriesTitle: series.title,   // display name (normalized)
                        seasonIndex: ep.season, episodeIndex: ep.episode
                    )
                    if let meta {
                        applyEpisode(&record, meta)
                        record.updatedAt = now
                        try await catalog.updateItem(record)
                        await noteTVEnriched(record)
                    }
                    added += 1
                }
            case .movie(let title, let year):
                // Collect now; reconciled as a group after the loop so multiple files
                // of the same title become one item with selectable versions.
                let groupKey = "\(HeuristicIdentifier.normalize(title))|\(year.map(String.init) ?? "")"
                movieGroups[groupKey, default: (title, year, [])].files.append(entry)
            case .extras(let info):
                // Bonus content nests under its enclosing title. A parent that
                // carries a year is a movie; otherwise it's a show (series). Resolve
                // (or create) that parent, then attach the clip to it via parentId.
                // The extras item inherits the parent's library (libraryId nil →
                // owningLibraryId walks up the parent chain).
                let parent: ItemRecord
                if info.parentYear != nil {
                    parent = try await ensureMovieParent(info.parentTitle, year: info.parentYear)
                } else {
                    parent = try await ensureSeries(info.parentTitle, year: nil)
                }
                touchedContainers.insert(parent.id)

                if var current = existingByKey.removeValue(forKey: entry.key) {
                    // Existing extra: refresh parent link / type if the structure
                    // changed (without disturbing admin-locked fields).
                    let locked = current.lockedFields()
                    let newTitle = locked.contains(LockableField.title) ? current.title : info.title
                    if current.parentId != parent.id || current.type != info.bucket.rawValue || current.title != newTitle {
                        current.parentId = parent.id
                        current.type = info.bucket.rawValue
                        current.title = newTitle
                        current.libraryId = nil
                        current.updatedAt = now
                        try await catalog.updateItem(current)
                        updated += 1
                    }
                } else {
                    _ = try await catalog.createItem(
                        type: info.bucket.rawValue, title: info.title,
                        sourceId: source.id, sourceKey: entry.key, container: entry.container,
                        tmdbId: nil, libraryId: nil, parentId: parent.id, year: nil
                    )
                    added += 1
                }
            }
        }

        // --- reconcile movie groups (one item per title+year; extra files = versions) ---
        for (_, group) in movieGroups {
            // Parse each file into a version, ordered best-first (resolution, then
            // dynamic range, then remux, then size). The first is the item's default.
            var versions = group.files.map {
                MediaVersionParser.version(key: $0.key, container: $0.container, size: $0.size)
            }
            versions.sort { MediaVersionParser.rank($0) > MediaVersionParser.rank($1) }
            let primary = versions[0]
            // Only persist a versions list when there's a real choice (≥2); a lone
            // file stays an ordinary single-file movie (versionsJSON nil). `.sortedKeys`
            // keeps the on-disk JSON canonical across platforms (Linux's JSONEncoder
            // doesn't otherwise guarantee key order).
            let desiredVersions = versions.count >= 2 ? versions : []
            let versionsJSON = try desiredVersions.isEmpty ? nil : {
                let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
                return String(data: try encoder.encode(versions), encoding: .utf8)
            }()
            let entryType = group.files.first?.type

            // Match an existing item by any of the group's file keys. The first match
            // is the canonical item to keep; any others are stale duplicates (files
            // that used to be separate tiles) and are merged away.
            let matched = group.files.compactMap { existingByKey.removeValue(forKey: $0.key) }
            if let canonical = matched.first {
                var rec = canonical
                let locked = rec.lockedFields()
                // The display title belongs to enrichment once the item is identified:
                // it normalizes a foreign-named release to TMDB's canonical name (e.g.
                // "Тачки 2" → "Cars 2"). Re-stamping the raw parsed `group.title` here
                // would clobber that on every re-scan, and enrichment then skips the
                // already-enriched row — so the canonical name only sticks if we leave an
                // enriched title alone. Stamp the parsed title only on a fresh, unlocked,
                // not-yet-enriched row.
                let newTitle = (locked.contains(LockableField.title) || rec.enrichedAt != nil) ? rec.title : group.title
                let newYear = locked.contains(LockableField.year) ? rec.year : (group.year ?? rec.year)
                let newType = entryType ?? rec.type
                // Compare versions structurally (not by JSON string): the encoder's
                // key order isn't stable across platforms, so a string compare would
                // flag a phantom change on every re-scan on Linux.
                if rec.title != newTitle || rec.year != newYear || rec.type != newType
                    || rec.sourceKey != primary.sourceKey || rec.container != primary.container
                    || rec.storedVersions() != desiredVersions {
                    rec.title = newTitle
                    rec.year = newYear
                    rec.type = newType
                    rec.sourceKey = primary.sourceKey
                    rec.container = primary.container
                    rec.versionsJSON = versionsJSON
                    rec.updatedAt = now
                    try await catalog.updateItem(rec)
                    updated += 1
                }
                for dup in matched.dropFirst() {
                    try await catalog.deleteItem(id: dup.id)
                    removed += 1
                }
            } else {
                var rec = try await catalog.createItem(
                    type: entryType ?? "movie", title: group.title,
                    sourceId: source.id, sourceKey: primary.sourceKey, container: primary.container,
                    tmdbId: nil, libraryId: movieLib, parentId: nil, year: group.year)
                if let versionsJSON {
                    rec.versionsJSON = versionsJSON
                    rec.updatedAt = now
                    try await catalog.updateItem(rec)
                }
                added += 1
            }
        }

        // Media items no longer present → removed (containers are left in place).
        for (_, stale) in existingByKey {
            try await catalog.deleteItem(id: stale.id)
            removed += 1
        }

        // Refresh container child counts.
        for containerId in touchedContainers {
            let count = try await catalog.countChildren(parentId: containerId)
            try await catalog.setChildCount(itemId: containerId, count: count)
        }

        // Movie identify + enrich (best-effort). TV (series/season/episode) is
        // already enriched inline above and reported via `noteTVEnriched`, so it's
        // excluded here — otherwise the movie pass re-touches every fresh TV row and
        // reports a spurious `.skipped`, drowning the Activity tab in skips.
        var enriched = tvEnriched
        if let enrichment {
            let candidates = try await catalog.itemsBySource(sourceId: sourceId)
                .filter { !Self.tvTypes.contains($0.type) }
            await DiagnosticsCenter.shared.enqueue(candidates.count)
            for item in candidates where await enrichment.process(item, force: false) {
                enriched += 1
            }
        }

        return IndexSummary(sourceId: sourceId, scanned: entries.count, added: added, updated: updated, removed: removed, enriched: enriched)
    }

    func scanAll() async throws -> [IndexSummary] {
        var summaries: [IndexSummary] = []
        for source in try await catalog.sources() {
            summaries.append(try await scan(sourceId: source.id))
        }
        return summaries
    }

    /// A TV episode's identity after merging hints + folder-aware parsing.
    struct EpisodeInfo { var series: String; var season: Int; var episode: Int; var episodeTitle: String?; var year: Int? }

    /// A bonus-content clip's identity: the extras type to store plus the enclosing
    /// title to nest it under. `parentYear` distinguishes a movie parent (carries a
    /// year) from a show parent (none).
    struct ExtrasInfo { var bucket: PathParser.ExtrasBucket; var title: String; var parentTitle: String; var parentYear: Int? }

    /// What an entry is, with the merged identity to store.
    enum Classified {
        case episode(EpisodeInfo)
        case movie(title: String, year: Int?)
        case extras(ExtrasInfo)
    }

    /// Classify an entry into a movie or an episode, merging the source's explicit
    /// hints (from an HTTP manifest) with folder-aware parsing of the key.
    ///
    /// Precedence: explicit manifest episode hints win; otherwise the folder-aware
    /// `PathParser` decides (an `SxxExx`/`NxNN` in the filename beats a
    /// season-folder, which beats the filename for the title).
    static func classify(_ entry: SourceEntry) -> Classified {
        // Explicit manifest episode hints (HTTP sources that pre-identify TV).
        if entry.type == "episode", let season = entry.season, let episode = entry.episode {
            let series = entry.seriesTitle ?? entry.title ?? FilenameParser.parse(entry.key).title
            return .episode(EpisodeInfo(series: series, season: season, episode: episode, episodeTitle: entry.title, year: entry.year))
        }

        switch PathParser.parse(entry.key) {
        case .episode(let series, let season, let episode, let epTitle, let year):
            return .episode(EpisodeInfo(series: series, season: season, episode: episode, episodeTitle: epTitle, year: entry.year ?? year))
        case .movie(let title, let year):
            // The manifest's title/year, when present, override the parsed ones.
            return .movie(title: entry.title ?? title, year: entry.year ?? year)
        case .extras(let bucket, let parentTitle, let parentYear, let title):
            // The manifest's title (when present) names the clip; the parent comes
            // from the folder structure (extras nest under their enclosing title).
            let clipTitle = entry.title ?? title ?? FilenameParser.parse(entry.key).title
            return .extras(ExtrasInfo(bucket: bucket, title: clipTitle, parentTitle: parentTitle, parentYear: parentYear))
        }
    }

    /// Map enrichment fields onto a record (series/season share this), skipping
    /// any field the admin has locked so manual edits survive re-enrichment.
    private func apply(_ fields: EnrichedFields, to record: inout ItemRecord, now: Double) {
        let locked = record.lockedFields()
        // Normalise the series title to TMDB's name in the server's metadata
        // language (episode names follow from the localized season fetch).
        if !locked.contains(LockableField.title), let title = fields.title, !title.isEmpty {
            record.title = title
        }
        if !locked.contains(LockableField.overview) { record.overview = fields.overview }
        if !locked.contains(LockableField.year), let year = fields.year { record.year = year }
        if !locked.contains(LockableField.genres) {
            record.genresJSON = fields.genres.isEmpty ? nil : (try? JSONEncoder().encode(fields.genres)).flatMap { String(data: $0, encoding: .utf8) }
        }
        if !locked.contains(LockableField.communityRating) { record.communityRating = fields.communityRating }
        if !locked.contains(LockableField.officialRating), let rating = fields.officialRating { record.officialRating = rating }
        if !locked.contains(LockableField.images) {
            record.primaryImage = fields.primaryImage
            record.backdropImage = fields.backdropImage
            record.thumbImage = fields.thumbImage
        }
        if !locked.contains(LockableField.placeholder) { record.placeholderURL = fields.placeholderURL }
        if !locked.contains(LockableField.cast) {
            record.castJSON = fields.cast.isEmpty ? nil : (try? JSONEncoder().encode(fields.cast)).flatMap { String(data: $0, encoding: .utf8) }
        }
        record.enrichedAt = now
    }
}

/// Result of scanning one source.
struct IndexSummary: Codable, Sendable, ResponseEncodable {
    var sourceId: String
    var scanned: Int
    var added: Int
    var updated: Int
    var removed: Int
    /// Items identified + enriched during this scan (0 if TMDB is disabled).
    var enriched: Int = 0
}

/// Result of scanning all sources.
struct IndexAllSummary: Codable, Sendable, ResponseEncodable {
    var sources: [IndexSummary]
}
