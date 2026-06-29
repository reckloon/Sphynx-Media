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
                candidates: true,
                events: true,
                passkeys: configuration.passkeysEnabled,
                deviceAuth: true,
                webAuth: true,
                metadata: policy.advertised,
                fields: Self.supportedItemFields,
                browse: BrowseCapabilities(
                    sorts: ["added", "name", "rating"],
                    filters: ["genre", "year", "unwatched"]
                ),
                playstateReportInterval: configuration.playstateReportInterval
            )
        )
    }

    /// The canonical `Item` fields this reference server can populate, advertised in
    /// `capabilities.fields` so clients know its coverage up front.
    ///
    /// `chapters` is populated **only when an item has been probed** by the
    /// media-probe extension (ffprobe `-show_chapters` — TMDB has no chapter data);
    /// it's advertised because the server *can* serve it. The one canonical field
    /// the server never fills is `criticRating`: TMDB exposes only an audience score
    /// (`vote_average` → `communityRating`), not a critic aggregate, so a critic
    /// rating needs a different source (e.g. an OMDb-backed extension) or rides in
    /// `extra` / is supplied by the client.
    ///
    /// Keep in sync with `ItemRecord.toProtocol(full:)` + the per-user fold.
    static let supportedItemFields: [String] = [
        // Always present
        "id", "type", "title",
        // Tile / identity / structure
        "tmdbId", "year", "images", "placeholder", "dateAdded", "updatedAt",
        "seriesId", "seriesTitle", "seasonIndex", "episodeIndex", "childCount",
        "parentId", "collectionId", "collectionTitle", "extra",
        // Enrichment (detail=full)
        "overview", "runtime", "genres", "communityRating", "officialRating", "cast",
        "originalTitle", "sortTitle", "tagline", "status", "premiereDate", "endDate",
        "studios", "directors", "writers", "countries", "tags", "trailers", "externalIds",
        // Embedded chapters (when probed by the media-probe extension)
        "chapters",
        // Selectable versions/editions (multiple files of one title)
        "versions",
        // Per-user state
        "resumePosition", "watched", "playCount", "isFavorite", "userRating", "lastPlayedAt",
    ]
}
