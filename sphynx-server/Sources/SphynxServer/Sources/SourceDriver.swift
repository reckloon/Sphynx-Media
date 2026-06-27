import SphynxProtocol

/// A raw entry discovered by listing a source (consumed by the Indexer).
/// Carries optional hints from the source so items can be created before
/// identification/enrichment (M4) fills in the rest.
struct SourceEntry: Sendable {
    var key: String
    var title: String?
    var type: String?
    var container: String?
    var year: Int?
    var size: Int?
}

/// A request to turn a source-relative key into a direct location.
struct ResolveRequest: Sendable {
    var key: String
    var container: String?
}

/// A direct, fetchable location plus the hints a player needs. Pure description
/// — resolving never moves bytes.
struct ResolvedLocation: Sendable {
    var url: String
    var headers: [String: String]
    var container: String?
    var ttl: Double?
    var preResolved: Bool
    var candidates: [Candidate]?
}

/// **The load-bearing extension point.** A driver knows how to *enumerate* a
/// backend and *resolve* one of its entries into a direct, fetchable URL. Adding
/// a new backend (s3, webdav, smb, …) means adding a driver; everything upstream
/// is driver-agnostic.
///
/// The server never proxies or transcodes: a driver only ever describes *where*
/// the bytes are.
protocol SourceDriver: Sendable {
    var id: String { get }
    /// Enumerate raw entries. Unused until the Indexer lands (M3).
    func list() async throws -> [SourceEntry]
    /// Resolve one entry into a direct location.
    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation
}
