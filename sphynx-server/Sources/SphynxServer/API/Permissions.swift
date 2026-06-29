import Foundation

/// The server's authorization vocabulary.
///
/// A user's permissions are an **open set of string keys**, stored uniformly as
/// JSON text on the user row and forward-compatible (unknown keys are tolerated,
/// never rejected). The bootstrap admin holds **every** permission implicitly and
/// is the only admin — no other account can be promoted (see `AuthService`).
///
/// Well-known keys are defined here, but the model is deliberately extensible:
/// a future capability only needs to define a new key and check it.
enum Permissions {
    /// Browse libraries + resolve/play their items.
    static let libraryRead = "library.read"
    /// Contribute intro/credit markers.
    static let markersWrite = "metadata.markers.write"
    /// Contribute artwork/images.
    static let imagesWrite = "metadata.images.write"
    /// Edit item metadata (title/overview/images/…), lock fields against
    /// auto-refresh, and re-identify / re-enrich an item from TMDB.
    static let metadataEdit = "metadata.edit"
    /// Create and curate **manual collections** (box sets): make a collection in a
    /// library and add/remove movies or series, rename it, or delete it. Distinct
    /// from `metadata.edit` so collection curation can be delegated on its own.
    static let collectionsEdit = "collections.edit"
    /// Trigger a scan/refresh of a source or library (re-index its content).
    /// Source *configuration and credentials* remain admin-only — this grants only
    /// the "go look again" action.
    static let catalogScan = "catalog.scan"

    /// Every well-known key. Used as the admin's effective set in `/v1/auth/me`
    /// and to validate (but not restrict) admin-assigned permissions.
    static let wellKnown: [String] = [
        libraryRead, markersWrite, imagesWrite, metadataEdit, collectionsEdit, catalogScan,
    ]

    /// The default permissions a freshly created user receives: enough to browse
    /// and play. The admin grants write permissions on top as needed.
    static let newUserDefault: [String] = [libraryRead]

    /// Maps a metadata access *field* (as advertised in `/v1/info`) to the
    /// permission key that grants writing it. Used to project the per-field
    /// `metadata` view in `/v1/auth/me`.
    static let writeKeyForField: [String: String] = [
        "markers": markersWrite,
        "images": imagesWrite,
    ]

    /// Scope a permission key to a specific **library or item**: `key:<id>`. A user
    /// granted the scoped form holds the permission for that one library (e.g.
    /// `metadata.edit:lib_abc`) or that single item (`metadata.edit:it_123`) only.
    static func scoped(_ key: String, to id: String) -> String {
        "\(key):\(id)"
    }

    /// Split a stored permission key into its base key and optional scope id
    /// (a library or item id). `"metadata.edit:it_123"` → `("metadata.edit", "it_123")`;
    /// `"library.read"` → `("library.read", nil)`.
    static func split(_ key: String) -> (base: String, scope: String?) {
        guard let colon = key.firstIndex(of: ":") else { return (key, nil) }
        return (String(key[..<colon]), String(key[key.index(after: colon)...]))
    }

    /// The admin permission editor's vocabulary: each well-known capability with a
    /// human label, a description, whether it can be scoped to a single library,
    /// and whether it is reserved (stored but not yet enforced by any endpoint).
    /// Served by `GET /v1/admin/permissions` so the editor is data-driven rather
    /// than hardcoding keys.
    static let catalog: [PermissionCapability] = [
        PermissionCapability(
            key: libraryRead, label: "Browse & play",
            description: "Browse libraries and resolve/play their items.",
            scopable: true, reserved: false),
        PermissionCapability(
            key: markersWrite, label: "Contribute markers",
            description: "Contribute intro/credit markers (when the server allows writes).",
            scopable: true, reserved: false),
        PermissionCapability(
            key: metadataEdit, label: "Edit metadata",
            description: "Edit item metadata, lock fields, and re-identify/re-enrich a title. Scopable per library or per item.",
            scopable: true, reserved: false),
        PermissionCapability(
            key: collectionsEdit, label: "Manage collections",
            description: "Create manual collections (box sets) and add/remove movies or series, rename, or delete them. Scopable per library.",
            scopable: true, reserved: false),
        PermissionCapability(
            key: catalogScan, label: "Scan / refresh",
            description: "Trigger a re-scan of a source or library (not its credentials).",
            scopable: true, reserved: false),
        PermissionCapability(
            key: imagesWrite, label: "Contribute artwork",
            description: "Contribute artwork/images. Reserved — no wire endpoint yet.",
            scopable: true, reserved: true),
    ]
}

/// One well-known permission, described for the admin permission editor.
struct PermissionCapability: Codable, Sendable {
    var key: String
    var label: String
    var description: String
    /// Whether the key may be granted per-library with a `:<libraryId>` suffix.
    var scopable: Bool
    /// Reserved keys are accepted/stored but not yet enforced by any endpoint.
    var reserved: Bool
}
