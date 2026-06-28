import Foundation
import Hummingbird
import SphynxProtocol

/// Implements §7 Playstate. Behind `AuthMiddleware`; every operation is
/// row-scoped to the authenticated subject.
struct PlaystateController: Sendable {
    let playstate: PlaystateService
    /// Per-user item state — a successful stop bumps play count + last-played.
    let userState: UserStateService
    /// Resolve an item's owning library so playstate is gated like the rest of the
    /// item surface (a user must not touch state for items outside their libraries).
    let catalog: Catalog
    /// Live updates: progress/stop publish a per-subject playstate event.
    let events: EventBus

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.post("playstate/:itemId/start", use: start)
        group.post("playstate/:itemId/progress", use: progress)
        group.post("playstate/:itemId/stop", use: stop)
        group.get("playstate/:itemId", use: get)
        group.get("playstate", use: batch)
        group.delete("playstate/:itemId", use: clear)
        group.delete("playstate", use: reset)
    }

    @Sendable
    func start(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateStartBody.self, context: context)
        try await playstate.start(userId: userId, itemId: itemId, position: body.position)
        await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()),
                             to: .user(userId))
        return Response(status: .noContent)
    }

    @Sendable
    func progress(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateProgressBody.self, context: context)
        try await playstate.progress(userId: userId, itemId: itemId, position: body.position)
        await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()),
                             to: .user(userId))
        return Response(status: .noContent)
    }

    @Sendable
    func stop(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateStopBody.self, context: context)
        // A failed stop must not clobber a good resume point — handled in the service.
        try await playstate.stop(userId: userId, itemId: itemId, position: body.position, failed: body.failed)
        await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()),
                             to: .user(userId))
        // A real (non-failed) stop counts as a play: bump count + last-played.
        if !body.failed {
            let state = try await userState.recordPlay(userId: userId, itemId: itemId)
            await events.publish(
                .userItemState(itemId: itemId, watched: state.watched, isFavorite: state.isFavorite,
                               playCount: state.playCount, ts: Self.now()),
                to: .user(userId))
        }
        return Response(status: .noContent)
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    @Sendable
    func get(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateResponse {
        let (userId, itemId) = try await subjectAndReadableItem(context)
        if let state = try await playstate.get(userId: userId, itemId: itemId) {
            return state
        }
        // No stored state → "from start" (position 0).
        return PlaystateResponse(position: 0, updatedAt: ISO8601DateFormatter().string(from: Date()))
    }

    @Sendable
    func batch(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateBatchResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: BatchQuery.self, context: context)
        let requested = (query.items ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        // Only return state for items the caller may read (silently drop the rest,
        // like the batch read already drops items with no stored state).
        let byId = try await catalog.items(ids: requested)
        var readable: [String] = []
        for id in requested {
            guard let record = byId[id] else { continue }
            let libraryId = try await catalog.owningLibraryId(of: record)
            if identity.canReadLibrary(libraryId) { readable.append(id) }
        }
        let states = try await playstate.batch(userId: identity.userId, itemIds: readable)
        return PlaystateBatchResponse(states: states)
    }

    /// Clear the caller's resume for an item: deletes their row so the item drops
    /// out of continue-watching and reads back "from start". Idempotent — 204
    /// whether or not a row existed.
    @Sendable
    func clear(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try await subjectAndReadableItem(context)
        try await playstate.clear(userId: userId, itemId: itemId)
        return Response(status: .noContent)
    }

    /// Reset the caller's entire watch history across every device: clear all
    /// resume positions **and** per-item state (watched/favorite/play-count).
    /// Row-scoped to the caller; idempotent. Returns the number of rows removed.
    @Sendable
    func reset(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateResetResponse {
        let identity = try context.requireIdentity()
        let resume = try await playstate.clearAll(userId: identity.userId)
        let state = try await userState.clearAll(userId: identity.userId)
        return PlaystateResetResponse(cleared: resume + state)
    }

    // MARK: Helpers

    /// The subject + item id, **gated on library read**: the item must exist and
    /// the caller must be able to read its owning library (admins bypass). Playstate
    /// is row-scoped to the user, but a user must not read/write state for items
    /// outside the libraries they can see — matching browse/resolve/markers.
    private func subjectAndReadableItem(_ context: SphynxRequestContext) async throws -> (userId: String, itemId: String) {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.canReadLibrary(libraryId) else {   // canReadLibrary admits admins
            throw SphynxError.forbidden("You don't have permission for this item")
        }
        return (identity.userId, itemId)
    }
}

struct BatchQuery: Codable, Sendable {
    var items: String?
}
