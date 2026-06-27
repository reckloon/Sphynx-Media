import Hummingbird
import SphynxProtocol

/// Implements §6 Resolve: `GET /v1/resolve/<itemId>`. Behind `AuthMiddleware`.
struct ResolveController: Sendable {
    let resolver: Resolver

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("resolve/:itemId", use: resolve)
    }

    @Sendable
    func resolve(_ request: Request, context: SphynxRequestContext) async throws -> ResolveDescriptor {
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        return try await resolver.resolve(itemId: itemId)
    }
}
