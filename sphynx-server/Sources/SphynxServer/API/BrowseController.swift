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
        guard let userId = context.identity?.userId else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        let recent = try await playstate.recentlyPlayed(userId: userId, limit: limit + 1, offset: offset)
        let hasMore = recent.count > limit
        let page = hasMore ? Array(recent.prefix(limit)) : recent

        // Resolve to items, preserving the recency order; skip any since deleted.
        let byId = try await catalog.items(ids: page.map(\.itemId))
        let items: [Item] = page.compactMap { state in
            guard let record = byId[state.itemId] else { return nil }
            var item = record.toProtocol(full: full)
            item.resumePosition = state.position
            return item
        }

        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
    }

    @Sendable
    func libraries(_ request: Request, context: SphynxRequestContext) async throws -> LibrariesResponse {
        let records = try await catalog.libraries()
        return LibrariesResponse(libraries: records.map { $0.toProtocol() })
    }

    @Sendable
    func items(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let query = try request.uri.decodeQuery(as: ItemsQuery.self, context: context)
        guard let parent = query.parent, !parent.isEmpty else {
            throw SphynxError.badRequest("query parameter 'parent' is required")
        }
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        // `parent` is either a library (top-level items) or an item (its children).
        let records: [ItemRecord]
        if try await catalog.library(id: parent) != nil {
            records = try await catalog.topLevelItems(libraryId: parent, limit: limit, offset: offset)
        } else {
            records = try await catalog.childItems(parentId: parent, limit: limit, offset: offset)
        }

        let hasMore = records.count > limit
        let page = hasMore ? Array(records.prefix(limit)) : records

        // Fold the authenticated user's resume positions into the tiles.
        var items = page.map { $0.toProtocol(full: full) }
        if let userId = context.identity?.userId {
            let positions = try await playstate.positions(userId: userId, itemIds: items.map(\.id))
            items = items.map { item in
                var item = item
                if let position = positions[item.id], position > 0 { item.resumePosition = position }
                return item
            }
        }

        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
    }

    @Sendable
    func item(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let record = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let query = try request.uri.decodeQuery(as: DetailQuery.self, context: context)
        var item = record.toProtocol(full: query.detail == "full")
        if let userId = context.identity?.userId,
           let position = try await playstate.get(userId: userId, itemId: itemId)?.position,
           position > 0 {
            item.resumePosition = position
        }
        return item
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
