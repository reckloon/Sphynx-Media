import Foundation

/// Minimal TMDB access the Identifier and Enricher need. Abstracted so tests can
/// inject a stub instead of hitting the real API.
protocol TMDBClient: Sendable {
    func searchMovie(title: String, year: Int?) async throws -> [TMDBSearchResult]
    func movieDetails(id: Int) async throws -> TMDBMovieDetails
}

struct TMDBSearchResult: Sendable {
    var id: Int
    var title: String
    var year: Int?
    var popularity: Double
}

struct TMDBMovieDetails: Sendable {
    var id: Int
    var title: String
    var overview: String?
    var year: Int?
    /// Runtime in **minutes** (TMDB's unit); converted to seconds at the wire.
    var runtimeMinutes: Int?
    var genres: [String]
    var voteAverage: Double?
    var posterPath: String?
    var backdropPath: String?
    var cast: [TMDBCastMember]
}

struct TMDBCastMember: Sendable {
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?
}

/// Builds a full image URL from a TMDB path + size (e.g. `w500`).
enum TMDBImage {
    static let base = "https://image.tmdb.org/t/p/"
    static func url(_ path: String?, size: String) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return "\(base)\(size)\(path)"
    }
}

/// Live TMDB v3 client. Reuses the shared `HTTPFetching` (so it's cross-platform
/// and unit-testable) and authenticates with the v3 `api_key` query parameter.
struct TMDBHTTPClient: TMDBClient {
    let apiKey: String
    let fetcher: any HTTPFetching
    private let apiBase = "https://api.themoviedb.org/3"

    func searchMovie(title: String, year: Int?) async throws -> [TMDBSearchResult] {
        var components = URLComponents(string: "\(apiBase)/search/movie")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false"),
        ] + (year.map { [URLQueryItem(name: "year", value: String($0))] } ?? [])

        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawSearchResponse.self, from: data)
        return raw.results.map {
            TMDBSearchResult(id: $0.id, title: $0.title ?? $0.name ?? "", year: Self.year(from: $0.release_date), popularity: $0.popularity ?? 0)
        }
    }

    func movieDetails(id: Int) async throws -> TMDBMovieDetails {
        var components = URLComponents(string: "\(apiBase)/movie/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "append_to_response", value: "credits"),
        ]
        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawMovieDetails.self, from: data)
        return TMDBMovieDetails(
            id: raw.id,
            title: raw.title ?? "",
            overview: raw.overview,
            year: Self.year(from: raw.release_date),
            runtimeMinutes: raw.runtime,
            genres: raw.genres?.map(\.name) ?? [],
            voteAverage: raw.vote_average,
            posterPath: raw.poster_path,
            backdropPath: raw.backdrop_path,
            cast: (raw.credits?.cast ?? []).map {
                TMDBCastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path)
            }
        )
    }

    /// TMDB release dates are "YYYY-MM-DD"; take the year.
    static func year(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

// MARK: - Raw TMDB JSON (decoded then mapped to the clean types above)

private struct RawSearchResponse: Decodable {
    var results: [RawMovie]
}

private struct RawMovie: Decodable {
    var id: Int
    var title: String?
    var name: String?
    var release_date: String?
    var popularity: Double?
}

private struct RawMovieDetails: Decodable {
    var id: Int
    var title: String?
    var overview: String?
    var release_date: String?
    var runtime: Int?
    var genres: [RawGenre]?
    var vote_average: Double?
    var poster_path: String?
    var backdrop_path: String?
    var credits: RawCredits?
}

private struct RawGenre: Decodable {
    var name: String
}

private struct RawCredits: Decodable {
    var cast: [RawCast]
}

private struct RawCast: Decodable {
    var id: Int
    var name: String
    var character: String?
    var profile_path: String?
}
