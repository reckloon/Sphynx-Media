import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Extended metadata projection")
struct ExtendedMetadataTests {
    /// The Matrix with the extended TMDB fields populated.
    private var stubTMDB: StubTMDBClient {
        StubTMDBClient(
            searchResults: [:],
            details: [603: TMDBMovieDetails(
                id: 603, title: "The Matrix",
                overview: "A hacker learns the truth about his reality.",
                year: 1999, runtimeMinutes: 136,
                genres: ["Action", "Science Fiction"],
                voteAverage: 8.2,
                posterPath: "/poster.jpg", backdropPath: "/back.jpg",
                cast: [TMDBCastMember(id: 6384, name: "Keanu Reeves", character: "Neo", profilePath: "/k.jpg")],
                originalTitle: "The Matrix",
                tagline: "Welcome to the Real World.",
                imdbId: "tt0133093",
                status: "Released",
                releaseDate: "1999-03-31",
                studios: ["Warner Bros.", "Village Roadshow Pictures"],
                directors: ["Lana Wachowski", "Lilly Wachowski"],
                writers: ["Lilly Wachowski", "Lana Wachowski"],
                countries: ["United States of America"]
            )]
        )
    }

    @Test("enrichment populates + projects the extended canonical fields")
    func extendedFieldsProject() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Unknown", sourceId: nil,
                    sourceKey: "https://cdn/x.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }

            _ = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "603", type: "movie"))
            ) { try $0.decoded(Item.self) }

            let full: Item = try await client.execute(
                uri: "/v1/items/\(created.id)?detail=full", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }

            #expect(full.tagline == "Welcome to the Real World.")
            #expect(full.status == "Released")
            #expect(full.premiereDate == "1999-03-31")
            #expect(full.studios == ["Warner Bros.", "Village Roadshow Pictures"])
            #expect(full.directors == ["Lana Wachowski", "Lilly Wachowski"])
            #expect(full.writers?.contains("Lana Wachowski") == true)
            #expect(full.countries == ["United States of America"])
            #expect(full.externalIds?["imdb"] == "tt0133093")
            #expect(full.dateAdded != nil)
            // originalTitle equals title here → omitted.
            #expect(full.originalTitle == nil)
        }
    }

    @Test("skeleton omits the extended fields but keeps dateAdded")
    func skeletonOmitsExtended() async throws {
        let app = try await buildApplication(configuration: testConfiguration(), httpFetcher: StubFetcher([:]), tmdbClient: stubTMDB)
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }
            let created: Item = try await client.execute(
                uri: "/v1/admin/items", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(CreateItemRequest(type: "movie", title: "Unknown", sourceId: nil,
                    sourceKey: "https://cdn/x.mkv", container: "mkv", tmdbId: nil,
                    libraryId: nil, parentId: nil, year: nil, extra: nil))
            ) { try $0.decoded() }
            _ = try await client.execute(
                uri: "/v1/admin/items/\(created.id)/identity", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(SetIdentityRequest(tmdbId: "603", type: "movie"))
            ) { try $0.decoded(Item.self) }

            let skeleton: Item = try await client.execute(
                uri: "/v1/items/\(created.id)?detail=skeleton", method: .get, headers: jsonHeaders(bearer: token)
            ) { try $0.decoded() }
            #expect(skeleton.tagline == nil)
            #expect(skeleton.studios == nil)
            #expect(skeleton.externalIds == nil)
            #expect(skeleton.dateAdded != nil)  // tile-level
        }
    }
}
