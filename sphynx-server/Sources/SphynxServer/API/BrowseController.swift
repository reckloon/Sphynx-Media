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

        var shelves: [Shelf] = []
        // Continue Watching is landscape (backdrops/episode stills) — this is the
        // aspect the cropping bug needed stated explicitly. It carries next-up too.
        let (cont, _) = try await continuePage(identity, full: full, limit: n, offset: 0)
        if !cont.isEmpty {
            shelves.append(Shelf(id: "continue", title: "Continue Watching",
                                 kind: .continueWatching, aspect: .landscape, items: cont))
        }
        let (recent, _) = try await recentPage(identity, full: full, limit: n, offset: 0)
        if !recent.isEmpty {
            shelves.append(Shelf(id: "recent", title: "Recently Added",
                                 kind: .recentlyAdded, aspect: .portrait, items: recent))
        }
        let (favs, _) = try await favoritesPage(identity, full: full, limit: n, offset: 0)
        if !favs.isEmpty {
            shelves.append(Shelf(id: "favorites", title: "Favorites",
                                 kind: .favorites, aspect: .portrait, items: favs))
        }
        return HomeResponse(shelves: shelves)
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
        if try await catalog.library(id: parent) != nil {
            libraryId = parent
            records = try await catalog.topLevelItems(
                libraryId: parent, limit: limit, offset: offset,
                sort: sort, ascending: ascending, genre: query.genre
            )
        } else if let parentItem = try await catalog.item(id: parent) {
            libraryId = try await catalog.owningLibraryId(of: parentItem)
            records = try await catalog.childItems(parentId: parent, limit: limit, offset: offset)
        } else {
            libraryId = nil
            records = []
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
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
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
