import Hummingbird
import SphynxProtocol

/// Implements §4 Discovery: `GET /v1/info` (unauthenticated).
///
/// Lets a client confirm "this URL is a Sphynx server" and learn its
/// capabilities — including the bi-directional metadata access policy — before
/// showing any credential UI.
struct InfoController: Sendable {
    let configuration: ServerConfiguration
    let policy: AccessPolicy

    func addRoutes(to group: RouterGroup<some RequestContext>) {
        group.get("info", use: info)
    }

    /// Reports server identity + capability flags + per-field metadata access.
    @Sendable
    func info(_ request: Request, context: some RequestContext) async throws -> ServerInfo {
        ServerInfo(
            serverName: configuration.serverName,
            id: configuration.serverID,
            version: configuration.version,
            protocols: ["v1"],
            capabilities: Capabilities(
                search: false,
                playstate: true,
                candidates: false,
                events: true,
                metadata: policy.advertised,
                fields: Self.supportedItemFields,
                playstateReportInterval: configuration.playstateReportInterval
            )
        )
    }

    /// The canonical `Item` fields this reference server can populate, advertised in
    /// `capabilities.fields` so clients know its coverage up front. Notably ABSENT
    /// (the server does not currently fill these): `criticRating`, `tags`,
    /// `trailers`, `chapters`, `sortTitle`, and the `logo`/`banner` image roles.
    ///
    /// Keep in sync with `ItemRecord.toProtocol(full:)` + the per-user fold.
    static let supportedItemFields: [String] = [
        // Always present
        "id", "type", "title",
        // Tile / identity / structure
        "tmdbId", "year", "images", "placeholder", "dateAdded", "updatedAt",
        "seriesId", "seriesTitle", "seasonIndex", "episodeIndex", "childCount",
        "parentId", "extra",
        // Enrichment (detail=full)
        "overview", "runtime", "genres", "communityRating", "officialRating", "cast",
        "originalTitle", "tagline", "status", "premiereDate", "endDate",
        "studios", "directors", "writers", "countries", "externalIds",
        // Per-user state
        "resumePosition", "watched", "playCount", "isFavorite", "lastPlayedAt",
    ]
}
