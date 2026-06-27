import Foundation
import Hummingbird
import SphynxProtocol

/// Bi-directional intro/credit markers (§6, §4 access policy). Behind
/// `AuthMiddleware`.
///
/// - `GET  /v1/items/:id/markers` — read (when `metadata.markers` ≥ read).
/// - `PUT  /v1/items/:id/markers` — contribute (when `metadata.markers` == readwrite).
///
/// Markers are item-level and shared across the server's clients, so a single
/// contribution (e.g. a client bridging TheIntroDB, or a server-side detector)
/// benefits everyone. Client contributions are best-effort and must not clobber
/// authoritative (server-detected / admin-pinned) markers.
struct MarkersController: Sendable {
    let catalog: Catalog
    let policy: AccessPolicy
    /// Age after which non-authoritative markers are reported `stale` (seconds).
    let staleAfter: Double

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("items/:itemId/markers", use: read)
        group.put("items/:itemId/markers", use: contribute)
    }

    @Sendable
    func read(_ request: Request, context: SphynxRequestContext) async throws -> MarkersInfo {
        guard policy.access("markers").allowsRead else {
            throw SphynxError.notFound("Markers are not offered by this server")
        }
        let identity = try context.requireIdentity()
        let item = try await requireItem(context)
        try await requireLibraryRead(item, identity)
        guard let info = item.markersInfo(staleAfter: staleAfter) else {
            throw SphynxError.notFound("No markers for this item")
        }
        return info
    }

    @Sendable
    func contribute(_ request: Request, context: SphynxRequestContext) async throws -> MarkersInfo {
        let identity = try context.requireIdentity()
        // Server must allow marker writes at all…
        guard policy.access("markers").allowsWrite else {
            throw SphynxError.forbidden("Markers are read-only on this server")
        }
        // …and this user must hold the markers-write permission (admins always do).
        guard identity.has(Permissions.markersWrite) else {
            throw SphynxError.forbidden("You don't have permission to contribute markers")
        }
        var item = try await requireItem(context)
        try await requireLibraryRead(item, identity)
        let body = try await request.decode(as: MarkerContribution.self, context: context)

        // A client contribution must not overwrite authoritative markers.
        if item.markersAuthoritative, !identity.isAdmin {
            throw SphynxError.conflict("Authoritative markers already exist for this item")
        }

        let now = Date().timeIntervalSince1970
        item.markersJSON = String(data: try JSONEncoder().encode(body.markers), encoding: .utf8)
        item.markersSource = body.source ?? (identity.isAdmin ? "admin" : "client")
        item.markersConfidence = body.confidence
        item.markersContributedBy = identity.userId
        // Admin contributions are treated as authoritative; everyone else's are
        // best-effort. (A server-side detector writes authoritative markers via
        // the internal catalog API — see docs/EXTENDING.md.)
        item.markersAuthoritative = identity.isAdmin
        item.markersUpdatedAt = now
        try await catalog.updateItem(item)

        guard let info = item.markersInfo(staleAfter: staleAfter) else {
            throw SphynxError.serverError("Failed to store markers")
        }
        return info
    }

    private func requireItem(_ context: SphynxRequestContext) async throws -> ItemRecord {
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        return item
    }

    /// Markers belong to an item, so reading or contributing them requires read
    /// access to that item's library (per-library scoping honored).
    private func requireLibraryRead(_ item: ItemRecord, _ identity: AuthIdentity) async throws {
        if identity.isAdmin { return }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.has(Permissions.libraryRead, inLibrary: libraryId) else {
            throw SphynxError.forbidden("You don't have permission to view this item")
        }
    }
}
