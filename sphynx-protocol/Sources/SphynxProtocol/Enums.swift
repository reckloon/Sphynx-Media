import Foundation

/// The kind of a catalog item (`Item.type`).
///
/// Open enum: unknown values decode to `.unknown` rather than throwing.
public enum ItemType: OpenEnum {
    case movie
    case series
    case season
    case episode
    case person
    case collection
    case other
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "movie": self = .movie
        case "series": self = .series
        case "season": self = .season
        case "episode": self = .episode
        case "person": self = .person
        case "collection": self = .collection
        case "other": self = .other
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .movie: "movie"
        case .series: "series"
        case .season: "season"
        case .episode: "episode"
        case .person: "person"
        case .collection: "collection"
        case .other: "other"
        case .unknown(let value): value
        }
    }
}

/// The kind of a top-level library (`Library.kind`).
///
/// Open enum: clients map unknown kinds to a neutral default.
public enum LibraryKind: OpenEnum {
    case movies
    case tvShows
    case homeVideos
    case musicVideos
    case boxSets
    case collection
    case other
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "movies": self = .movies
        case "tvShows": self = .tvShows
        case "homeVideos": self = .homeVideos
        case "musicVideos": self = .musicVideos
        case "boxSets": self = .boxSets
        case "collection": self = .collection
        case "other": self = .other
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .movies: "movies"
        case .tvShows: "tvShows"
        case .homeVideos: "homeVideos"
        case .musicVideos: "musicVideos"
        case .boxSets: "boxSets"
        case .collection: "collection"
        case .other: "other"
        case .unknown(let value): value
        }
    }
}
