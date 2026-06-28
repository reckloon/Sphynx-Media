import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Playback completion: mark-watched clears resume; 95%/5% thresholds")
struct PlaybackCompletionTests {
    private func login(_ c: any TestClientProtocol) async throws -> String {
        try await c.execute(uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded(TokenResponse.self).accessToken }
    }
    private func library(_ c: any TestClientProtocol, _ t: String) async throws -> String {
        try await c.execute(uri: "/v1/admin/libraries", method: .post, headers: jsonHeaders(bearer: t),
            body: try jsonBody(CreateLibraryRequest(title: "Lib", kind: "movies"))
        ) { try $0.decoded(LibraryResponse.self).id }
    }
    /// Create a movie and (optionally) set its runtime in seconds via the admin edit.
    private func movie(_ c: any TestClientProtocol, _ t: String, _ lib: String, runtime: Double?) async throws -> String {
        let id: String = try await c.execute(uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: t),
            body: try jsonBody(CreateItemRequest(type: "movie", title: "Film", sourceId: nil,
                sourceKey: "https://cdn/film.mkv", container: "mkv", tmdbId: nil,
                libraryId: lib, parentId: nil, year: nil, extra: nil))
        ) { try $0.decoded(Item.self).id }
        if let runtime {
            try await c.execute(uri: "/v1/admin/items/\(id)", method: .patch, headers: jsonHeaders(bearer: t),
                body: try jsonBody(EditItemRequest(runtime: runtime))) { #expect($0.status == .ok) }
        }
        return id
    }
    private func resume(_ c: any TestClientProtocol, _ t: String, _ id: String) async throws -> Double {
        try await c.execute(uri: "/v1/playstate/\(id)", method: .get, headers: jsonHeaders(bearer: t)) {
            try $0.decoded(PlaystateResponse.self).position
        }
    }
    private func item(_ c: any TestClientProtocol, _ t: String, _ id: String) async throws -> Item {
        try await c.execute(uri: "/v1/items/\(id)?detail=full", method: .get, headers: jsonHeaders(bearer: t)) { try $0.decoded() }
    }
    private func inContinue(_ c: any TestClientProtocol, _ t: String, _ id: String) async throws -> Bool {
        try await c.execute(uri: "/v1/home/continue", method: .get, headers: jsonHeaders(bearer: t)) {
            try $0.decoded(ItemsResponse.self).items.contains { $0.id == id }
        }
    }
    private func stop(_ c: any TestClientProtocol, _ t: String, _ id: String, at p: Double, failed: Bool = false) async throws {
        try await c.execute(uri: "/v1/playstate/\(id)/stop", method: .post, headers: jsonHeaders(bearer: t),
            body: try jsonBody(PlaystateStopBody(position: p, failed: failed))) { #expect($0.status == .noContent) }
    }
    private func progress(_ c: any TestClientProtocol, _ t: String, _ id: String, to p: Double) async throws {
        try await c.execute(uri: "/v1/playstate/\(id)/progress", method: .post, headers: jsonHeaders(bearer: t),
            body: try jsonBody(PlaystateProgressBody(position: p))) { #expect($0.status == .noContent) }
    }
    private func setWatched(_ c: any TestClientProtocol, _ t: String, _ id: String, _ w: Bool) async throws {
        try await c.execute(uri: "/v1/items/\(id)/state", method: .put, headers: jsonHeaders(bearer: t),
            body: try jsonBody(ItemStateUpdate(watched: w))) { #expect($0.status == .ok) }
    }

    @Test("PUT state {watched:true} clears resume → resumePosition 0, drops out of Continue Watching")
    func markWatchedClearsResume() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: nil)
            try await progress(c, t, id, to: 50)
            #expect(try await resume(c, t, id) == 50)
            #expect(try await inContinue(c, t, id) == true)

            try await setWatched(c, t, id, true)
            #expect(try await resume(c, t, id) == 0)               // resume cleared
            #expect(try await inContinue(c, t, id) == false)       // gone from Continue Watching
            #expect(try await item(c, t, id).watched == true)
        }
    }

    @Test("stop within the last 5% completes: watched + resume cleared + play counted")
    func completesNearEnd() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 100)       // 100 s
            try await progress(c, t, id, to: 40)
            try await stop(c, t, id, at: 96)                        // 96% ≥ 95%
            #expect(try await resume(c, t, id) == 0)
            #expect(try await inContinue(c, t, id) == false)
            let it = try await item(c, t, id)
            #expect(it.watched == true)
            #expect(it.playCount == 1)
        }
    }

    @Test("stop within the first 5% un-watches: unwatched + resume cleared + NOT counted")
    func abandonsAtStart() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 100)
            try await setWatched(c, t, id, true)                   // previously watched
            try await progress(c, t, id, to: 40)                   // re-watching → resume + in continue
            try await stop(c, t, id, at: 3)                        // 3% ≤ 5%
            #expect(try await resume(c, t, id) == 0)               // resume cleared
            #expect(try await inContinue(c, t, id) == false)
            let it = try await item(c, t, id)
            #expect(it.watched == nil)                             // flipped back to unwatched
            #expect(it.playCount == nil)                           // a false start is not a play
        }
    }

    @Test("a normal partial stop is unchanged: keeps resume, counts the play, stays in Continue")
    func partialStop() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 100)
            try await stop(c, t, id, at: 50)                       // 50%
            #expect(try await resume(c, t, id) == 50)              // resume kept
            #expect(try await inContinue(c, t, id) == true)
            let it = try await item(c, t, id)
            #expect(it.watched == nil)
            #expect(it.playCount == 1)
        }
    }

    @Test("completion thresholds: ≥95% completed, ≤5% abandoned, else partial; unknown runtime = partial")
    func thresholds() {
        #expect(PlaystateController.completion(position: 96, runtime: 100) == .completed)
        #expect(PlaystateController.completion(position: 100, runtime: 100) == .completed)
        #expect(PlaystateController.completion(position: 3, runtime: 100) == .abandoned)
        #expect(PlaystateController.completion(position: 0, runtime: 100) == .abandoned)
        #expect(PlaystateController.completion(position: 50, runtime: 100) == .partial)
        #expect(PlaystateController.completion(position: 50, runtime: nil) == .partial)   // unknown length
        #expect(PlaystateController.completion(position: 50, runtime: 0) == .partial)
    }
}
