import Foundation

/// The authenticated subject (§3). Carried in the login/refresh response.
public struct User: Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var avatarURL: String?

    public init(id: String, displayName: String, avatarURL: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
    }
}

/// `POST /v1/auth/login` request body.
public struct LoginRequest: Codable, Hashable, Sendable {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// `POST /v1/auth/refresh` request body.
public struct RefreshRequest: Codable, Hashable, Sendable {
    public var refreshToken: String

    public init(refreshToken: String) {
        self.refreshToken = refreshToken
    }
}

/// `POST /v1/auth/logout` request body. `allDevices` optionally revokes every
/// session for the device subject rather than just the presented token.
public struct LogoutRequest: Codable, Hashable, Sendable {
    public var refreshToken: String
    public var allDevices: Bool?

    public init(refreshToken: String, allDevices: Bool? = nil) {
        self.refreshToken = refreshToken
        self.allDevices = allDevices
    }
}

/// Response for `GET /v1/auth/me`: the authenticated user plus **that user's
/// effective** permissions.
///
/// `/v1/info.capabilities` advertises what the *server* supports; the fields
/// here describe what *this user* may actually do (permissions are granted
/// per-user by the admin). A client uses this to decide which affordances to
/// show (browse, contribute markers, edit metadata, …).
///
/// - `permissions`: the user's effective permission keys (e.g. `library.read`,
///   `metadata.markers.write`, `metadata.edit`). The admin holds all of them
///   implicitly. Open-ended and forward-compatible: a client should treat
///   unknown keys as opaque and ignore them.
/// - `metadata`: a per-field metadata-access view (server policy ∩ this user's
///   write permissions), retained for the "contribute / fix this" affordance.
public struct MeResponse: Codable, Hashable, Sendable {
    public var user: User
    public var permissions: [String]
    public var metadata: [String: MetadataAccess]

    public init(user: User, permissions: [String] = [], metadata: [String: MetadataAccess]) {
        self.user = user
        self.permissions = permissions
        self.metadata = metadata
    }
}

/// `POST /v1/auth/password` request body: change the authenticated user's own
/// password. The caller must present its current password.
public struct PasswordChangeRequest: Codable, Hashable, Sendable {
    public var currentPassword: String
    public var newPassword: String

    public init(currentPassword: String, newPassword: String) {
        self.currentPassword = currentPassword
        self.newPassword = newPassword
    }
}

/// The token pair returned by `login` and `refresh`.
public struct TokenResponse: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Lifetime of the access token, in **seconds** (wire unit is Double).
    public var expiresIn: Double
    /// Lifetime of the **refresh** token, in **seconds** (wire unit is Double).
    /// Parallels `expiresIn` so a client can pre-empt a forced re-login. Optional
    /// for back-compat; absent on servers that don't advertise it.
    public var refreshExpiresIn: Double?
    public var user: User

    public init(accessToken: String, refreshToken: String, expiresIn: Double, refreshExpiresIn: Double? = nil, user: User) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.refreshExpiresIn = refreshExpiresIn
        self.user = user
    }
}
