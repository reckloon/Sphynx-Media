import Foundation
import GRDB

/// Catalog queries supporting extras / bonus-content nesting (M8). A bonus clip
/// found under a `…/Extras/…` bucket attaches to its enclosing movie or show item
/// via `parentId`; this lookup resolves an existing *movie* parent so a curated
/// `Some Movie (2020)/Extras/clip.mkv` nests under that movie rather than spawning
/// a duplicate. (Show parents reuse the indexer's `seriesItem` lookup.)
extension Catalog {
    /// Find a flat movie item in a library by exact title, optionally constrained
    /// to a year. Used by the indexer to attach extras to their enclosing movie
    /// (and to avoid creating a duplicate placeholder when the feature is present).
    func movieItem(libraryId: String, title: String, year: Int?) async throws -> ItemRecord? {
        try await db.writer.read { db in
            var request = ItemRecord
                .filter(Column("libraryId") == libraryId && Column("type") == "movie" && Column("title") == title)
            if let year { request = request.filter(Column("year") == year) }
            return try request.fetchOne(db)
        }
    }
}
