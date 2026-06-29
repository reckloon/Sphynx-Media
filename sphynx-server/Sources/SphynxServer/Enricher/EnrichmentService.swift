import Foundation
import Logging

/// Orchestrates identification + enrichment for items and persists the result.
/// Present only when TMDB is configured; the Indexer and admin endpoints call it.
struct EnrichmentService: Sendable {
    let catalog: Catalog
    let identifier: any Identifier
    let enricher: Enricher
    /// TV identify + enrich (present when TMDB is configured). Movies use
    /// `enricher`; TV (series/season/episode) routes through this.
    let tv: TVEnricher?
    /// Freshness window — enriched items aren't re-fetched until this elapses.
    let ttl: Double
    let logger: Logger

    private static let tvTypes: Set<String> = ["series", "season", "episode"]

    /// Identify (if needed) and enrich one item, persisting changes.
    /// Returns true if the item was updated. Best-effort: failures are logged,
    /// not thrown, so one bad item never aborts a scan.
    @discardableResult
    func process(_ item: ItemRecord, force: Bool) async -> Bool {
        let kind = Self.tvTypes.contains(item.type) ? "tv" : "movie"
        let token = await DiagnosticsCenter.shared.begin(itemId: item.id, title: item.title, kind: kind)
        let outcome = await runProcess(item, force: force)
        await DiagnosticsCenter.shared.finish(token, result: outcome)
        return outcome == .enriched
    }

    /// The actual identify + enrich. `process` wraps this to report activity to
    /// the diagnostics center (the web admin Activity tab).
    private func runProcess(_ item: ItemRecord, force: Bool) async -> DiagnosticsCenter.JobResult {
        let now = Date().timeIntervalSince1970

        // Already identified + still fresh: nothing to re-fetch. Reported distinctly
        // from `.skipped` (which means unidentifiable) so the Activity tab can show
        // "already complete" rather than a misleading "skipped".
        if !force, let enrichedAt = item.enrichedAt, item.tmdbId != nil, now - enrichedAt < ttl {
            return .alreadyComplete
        }

        // TV items use the TV endpoints, not the movie endpoint.
        if Self.tvTypes.contains(item.type) {
            return await processTV(item, now: now)
        }

        do {
            var updated = item

            // Resolve the TMDB id: pinned/known, else identify.
            let resolvedId: Int?
            if item.identityPinned, let existing = item.tmdbId, let value = Int(existing) {
                resolvedId = value
            } else if let existing = item.tmdbId, let value = Int(existing), !force {
                resolvedId = value
            } else if let identification = try await identifier.identify(
                title: item.title, year: item.year, type: item.type, sourceKey: item.sourceKey
            ) {
                updated.tmdbId = String(identification.tmdbId)
                updated.type = identification.type
                updated.confidence = identification.confidence
                resolvedId = identification.tmdbId
            } else {
                resolvedId = nil
            }

            guard let resolvedId else {
                // Unidentified — leave as a skeleton; a later forced run can retry.
                return .skipped
            }

            let fields = try await enricher.enrichMovie(tmdbId: resolvedId)
            apply(fields, to: &updated)
            try await linkCollection(fields.collection, to: &updated)
            updated.enrichedAt = now
            updated.updatedAt = now
            try await catalog.updateItem(updated)
            return .enriched
        } catch {
            logger.warning("Enrichment failed for item \(item.id): \(error)")
            return .failed
        }
    }

    /// Enrich a TV item (series / season / episode) via the TV endpoints, honoring
    /// admin field locks. Series resolve their own TMDB id (pinned or searched);
    /// seasons/episodes inherit the series id stored on the row.
    private func processTV(_ item: ItemRecord, now: Double) async -> DiagnosticsCenter.JobResult {
        guard let tv else { return .skipped }  // TV enrichment needs TMDB configured
        do {
            var updated = item
            switch item.type {
            case "series":
                // Resolve the series TMDB id: pinned, else known, else search.
                let resolvedId: Int?
                if item.identityPinned, let id = item.tmdbId.flatMap(Int.init) {
                    resolvedId = id
                } else if let id = item.tmdbId.flatMap(Int.init) {
                    resolvedId = id
                } else {
                    resolvedId = try await tv.identifySeries(title: item.seriesTitle ?? item.title)
                }
                guard let resolvedId else { return .skipped }
                updated.tmdbId = String(resolvedId)
                // Series fields map onto the same EnrichedFields the movie path
                // uses, so the shared `apply` honors locks identically.
                apply(try await tv.seriesFields(tmdbId: resolvedId), to: &updated)

            case "season":
                guard let seriesId = item.tmdbId.flatMap(Int.init), let season = item.seasonIndex else { return .skipped }
                let details = try await tv.season(tmdbId: seriesId, season: season)
                let locked = updated.lockedFields()
                if !locked.contains(LockableField.overview) { updated.overview = details.overview }
                if !locked.contains(LockableField.images) {
                    updated.primaryImage = TMDBImage.url(details.posterPath, size: "w500")
                    // `thumb` is the horizontal card image: a season has no landscape
                    // art of its own, so mirror the inherited show backdrop.
                    updated.thumbImage = updated.backdropImage
                }
                if !locked.contains(LockableField.placeholder) {
                    updated.placeholderURL = TMDBImage.url(details.posterPath, size: "w92")
                }

            case "episode":
                guard let seriesId = item.tmdbId.flatMap(Int.init),
                      let season = item.seasonIndex, let episode = item.episodeIndex else { return .skipped }
                let details = try await tv.season(tmdbId: seriesId, season: season)
                guard let meta = details.episodes.first(where: { $0.episodeNumber == episode }) else { return .skipped }
                let locked = updated.lockedFields()
                // Refresh the episode title from TMDB so a re-identified show's
                // episodes pick up their new names (honoring a manual title lock).
                if !locked.contains(LockableField.title), let name = meta.name, !name.isEmpty {
                    updated.title = name
                }
                if !locked.contains(LockableField.overview) { updated.overview = meta.overview }
                if !locked.contains(LockableField.runtime) { updated.runtime = meta.runtimeMinutes.map { Double($0) * 60 } }
                if !locked.contains(LockableField.images) {
                    updated.primaryImage = TMDBImage.url(meta.stillPath, size: "w780")
                    updated.thumbImage = TMDBImage.url(meta.stillPath, size: "w300")
                }
                if !locked.contains(LockableField.placeholder) {
                    updated.placeholderURL = TMDBImage.url(meta.stillPath, size: "w92")
                }
                if !locked.contains(LockableField.cast) {
                    updated.castJSON = meta.guestStars.isEmpty ? nil : Self.encode(Enricher.storedCast(meta.guestStars))
                }

            default:
                return .skipped
            }
            updated.enrichedAt = now
            updated.updatedAt = now
            try await catalog.updateItem(updated)
            return .enriched
        } catch {
            logger.warning("TV enrichment failed for item \(item.id): \(error)")
            return .failed
        }
    }

    /// Enrich every item that needs it (new or stale). Returns the count updated.
    func enrichAll(force: Bool) async throws -> Int {
        var count = 0
        for item in try await catalog.allItems() where await process(item, force: force) {
            count += 1
        }
        return count
    }

    /// Create-or-fetch the `collection` item this movie belongs to and link the
    /// movie to it via BOTH `collectionId`/`collectionTitle` AND the generic
    /// `parentId` (so `GET /v1/items?parent=<collectionId>` lists members). The
    /// collection lives in the movie's owning library; dedup is by TMDB collection
    /// id across movies. No-op when the movie isn't in a collection or has no
    /// resolvable library. Honors the `images` lock for the collection link unit
    /// is unnecessary — membership is structural, not an editable field.
    private func linkCollection(_ collection: TMDBCollection?, to item: inout ItemRecord) async throws {
        guard let collection else { return }
        guard let libraryId = try await catalog.owningLibraryId(of: item) else { return }
        let record = try await catalog.upsertCollection(
            libraryId: libraryId,
            tmdbCollectionId: collection.id,
            title: collection.name,
            primaryImage: TMDBImage.url(collection.posterPath, size: "w500"),
            backdropImage: TMDBImage.url(collection.backdropPath, size: "w1280"),
            placeholderURL: TMDBImage.url(collection.posterPath, size: "w92")
        )
        item.collectionId = record.id
        item.collectionTitle = record.title
        // The generic parent link drives `items?parent=<collectionId>` listing.
        item.parentId = record.id
    }

    private func apply(_ fields: EnrichedFields, to item: inout ItemRecord) {
        // Manual edits win: never overwrite a field the admin has locked.
        let locked = item.lockedFields()
        // Normalise the display title to TMDB's name in the server's metadata
        // language (so a foreign-named release shows in the declared language).
        if !locked.contains(LockableField.title), let title = fields.title, !title.isEmpty {
            item.title = title
        }
        if !locked.contains(LockableField.overview) { item.overview = fields.overview }
        if !locked.contains(LockableField.year), let year = fields.year { item.year = year }
        if !locked.contains(LockableField.runtime) { item.runtime = fields.runtimeSeconds }
        if !locked.contains(LockableField.genres) { item.genresJSON = Self.encode(fields.genres) }
        if !locked.contains(LockableField.communityRating) { item.communityRating = fields.communityRating }
        if !locked.contains(LockableField.officialRating), let rating = fields.officialRating { item.officialRating = rating }
        if !locked.contains(LockableField.images) {
            item.primaryImage = fields.primaryImage
            item.backdropImage = fields.backdropImage
            item.thumbImage = fields.thumbImage
            // Logo + banner artwork share the `images` lock unit.
            item.logoImage = fields.logoImage
            item.bannerImage = fields.bannerImage
        }
        if !locked.contains(LockableField.placeholder) { item.placeholderURL = fields.placeholderURL }
        if !locked.contains(LockableField.cast) { item.castJSON = Self.encode(fields.cast) }
        if !locked.contains(LockableField.trailers) {
            item.trailersJSON = fields.trailers.isEmpty ? nil : Self.encode(fields.trailers)
        }
        if !locked.contains(LockableField.tags) {
            item.tagsJSON = fields.tags.isEmpty ? nil : Self.encode(fields.tags)
        }
        // sortTitle is derived from the title, so it follows the title lock.
        if !locked.contains(LockableField.title) { item.sortTitle = fields.sortTitle }

        // Extended metadata (server-owned; projected onto the canonical Item).
        let extended = StoredExtended(
            originalTitle: fields.originalTitle,
            tagline: fields.tagline,
            status: fields.status,
            premiereDate: fields.premiereDate,
            endDate: nil,
            studios: fields.studios.isEmpty ? nil : fields.studios,
            directors: fields.directors.isEmpty ? nil : fields.directors,
            writers: fields.writers.isEmpty ? nil : fields.writers,
            countries: fields.countries.isEmpty ? nil : fields.countries,
            externalIds: fields.externalIds.isEmpty ? nil : fields.externalIds
        )
        item.extendedJSON = extended.isEmpty ? nil : Self.encode(extended)
    }

    private static func encode(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
