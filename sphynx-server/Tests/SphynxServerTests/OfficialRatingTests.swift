import Foundation
import Testing
@testable import SphynxServer

@Suite("Official rating (content certification) from TMDB")
struct OfficialRatingTests {
    @Test("movie certification picks the country's theatrical rating")
    func movieCertification() {
        let results = [
            RawCountryReleaseDates(iso_3166_1: "GB", release_dates: [RawRelease(certification: "15", type: 3)]),
            RawCountryReleaseDates(iso_3166_1: "US", release_dates: [
                RawRelease(certification: "", type: 1),       // premiere, no cert — skipped
                RawRelease(certification: "PG-13", type: 3),  // theatrical — chosen
            ]),
        ]
        #expect(TMDBHTTPClient.movieCertification(from: results) == "PG-13")
        #expect(TMDBHTTPClient.movieCertification(from: results, country: "GB") == "15")
        #expect(TMDBHTTPClient.movieCertification(from: results, country: "DE") == nil)  // no entry
        #expect(TMDBHTTPClient.movieCertification(from: nil) == nil)
    }

    @Test("movie certification falls back to any non-empty cert when no theatrical one")
    func movieCertificationFallback() {
        let results = [RawCountryReleaseDates(iso_3166_1: "US", release_dates: [
            RawRelease(certification: "R", type: 5),  // physical release, still a valid cert
        ])]
        #expect(TMDBHTTPClient.movieCertification(from: results) == "R")
    }

    @Test("logo picker prefers a raster (PNG) logo over an SVG that TMDB lists first")
    func logoPrefersRaster() {
        // TMDB's vote order can put a vector logo first (e.g. Maniac); SVG renders blank
        // on raster-only clients, so the PNG must win.
        let logos = [
            RawImage(file_path: "/vector.svg"),
            RawImage(file_path: "/raster.png"),
        ]
        #expect(TMDBHTTPClient.logoPath(from: logos) == "/raster.png")
        // All-SVG ⇒ fall back to the first rather than dropping the logo entirely.
        #expect(TMDBHTTPClient.logoPath(from: [RawImage(file_path: "/only.svg")]) == "/only.svg")
        // PNG already first ⇒ unchanged; empty/nil ⇒ nil.
        #expect(TMDBHTTPClient.logoPath(from: [RawImage(file_path: "/a.png"), RawImage(file_path: "/b.svg")]) == "/a.png")
        #expect(TMDBHTTPClient.logoPath(from: []) == nil)
        #expect(TMDBHTTPClient.logoPath(from: nil) == nil)
    }

    @Test("tv rating picks the country's content rating")
    func tvRating() {
        let results = [
            RawContentRating(iso_3166_1: "US", rating: "TV-MA"),
            RawContentRating(iso_3166_1: "GB", rating: "18"),
        ]
        #expect(TMDBHTTPClient.tvRating(from: results) == "TV-MA")
        #expect(TMDBHTTPClient.tvRating(from: results, country: "GB") == "18")
        #expect(TMDBHTTPClient.tvRating(from: results, country: "FR") == nil)
        #expect(TMDBHTTPClient.tvRating(from: nil) == nil)
    }

    @Test("enrichMovie carries officialRating into the enrichment fields")
    func movieEnrichPropagates() async throws {
        let stub = StubTMDBClient(details: [42: TMDBMovieDetails(
            id: 42, title: "Hard R Movie", overview: nil, year: 2008, runtimeMinutes: nil,
            genres: [], voteAverage: nil, posterPath: nil, backdropPath: nil, cast: [],
            officialRating: "R")])
        let fields = try await Enricher(tmdb: stub).enrichMovie(tmdbId: 42)
        #expect(fields.officialRating == "R")
    }

    @Test("seriesFields carries officialRating into the enrichment fields")
    func tvSeriesPropagates() async throws {
        let stub = StubTMDBClient(tvDetailsByID: [95: TMDBTVDetails(
            id: 95, name: "Severance", overview: nil, year: 2022, genres: [], voteAverage: nil,
            posterPath: nil, backdropPath: nil, seasons: [], officialRating: "TV-MA")])
        let fields = try await TVEnricher(tmdb: stub).seriesFields(tmdbId: 95)
        #expect(fields.officialRating == "TV-MA")
    }
}
