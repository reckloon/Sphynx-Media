import SphynxProtocol

/// The server's per-field metadata access policy — the bi-directional contract.
/// Built from configuration, advertised in `/v1/info` (`capabilities.metadata`),
/// and enforced on the contribution endpoints.
struct AccessPolicy: Sendable {
    /// Field/category → access level. Absent ⇒ `.none`.
    let fields: [String: MetadataAccess]

    func access(_ field: String) -> MetadataAccess {
        fields[field] ?? .none
    }

    /// The map advertised in capabilities (only fields the server actually
    /// offers; `.none` entries are dropped so absent == not offered).
    var advertised: [String: MetadataAccess] {
        fields.filter { $0.value != .none }
    }

    static func fromConfiguration(_ configuration: ServerConfiguration) -> AccessPolicy {
        let markers = MetadataAccess(rawValue: configuration.markersAccess.lowercased()) ?? .none
        return AccessPolicy(fields: [
            "markers": markers,
            // The reference server serves artwork it enriched, but does not (yet)
            // accept image contributions — advertised read-only.
            "images": .read,
        ])
    }
}
