import Foundation
import Hummingbird
import SphynxProtocol

/// Per-user item state writes — `PUT /v1/items/:id/state` (watched / favorite).
/// Behind `AuthMiddleware`; row-scoped to the authenticated subject. Reading state
/// happens by folding it into item responses (browse), like `resumePosition`.
struct UserStateController: Sendable {
    let catalog: Catalog
    let userState: UserStateService
    /// Marking watched clears the caller's resume for the item, so it leaves
    /// Continue Watching and `resumePosition` reads back 0.
    let playstate: PlaystateService
    /// Live updates: a state change publishes a per-subject event.
    let events: EventBus
    /// Live source for the low-res-images extension's placeholder mode.
    let settings: SettingsStore

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
        if let rating = body.rating, !(0...10).contains(rating) {
            throw SphynxError.badRequest("rating must be between 0 and 10")
        }
        let state = try await userState.update(
            userId: identity.userId, itemId: itemId,
            watched: body.watched, isFavorite: body.isFavorite, rating: body.rating
        )
        let now = Date().timeIntervalSince1970
        // Marking watched means "finished": clear the caller's resume so the item
        // drops out of Continue Watching and `resumePosition` reads back 0 — matching
        // Jellyfin (PlayedItems) and Plex (scrobble). No-op if there was no resume.
        if body.watched == true {
            try await playstate.clear(userId: identity.userId, itemId: itemId)
            await events.publish(.playstate(itemId: itemId, position: 0, ts: now), to: .user(identity.userId))
        }
        await events.publish(
            .userItemState(itemId: itemId, watched: state.watched, isFavorite: state.isFavorite,
                           playCount: state.playCount, ts: now),
            to: .user(identity.userId))
        var item = record.toProtocol(full: false, placeholderMode: try await PlaceholderMode.current(settings))
        UserStateService.fold(state, into: &item)
        return item
    }
}
