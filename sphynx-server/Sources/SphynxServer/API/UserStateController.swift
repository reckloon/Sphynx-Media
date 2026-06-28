import Foundation
import Hummingbird
import SphynxProtocol

/// Per-user item state writes — `PUT /v1/items/:id/state` (watched / favorite).
/// Behind `AuthMiddleware`; row-scoped to the authenticated subject. Reading state
/// happens by folding it into item responses (browse), like `resumePosition`.
struct UserStateController: Sendable {
    let catalog: Catalog
    let userState: UserStateService
    /// Live updates: a state change publishes a per-subject event.
    let events: EventBus

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.put("items/:itemId/state", use: setState)
    }

    @Sendable
    func setState(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let record = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        // The user must be able to read the item's library to track state on it.
        guard identity.canReadLibrary(try await catalog.owningLibraryId(of: record)) else {
            throw SphynxError.forbidden("You don't have permission to view this item")
        }
        let body = try await request.decode(as: ItemStateUpdate.self, context: context)
        let state = try await userState.update(
            userId: identity.userId, itemId: itemId,
            watched: body.watched, isFavorite: body.isFavorite
        )
        await events.publish(
            .userItemState(itemId: itemId, watched: state.watched, isFavorite: state.isFavorite,
                           playCount: state.playCount, ts: Date().timeIntervalSince1970),
            to: .user(identity.userId))
        var item = record.toProtocol(full: false)
        UserStateService.fold(state, into: &item)
        return item
    }
}
