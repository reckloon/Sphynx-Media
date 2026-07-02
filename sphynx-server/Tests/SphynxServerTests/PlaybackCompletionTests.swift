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

    @Test("abandon resets a previously-PLAYED item to pristine — no lingering 'watching' indicator")
    func abandonResetsPlayedItem() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 100)
            // A real play first: complete it → watched + playCount + lastPlayedAt set.
            try await stop(c, t, id, at: 96)
            var it = try await item(c, t, id)
            #expect(it.watched == true); #expect(it.playCount == 1); #expect(it.lastPlayedAt != nil)
            // Re-open and bail in the first 5% → must reset to COMPLETELY unwatched,
            // not just drop the resume (which used to leave playCount/lastPlayedAt set,
            // so the client still showed an "in progress / watching" state).
            try await progress(c, t, id, to: 40)
            try await stop(c, t, id, at: 3)
            #expect(try await resume(c, t, id) == 0)
            #expect(try await inContinue(c, t, id) == false)
            it = try await item(c, t, id)
            #expect(it.watched == nil)         // no watched mark
            #expect(it.playCount == nil)       // no play count
            #expect(it.lastPlayedAt == nil)    // no "watching" signal at all
        }
    }

    @Test("abandon keeps an explicit favorite while resetting playback")
    func abandonPreservesFavorite() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 100)
            try await stop(c, t, id, at: 96)                       // played
            try await c.execute(uri: "/v1/items/\(id)/state", method: .put, headers: jsonHeaders(bearer: t),
                body: try jsonBody(ItemStateUpdate(isFavorite: true))) { #expect($0.status == .ok) }
            try await stop(c, t, id, at: 2)                        // abandon
            let it = try await item(c, t, id)
            #expect(it.isFavorite == true)                         // favorite kept
            #expect(it.watched == nil)                             // playback reset
            #expect(it.playCount == nil)
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

    @Test("client-reported duration beats the nominal metadata runtime")
    func reportedDurationWins() {
        // The classic TV case: TMDB's nominal 25-minute slot, a 21.5-minute file.
        // Finishing the file is 86% of the *nominal* runtime — against the player's
        // real duration it's 100% and must mark watched.
        #expect(PlaystateController.completion(position: 1_290, duration: 1_290, runtime: 1_500) == .completed)
        #expect(PlaystateController.completion(position: 1_290, runtime: 1_500) == .partial)  // without it: the old bug
        // Duration also rescues items with no metadata runtime at all.
        #expect(PlaystateController.completion(position: 96, duration: 100, runtime: nil) == .completed)
        #expect(PlaystateController.completion(position: 2, duration: 100, runtime: nil) == .abandoned)
        // A bogus (zero/negative) duration falls back to the runtime, then partial.
        #expect(PlaystateController.completion(position: 96, duration: 0, runtime: 100) == .completed)
        #expect(PlaystateController.completion(position: 50, duration: 0, runtime: nil) == .partial)
    }

    @Test("stop with duration marks a nominal-runtime item watched end-to-end")
    func stopWithDurationCompletes() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { c in
            let t = try await login(c); let lib = try await library(c, t)
            let id = try await movie(c, t, lib, runtime: 1_500)     // nominal 25 min
            try await progress(c, t, id, to: 600)
            // Finish the actual 21.5-minute file, reporting the player's duration.
            try await c.execute(uri: "/v1/playstate/\(id)/stop", method: .post, headers: jsonHeaders(bearer: t),
                body: try jsonBody(PlaystateStopBody(position: 1_290, duration: 1_290))) { #expect($0.status == .noContent) }

            let it = try await item(c, t, id)
            #expect(it.watched == true)                             // fully complete…
            #expect(try await resume(c, t, id) == 0)                // …no end-of-file resume point
            #expect(try await inContinue(c, t, id) == false)
        }
    }
}
