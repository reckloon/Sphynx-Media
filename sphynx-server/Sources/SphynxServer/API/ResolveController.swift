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
        // Resolving hands back a playback URL, so it requires read access to the
        // item's library (per-library scoping honored).
        if !identity.isAdmin, let item = try await catalog.item(id: itemId) {
            let libraryId = try await catalog.owningLibraryId(of: item)
            guard identity.has(Permissions.libraryRead, inLibrary: libraryId) else {
                throw SphynxError.forbidden("You don't have permission to play this item")
            }
        }
        return try await resolver.resolve(itemId: itemId)
    }
}
