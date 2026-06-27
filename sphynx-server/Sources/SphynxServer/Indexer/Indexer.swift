import Foundation
import Hummingbird

/// Walks each source's driver to produce raw entries, then diffs against what the
/// catalog already holds to detect adds / updates / removes. Metadata-only — it
/// never touches media bytes. Identification + enrichment (TMDB) come in M4.
struct Indexer: Sendable {
    let catalog: Catalog
    let drivers: DriverFactory
    /// Present when TMDB is configured; runs identify + enrich after reconcile.
    let enrichment: EnrichmentService?

    /// Scan one source and reconcile its items.
    func scan(sourceId: String) async throws -> IndexSummary {
        guard let source = try await catalog.source(id: sourceId) else {
            throw SphynxError.notFound("No source '\(sourceId)'")
        }
        let driver = try drivers.makeDriver(for: source)
        let entries = try await driver.list()

        // Index existing items for this source by their stable sourceKey.
        var existingByKey: [String: ItemRecord] = [:]
        for record in try await catalog.itemsBySource(sourceId: sourceId) {
            existingByKey[record.sourceKey] = record
        }

        var added = 0, updated = 0
        let now = Date().timeIntervalSince1970

        for entry in entries {
            if var current = existingByKey.removeValue(forKey: entry.key) {
                // Existing item: update the hint fields if the manifest changed.
                let newTitle = entry.title ?? current.title
                let newType = entry.type ?? current.type
                if newTitle != current.title
                    || newType != current.type
                    || entry.container != current.container
                    || entry.year != current.year {
                    current.title = newTitle
                    current.type = newType
                    current.container = entry.container ?? current.container
                    current.year = entry.year ?? current.year
                    current.updatedAt = now
                    try await catalog.updateItem(current)
                    updated += 1
                }
            } else {
                // New entry → create an item in the source's library.
                _ = try await catalog.createItem(
                    type: entry.type ?? "movie",
                    title: entry.title ?? Self.titleFromKey(entry.key),
                    sourceId: source.id,
                    sourceKey: entry.key,
                    container: entry.container,
                    tmdbId: nil,
                    libraryId: source.libraryId,
                    parentId: nil,
                    year: entry.year
                )
                added += 1
            }
        }

        // Anything left in the map is no longer in the manifest → removed.
        var removed = 0
        for (_, stale) in existingByKey {
            try await catalog.deleteItem(id: stale.id)
            removed += 1
        }

        // Identify + enrich items that need it (best-effort; skips fresh ones).
        var enriched = 0
        if let enrichment {
            for item in try await catalog.itemsBySource(sourceId: sourceId)
            where await enrichment.process(item, force: false) {
                enriched += 1
            }
        }

        return IndexSummary(sourceId: sourceId, scanned: entries.count, added: added, updated: updated, removed: removed, enriched: enriched)
    }

    /// Scan every configured source.
    func scanAll() async throws -> [IndexSummary] {
        var summaries: [IndexSummary] = []
        for source in try await catalog.sources() {
            summaries.append(try await scan(sourceId: source.id))
        }
        return summaries
    }

    /// Derive a human-ish title from a key when the manifest gives none:
    /// last path component, extension stripped, separators spaced.
    static func titleFromKey(_ key: String) -> String {
        let last = key.split(separator: "/").last.map(String.init) ?? key
        let noExt = last.contains(".") ? String(last[..<last.lastIndex(of: ".")!]) : last
        let spaced = noExt.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
        return spaced.isEmpty ? key : spaced
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
