import Foundation
import Hummingbird
import SphynxProtocol

/// Implements the incremental **changes feed**: `GET /v1/changes?since=…`.
/// Behind `AuthMiddleware`.
///
/// Returns the items whose client-rendered data changed after `since` (permission-
/// filtered to libraries the caller can read), the deletion `tombstones` in the
/// same window (ids only — the item is gone, so it can't be permission-checked),
/// and `until` = the server's clock now, which the client passes as its next
/// `since` to form a gap-free cursor loop. `changes` are cursor-paginated within a
/// single `since` window via `cursor`/`nextCursor`.
struct ChangesController: Sendable {
    let catalog: Catalog
    let playstate: PlaystateService
    let userState: UserStateService

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("changes", use: changes)
    }

    @Sendable
    func changes(_ request: Request, context: SphynxRequestContext) async throws -> ChangesResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: ChangesQuery.self, context: context)
        let since = Self.parseSince(query.since)
        let limit = Cursor.clampLimit(query.limit)
        // The window's `until` ceiling is fixed when the window opens (first page,
        // no cursor) and then carried in the cursor, so every page of one window
        // shares the same `(since, until]` bounds — making pagination gap-free.
        let page0 = Self.decodeCursor(query.cursor)
        let offset = page0?.offset ?? 0
        let until = page0?.until ?? Date().timeIntervalSince1970

        // Changed items in the window, permission-filtered to readable libraries.
        let records = try await catalog.changedItems(since: since, until: until, limit: limit, offset: offset)
        let hasMore = records.count > limit
        let page = hasMore ? Array(records.prefix(limit)) : records

        var items: [Item] = []
        for record in page where try await canRead(record, identity) {
            items.append(record.toProtocol(full: query.detail == "full"))
        }
        items = try await foldUserData(items, userId: identity.userId)

        // Tombstones for the same `(since, until]` window. Ids only — the item is
        // gone and can't be permission-checked; surfacing a deletion leaks nothing
        // about content. A client dedupes by id across the window's pages.
        let tombstones = try await catalog.tombstones(since: since, until: until).map { $0.toProtocol() }

        return ChangesResponse(
            changes: items,
            tombstones: tombstones,
            until: Self.rfc3339().string(from: Date(timeIntervalSince1970: until)),
            nextCursor: hasMore ? Self.encodeCursor(offset: offset + limit, until: until) : nil
        )
    }

    /// Changes cursor: packs the page `offset` **and** the window's `until`
    /// ceiling, so the next page reuses the exact same window. Base64 of
    /// `<offset>:<until>`.
    private static func encodeCursor(offset: Int, until: Double) -> String {
        Data("\(offset):\(until)".utf8).base64EncodedString()
    }

    private static func decodeCursor(_ raw: String?) -> (offset: Int, until: Double)? {
        guard let raw, let data = Data(base64Encoded: raw),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let parts = str.split(separator: ":")
        guard parts.count == 2, let offset = Int(parts[0]), let until = Double(parts[1]) else { return nil }
        return (offset, until)
    }

    /// RFC3339 with fractional seconds, so `until` round-trips back through
    /// `since` losslessly — a whole-second `until` would parse back *before* a
    /// sub-second change time and re-deliver it on every poll.
    private static func rfc3339() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    /// Parse `since`: epoch seconds (e.g. `1719500000`) OR RFC3339, with or
    /// without fractional seconds (`2026-06-27T12:00:00Z` /
    /// `2026-06-27T12:00:00.789Z`). Absent / unparseable → 0 (a full sync).
    private static func parseSince(_ raw: String?) -> Double {
        guard let raw, !raw.isEmpty else { return 0 }
        if let epoch = Double(raw) { return epoch }
        if let date = rfc3339().date(from: raw) { return date.timeIntervalSince1970 }
        if let date = ISO8601DateFormatter().date(from: raw) { return date.timeIntervalSince1970 }
        return 0
    }

    /// Whether the user may read an item, honoring per-library scoping.
    private func canRead(_ record: ItemRecord, _ identity: AuthIdentity) async throws -> Bool {
        if identity.isAdmin { return true }
        let libraryId = try await catalog.owningLibraryId(of: record)
        return identity.canReadLibrary(libraryId)
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
}

// MARK: - Query DTO

struct ChangesQuery: Codable, Sendable {
    /// Epoch seconds or RFC3339; default 0 (full sync).
    var since: String?
    var detail: String?
    var limit: Int?
    var cursor: String?
}
