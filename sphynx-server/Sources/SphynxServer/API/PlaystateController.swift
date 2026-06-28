import Foundation
import Hummingbird
import SphynxProtocol

/// Implements §7 Playstate. Behind `AuthMiddleware`; every operation is
/// row-scoped to the authenticated subject.
struct PlaystateController: Sendable {
    let playstate: PlaystateService
    /// Per-user item state — a successful stop bumps play count + last-played.
    let userState: UserStateService

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.post("playstate/:itemId/start", use: start)
        group.post("playstate/:itemId/progress", use: progress)
        group.post("playstate/:itemId/stop", use: stop)
        group.get("playstate/:itemId", use: get)
        group.get("playstate", use: batch)
    }

    @Sendable
    func start(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try subjectAndItem(context)
        let body = try await request.decode(as: PlaystateStartBody.self, context: context)
        try await playstate.start(userId: userId, itemId: itemId, position: body.position)
        return Response(status: .noContent)
    }

    @Sendable
    func progress(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try subjectAndItem(context)
        let body = try await request.decode(as: PlaystateProgressBody.self, context: context)
        try await playstate.progress(userId: userId, itemId: itemId, position: body.position)
        return Response(status: .noContent)
    }

    @Sendable
    func stop(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let (userId, itemId) = try subjectAndItem(context)
        let body = try await request.decode(as: PlaystateStopBody.self, context: context)
        // A failed stop must not clobber a good resume point — handled in the service.
        try await playstate.stop(userId: userId, itemId: itemId, position: body.position, failed: body.failed)
        // A real (non-failed) stop counts as a play: bump count + last-played.
        if !body.failed {
            try await userState.recordPlay(userId: userId, itemId: itemId)
        }
        return Response(status: .noContent)
    }

    @Sendable
    func get(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateResponse {
        let (userId, itemId) = try subjectAndItem(context)
        if let state = try await playstate.get(userId: userId, itemId: itemId) {
            return state
        }
        // No stored state → "from start" (position 0).
        return PlaystateResponse(position: 0, updatedAt: ISO8601DateFormatter().string(from: Date()))
    }

    @Sendable
    func batch(_ request: Request, context: SphynxRequestContext) async throws -> PlaystateBatchResponse {
        let userId = try subject(context)
        let query = try request.uri.decodeQuery(as: BatchQuery.self, context: context)
        let itemIds = (query.items ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        let states = try await playstate.batch(userId: userId, itemIds: itemIds)
        return PlaystateBatchResponse(states: states)
    }

    // MARK: Helpers

    private func subject(_ context: SphynxRequestContext) throws -> String {
        guard let userId = context.identity?.userId else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        return userId
    }

    private func subjectAndItem(_ context: SphynxRequestContext) throws -> (userId: String, itemId: String) {
        let userId = try subject(context)
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        return (userId, itemId)
    }
}

struct BatchQuery: Codable, Sendable {
    var items: String?
}
