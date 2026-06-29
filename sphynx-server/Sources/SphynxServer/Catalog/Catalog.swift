import Foundation
import GRDB
import SphynxProtocol

/// The queryable item/source store the API reads from: libraries, items, their
/// identity, and parent/child structure. Backed by SQLite (GRDB).
struct Catalog: Sendable {
    let db: AppDatabase

    // MARK: Libraries

    func createLibrary(title: String, kind: String) async throws -> LibraryRecord {
        let record = LibraryRecord(
            id: Tokens.newID("lib_"),
            title: title,
            kind: kind,
            createdAt: Date().timeIntervalSince1970
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    func libraries() async throws -> [LibraryRecord] {
        try await db.writer.read { db in
            try LibraryRecord.order(Column("createdAt"), Column("id")).fetchAll(db)
        }
    }

    func library(id: String) async throws -> LibraryRecord? {
        try await db.writer.read { db in try LibraryRecord.filter(Column("id") == id).fetchOne(db) }
    }

    /// Update a library's editable fields (only non-nil arguments are applied).
    /// `collectionThreshold` is clamped to `>= 0`.
    func updateLibrary(
        id: String, title: String?, kind: String?, collectionThreshold: Int? = nil
    ) async throws -> LibraryRecord {
        let updated: LibraryRecord? = try await db.writer.write { db in
            guard var lib = try LibraryRecord.filter(Column("id") == id).fetchOne(db) else { return nil }
            if let title, !title.isEmpty { lib.title = title }
            if let kind { lib.kind = kind }
            if let collectionThreshold { lib.collectionThreshold = max(0, collectionThreshold) }
            try lib.update(db)
            return lib
        }
        guard let updated else { throw SphynxError.notFound("No library '\(id)'") }
        return updated
    }

    /// Delete a library and **cascade**: every item it holds (the whole tree), then
    /// unbind it from any source that feeds it — deleting a source only if that
    /// leaves it feeding no library at all (a source that also feeds another
    /// library survives, with this library removed from its routing).
    func deleteLibrary(id: String) async throws {
        let now = Date().timeIntervalSince1970
        let existed: Bool = try await db.writer.write { db in
            guard try LibraryRecord.filter(Column("id") == id).fetchCount(db) > 0 else { return false }
            // Items carry their resolved libraryId, so this removes the whole tree.
            // Capture the exact removed ids first so each gets a tombstone.
            let removedIds = try ItemRecord
                .filter(Column("libraryId") == id)
                .select(Column("id"), as: String.self)
                .fetchAll(db)
            try ItemRecord.filter(Column("libraryId") == id).deleteAll(db)
            try Self.recordTombstones(removedIds, at: now, in: db)

            for var source in try SourceRecord.fetchAll(db) {
                var changed = false
                if source.libraryId == id { source.libraryId = nil; changed = true }
                let map = source.libraryMap()
                let pruned = map.filter { $0.value != id }
                if pruned.count != map.count {
                    source.libraryMapJSON = pruned.isEmpty ? nil : Self.encodeStringMap(pruned)
                    changed = true
                }
                guard changed else { continue }
                if source.feedsLibraries().isEmpty {
                    try SourceRecord.deleteOne(db, key: source.id)
                } else {
                    try source.update(db)
                }
            }
            _ = try LibraryRecord.deleteOne(db, key: id)
            return true
        }
        guard existed else { throw SphynxError.notFound("No library '\(id)'") }
    }

    // MARK: Sources

    func createSource(
        label: String,
        driver: String,
        baseURL: String?,
        headers: [String: String]?,
        libraryId: String?,
        manifestURL: String?,
        config: [String: String]? = nil,
        secrets: [String: String]? = nil,
        libraryMap: [String: String]? = nil,
        refreshInterval: Double = 0
    ) async throws -> SourceRecord {
        let record = SourceRecord(
            id: Tokens.newID("src_"),
            label: label,
            driver: driver,
            baseURL: baseURL,
            headersJSON: Self.encodeStringMap(headers),
            libraryId: libraryId,
            manifestURL: manifestURL,
            configJSON: Self.encodeStringMap(config),
            secretsJSON: Self.encodeStringMap(secrets),
            libraryMapJSON: Self.encodeStringMap(libraryMap),
            createdAt: Date().timeIntervalSince1970,
            refreshInterval: max(0, refreshInterval)
        )
        try await db.writer.write { db in try record.insert(db) }
        return record
    }

    /// Sources due for an auto-refresh: `refreshInterval > 0` and the interval has
    /// elapsed since the last scan (or never scanned).
    func dueSources(now: Double) async throws -> [SourceRecord] {
        try await db.writer.read { db in
            try SourceRecord
                .filter(Column("refreshInterval") > 0)
                .filter(sql: "COALESCE(lastScannedAt, 0) + refreshInterval <= ?", arguments: [now])
                .fetchAll(db)
        }
    }

    /// Record that a source was just scanned (for the auto-refresh scheduler).
    func markSourceScanned(id: String, at now: Double = Date().timeIntervalSince1970) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE source SET lastScannedAt = ? WHERE id = ?", arguments: [now, id])
        }
    }

    /// Encode a non-empty string map to JSON text (nil when empty/absent).
    private static func encodeStringMap(_ map: [String: String]?) -> String? {
        guard let map, !map.isEmpty else { return nil }
        return (try? JSONEncoder().encode(map)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func source(id: String) async throws -> SourceRecord? {
        try await db.writer.read { db in try SourceRecord.filter(Column("id") == id).fetchOne(db) }
    }

    func sources() async throws -> [SourceRecord] {
        try await db.writer.read { db in try SourceRecord.order(Column("createdAt")).fetchAll(db) }
    }

    /// Update a source's editable fields (only non-nil arguments are applied).
    /// `config`/`secrets`/`headers` replace the stored maps wholesale when given.
    func updateSource(
        id: String,
        label: String?,
        baseURL: String?,
        headers: [String: String]?,
        manifestURL: String?,
        libraryId: String?,
        config: [String: String]?,
        secrets: [String: String]?,
        libraryMap: [String: String]?,
        refreshInterval: Double? = nil
    ) async throws -> SourceRecord {
        let updated: SourceRecord? = try await db.writer.write { db in
            guard var s = try SourceRecord.filter(Column("id") == id).fetchOne(db) else { return nil }
            if let label, !label.isEmpty { s.label = label }
            if let baseURL { s.baseURL = baseURL }
            if let headers { s.headersJSON = Self.encodeStringMap(headers) }
            if let manifestURL { s.manifestURL = manifestURL }
            if let libraryId { s.libraryId = libraryId }
            if let config { s.configJSON = Self.encodeStringMap(config) }
            if let secrets { s.secretsJSON = Self.encodeStringMap(secrets) }
            if let libraryMap { s.libraryMapJSON = Self.encodeStringMap(libraryMap) }
            if let refreshInterval { s.refreshInterval = max(0, refreshInterval) }
            try s.update(db)
            return s
        }
        guard let updated else { throw SphynxError.notFound("No source '\(id)'") }
        return updated
    }

    /// Delete a source and **cascade**: the items it produced, then any series/
    /// season containers those items leave empty, then the source row.
    func deleteSource(id: String) async throws {
        let items = try await itemsBySource(sourceId: id)
        let parentIds = Set(items.compactMap(\.parentId))
        let removedIds = items.map(\.id)
        let now = Date().timeIntervalSince1970
        let existed: Bool = try await db.writer.write { db in
            guard try SourceRecord.filter(Column("id") == id).fetchCount(db) > 0 else { return false }
            try ItemRecord.filter(Column("sourceId") == id).deleteAll(db)
            try Self.recordTombstones(removedIds, at: now, in: db)
            _ = try SourceRecord.deleteOne(db, key: id)
            return true
        }
        guard existed else { throw SphynxError.notFound("No source '\(id)'") }
        try await pruneEmptyContainers(seeds: parentIds)
    }

    // MARK: Items

    func createItem(
        type: String,
        title: String,
        sourceId: String?,
        sourceKey: String,
        container: String?,
        tmdbId: String?,
        libraryId: String? = nil,
        parentId: String? = nil,
        year: Int? = nil,
        seriesId: String? = nil,
        seriesTitle: String? = nil,
        seasonIndex: Int? = nil,
        episodeIndex: Int? = nil,
        extra: [String: JSONValue]? = nil
    ) async throws -> ItemRecord {
        if let sourceId, try await source(id: sourceId) == nil {
            throw SphynxError.badRequest("No source '\(sourceId)'")
        }
        let now = Date().timeIntervalSince1970
        let extraJSON: String? = try extra.flatMap { value in
            value.isEmpty ? nil : String(data: try JSONEncoder().encode(value), encoding: .utf8)
        }
        let record = ItemRecord(
            id: Tokens.newID("it_"),
            type: type,
            title: title,
            sourceId: sourceId,
            sourceKey: sourceKey,
            container: container,
            tmdbId: tmdbId,
            libraryId: libraryId,
            parentId: parentId,
            year: year,
            createdAt: now,
            updatedAt: now,
            seriesId: seriesId,
            seriesTitle: seriesTitle,
            seasonIndex: seasonIndex,
            episodeIndex: episodeIndex,
            identityPinned: false,
            extraJSON: extraJSON
        )
        try await db.writer.write { db in try record.insert(db) }
        // No tombstone to clear: `createItem` always mints a brand-new id
        // (`Tokens.newID`), so a re-added item never reuses a deleted id and can't
        // collide with an existing tombstone. Tombstones are keyed by the (unique,
        // never-reused) item id and simply accumulate for the changes feed.
        return record
    }

    /// Upsert deletion tombstones for the given item ids within a write
    /// transaction (one row per id, `deletedAt = now`). Records exactly the ids
    /// passed — callers compute the precise set of rows actually removed.
    static func recordTombstones(_ ids: some Collection<String>, at now: Double, in db: Database) throws {
        for id in ids {
            try TombstoneRecord(itemId: id, deletedAt: now).upsert(db)
        }
    }

    /// Find a series container by its parsed name (for indexer dedup). Matches on
    /// `seriesTitle` — the stable name the parser derives from the filename — NOT the
    /// display `title`, which enrichment rewrites to TMDB's canonical name. When the
    /// parsed name differs from the canonical one (a foreign-language or abbreviated
    /// folder, e.g. "Тед Лассо" → "Ted Lasso"), a `title` match would miss the
    /// already-enriched row every re-scan and recreate the whole subtree. Also
    /// library-agnostic: an unmapped source stores a NULL `libraryId`, so scoping the
    /// match to a library (`libraryId = ''`) would never match those rows either.
    func seriesItem(title: String) async throws -> ItemRecord? {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("type") == "series" && Column("seriesTitle") == title)
                .fetchOne(db)
        }
    }

    /// Find a season container under a series by its season number.
    func seasonItem(seriesItemId: String, seasonNumber: Int) async throws -> ItemRecord? {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == seriesItemId && Column("type") == "season" && Column("seasonIndex") == seasonNumber)
                .fetchOne(db)
        }
    }

    /// Count an item's direct children (seasons of a series, episodes of a season).
    func countChildren(parentId: String) async throws -> Int {
        try await db.writer.read { db in
            try ItemRecord.filter(Column("parentId") == parentId).fetchCount(db)
        }
    }

    /// Persist a container's child count.
    func setChildCount(itemId: String, count: Int) async throws {
        try await db.writer.write { db in
            _ = try ItemRecord
                .filter(Column("id") == itemId)
                .updateAll(db, Column("childCount").set(to: count))
        }
    }

    func item(id: String) async throws -> ItemRecord? {
        try await db.writer.read { db in try ItemRecord.filter(Column("id") == id).fetchOne(db) }
    }

    /// The library an item belongs to. Seasons/episodes inherit their series'
    /// library, so walk up the parent chain when the item carries no `libraryId`
    /// of its own. Returns nil for an orphaned/self-contained item.
    func owningLibraryId(of item: ItemRecord) async throws -> String? {
        if let libraryId = item.libraryId { return libraryId }
        var current = item
        var hops = 0
        while let parentId = current.parentId, hops < 8 {
            guard let parent = try await self.item(id: parentId) else { return nil }
            if let libraryId = parent.libraryId { return libraryId }
            current = parent
            hops += 1
        }
        return nil
    }

    /// How a library's top level is sorted.
    enum ItemSort: String, Sendable { case added, name, rating }

    /// Top-level items of a library (no parent), with optional sort + genre filter.
    /// Fetches `limit + 1` so the caller can tell whether another page exists.
    ///
    /// Collection grouping is resolved here per the library's `collectionThreshold`:
    /// a `collection` tile appears only when it has at least that many present
    /// members. Below the threshold the tile is hidden and its member movies are
    /// surfaced individually at the top level — so raising the threshold ungroups
    /// small box sets without any re-indexing. Threshold `<= 1` is the historical
    /// "group everything" behavior (no extra query work).
    func topLevelItems(
        libraryId: String, limit: Int, offset: Int,
        sort: ItemSort = .added, ascending: Bool? = nil, genre: String? = nil, year: Int? = nil
    ) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            var request = try Self.topLevelRequest(db, libraryId: libraryId, genre: genre, year: year)
            // name defaults ascending; added/rating default descending (newest /
            // highest first). `dir` is a fixed literal — never user input.
            let dir = (ascending ?? (sort == .name)) ? "ASC" : "DESC"
            switch sort {
            case .added:  request = request.order(sql: "createdAt \(dir), id")
            case .name:   request = request.order(sql: "title COLLATE NOCASE \(dir), id")
            case .rating: request = request.order(sql: "communityRating \(dir), id")
            }
            return try request.limit(limit + 1, offset: offset).fetchAll(db)
        }
    }

    /// Count of a library's top level matching the structural filters (genre/year),
    /// i.e. the full set `topLevelItems` paginates — for `ItemsResponse.totalCount`.
    /// Independent of pagination and of the per-user `unwatched` view-filter.
    func countTopLevelItems(libraryId: String, genre: String? = nil, year: Int? = nil) async throws -> Int {
        try await db.writer.read { db in
            try Self.topLevelRequest(db, libraryId: libraryId, genre: genre, year: year).fetchCount(db)
        }
    }

    /// Every `collection`-typed tile across the given libraries — the aggregate
    /// feed for a `kind:"collection"` library, which holds no items of its own
    /// (box-set tiles live in the library their movies came from). `inLibraries`
    /// is the caller's readable set, so a collection whose films sit in an
    /// off-limits library never surfaces. Sorted like a normal top level and
    /// fetched `limit + 1` so the caller can tell whether another page exists.
    /// Genre/year don't apply to a box-set tile, so they're intentionally omitted.
    func allCollections(
        inLibraries libraries: Set<String>, limit: Int, offset: Int,
        sort: ItemSort = .added, ascending: Bool? = nil
    ) async throws -> [ItemRecord] {
        guard !libraries.isEmpty else { return [] }
        return try await db.writer.read { db in
            var request = ItemRecord
                .filter(Column("type") == "collection")
                .filter(libraries.contains(Column("libraryId")))
            // Mirror `topLevelItems`: name defaults ascending; added/rating descending.
            let dir = (ascending ?? (sort == .name)) ? "ASC" : "DESC"
            switch sort {
            case .added:  request = request.order(sql: "createdAt \(dir), id")
            case .name:   request = request.order(sql: "title COLLATE NOCASE \(dir), id")
            case .rating: request = request.order(sql: "communityRating \(dir), id")
            }
            return try request.limit(limit + 1, offset: offset).fetchAll(db)
        }
    }

    /// Count of every `collection` tile across `inLibraries` — the full set
    /// `allCollections` paginates, for `ItemsResponse.totalCount`.
    func countAllCollections(inLibraries libraries: Set<String>) async throws -> Int {
        guard !libraries.isEmpty else { return 0 }
        return try await db.writer.read { db in
            try ItemRecord
                .filter(Column("type") == "collection")
                .filter(libraries.contains(Column("libraryId")))
                .fetchCount(db)
        }
    }

    /// The top-level browse filter — collection threshold + optional genre/year —
    /// without ordering or pagination. Shared by `topLevelItems` (adds sort + limit)
    /// and `countTopLevelItems` (counts) so the two never diverge. Static so it has
    /// no actor isolation and runs inside a database read closure.
    private static func topLevelRequest(
        _ db: Database, libraryId: String, genre: String?, year: Int?
    ) throws -> QueryInterfaceRequest<ItemRecord> {
        let threshold = try Int.fetchOne(
            db, sql: "SELECT collectionThreshold FROM library WHERE id = ?", arguments: [libraryId]
        ) ?? 1

        var request: QueryInterfaceRequest<ItemRecord>
        if threshold > 1 {
            // Sub-threshold collections (too few present members to group). A
            // collection's member count is the number of items parented to it.
            let subThreshold = """
                SELECT c.id FROM item c
                WHERE c.libraryId = :lib AND c.type = 'collection'
                  AND (SELECT COUNT(*) FROM item m WHERE m.parentId = c.id) < :thr
                """
            // Top level = the usual roots minus hidden collection tiles, plus the
            // orphaned members of those hidden collections.
            request = ItemRecord
                .filter(Column("libraryId") == libraryId)
                .filter(sql: """
                    (parentId IS NULL AND NOT (type = 'collection' AND id IN (\(subThreshold))))
                    OR parentId IN (\(subThreshold))
                    """, arguments: ["lib": libraryId, "thr": threshold])
        } else {
            request = ItemRecord.filter(Column("libraryId") == libraryId && Column("parentId") == nil)
        }
        if let genre, !genre.isEmpty {
            // genresJSON is a JSON array of strings, e.g. ["Action","Drama"].
            request = request.filter(sql: "genresJSON LIKE ?", arguments: ["%\"\(genre)\"%"])
        }
        if let year {
            request = request.filter(Column("year") == year)
        }
        return request
    }

    /// Top-level items across all libraries, newest first — the "Recently Added"
    /// feed. The caller filters by readability + folds per-user state.
    ///
    /// Collection grouping is honored **per library**, exactly as `topLevelItems`
    /// does for a single library: a `collection` tile that has fewer present members
    /// than its owning library's `collectionThreshold` is hidden, and those member
    /// movies/series surface individually instead. So "Recently Added" shows the same
    /// effective top level a user sees when browsing — a small (sub-threshold) box set
    /// never appears as a one-item tile here while showing ungrouped in the library.
    func recentItems(limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            // Collections below their own library's threshold, across all libraries
            // (the library join supplies each collection's own threshold).
            let subThreshold = """
                SELECT c.id FROM item c
                JOIN library l ON l.id = c.libraryId
                WHERE c.type = 'collection'
                  AND (SELECT COUNT(*) FROM item m WHERE m.parentId = c.id) < l.collectionThreshold
                """
            return try ItemRecord
                .filter(sql: """
                    (parentId IS NULL AND NOT (type = 'collection' AND id IN (\(subThreshold))))
                    OR parentId IN (\(subThreshold))
                    """)
                .order(Column("createdAt").desc, Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Top-level items across **all** libraries carrying `genre`, highest-rated
    /// first (then newest). Powers a configurable "genre" home row; the caller
    /// filters by readability + folds per-user state. Fetches `limit + 1` so the
    /// caller can tell whether another page exists.
    func itemsByGenre(genre: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        guard !genre.isEmpty else { return [] }
        return try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == nil)
                // genresJSON is a JSON array of strings, e.g. ["Action","Drama"].
                .filter(sql: "genresJSON LIKE ?", arguments: ["%\"\(genre)\"%"])
                .order(Column("communityRating").desc, Column("createdAt").desc, Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Top-level items released in the decade beginning `startYear` (e.g. 1980 ⇒
    /// 1980–1989), newest first. Powers a configurable "release decade" home row.
    func itemsByDecade(startYear: Int, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == nil)
                .filter(Column("year") >= startYear && Column("year") <= startYear + 9)
                .order(Column("createdAt").desc, Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Distinct genres present across the catalog, alphabetically — to populate the
    /// admin/user home-row genre picker. Uses SQLite's JSON1 `json_each` to unnest
    /// the per-item `genresJSON` arrays.
    func distinctGenres() async throws -> [String] {
        try await db.writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT value FROM item, json_each(item.genresJSON)
                WHERE item.genresJSON IS NOT NULL AND TRIM(value) <> ''
                ORDER BY value COLLATE NOCASE
                """)
        }
    }

    /// Children of a parent item, ordered for display: seasons by season number,
    /// episodes by episode number, falling back to insertion order.
    func childItems(parentId: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("parentId") == parentId)
                .order(Column("seasonIndex"), Column("episodeIndex"), Column("createdAt"), Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// A library's top level **without** collection grouping — the raw file-tree
    /// view used by the admin item-correction browser. Unlike `topLevelItems`,
    /// this never hides a collection's members behind a box-set tile: collection
    /// containers appear as their own (openable) rows and standalone movies appear
    /// individually, so what you browse maps 1-to-1 onto the indexed source tree.
    func rawTopLevel(libraryId: String, limit: Int, offset: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("libraryId") == libraryId && Column("parentId") == nil)
                .order(Column("sortTitle"), Column("title"), Column("id"))
                .limit(limit + 1, offset: offset)
                .fetchAll(db)
        }
    }

    /// Every episode of a series (across all its seasons), ordered by
    /// (season, episode) then insertion — the natural play order. Used to compute
    /// "next up" (the next unwatched episode) for the unified Continue Watching row.
    func episodes(seriesId: String) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord
                .filter(Column("type") == "episode" && Column("seriesId") == seriesId)
                .order(Column("seasonIndex"), Column("episodeIndex"), Column("createdAt"), Column("id"))
                .fetchAll(db)
        }
    }

    // MARK: Indexer support

    func itemsBySource(sourceId: String) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            try ItemRecord.filter(Column("sourceId") == sourceId).fetchAll(db)
        }
    }

    /// Catalog-wide search for the admin correction browser: an optional
    /// case-insensitive title substring and/or "needs metadata" filter (unenriched,
    /// excluding the extra kinds that never enrich). Ordered for a stable, readable
    /// list. The caller is responsible for permission-filtering by owning library.
    func searchItems(titleQuery: String?, unenrichedOnly: Bool, limit: Int) async throws -> [ItemRecord] {
        try await db.writer.read { db in
            var request = ItemRecord.all()
            if let q = titleQuery, !q.isEmpty {
                request = request.filter(sql: "title LIKE ? COLLATE NOCASE", arguments: ["%\(q)%"])
            }
            if unenrichedOnly {
                let neverEnrich = ["trailer", "featurette", "deletedScene", "behindTheScenes"]
                request = request
                    .filter(Column("enrichedAt") == nil)
                    .filter(!neverEnrich.contains(Column("type")))
            }
            return try request
                .order(Column("type"), Column("sortTitle"), Column("title"), Column("id"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func allItems() async throws -> [ItemRecord] {
        try await db.writer.read { db in try ItemRecord.fetchAll(db) }
    }

    /// Fetch several items by id, keyed by id (missing ids simply absent).
    func items(ids: [String]) async throws -> [String: ItemRecord] {
        guard !ids.isEmpty else { return [:] }
        let records = try await db.writer.read { db in
            try ItemRecord.filter(ids.contains(Column("id"))).fetchAll(db)
        }
        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    func updateItem(_ record: ItemRecord) async throws {
        try await db.writer.write { db in try record.update(db) }
    }

    func deleteItem(id: String) async throws {
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            // Record a tombstone only when a row was actually removed.
            if try ItemRecord.deleteOne(db, key: id) {
                try Self.recordTombstones([id], at: now, in: db)
            }
        }
    }

    /// Delete an item and **cascade**: its whole subtree (a series takes its
    /// seasons + episodes), then prune any container the deletion leaves empty
    /// up the parent chain. Throws `notFound` if the item doesn't exist.
    func deleteItemTree(id: String) async throws {
        guard let item = try await item(id: id) else {
            throw SphynxError.notFound("No item '\(id)'")
        }
        // Collect the subtree (self + descendants) by walking parentId levels.
        var toDelete: [String] = []
        var frontier: [String] = [id]
        while !frontier.isEmpty {
            toDelete.append(contentsOf: frontier)
            let level = frontier
            let children = try await db.writer.read { db in
                try ItemRecord.filter(level.contains(Column("parentId"))).fetchAll(db)
            }
            frontier = children.map(\.id)
        }
        let ids = toDelete
        let now = Date().timeIntervalSince1970
        try await db.writer.write { db in
            _ = try ItemRecord.filter(ids.contains(Column("id"))).deleteAll(db)
            // One tombstone per removed id (self + descendants).
            try Self.recordTombstones(ids, at: now, in: db)
        }
        if let parentId = item.parentId {
            try await pruneEmptyContainers(seeds: [parentId])
        }
    }

    /// Remove series/season/collection containers left with no children, bubbling
    /// up the parent chain (deleting a season may empty its series). Containers
    /// carry an empty `sourceKey`, so they're never playable on their own — and a
    /// `collection` has no `sourceId`, so a `deleteSource` cascade reaches it only
    /// through this prune (seeded by its members' `parentId`), preventing an
    /// orphaned, member-less box-set tile.
    func pruneEmptyContainers(seeds: Set<String>) async throws {
        var frontier = seeds
        while !frontier.isEmpty {
            var next: Set<String> = []
            for containerId in frontier {
                guard let container = try await item(id: containerId),
                      container.type == "series" || container.type == "season"
                        || container.type == "collection"
                else { continue }
                if try await countChildren(parentId: containerId) == 0 {
                    if let parentId = container.parentId { next.insert(parentId) }
                    try await deleteItem(id: containerId)
                }
            }
            frontier = next
        }
    }
}
