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

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("libraries", use: libraries)
        group.get("items", use: items)
        group.get("items/:itemId", use: item)
        group.get("home/continue", use: continueWatching)
    }

    /// §7 "continue watching": the user's in-progress items, most-recent first,
    /// each with `resumePosition` folded in. The server just exposes the data
    /// (ordered, paginated) — the client owns presentation and what counts as
    /// "finished" (it has each item's runtime). Cursor-paginated.
    @Sendable
    func continueWatching(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        let recent = try await playstate.recentlyPlayed(userId: identity.userId, limit: limit + 1, offset: offset)
        let hasMore = recent.count > limit
        let page = hasMore ? Array(recent.prefix(limit)) : recent

        // Resolve to items, preserving recency order; skip any since deleted or
        // the user may no longer read (per-library scoping).
        let byId = try await catalog.items(ids: page.map(\.itemId))
        var items: [Item] = []
        for state in page {
            guard let record = byId[state.itemId],
                  try await canRead(record, identity) else { continue }
            var item = record.toProtocol(full: full)
            item.resumePosition = state.position
            items.append(item)
        }

        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
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
        let records: [ItemRecord]
        let libraryId: String?
        if try await catalog.library(id: parent) != nil {
            libraryId = parent
            records = try await catalog.topLevelItems(libraryId: parent, limit: limit, offset: offset)
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
        let page = hasMore ? Array(records.prefix(limit)) : records

        // Fold the authenticated user's resume positions into the tiles.
        var items = page.map { $0.toProtocol(full: full) }
        let positions = try await playstate.positions(userId: identity.userId, itemIds: items.map(\.id))
        items = items.map { item in
            var item = item
            if let position = positions[item.id], position > 0 { item.resumePosition = position }
            return item
        }

        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
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
}

struct DetailQuery: Codable, Sendable {
    var detail: String?
}

struct ContinueQuery: Codable, Sendable {
    var detail: String?
    var limit: Int?
    var cursor: String?
}
