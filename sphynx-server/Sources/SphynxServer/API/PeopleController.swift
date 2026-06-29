import Hummingbird
import SphynxProtocol

/// Implements the person filmography surface: the inverse of an item's cast list.
/// Behind `AuthMiddleware`, like the rest of `/v1`.
///
/// `GET /v1/people/{personId}/items` returns the distinct movies and series the
/// person is credited on (cast credits only — see `Catalog.itemsCreditingPerson`),
/// newest-first, filtered to libraries the caller may read. People are not a
/// first-class table, so a person id is only meaningful as a `pe_<tmdbId>` cast
/// id: a malformed id (not of the `pe_…` shape) is a `404`; a well-formed id with
/// no credited items is a normal `200` with an empty list.
struct PeopleController: Sendable {
    let catalog: Catalog
    let userState: UserStateService
    let playstate: PlaystateService
    /// Live source for the low-res-images extension's placeholder mode.
    let settings: SettingsStore

    /// The required shape of a person id (the cast-entry id minted by the enricher).
    private static let personIdPrefix = "pe_"

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("people/:personId/items", use: items)
    }

    /// §inverse-cast: everything a person appears in. Distinct by item id, sorted
    /// newest-first (premiere/production date desc, then title), permission-filtered.
    @Sendable
    func items(_ request: Request, context: SphynxRequestContext) async throws -> ItemsResponse {
        let identity = try context.requireIdentity()
        guard let personId = context.parameters.get("personId"), !personId.isEmpty else {
            throw SphynxError.badRequest("Missing person id")
        }
        // There is no person registry, so we cannot distinguish "unknown person"
        // from "known person with zero credits". A malformed id (not `pe_…`) can
        // never correspond to a real cast entry, so it's a 404; any well-formed id
        // returns a (possibly empty) 200 list.
        guard personId.hasPrefix(Self.personIdPrefix), personId.count > Self.personIdPrefix.count else {
            throw SphynxError.notFound("No person '\(personId)'")
        }

        let query = try request.uri.decodeQuery(as: ContinueQuery.self, context: context)
        let full = query.detail == "full"
        let limit = Cursor.clampLimit(query.limit)
        let offset = Cursor.offset(from: query.cursor)

        // Fetch all credited records, then permission-filter (per-library scoping).
        let records = try await catalog.itemsCreditingPerson(personId: personId)
        var readable: [ItemRecord] = []
        for record in records where try await canRead(record, identity) {
            readable.append(record)
        }

        // Newest-first: premiere/production date desc, then title (matches
        // Jellyfin's PremiereDate desc). Sort in Swift over the projection.
        let sorted = readable.sorted { lhs, rhs in
            let l = Self.sortKey(lhs), r = Self.sortKey(rhs)
            if l.date != r.date { return l.date > r.date }
            return l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending
        }

        let hasMore = sorted.count > offset + limit
        let page = Array(sorted.dropFirst(offset).prefix(limit))

        let mode = try await PlaceholderMode.current(settings)
        let items = try await foldUserData(
            page.map { $0.toProtocol(full: full, placeholderMode: mode) }, userId: identity.userId)
        return ItemsResponse(
            items: items,
            nextCursor: hasMore ? Cursor.encode(offset: offset + limit) : nil
        )
    }

    /// The sort key for newest-first ordering: the extended premiere date when
    /// present (ISO `YYYY-MM-DD`, lexicographically orderable), else the year as a
    /// date string, else empty (sorts last under desc). Title breaks ties.
    private static func sortKey(_ record: ItemRecord) -> (date: String, title: String) {
        if let premiere = record.extended()?.premiereDate, !premiere.isEmpty {
            return (premiere, record.title)
        }
        if let year = record.year {
            return (String(format: "%04d", year), record.title)
        }
        return ("", record.title)
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

    /// Whether the user may read an item, honoring per-library scoping.
    private func canRead(_ record: ItemRecord, _ identity: AuthIdentity) async throws -> Bool {
        if identity.isAdmin { return true }
        let libraryId = try await catalog.owningLibraryId(of: record)
        return identity.canReadLibrary(libraryId)
    }
}
