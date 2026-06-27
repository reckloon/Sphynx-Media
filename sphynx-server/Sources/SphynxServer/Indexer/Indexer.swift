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

    func scan(sourceId: String) async throws -> IndexSummary {
        guard let source = try await catalog.source(id: sourceId) else {
            throw SphynxError.notFound("No source '\(sourceId)'")
        }
        let driver = try drivers.makeDriver(for: source)
        let entries = try await driver.list()
        let now = Date().timeIntervalSince1970

        // Existing media items (episodes + movies) keyed by their stable
        // sourceKey. Containers (series/season, empty sourceKey) are excluded —
        // they're found via dedicated lookups so they don't collide on "".
        var existingByKey: [String: ItemRecord] = [:]
        for record in try await catalog.itemsBySource(sourceId: sourceId) where !record.sourceKey.isEmpty {
            existingByKey[record.sourceKey] = record
        }

        // Per-scan caches to dedupe containers and avoid refetching seasons.
        var seriesCache: [String: ItemRecord] = [:]                 // normalized series title
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
            if var existing = try await catalog.seriesItem(libraryId: source.libraryId ?? "", title: title) {
                // Backfill a year from the show folder when the container lacks one.
                if existing.year == nil, let year {
                    existing.year = year
                    existing.updatedAt = now
                    try await catalog.updateItem(existing)
                }
                seriesCache[cacheKey] = existing
                return existing
            }
            var record = try await catalog.createItem(
                type: "series", title: title, sourceId: source.id, sourceKey: "",
                container: nil, tmdbId: nil, libraryId: source.libraryId,
                parentId: nil, year: year, seriesTitle: title
            )
            if let tv, let tmdbId = try? await tv.identifySeries(title: title) {
                record.tmdbId = String(tmdbId)
                if let fields = try? await tv.seriesFields(tmdbId: tmdbId) {
                    apply(fields, to: &record, now: now)
                }
                record.updatedAt = now
                try await catalog.updateItem(record)
            }
            seriesCache[cacheKey] = record
            return record
        }

        func ensureSeason(series: ItemRecord, season: Int) async throws -> ItemRecord {
            let cacheKey = "\(series.id)|\(season)"
            if let cached = seasonCache[cacheKey] { return cached }
            if let existing = try await catalog.seasonItem(seriesItemId: series.id, seasonNumber: season) {
                seasonCache[cacheKey] = existing
                return existing
            }
            var record = try await catalog.createItem(
                type: "season", title: "Season \(season)", sourceId: source.id, sourceKey: "",
                container: nil, tmdbId: series.tmdbId, libraryId: source.libraryId,
                parentId: series.id, year: nil,
                seriesId: series.id, seriesTitle: series.seriesTitle ?? series.title,
                seasonIndex: season
            )
            if let tmdbId = series.tmdbId.flatMap(Int.init), let details = await cachedSeason(tmdbId: tmdbId, season: season) {
                record.primaryImage = TMDBImage.url(details.posterPath, size: "w500")
                record.thumbImage = TMDBImage.url(details.posterPath, size: "w342")
                record.placeholderURL = TMDBImage.url(details.posterPath, size: "w92")
                record.overview = details.overview
                record.enrichedAt = now
                record.updatedAt = now
                try await catalog.updateItem(record)
            }
            seasonCache[cacheKey] = record
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

                if let current = existingByKey.removeValue(forKey: entry.key) {
                    // Keep the episode's tree links correct; otherwise leave as-is.
                    if current.parentId != season.id || current.seasonIndex != ep.season || current.episodeIndex != ep.episode {
                        var record = current
                        record.parentId = season.id
                        record.seriesId = series.id
                        record.seriesTitle = series.seriesTitle ?? series.title
                        record.seasonIndex = ep.season
                        record.episodeIndex = ep.episode
                        record.updatedAt = now
                        try await catalog.updateItem(record)
                        updated += 1
                    }
                } else {
                    var record = try await catalog.createItem(
                        type: "episode", title: episodeTitle, sourceId: source.id, sourceKey: entry.key,
                        container: entry.container, tmdbId: series.tmdbId, libraryId: source.libraryId,
                        parentId: season.id, year: entry.year,
                        seriesId: series.id, seriesTitle: series.seriesTitle ?? series.title,
                        seasonIndex: ep.season, episodeIndex: ep.episode
                    )
                    if let episodeMeta {
                        record.overview = episodeMeta.overview
                        record.runtime = episodeMeta.runtimeMinutes.map { Double($0) * 60 }
                        record.primaryImage = TMDBImage.url(episodeMeta.stillPath, size: "w780")
                        record.thumbImage = TMDBImage.url(episodeMeta.stillPath, size: "w300")
                        record.placeholderURL = TMDBImage.url(episodeMeta.stillPath, size: "w92")
                        record.enrichedAt = now
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
                        tmdbId: nil, libraryId: source.libraryId, parentId: nil, year: year
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
            for item in try await catalog.itemsBySource(sourceId: sourceId)
            where await enrichment.process(item, force: false) {
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

    /// What an entry is, with the merged identity to store.
    enum Classified {
        case episode(EpisodeInfo)
        case movie(title: String, year: Int?)
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
