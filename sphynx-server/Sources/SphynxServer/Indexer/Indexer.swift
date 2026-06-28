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

        var added = 0, updated = 0

        // --- nested helpers (capture the caches above) ---

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
            if let existing = try await catalog.seriesItem(libraryId: tvLib ?? "", title: title) {
                record = existing
                if record.year == nil, let year { record.year = year; changed = true }
            } else {
                record = try await catalog.createItem(
                    type: "series", title: title, sourceId: source.id, sourceKey: "",
                    container: nil, tmdbId: nil, libraryId: tvLib,
                    parentId: nil, year: year, seriesTitle: title
                )
            }
            // Identify + enrich when not yet identified — this also heals a series
            // first scanned before TMDB was configured (re-scan fills it in).
            if record.tmdbId == nil, let tv,
               let tmdbId = try? await tv.identifySeries(title: record.seriesTitle ?? title) {
                record.tmdbId = String(tmdbId)
                if let fields = try? await tv.seriesFields(tmdbId: tmdbId) {
                    apply(fields, to: &record, now: now)
                }
                changed = true
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
                    seriesId: series.id, seriesTitle: series.seriesTitle ?? series.title,
                    seasonIndex: season
                )
            }
            // Fetch (and cache) the season details whenever the series is
            // identified, so the episode loop can read them even when the season
            // row is already enriched. Enrich the season row only when it needs it
            // (heals a season created before TMDB / before the series had an id).
            if let tmdbId = series.tmdbId.flatMap(Int.init),
               let details = await cachedSeason(tmdbId: tmdbId, season: season),
               record.primaryImage == nil {
                record.tmdbId = series.tmdbId
                record.primaryImage = TMDBImage.url(details.posterPath, size: "w500")
                record.thumbImage = TMDBImage.url(details.posterPath, size: "w342")
                record.placeholderURL = TMDBImage.url(details.posterPath, size: "w92")
                // Seasons have no backdrop of their own — inherit the show's wide
                // art so season screens have a horizontal image too.
                record.backdropImage = series.backdropImage
                record.overview = details.overview
                record.enrichedAt = now
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
            if let existing = try await catalog.movieItem(libraryId: movieLib ?? "", title: title, year: year) {
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

                var episodeMeta: TMDBEpisode?
                if let tmdbId = series.tmdbId.flatMap(Int.init) {
                    episodeMeta = seasonDetailsCache["\(tmdbId)|\(ep.season)"]?
                        .episodes.first { $0.episodeNumber == ep.episode }
                }
                let episodeTitle = entry.title ?? episodeMeta?.name ?? ep.episodeTitle ?? "Episode \(ep.episode)"

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
                    if record.parentId != season.id || record.seasonIndex != ep.season || record.episodeIndex != ep.episode {
                        record.parentId = season.id
                        record.seriesId = series.id
                        record.seriesTitle = series.seriesTitle ?? series.title
                        record.seasonIndex = ep.season
                        record.episodeIndex = ep.episode
                        changed = true
                    }
                    if record.primaryImage == nil, let episodeMeta {
                        applyEpisode(&record, episodeMeta)
                        changed = true
                    }
                    if changed {
                        record.updatedAt = now
                        try await catalog.updateItem(record)
                        updated += 1
                    }
                } else {
                    var record = try await catalog.createItem(
                        type: "episode", title: episodeTitle, sourceId: source.id, sourceKey: entry.key,
                        container: entry.container, tmdbId: series.tmdbId, libraryId: tvLib,
                        parentId: season.id, year: entry.year,
                        seriesId: series.id, seriesTitle: series.seriesTitle ?? series.title,
                        seasonIndex: ep.season, episodeIndex: ep.episode
                    )
                    if let episodeMeta {
                        applyEpisode(&record, episodeMeta)
                        record.updatedAt = now
                        try await catalog.updateItem(record)
                    }
                    added += 1
                }
            case .movie(let title, let year):
                if var current = existingByKey.removeValue(forKey: entry.key) {
                    // Existing movie: refresh source-derived fields if changed —
                    // but never overwrite a field the admin has locked.
                    let locked = current.lockedFields()
                    let newTitle = locked.contains(LockableField.title) ? current.title : title
                    let newType = entry.type ?? current.type
                    let newContainer = entry.container ?? current.container
                    let newYear = locked.contains(LockableField.year) ? current.year : (year ?? current.year)
                    if newTitle != current.title || newType != current.type
                        || newContainer != current.container || newYear != current.year {
                        current.title = newTitle
                        current.type = newType
                        current.container = newContainer
                        current.year = newYear
                        current.updatedAt = now
                        try await catalog.updateItem(current)
                        updated += 1
                    }
                } else {
                    // New movie (flat).
                    _ = try await catalog.createItem(
                        type: entry.type ?? "movie",
                        title: title,
                        sourceId: source.id, sourceKey: entry.key, container: entry.container,
                        tmdbId: nil, libraryId: movieLib, parentId: nil, year: year
                    )
                    added += 1
                }
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

        // Media items no longer present → removed (containers are left in place).
        var removed = 0
        for (_, stale) in existingByKey {
            try await catalog.deleteItem(id: stale.id)
            removed += 1
        }

        // Refresh container child counts.
        for containerId in touchedContainers {
            let count = try await catalog.countChildren(parentId: containerId)
            try await catalog.setChildCount(itemId: containerId, count: count)
        }

        // Movie identify + enrich (best-effort; skips fresh and non-movie items).
        var enriched = 0
        if let enrichment {
            let candidates = try await catalog.itemsBySource(sourceId: sourceId)
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
        if !locked.contains(LockableField.overview) { record.overview = fields.overview }
        if !locked.contains(LockableField.year), let year = fields.year { record.year = year }
        if !locked.contains(LockableField.genres) {
            record.genresJSON = fields.genres.isEmpty ? nil : (try? JSONEncoder().encode(fields.genres)).flatMap { String(data: $0, encoding: .utf8) }
        }
        if !locked.contains(LockableField.communityRating) { record.communityRating = fields.communityRating }
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
