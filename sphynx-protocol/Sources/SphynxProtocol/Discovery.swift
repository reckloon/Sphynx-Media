import Foundation

/// Access level a server grants for a metadata field/category (§4).
///
/// Open enum, so unknown future levels decode to `.unknown` rather than throwing.
/// A field absent from the capability map means **no contribution advertised** —
/// the client still reads whatever the server serves, but may not write.
public enum MetadataAccess: OpenEnum {
    /// Not offered (neither read nor write advertised).
    case none
    /// Readable, not writable by clients.
    case read
    /// Readable and contributable by clients (subject to auth).
    case readWrite
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "read": self = .read
        case "readwrite": self = .readWrite
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .none: "none"
        case .read: "read"
        case .readWrite: "readwrite"
        case .unknown(let value): value
        }
    }

    /// Whether clients may contribute (write) this field.
    public var allowsWrite: Bool { self == .readWrite }
    /// Whether the field is at least readable.
    public var allowsRead: Bool { self == .read || self == .readWrite }
}

/// What the server's `GET /v1/items` browse endpoint supports, so a client can
/// build its sort/filter affordances from the advertised contract instead of
/// probing. Absent ⇒ the client assumes nothing and offers no typed sort/filter UI.
public struct BrowseCapabilities: Codable, Hashable, Sendable {
    /// Supported `sort` keys for a library's top level (e.g. `["added","name","rating"]`).
    public var sorts: [String]
    /// Supported filter query parameters (e.g. `["genre","unwatched","year"]`).
    public var filters: [String]

    public init(sorts: [String] = [], filters: [String] = []) {
        self.sorts = sorts
        self.filters = filters
    }
}

/// Capability advertisement from `GET /v1/info`.
///
/// Per the protocol: "absent = unsupported". Missing booleans decode to `false`,
/// unknown keys are ignored. `metadata` is the **bi-directional access policy**:
/// a per-field map declaring what clients may read/contribute (§4, EXTENDING.md).
public struct Capabilities: Codable, Hashable, Sendable {
    /// Does the server implement the **optional** search endpoint
    /// (`GET /v1/search` → `SearchResponse`)? `false` ⇒ the endpoint is absent and
    /// the client searches its own synced catalogue instead (see `SearchResponse`).
    public var search: Bool
    public var playstate: Bool
    /// Does `/resolve` return ranked fallbacks?
    public var candidates: Bool
    /// Does the server expose the additive server→client event stream
    /// (`GET /v1/events`, Server-Sent Events)? Absent ⇒ `false`: clients fall
    /// back to polling. The stream is a live-update convenience (continue-watching,
    /// now-playing, watched/favorite sync, "library changed" nudges) and never a
    /// substitute for the access-controlled REST endpoints.
    public var events: Bool
    /// Per-field metadata access policy, keyed by field/category ("markers",
    /// "images", …). Absent field ⇒ `.none` (read what's served, no writes).
    public var metadata: [String: MetadataAccess]
    /// The canonical `Item` field names this server can **populate** (e.g.
    /// `"overview"`, `"genres"`, `"cast"`, `"trailers"`). This is a *coverage*
    /// advertisement — distinct from `metadata`, which is the read/write access
    /// policy. A server is **highly recommended** to list every field it serves so
    /// a client can tell up front which canonical features it backs and inform the
    /// user of unsupported ones. Absent/empty ⇒ the server doesn't advertise
    /// coverage, and a client must not assume any field is present (it falls back
    /// to "render whatever actually arrives").
    public var fields: [String]
    /// What the browse endpoint (`GET /v1/items`) supports — sort keys + filter
    /// params. Absent ⇒ the client offers no typed sort/filter UI. See
    /// `BrowseCapabilities`.
    public var browse: BrowseCapabilities?
    /// Preferred client playback-report cadence, in **seconds**. A client that
    /// reports progress periodically SHOULD use this interval; absent ⇒ the client
    /// falls back to the protocol default (~5s). Push-only: the server stores what
    /// the client sends and never polls the client.
    public var playstateReportInterval: Double?

    public init(
        search: Bool = false,
        playstate: Bool = false,
        candidates: Bool = false,
        events: Bool = false,
        metadata: [String: MetadataAccess] = [:],
        fields: [String] = [],
        browse: BrowseCapabilities? = nil,
        playstateReportInterval: Double? = nil
    ) {
        self.search = search
        self.playstate = playstate
        self.candidates = candidates
        self.events = events
        self.metadata = metadata
        self.fields = fields
        self.browse = browse
        self.playstateReportInterval = playstateReportInterval
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.search = try container.decodeIfPresent(Bool.self, forKey: .search) ?? false
        self.playstate = try container.decodeIfPresent(Bool.self, forKey: .playstate) ?? false
        self.candidates = try container.decodeIfPresent(Bool.self, forKey: .candidates) ?? false
        self.events = try container.decodeIfPresent(Bool.self, forKey: .events) ?? false
        self.metadata = try container.decodeIfPresent([String: MetadataAccess].self, forKey: .metadata) ?? [:]
        self.fields = try container.decodeIfPresent([String].self, forKey: .fields) ?? []
        self.browse = try container.decodeIfPresent(BrowseCapabilities.self, forKey: .browse)
        self.playstateReportInterval = try container.decodeIfPresent(Double.self, forKey: .playstateReportInterval)
    }

    /// Whether the server advertises that it can populate `field`. When the server
    /// publishes no coverage list at all (`fields` empty), this returns `true` —
    /// "unknown, assume it might" — so a client only treats a field as *unsupported*
    /// when the server actively advertises coverage that omits it.
    public func supportsField(_ field: String) -> Bool {
        fields.isEmpty || fields.contains(field)
    }

    /// Access level the server advertises for a field (`.none` if unlisted).
    public func access(_ field: String) -> MetadataAccess {
        metadata[field] ?? .none
    }

    private enum CodingKeys: String, CodingKey {
        case search, playstate, candidates, events, metadata, fields, browse, playstateReportInterval
    }
}

/// Identity + capability response from `GET /v1/info` (unauthenticated).
public struct ServerInfo: Codable, Hashable, Sendable {
    /// Always "Sphynx" for a reference server, but a string so clients can probe.
    public var product: String
    /// Human-facing server name, e.g. "Mike's Library".
    public var serverName: String
    /// Stable server identity, e.g. "srv_…".
    public var id: String
    /// Server version string, e.g. "1.0".
    public var version: String
    /// Supported protocol versions, e.g. ["v1"]. (`protocol` is a Swift keyword,
    /// so the Swift property is `protocols`, mapped to the JSON key `protocol`.)
    public var protocols: [String]
    public var capabilities: Capabilities

    public init(
        product: String = "Sphynx",
        serverName: String,
        id: String,
        version: String,
        protocols: [String] = ["v1"],
        capabilities: Capabilities = Capabilities()
    ) {
        self.product = product
        self.serverName = serverName
        self.id = id
        self.version = version
        self.protocols = protocols
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case product
        case serverName
        case id
        case version
        case protocols = "protocol"
        case capabilities
    }
}
