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
/// effective** per-field metadata access.
///
/// `/v1/info.capabilities.metadata` advertises what the *server* supports;
/// `metadata` here is what *this user* may actually do (writes are granted
/// per-user by an admin). A client uses this to decide whether to show a
/// "contribute / fix this" affordance.
public struct MeResponse: Codable, Hashable, Sendable {
    public var user: User
    public var metadata: [String: MetadataAccess]

    public init(user: User, metadata: [String: MetadataAccess]) {
        self.user = user
        self.metadata = metadata
    }
}

/// The token pair returned by `login` and `refresh`.
public struct TokenResponse: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    /// Lifetime of the access token, in **seconds** (wire unit is Double).
    public var expiresIn: Double
    public var user: User

    public init(accessToken: String, refreshToken: String, expiresIn: Double, user: User) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.user = user
    }
}
