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
                metadata: policy.advertised
            )
        )
    }
}
