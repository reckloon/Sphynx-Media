import Foundation

/// In-process publish/subscribe powering the `GET /v1/events` SSE stream.
///
/// Each open connection is one subscription that carries the subscriber's
/// `AuthIdentity`, so delivery enforces the same fail-closed access rules as the
/// REST surface (a `library` event only reaches connections that may read that
/// library). It is deliberately in-process and best-effort: events are a live
/// convenience layered on top of the durable REST state, not a delivery
/// guarantee — a slow client drops buffered events rather than back-pressuring
/// the server (`bufferingNewest`).
actor EventBus {
    /// A handle to one open connection, returned by `subscribe`.
    struct Subscription: Sendable { let id: UInt64 }

    private struct Entry {
        let identity: AuthIdentity
        let continuation: AsyncStream<ServerEvent>.Continuation
    }

    private var entries: [UInt64: Entry] = [:]
    private var nextId: UInt64 = 0

    /// Register a connection. Returns the stream the SSE handler drains and a
    /// handle to tear it down. The stream finishes when `unsubscribe` is called
    /// or the bus is torn down.
    func subscribe(identity: AuthIdentity) -> (stream: AsyncStream<ServerEvent>, subscription: Subscription) {
        nextId += 1
        let id = nextId
        let (stream, continuation) = AsyncStream<ServerEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        entries[id] = Entry(identity: identity, continuation: continuation)
        return (stream, Subscription(id: id))
    }

    /// Tear down a connection's subscription and finish its stream.
    func unsubscribe(_ subscription: Subscription) {
        if let entry = entries.removeValue(forKey: subscription.id) {
            entry.continuation.finish()
        }
    }

    /// Deliver an event to every connection the audience permits.
    func publish(_ event: ServerEvent, to audience: EventAudience) {
        for entry in entries.values where Self.delivers(audience, to: entry.identity) {
            entry.continuation.yield(event)
        }
    }

    /// Send a keep-alive tick to a single connection (rendered as an SSE comment).
    func heartbeat(_ subscription: Subscription, ts: Double) {
        entries[subscription.id]?.continuation.yield(.heartbeat(ts: ts))
    }

    /// Open connection count — exposed for tests / future diagnostics.
    var subscriberCount: Int { entries.count }

    private static func delivers(_ audience: EventAudience, to identity: AuthIdentity) -> Bool {
        switch audience {
        case .user(let userId): return identity.userId == userId
        case .library(let libraryId): return identity.canReadLibrary(libraryId)
        }
    }
}
