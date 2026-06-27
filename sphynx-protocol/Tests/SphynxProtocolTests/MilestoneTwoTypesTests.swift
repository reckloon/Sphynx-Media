import Foundation
import Testing
@testable import SphynxProtocol

private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value, "\(T.self) did not survive a JSON round-trip")
}

@Suite("Auth types")
struct AuthTypesTests {
    @Test("Login/refresh/logout/token/user round-trip")
    func authRoundTrips() throws {
        try assertRoundTrips(LoginRequest(username: "mike", password: "hunter2"))
        try assertRoundTrips(RefreshRequest(refreshToken: "rt_abc"))
        try assertRoundTrips(LogoutRequest(refreshToken: "rt_abc", allDevices: true))
        try assertRoundTrips(LogoutRequest(refreshToken: "rt_abc"))
        let user = User(id: "u_1", displayName: "Mike", avatarURL: "https://x/y.png")
        try assertRoundTrips(user)
        try assertRoundTrips(TokenResponse(accessToken: "at", refreshToken: "rt", expiresIn: 3600, user: user))
        try assertRoundTrips(MeResponse(user: user, metadata: ["markers": .readWrite, "images": .read]))
    }

    @Test("Optional user/logout fields are omitted when nil")
    func omitsNilFields() throws {
        let json = String(data: try JSONEncoder().encode(User(id: "u", displayName: "M")), encoding: .utf8)!
        #expect(!json.contains("avatarURL"))
    }
}

@Suite("Item types")
struct ItemTypesTests {
    @Test("Full item round-trips")
    func fullItem() throws {
        let item = Item(
            id: "it_1",
            type: .movie,
            title: "Blade Runner 2049",
            tmdbId: "335984",
            overview: "K, a blade runner…",
            year: 2017,
            runtime: 9840.0,
            images: ItemImages(primary: "https://p", backdrop: "https://b", thumb: "https://t"),
            placeholder: .blurHash("LEHV6nWB"),
            genres: ["Sci-Fi", "Drama"],
            communityRating: 8.0,
            officialRating: "R",
            cast: [CastMember(id: "pe_1", name: "Ryan Gosling", role: "K", imageURL: "https://i", placeholder: .url("https://tiny.jpg"))],
            resumePosition: 1342.5
        )
        try assertRoundTrips(item)
    }

    @Test("Item.updatedAt round-trips")
    func itemUpdatedAt() throws {
        try assertRoundTrips(Item(id: "it_3", type: .episode, title: "Pilot", updatedAt: "2026-06-27T12:00:00Z"))
    }

    @Test("Skeleton item omits enrichment fields on the wire")
    func skeletonItem() throws {
        let item = Item(id: "it_2", type: .episode, title: "Pilot")
        let json = String(data: try JSONEncoder().encode(item), encoding: .utf8)!
        #expect(json.contains("\"id\""))
        #expect(json.contains("\"title\""))
        #expect(!json.contains("overview"))
        #expect(!json.contains("genres"))
        #expect(!json.contains("cast"))
        try assertRoundTrips(item)
    }
}

@Suite("Placeholder (self-describing one-of)")
struct PlaceholderTests {
    @Test("Each known form round-trips")
    func knownForms() throws {
        try assertRoundTrips(Placeholder.blurHash("LEHV6nWB"))
        try assertRoundTrips(Placeholder.url("https://x/tiny.jpg"))
    }

    @Test("blurHash decodes from its object form")
    func decodeBlurHash() throws {
        let p = try JSONDecoder().decode(Placeholder.self, from: "{\"blurHash\":\"LEHV6nWB\"}".data(using: .utf8)!)
        #expect(p == .blurHash("LEHV6nWB"))
    }

    @Test("url decodes from its object form")
    func decodeURL() throws {
        let p = try JSONDecoder().decode(Placeholder.self, from: "{\"url\":\"https://x/tiny.jpg\"}".data(using: .utf8)!)
        #expect(p == .url("https://x/tiny.jpg"))
    }

    @Test("first understood form wins when several are present")
    func firstFormWins() throws {
        let p = try JSONDecoder().decode(Placeholder.self, from: "{\"blurHash\":\"BH\",\"url\":\"U\"}".data(using: .utf8)!)
        #expect(p == .blurHash("BH"))
    }

    @Test("an unknown future form decodes to .unknown, never throws")
    func unknownForm() throws {
        let p = try JSONDecoder().decode(Placeholder.self, from: "{\"gradient\":\"radial\"}".data(using: .utf8)!)
        #expect(p == .unknown)
    }
}

@Suite("Resolve types")
struct ResolveTypesTests {
    @Test("Full resolve descriptor round-trips")
    func fullDescriptor() throws {
        let d = ResolveDescriptor(
            url: "https://cdn/movie.mkv",
            headers: ["Authorization": "Bearer x"],
            container: "mkv",
            ttl: 300,
            preResolved: true,
            tracks: Tracks(preferredAudio: 1, copyableAudio: 1, preferredSubtitle: 4),
            markers: Markers(intro: Marker(start: 75, end: 145), credits: Marker(start: 9120)),
            candidates: [Candidate(url: "https://cdn-b/x", headers: [:], priority: 1)]
        )
        try assertRoundTrips(d)
    }

    @Test("Minimal resolve descriptor (single location, no expiry) round-trips")
    func minimalDescriptor() throws {
        try assertRoundTrips(ResolveDescriptor(url: "https://cdn/movie.mp4"))
    }

    @Test("Open-ended credits marker (no end) round-trips")
    func openEndedMarker() throws {
        try assertRoundTrips(Marker(start: 9120))
    }
}
