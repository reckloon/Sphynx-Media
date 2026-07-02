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
        let (userId, itemId, _) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateStartBody.self, context: context)
        try await playstate.start(userId: userId, itemId: itemId, position: body.position)
        await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()),
                             to: .user(userId))
        return Response(status: .noContent)
    }

    @Sendable
    func progress(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId, _) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateProgressBody.self, context: context)
        try await playstate.progress(userId: userId, itemId: itemId, position: body.position)
        await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()),
                             to: .user(userId))
        return Response(status: .noContent)
    }

    @Sendable
    func stop(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId, item) = try await subjectAndReadableItem(context)
        let body = try await request.decode(as: PlaystateStopBody.self, context: context)
        // Store the resume point (a failed stop is a no-op in the service, so it
        // never clobbers a good one).
        try await playstate.stop(userId: userId, itemId: itemId, position: body.position, failed: body.failed)

        // A failed stop changes no per-user state and counts no play; just nudge
        // listeners with the (unchanged) position.
        guard !body.failed else {
            await events.publish(.playstate(itemId: itemId, position: body.position, ts: Self.now()), to: .user(userId))
            return Response(status: .noContent)
        }

        // Decide the outcome from how far in they got (per user). Completing within
        // the last 5% marks watched + clears resume (Jellyfin PlayedItems / Plex
        // scrobble); stopping in the first 5% marks unwatched + clears resume and
        // doesn't count a play; anything between is a normal partial watch that keeps
        // its resume point and counts a play.
        let state: UserStateRecord
        let resumeAfter: Double
        switch Self.completion(position: body.position, duration: body.duration, runtime: item.runtime) {
        case .completed:
            state = try await userState.recordPlay(userId: userId, itemId: itemId, watched: true)
            try await playstate.clear(userId: userId, itemId: itemId)
            resumeAfter = 0
        case .abandoned:
            // Stopping in the first 5% means "didn't really watch it" → reset to
            // pristine unwatched (no watched mark, no play count, no last-played) so
            // there's no lingering "in progress" indicator, not just a cleared resume.
            state = try await userState.resetPlayback(userId: userId, itemId: itemId)
            try await playstate.clear(userId: userId, itemId: itemId)
            resumeAfter = 0
        case .partial:
            state = try await userState.recordPlay(userId: userId, itemId: itemId)
            resumeAfter = body.position
        }
        await events.publish(.playstate(itemId: itemId, position: resumeAfter, ts: Self.now()), to: .user(userId))
        await events.publish(
            .userItemState(itemId: itemId, watched: state.watched, isFavorite: state.isFavorite,
                           playCount: state.playCount, ts: Self.now()),
            to: .user(userId))
        return Response(status: .noContent)
    }

    /// How a non-failed stop resolves, from the fraction watched.
    enum Completion: Equatable { case completed, abandoned, partial }
    static let completedFraction = 0.95
    static let abandonedFraction = 0.05

    /// Classify a stop position by the fraction watched. The **client-reported
    /// duration wins** over the catalog's metadata runtime: the player knows the
    /// file's true length, while metadata runtime is nominal (TMDB lists a TV
    /// episode's broadcast slot — a "25-minute" episode is often a ~21-minute file,
    /// so finishing it reads as 86% against the nominal figure and would never mark
    /// watched). No usable length at all → `.partial` (keep resume, count the play).
    static func completion(position: Double, duration: Double? = nil, runtime: Double?) -> Completion {
        let length = [duration, runtime].compactMap { $0 }.first { $0 > 0 }
        guard let length else { return .partial }
        let fraction = position / length
        if fraction >= completedFraction { return .completed }
        if fraction <= abandonedFraction { return .abandoned }
        return .partial
    }

    private static func now() -> Double { Date().timeIntervalSince1970 }

    @Sendable
    func get(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateResponse {
        let (userId, itemId, _) = try await subjectAndReadableItem(context)
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
        let (userId, itemId, _) = try await subjectAndReadableItem(context)
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
    private func subjectAndReadableItem(_ context: SphynxRequestContext) async throws -> (userId: String, itemId: String, item: ItemRecord) {
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
        return (identity.userId, itemId, item)
    }
}

struct BatchQuery: Codable, Sendable {
    var items: String?
}
