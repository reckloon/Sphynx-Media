import Foundation
import Testing
@testable import SphynxServer

/// Unit tests for the event stream's core: identity-scoped delivery in `EventBus`
/// and SSE frame rendering. (The HTTP streaming wrapper is thin glue over these.)
@Suite("Event stream")
struct EventStreamTests {
    // MARK: Identities

    private func admin() -> AuthIdentity {
        AuthIdentity(userId: "u_admin", isAdmin: true, displayName: "Admin",
                     avatarURL: nil, sessionId: "s", permissions: [])
    }
    private func user(_ id: String, permissions: Set<String> = []) -> AuthIdentity {
        AuthIdentity(userId: id, isAdmin: false, displayName: id,
                     avatarURL: nil, sessionId: "s", permissions: permissions)
    }

    /// Drain a stream to completion. Caller must `unsubscribe` first so it finishes.
    private func drain(_ stream: AsyncStream<ServerEvent>) async -> [ServerEvent] {
        var out: [ServerEvent] = []
        for await event in stream { out.append(event) }
        return out
    }

    // MARK: Per-user delivery

    @Test("a user-scoped event reaches only that user's connections")
    func userScoped() async throws {
        let bus = EventBus()
        let (aStream, aSub) = await bus.subscribe(identity: user("u1"))
        let (bStream, bSub) = await bus.subscribe(identity: user("u2"))

        await bus.publish(.playstate(itemId: "it_1", position: 42, ts: 1), to: .user("u1"))

        await bus.unsubscribe(aSub)
        await bus.unsubscribe(bSub)
        let a = await drain(aStream)
        let b = await drain(bStream)

        #expect(a.map(\.type) == ["playstate"])
        #expect(a.first?.itemId == "it_1")
        #expect(a.first?.position == 42)
        #expect(b.isEmpty)  // u2 must not see u1's playstate
    }

    // MARK: Library-scoped delivery (fail-closed, mirrors REST access)

    @Test("a library event reaches admins and readers, not the unentitled")
    func libraryScoped() async throws {
        let bus = EventBus()
        let (adminS, adminSub) = await bus.subscribe(identity: admin())
        let (readerS, readerSub) = await bus.subscribe(identity: user("u_r", permissions: [Permissions.libraryRead]))
        let (noneS, noneSub) = await bus.subscribe(identity: user("u_n"))

        await bus.publish(.library(libraryId: "lib_x", action: "scanned", ts: 1), to: .library("lib_x"))

        for sub in [adminSub, readerSub, noneSub] { await bus.unsubscribe(sub) }
        let adminEvents = await drain(adminS)
        let readerEvents = await drain(readerS)
        let noneEvents = await drain(noneS)

        #expect(adminEvents.map(\.type) == ["library"])
        #expect(readerEvents.map(\.type) == ["library"])
        #expect(noneEvents.isEmpty)  // no library.read → no event
    }

    @Test("a nil-library event is admin-only (fail-closed)")
    func nilLibraryAdminOnly() async throws {
        let bus = EventBus()
        let (adminS, adminSub) = await bus.subscribe(identity: admin())
        // Even a global library.read holder is excluded from an ungoverned (nil) item.
        let (readerS, readerSub) = await bus.subscribe(identity: user("u_r", permissions: [Permissions.libraryRead]))

        await bus.publish(.markers(itemId: "it_1", libraryId: nil, ts: 1), to: .library(nil))

        await bus.unsubscribe(adminSub)
        await bus.unsubscribe(readerSub)
        #expect(await drain(adminS).map(\.type) == ["markers"])
        #expect(await drain(readerS).isEmpty)
    }

    // MARK: Lifecycle

    @Test("unsubscribe finishes the stream and drops the subscriber")
    func unsubscribeFinishes() async throws {
        let bus = EventBus()
        let (stream, sub) = await bus.subscribe(identity: user("u1"))
        #expect(await bus.subscriberCount == 1)
        await bus.unsubscribe(sub)
        #expect(await bus.subscriberCount == 0)
        // A publish after unsubscribe reaches nobody; the stream is already finished.
        await bus.publish(.playstate(itemId: "it_1", position: 1, ts: 1), to: .user("u1"))
        #expect(await drain(stream).isEmpty)
    }

    @Test("heartbeat delivers a keep-alive tick to one connection")
    func heartbeat() async throws {
        let bus = EventBus()
        let (stream, sub) = await bus.subscribe(identity: user("u1"))
        await bus.heartbeat(sub, ts: 99)
        await bus.unsubscribe(sub)
        #expect(await drain(stream).map(\.type) == ["heartbeat"])
    }

    // MARK: SSE rendering

    @Test("a heartbeat renders as an SSE comment, not a data frame")
    func renderHeartbeat() {
        #expect(EventsController.render(.heartbeat(ts: 1)) == ": ping\n\n")
    }

    @Test("a data event renders as an event+data frame with omitted nils")
    func renderDataFrame() {
        let frame = EventsController.render(.playstate(itemId: "it_9", position: 12.5, ts: 1))
        #expect(frame.hasPrefix("event: playstate\ndata: {"))
        #expect(frame.hasSuffix("}\n\n"))
        #expect(frame.contains("\"itemId\":\"it_9\""))
        #expect(frame.contains("\"position\":12.5"))
        #expect(!frame.contains("watched"))   // nil fields are omitted
        #expect(!frame.contains("libraryId"))
    }
}
