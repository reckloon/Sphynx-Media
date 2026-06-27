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
    /// Edit item metadata (title/overview/images/…) and lock fields against
    /// auto-refresh.
    static let metadataEdit = "metadata.edit"

    /// Every well-known key. Used as the admin's effective set in `/v1/auth/me`
    /// and to validate (but not restrict) admin-assigned permissions.
    static let wellKnown: [String] = [
        libraryRead, markersWrite, imagesWrite, metadataEdit,
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

    /// Scope a permission key to a specific library: `key:<libraryId>`. A user
    /// granted the scoped form holds the permission for that library only.
    static func scoped(_ key: String, to libraryId: String) -> String {
        "\(key):\(libraryId)"
    }
}
