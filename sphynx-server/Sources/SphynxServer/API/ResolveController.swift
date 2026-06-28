import Hummingbird
import SphynxProtocol

/// Implements §6 Resolve: `GET /v1/resolve/<itemId>`. Behind `AuthMiddleware`.
struct ResolveController: Sendable {
    let catalog: Catalog
    let resolver: Resolver

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("resolve/:itemId", use: resolve)
    }

    @Sendable
    func resolve(_ request: Request, context: SphynxRequestContext) async throws -> ResolveDescriptor {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        // Resolving hands back a playback URL + headers (credentials), so it
        // requires read access to the item's owning library — and an item that
        // belongs to no library is admin-only (fail closed; never leak to a
        // regular user holding only global library.read).
        if !identity.isAdmin {
            guard let item = try await catalog.item(id: itemId) else {
                throw SphynxError.notFound("No item '\(itemId)'")
            }
            let libraryId = try await catalog.owningLibraryId(of: item)
            guard identity.canReadLibrary(libraryId) else {
                throw SphynxError.forbidden("You don't have permission to play this item")
            }
        }
        // Optional `?version=<id>` selects a specific edition/quality; absent ⇒ the
        // item's default (highest-quality) version.
        let version = request.uri.queryParameters["version"].map(String.init)
        return try await resolver.resolve(itemId: itemId, version: version)
    }
}
