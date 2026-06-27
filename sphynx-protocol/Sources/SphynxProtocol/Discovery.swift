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

/// Capability advertisement from `GET /v1/info`.
///
/// Per the protocol: "absent = unsupported". Missing booleans decode to `false`,
/// unknown keys are ignored. `metadata` is the **bi-directional access policy**:
/// a per-field map declaring what clients may read/contribute (§4, EXTENDING.md).
public struct Capabilities: Codable, Hashable, Sendable {
    public var search: Bool
    public var playstate: Bool
    /// Does `/resolve` return ranked fallbacks?
    public var candidates: Bool
    /// Per-field metadata access policy, keyed by field/category ("markers",
    /// "images", …). Absent field ⇒ `.none` (read what's served, no writes).
    public var metadata: [String: MetadataAccess]

    public init(
        search: Bool = false,
        playstate: Bool = false,
        candidates: Bool = false,
        metadata: [String: MetadataAccess] = [:]
    ) {
        self.search = search
        self.playstate = playstate
        self.candidates = candidates
        self.metadata = metadata
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.search = try container.decodeIfPresent(Bool.self, forKey: .search) ?? false
        self.playstate = try container.decodeIfPresent(Bool.self, forKey: .playstate) ?? false
        self.candidates = try container.decodeIfPresent(Bool.self, forKey: .candidates) ?? false
        self.metadata = try container.decodeIfPresent([String: MetadataAccess].self, forKey: .metadata) ?? [:]
    }

    /// Access level the server advertises for a field (`.none` if unlisted).
    public func access(_ field: String) -> MetadataAccess {
        metadata[field] ?? .none
    }

    private enum CodingKeys: String, CodingKey {
        case search, playstate, candidates, metadata
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
