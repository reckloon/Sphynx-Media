import Foundation

/// Minimal TMDB access the Identifier and Enricher need. Abstracted so tests can
/// inject a stub instead of hitting the real API.
protocol TMDBClient: Sendable {
    func searchMovie(title: String, year: Int?) async throws -> [TMDBSearchResult]
    func movieDetails(id: Int) async throws -> TMDBMovieDetails
    // TV
    func searchTV(title: String) async throws -> [TMDBTVSearchResult]
    func tvDetails(id: Int) async throws -> TMDBTVDetails
    func seasonDetails(tvId: Int, season: Int) async throws -> TMDBSeasonDetails
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

// MARK: TV

struct TMDBTVSearchResult: Sendable {
    var id: Int
    var name: String
    var year: Int?
    var popularity: Double
}

struct TMDBTVDetails: Sendable {
    var id: Int
    var name: String
    var overview: String?
    var year: Int?
    var genres: [String]
    var voteAverage: Double?
    var posterPath: String?
    var backdropPath: String?
    var seasons: [TMDBSeasonSummary]
}

struct TMDBSeasonSummary: Sendable {
    var seasonNumber: Int
    var name: String?
    var episodeCount: Int?
    var posterPath: String?
}

struct TMDBSeasonDetails: Sendable {
    var seasonNumber: Int
    var name: String?
    var overview: String?
    var posterPath: String?
    var episodes: [TMDBEpisode]
}

struct TMDBEpisode: Sendable {
    var episodeNumber: Int
    var name: String?
    var overview: String?
    var stillPath: String?
    var airDate: String?
    var runtimeMinutes: Int?
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

    // MARK: TV

    func searchTV(title: String) async throws -> [TMDBTVSearchResult] {
        var components = URLComponents(string: "\(apiBase)/search/tv")!
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "include_adult", value: "false"),
        ]
        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawTVSearchResponse.self, from: data)
        return raw.results.map {
            TMDBTVSearchResult(id: $0.id, name: $0.name ?? $0.original_name ?? "", year: Self.year(from: $0.first_air_date), popularity: $0.popularity ?? 0)
        }
    }

    func tvDetails(id: Int) async throws -> TMDBTVDetails {
        var components = URLComponents(string: "\(apiBase)/tv/\(id)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawTVDetails.self, from: data)
        return TMDBTVDetails(
            id: raw.id,
            name: raw.name ?? "",
            overview: raw.overview,
            year: Self.year(from: raw.first_air_date),
            genres: raw.genres?.map(\.name) ?? [],
            voteAverage: raw.vote_average,
            posterPath: raw.poster_path,
            backdropPath: raw.backdrop_path,
            seasons: (raw.seasons ?? []).map {
                TMDBSeasonSummary(seasonNumber: $0.season_number, name: $0.name, episodeCount: $0.episode_count, posterPath: $0.poster_path)
            }
        )
    }

    func seasonDetails(tvId: Int, season: Int) async throws -> TMDBSeasonDetails {
        var components = URLComponents(string: "\(apiBase)/tv/\(tvId)/season/\(season)")!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawSeasonDetails.self, from: data)
        return TMDBSeasonDetails(
            seasonNumber: raw.season_number ?? season,
            name: raw.name,
            overview: raw.overview,
            posterPath: raw.poster_path,
            episodes: (raw.episodes ?? []).map {
                TMDBEpisode(episodeNumber: $0.episode_number, name: $0.name, overview: $0.overview, stillPath: $0.still_path, airDate: $0.air_date, runtimeMinutes: $0.runtime)
            }
        )
    }

    /// TMDB release/air dates are "YYYY-MM-DD"; take the year.
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

private struct RawTVSearchResponse: Decodable {
    var results: [RawTV]
}

private struct RawTV: Decodable {
    var id: Int
    var name: String?
    var original_name: String?
    var first_air_date: String?
    var popularity: Double?
}

private struct RawTVDetails: Decodable {
    var id: Int
    var name: String?
    var overview: String?
    var first_air_date: String?
    var genres: [RawGenre]?
    var vote_average: Double?
    var poster_path: String?
    var backdrop_path: String?
    var seasons: [RawSeasonSummary]?
}

private struct RawSeasonSummary: Decodable {
    var season_number: Int
    var name: String?
    var episode_count: Int?
    var poster_path: String?
}

private struct RawSeasonDetails: Decodable {
    var season_number: Int?
    var name: String?
    var overview: String?
    var poster_path: String?
    var episodes: [RawEpisode]?
}

private struct RawEpisode: Decodable {
    var episode_number: Int
    var name: String?
    var overview: String?
    var still_path: String?
    var air_date: String?
    var runtime: Int?
}
