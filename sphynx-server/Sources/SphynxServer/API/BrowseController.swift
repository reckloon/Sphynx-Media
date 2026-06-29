import Hummingbird
import SphynxProtocol

/// Implements §5 Browse: libraries and items. Behind `AuthMiddleware`.
///
/// `GET /v1/items?parent=<id>` returns the children of a container — the `parent`
/// may be a library id (top-level items) or an item id (its children). `detail`
/// selects skeleton vs full projection; results are cursor-paginated.
struct BrowseController: Sendable {
    let catalog: Catalog
    let playstate: PlaystateService
    let userState: UserStateService
    let home: HomeService
    let homeConfig: HomeConfigStore

    /// Default number of items per shelf on the aggregated home feed.
    private static let shelfLimit = 20

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("libraries", use: libraries)
        group.get("items", use: items)
        group.get("items/:itemId", use: item)
        group.get("home", use: homeFeed)
        group.get("home/continue", use: continueWatching)
        group.get("home/recent", use: recentlyAdded)
        group.get("home/favorites", use: favorites)
        group.get("home/genre", use: genreRow)
        group.get("home/decade", use: decadeRow)
        // Each signed-in user's own home layout (replaces the admin default for them).
        group.get("home/config", use: getHomeConfig)
        group.put("home/config", use: putHomeConfig)
        group.delete("home/config", use: resetHomeConfig)
        // Genres present in the catalog, to populate the user's row picker.
        group.get("home/genres", use: genresList)
    }

    /// §7 the **typed home feed**: the ordered shelves that make up a user's home
    /// screen, each tagged with its `kind` and tile `aspect` so layout (and
    /// cropping) is contract, not guesswork. Empty shelves are omitted. Shelves
    /// are not individually paginated here — fetch a full row via its own endpoint
    /// (`/home/continue`, `/home/recent`, `/home/favorites`) with a cursor.
    @Sendable
    func homeFeed(_ request: Request, context: SphynxRequestContext) async throws -> HomeResponse {
        let identity = try context.requireIdentity()
        let full = (try request.uri.decodeQuery(as: DetailQuery.self, context: context)).detail == "full"
        let n = Self.shelfLimit

        // The user's effective layout: their saved override if any, else the admin
        // default (which itself falls back to the built-in default).
        let specs = try await homeConfig.effective(userId: identity.userId)

        var shelves: [Shelf] = []
        for spec in specs where spec.enabled {
            // Build the row's first page; empty rows are omitted (existing contract).
            let items = try await rowItems(spec, identity, full: full, limit: n, offset: 0).items
            guard !items.isEmpty, let kind = ShelfKind(rawValue: spec.kind) else { continue }
            let aspect = ShelfAspect(rawValue: spec.aspect) ?? .portrait
            shelves.append(Shelf(id: spec.id, title: spec.title, kind: kind, aspect: aspect, items: items))
        }
        return HomeResponse(shelves: shelves)
    }

    /// Build one page of a configured row, dispatching on its kind. Continue
    /// Watching carries next-up; genre/decade rows query the catalog cross-library.
    private func rowItems(_ spec: HomeShelfSpec, _ identity: AuthIdentity,
                          full: Bool, limit: Int, offset: Int) async throws -> (items: [Item], hasMore: Bool) {
        switch spec.kind {
        case "continueWatching": return try await continuePage(identity, full: full, limit: limit, offset: offset)
        case "recentlyAdded":    return try await recentPage(identity, full: full, limit: limit, offset: offset)
        case "favorites":        return try await favoritesPage(identity, full: full, limit: limit, offset: offset)
        case "genre":
            guard let genre = spec.genre else { return ([], false) }
            return try await genrePage(genre, identity, full: full, limit: limit, offset: offset)
        case "releaseDecade":
            guard let decade = spec.decade else { return ([], false) }
            return try await decadePage(decade, identity, full: full, limit: limit, offset: offset)
        default:
            return ([], false)
        }
    }

    /// §7 "continue watching": the user's in-progress items **plus** the next
    /// unwatched episode of each show they've started — one unified, recency-ordered
    /// list (never a separate "Next Up"). `resumePosition` is folded in (0 for a
    /// next-up episode). The client owns presentation and what counts as "finished".
    /// Cursor-paginated.
    @Sendable
    func continueWatching(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        let (items, hasMore) = try await continuePage(identity, full: full, limit: limit, offset: offset)
        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
    }

    /// Build one page of the unified Continue Watching list (resume + next-up),
    /// filtered to items the user may read, with resume + per-user state folded in.
    private func continuePage(_ identity: AuthIdentity, full: Bool, limit: Int, offset: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let entries = try await home.continueWatching(userId: identity.userId)
        // Permission filter (per-library scoping) preserving recency order.
        var readable: [HomeService.Entry] = []
        for entry in entries where try await canRead(entry.record, identity) {
            readable.append(entry)
        }
        let hasMore = readable.count > offset + limit
        let page = Array(readable.dropFirst(offset).prefix(limit))

        var items = page.map { entry -> Item in
            var item = entry.record.toProtocol(full: full)
            if entry.position > 0 { item.resumePosition = entry.position }
            return item
        }
        let states = try await userState.states(userId: identity.userId, itemIds: items.map(\.id))
        items = items.map { var i = $0; UserStateService.fold(states[i.id], into: &i); return i }
        return (items, hasMore)
    }

    @Sendable
    func libraries(_ request: Request, context: SphynxRequestContext) async throws -> LibrariesResponse {
        let identity = try context.requireIdentity()
        // Only libraries this user may read (admins and globally-granted users
        // see all; library-scoped users see only their libraries).
        let records = try await catalog.libraries()
            .filter { identity.canReadLibrary($0.id) }
        return LibrariesResponse(libraries: records.map { $0.toProtocol() })
    }

    @Sendable
    func items(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ItemsQuery.self, context: context)
        guard let parent = query.parent, !parent.isEmpty else {
            throw SphynxError.badRequest("query parameter 'parent' is required")
        }
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        // `parent` is either a library (top-level items) or an item (its
        // children). Resolve the owning library and gate read access on it.
        // Sort + genre filter apply to a library's top level; children of an item
        // (seasons/episodes) keep their natural episode order.
        let sort = Catalog.ItemSort(rawValue: query.sort ?? "") ?? .added
        let ascending: Bool? = query.order.map { $0.lowercased() == "asc" }
        let records: [ItemRecord]
        let libraryId: String?
        // The full set the cursor paginates over, for `totalCount` (structural —
        // genre/year — not the per-user `unwatched` post-filter). nil ⇒ not computed.
        let totalCount: Int?
        if let library = try await catalog.library(id: parent) {
            libraryId = parent
            if library.kind == "collection" {
                // A `collection` library holds no items of its own — it's a
                // cross-library view of every box-set tile. Aggregate them,
                // restricted to the libraries this user may read so a box set
                // whose movies live in an off-limits library never leaks.
                let readable = Set(try await catalog.libraries()
                    .filter { identity.canReadLibrary($0.id) }
                    .map(\.id))
                records = try await catalog.allCollections(
                    inLibraries: readable, limit: limit, offset: offset,
                    sort: sort, ascending: ascending
                )
                totalCount = try await catalog.countAllCollections(inLibraries: readable)
            } else {
                records = try await catalog.topLevelItems(
                    libraryId: parent, limit: limit, offset: offset,
                    sort: sort, ascending: ascending, genre: query.genre, year: query.year
                )
                totalCount = try await catalog.countTopLevelItems(libraryId: parent, genre: query.genre, year: query.year)
            }
        } else if let parentItem = try await catalog.item(id: parent) {
            libraryId = try await catalog.owningLibraryId(of: parentItem)
            records = try await catalog.childItems(parentId: parent, limit: limit, offset: offset)
            totalCount = try await catalog.countChildren(parentId: parent)
        } else {
            libraryId = nil
            records = []
            totalCount = nil
        }
        guard identity.canReadLibrary(libraryId) else {
            throw SphynxError.forbidden("You don't have permission to browse this library")
        }

        let hasMore = records.count > limit
        var page = hasMore ? Array(records.prefix(limit)) : records

        // Optional "unwatched" filter (per-user; post-fetch).
        if query.unwatched == true {
            let watched = try await userState.watchedItemIds(userId: identity.userId)
            page = page.filter { !watched.contains($0.id) }
        }

        let items = try await foldUserData(page.map { $0.toProtocol(full: full) }, userId: identity.userId)
        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil,
            totalCount: totalCount,
            pageSize: limit
        )
    }

    /// §5 "recently added": top-level items (movies + series) newest first, with
    /// per-user state folded in. Skips libraries the user can't read.
    @Sendable
    func recentlyAdded(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)
        let (items, hasMore) = try await recentPage(identity, full: query.detail == "full", limit: limit, offset: offset)
        return ItemsResponse(items: items, nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil)
    }

    private func recentPage(_ identity: AuthIdentity, full: Bool, limit: Int, offset: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let records = try await catalog.recentItems(limit: limit + 1, offset: offset)
        let hasMore = records.count > limit
        let page = hasMore ? Array(records.prefix(limit)) : records

        var items: [Item] = []
        for record in page where try await canRead(record, identity) {
            items.append(record.toProtocol(full: full))
        }
        return (try await foldUserData(items, userId: identity.userId), hasMore)
    }

    /// The user's favourites, most-recently-played first.
    @Sendable
    func favorites(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)
        let (items, hasMore) = try await favoritesPage(identity, full: query.detail == "full", limit: limit, offset: offset)
        return ItemsResponse(items: items, nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil)
    }

    private func favoritesPage(_ identity: AuthIdentity, full: Bool, limit: Int, offset: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let ids = try await userState.favoriteItemIds(userId: identity.userId, limit: limit, offset: offset)
        let hasMore = ids.count > limit
        let page = hasMore ? Array(ids.prefix(limit)) : ids

        let byId = try await catalog.items(ids: page)
        var items: [Item] = []
        for id in page {  // preserve the favourites order
            guard let record = byId[id], try await canRead(record, identity) else { continue }
            items.append(record.toProtocol(full: full))
        }
        return (try await foldUserData(items, userId: identity.userId), hasMore)
    }

    /// A configured **genre** row: top items carrying `genre`, across all libraries
    /// the user may read, highest-rated first. Cursor-paginated ("see all").
    @Sendable
    func genreRow(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: RowQuery.self, context: context)
        guard let name = query.name, !name.isEmpty else {
            throw SphynxError.badRequest("query parameter 'name' is required")
        }
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)
        let (items, hasMore) = try await genrePage(name, identity, full: query.detail == "full", limit: limit, offset: offset)
        return ItemsResponse(items: items, nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil)
    }

    private func genrePage(_ genre: String, _ identity: AuthIdentity, full: Bool, limit: Int, offset: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let records = try await catalog.itemsByGenre(genre: genre, limit: limit + 1, offset: offset)
        return try await page(records, identity, full: full, limit: limit)
    }

    /// A configured **release-decade** row: top items released in the decade that
    /// begins at `start` (e.g. 1980 ⇒ 1980–1989), newest first. Cursor-paginated.
    @Sendable
    func decadeRow(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: RowQuery.self, context: context)
        guard let start = query.start else {
            throw SphynxError.badRequest("query parameter 'start' is required")
        }
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)
        let (items, hasMore) = try await decadePage(start, identity, full: query.detail == "full", limit: limit, offset: offset)
        return ItemsResponse(items: items, nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil)
    }

    private func decadePage(_ start: Int, _ identity: AuthIdentity, full: Bool, limit: Int, offset: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let records = try await catalog.itemsByDecade(startYear: start, limit: limit + 1, offset: offset)
        return try await page(records, identity, full: full, limit: limit)
    }

    /// Shared paging tail for cross-library rows: take a `limit + 1` fetch,
    /// permission-filter, project, and fold per-user state. Like `recentPage`,
    /// `hasMore` reflects the raw fetch before the read-permission filter.
    private func page(_ records: [ItemRecord], _ identity: AuthIdentity, full: Bool, limit: Int)
        async throws -> (items: [Item], hasMore: Bool) {
        let hasMore = records.count > limit
        let slice = hasMore ? Array(records.prefix(limit)) : records
        var items: [Item] = []
        for record in slice where try await canRead(record, identity) {
            items.append(record.toProtocol(full: full))
        }
        return (try await foldUserData(items, userId: identity.userId), hasMore)
    }

    // MARK: - Per-user home layout

    /// The signed-in user's effective home layout (their saved override, or the
    /// admin default if they haven't customized) plus whether it is customized.
    @Sendable
    func getHomeConfig(_ request: Request, context: SphynxRequestContext) async throws -> HomeConfigResponse {
        let identity = try context.requireIdentity()
        let mine = try await homeConfig.userShelves(userId: identity.userId)
        let effective: [HomeShelfSpec]
        if let mine { effective = mine } else { effective = try await homeConfig.defaultShelves() }
        return HomeConfigResponse(shelves: effective.map(HomeShelfDTO.init), customized: mine != nil)
    }

    /// Save the user's own home layout (replaces the admin default for them).
    @Sendable
    func putHomeConfig(_ request: Request, context: SphynxRequestContext) async throws -> HomeConfigResponse {
        let identity = try context.requireIdentity()
        let body = try await request.decode(as: HomeConfigRequest.self, context: context)
        try await homeConfig.setUserShelves(userId: identity.userId, body.shelves.map(\.spec))
        let saved = try await homeConfig.userShelves(userId: identity.userId) ?? []
        return HomeConfigResponse(shelves: saved.map(HomeShelfDTO.init), customized: true)
    }

    /// Reset the user's home layout back to the admin default.
    @Sendable
    func resetHomeConfig(_ request: Request, context: SphynxRequestContext) async throws -> HomeConfigResponse {
        let identity = try context.requireIdentity()
        try await homeConfig.clearUserShelves(userId: identity.userId)
        let effective = try await homeConfig.defaultShelves()
        return HomeConfigResponse(shelves: effective.map(HomeShelfDTO.init), customized: false)
    }

    /// Genres present in the catalog — to populate the user's row picker.
    @Sendable
    func genresList(_ request: Request, context: SphynxRequestContext) async throws -> GenresResponse {
        _ = try context.requireIdentity()
        return GenresResponse(genres: try await catalog.distinctGenres())
    }

    /// Fold the user's resume position + watched/favorite/play-count onto a page.
    private func foldUserData(_ items: [Item], userId: String) async throws -> [Item] {
        let ids = items.map(\.id)
        let positions = try await playstate.positions(userId: userId, itemIds: ids)
        let states = try await userState.states(userId: userId, itemIds: ids)
        return items.map { item in
            var item = item
            if let position = positions[item.id], position > 0 { item.resumePosition = position }
            UserStateService.fold(states[item.id], into: &item)
            return item
        }
    }

    @Sendable
    func item(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let record = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        guard try await canRead(record, identity) else {
            throw SphynxError.forbidden("You don't have permission to view this item")
        }
        let query = try request.uri.decodeQuery(as: DetailQuery.self, context: context)
        var item = record.toProtocol(full: query.detail == "full")
        if let position = try await playstate.get(userId: identity.userId, itemId: itemId)?.position,
           position > 0 {
            item.resumePosition = position
        }
        UserStateService.fold(try await userState.get(userId: identity.userId, itemId: itemId), into: &item)
        return item
    }

    /// Whether the user may read an item, honoring per-library scoping.
    private func canRead(_ record: ItemRecord, _ identity: AuthIdentity) async throws -> Bool {
        if identity.isAdmin { return true }
        let libraryId = try await catalog.owningLibraryId(of: record)
        return identity.canReadLibrary(libraryId)
    }
}

// MARK: - Query DTOs

struct ItemsQuery: Codable, Sendable {
    var parent: String?
    var detail: String?
    var limit: Int?
    var cursor: String?
    /// Sort a library's top level: `added` (default) | `name` | `rating`.
    var sort: String?
    /// `asc` | `desc`; default depends on the sort (name asc, added/rating desc).
    var order: String?
    /// Filter a library's top level to items carrying this genre.
    var genre: String?
    /// Filter a library's top level to items of this release year.
    var year: Int?
    /// Filter out items the user has marked watched.
    var unwatched: Bool?
}

struct DetailQuery: Codable, Sendable {
    var detail: String?
}

struct ContinueQuery: Codable, Sendable {
    var detail: String?
    var limit: Int?
    var cursor: String?
}

/// Query for the parameterized "see all" rows (`/home/genre`, `/home/decade`).
struct RowQuery: Codable, Sendable {
    var detail: String?
    var limit: Int?
    var cursor: String?
    /// Genre name, for `/home/genre`.
    var name: String?
    /// Decade start year (e.g. 1980), for `/home/decade`.
    var start: Int?
}

// MARK: - Home-config wire types

/// One row in a home-layout payload — the wire shape of `HomeShelfSpec`.
struct HomeShelfDTO: Codable, Sendable {
    var id: String
    var kind: String
    var title: String
    var genre: String?
    var decade: Int?
    var aspect: String
    var enabled: Bool

    init(_ spec: HomeShelfSpec) {
        id = spec.id; kind = spec.kind; title = spec.title
        genre = spec.genre; decade = spec.decade; aspect = spec.aspect; enabled = spec.enabled
    }

    /// Back to the persisted spec; `sanitized()` on the store side drops anything
    /// malformed, so this is a straight projection.
    var spec: HomeShelfSpec {
        HomeShelfSpec(id: id, kind: kind, title: title,
                      genre: genre, decade: decade, aspect: aspect, enabled: enabled)
    }
}

/// `GET/PUT/DELETE /v1/home/config` response: the effective layout + whether the
/// user has customized it (so the GUI can show "Reset to default" only when apt).
struct HomeConfigResponse: Codable, Sendable, ResponseEncodable {
    var shelves: [HomeShelfDTO]
    var customized: Bool
}

/// `PUT /v1/home/config` body — the user's chosen rows, in order.
struct HomeConfigRequest: Codable, Sendable {
    var shelves: [HomeShelfDTO]
}

/// `GET /v1/home/genres` response: distinct genres present in the catalog.
struct GenresResponse: Codable, Sendable, ResponseEncodable {
    var genres: [String]
}
