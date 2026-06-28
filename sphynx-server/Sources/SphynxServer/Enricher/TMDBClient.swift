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
    // Extended metadata (optional; defaulted so stubs/TV need not set them).
    var originalTitle: String? = nil
    var tagline: String? = nil
    var imdbId: String? = nil
    var status: String? = nil
    /// Release date, full "YYYY-MM-DD".
    var releaseDate: String? = nil
    var studios: [String] = []
    var directors: [String] = []
    var writers: [String] = []
    var countries: [String] = []
    /// Collection / box set this movie belongs to (TMDB `belongs_to_collection`).
    var collection: TMDBCollection? = nil
    /// Title-logo / banner artwork (TMDB `/movie/{id}/images`, appended).
    var logoPath: String? = nil
    var bannerPath: String? = nil
    /// Trailer URLs (resolved from TMDB `videos`: YouTube/Vimeo site+key).
    var trailers: [String] = []
    /// Free-form keyword tags (TMDB `keywords`).
    var tags: [String] = []
    /// Content certification (e.g. "PG-13"), from the chosen country's
    /// `release_dates`. Defaulted so stubs need not set it.
    var officialRating: String? = nil
}

/// A TMDB movie collection / box set (from `belongs_to_collection`).
struct TMDBCollection: Sendable {
    var id: Int
    var name: String
    var posterPath: String?
    var backdropPath: String?
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
    /// Series regulars (TMDB `credits.cast`). Defaulted so stubs need not set it.
    var cast: [TMDBCastMember] = []
    /// Content rating (e.g. "TV-MA"), from the chosen country's `content_ratings`.
    var officialRating: String? = nil
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
    /// Episode guest stars (TMDB season `episodes[].guest_stars`). Defaulted so
    /// stubs need not set it.
    var guestStars: [TMDBCastMember] = []
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
            URLQueryItem(name: "append_to_response", value: "credits,videos,keywords,images,release_dates"),
            // Logos for the title-logo image carry no language on backdrops; ask
            // for English + null-language so a clearlogo is available.
            URLQueryItem(name: "include_image_language", value: "en,null"),
        ]
        let data = try await fetcher.getData(url: components.url!.absoluteString, headers: [:])
        let raw = try JSONDecoder().decode(RawMovieDetails.self, from: data)
        let crew = raw.credits?.crew ?? []
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
            },
            originalTitle: raw.original_title,
            tagline: (raw.tagline?.isEmpty ?? true) ? nil : raw.tagline,
            imdbId: (raw.imdb_id?.isEmpty ?? true) ? nil : raw.imdb_id,
            status: raw.status,
            releaseDate: raw.release_date,
            studios: raw.production_companies?.map(\.name) ?? [],
            directors: crew.filter { $0.job == "Director" }.map(\.name),
            writers: crew.filter { $0.department == "Writing" }.map(\.name),
            countries: raw.production_countries?.map(\.name) ?? [],
            collection: raw.belongs_to_collection.map {
                TMDBCollection(id: $0.id, name: $0.name, posterPath: $0.poster_path, backdropPath: $0.backdrop_path)
            },
            logoPath: raw.images?.logos?.first?.file_path,
            bannerPath: Self.bannerPath(from: raw.images?.backdrops),
            trailers: Self.trailerURLs(from: raw.videos?.results ?? []),
            tags: (raw.keywords?.keywords ?? []).map(\.name),
            officialRating: Self.movieCertification(from: raw.release_dates?.results)
        )
    }

    /// The content certification for the configured country (default US) from a
    /// movie's `release_dates`. Prefers a theatrical entry (type 3) but falls back
    /// to any non-empty certification for that country. Best-effort → nil.
    static func movieCertification(from results: [RawCountryReleaseDates]?, country: String = "US") -> String? {
        guard let entry = results?.first(where: { $0.iso_3166_1 == country }) else { return nil }
        let rels = entry.release_dates ?? []
        let theatrical = rels.first { $0.type == 3 && !($0.certification ?? "").isEmpty }
        let any = rels.first { !($0.certification ?? "").isEmpty }
        let cert = (theatrical ?? any)?.certification?.trimmingCharacters(in: .whitespaces)
        return (cert?.isEmpty ?? true) ? nil : cert
    }

    /// Pick a banner-ish image: a backdrop explicitly flagged wide (aspect ≥ 2.0,
    /// i.e. ultra-wide letterbox art), else the widest available backdrop. Best-effort.
    static func bannerPath(from backdrops: [RawImage]?) -> String? {
        guard let backdrops, !backdrops.isEmpty else { return nil }
        let wide = backdrops.first { ($0.aspect_ratio ?? 0) >= 2.0 }
        return (wide ?? backdrops.max { ($0.aspect_ratio ?? 0) < ($1.aspect_ratio ?? 0) })?.file_path
    }

    /// Map TMDB videos to playable URLs (YouTube/Vimeo trailers + teasers).
    static func trailerURLs(from videos: [RawVideo]) -> [String] {
        videos.compactMap { video in
            guard let key = video.key, !key.isEmpty else { return nil }
            let type = (video.type ?? "").lowercased()
            guard type == "trailer" || type == "teaser" else { return nil }
            switch (video.site ?? "").lowercased() {
            case "youtube": return "https://www.youtube.com/watch?v=\(key)"
            case "vimeo":   return "https://vimeo.com/\(key)"
            default:        return nil
            }
        }
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
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "append_to_response", value: "credits,content_ratings"),
        ]
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
            },
            cast: (raw.credits?.cast ?? []).map {
                TMDBCastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path)
            },
            officialRating: Self.tvRating(from: raw.content_ratings?.results)
        )
    }

    /// The content rating for the configured country (default US) from a series'
    /// `content_ratings`. Best-effort → nil.
    static func tvRating(from results: [RawContentRating]?, country: String = "US") -> String? {
        let rating = results?.first(where: { $0.iso_3166_1 == country })?.rating?.trimmingCharacters(in: .whitespaces)
        return (rating?.isEmpty ?? true) ? nil : rating
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
                TMDBEpisode(
                    episodeNumber: $0.episode_number, name: $0.name, overview: $0.overview,
                    stillPath: $0.still_path, airDate: $0.air_date, runtimeMinutes: $0.runtime,
                    guestStars: ($0.guest_stars ?? []).map {
                        TMDBCastMember(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path)
                    }
                )
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
    var original_title: String?
    var overview: String?
    var tagline: String?
    var imdb_id: String?
    var status: String?
    var release_date: String?
    var runtime: Int?
    var genres: [RawGenre]?
    var vote_average: Double?
    var poster_path: String?
    var backdrop_path: String?
    var production_companies: [RawNamed]?
    var production_countries: [RawNamed]?
    var credits: RawCredits?
    var belongs_to_collection: RawCollection?
    var videos: RawVideos?
    var keywords: RawKeywords?
    var images: RawImages?
    var release_dates: RawReleaseDates?
}

/// TMDB `release_dates` append: certifications grouped by country.
struct RawReleaseDates: Decodable {
    var results: [RawCountryReleaseDates]?
}
struct RawCountryReleaseDates: Decodable {
    var iso_3166_1: String
    var release_dates: [RawRelease]?
}
struct RawRelease: Decodable {
    var certification: String?
    /// TMDB release type (1 premiere … 3 theatrical … 6 TV).
    var type: Int?
}

/// TMDB TV `content_ratings` append: a rating per country.
struct RawContentRatings: Decodable {
    var results: [RawContentRating]?
}
struct RawContentRating: Decodable {
    var iso_3166_1: String
    var rating: String?
}

private struct RawCollection: Decodable {
    var id: Int
    var name: String
    var poster_path: String?
    var backdrop_path: String?
}

private struct RawVideos: Decodable {
    var results: [RawVideo]
}

struct RawVideo: Decodable {
    var key: String?
    var site: String?
    var type: String?
}

private struct RawKeywords: Decodable {
    var keywords: [RawNamed]?
}

private struct RawImages: Decodable {
    var logos: [RawImage]?
    var backdrops: [RawImage]?
}

struct RawImage: Decodable {
    var file_path: String?
    var aspect_ratio: Double?
}

private struct RawGenre: Decodable {
    var name: String
}

/// A TMDB object reduced to its `name` (production companies, countries, …).
private struct RawNamed: Decodable {
    var name: String
}

private struct RawCredits: Decodable {
    var cast: [RawCast]
    var crew: [RawCrew]?
}

private struct RawCrew: Decodable {
    var name: String
    var job: String?
    var department: String?
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
    var credits: RawCredits?
    var content_ratings: RawContentRatings?
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
    var guest_stars: [RawCast]?
}
