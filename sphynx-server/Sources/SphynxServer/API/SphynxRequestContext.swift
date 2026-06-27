import Hummingbird
import SphynxProtocol

/// The authenticated subject attached to a request by `AuthMiddleware`.
struct AuthIdentity: Sendable {
    let userId: String
    let isAdmin: Bool
    let displayName: String
    let avatarURL: String?
    let sessionId: String
    /// The permission keys this user holds. The admin holds everything
    /// implicitly, so this set is ignored for admins.
    let permissions: Set<String>

    /// Whether this user holds a permission. The admin holds all permissions.
    /// When `libraryId` is given, a library-scoped grant (`key:<libraryId>`)
    /// also satisfies the check.
    func has(_ key: String, inLibrary libraryId: String? = nil) -> Bool {
        if isAdmin { return true }
        if permissions.contains(key) { return true }
        if let libraryId, permissions.contains(Permissions.scoped(key, to: libraryId)) { return true }
        return false
    }

    /// Effective write permission for a metadata field given the server's policy:
    /// the server must advertise the field as `readwrite` AND the user must hold
    /// the field's write permission (admins always do).
    func canWrite(_ field: String, policy: AccessPolicy) -> Bool {
        guard policy.access(field) == .readWrite else { return false }
        guard let key = Permissions.writeKeyForField[field] else { return isAdmin }
        return has(key)
    }

    /// This user's effective per-field metadata access (for /auth/me): the server
    /// policy narrowed to what this user may actually do.
    func effectiveAccess(policy: AccessPolicy) -> [String: MetadataAccess] {
        var result: [String: MetadataAccess] = [:]
        for (field, level) in policy.advertised {
            if level == .readWrite, let key = Permissions.writeKeyForField[field] {
                result[field] = has(key) ? .readWrite : .read
            } else {
                result[field] = level
            }
        }
        return result
    }

    /// This user's effective permission keys (for /auth/me). The admin holds the
    /// full well-known set; everyone else holds exactly what was granted.
    func effectivePermissions() -> [String] {
        (isAdmin ? Set(Permissions.wellKnown) : permissions).sorted()
    }
}

/// A request context that can carry an authenticated identity, set by
/// `AuthMiddleware` and read by protected handlers.
protocol AuthenticatedRequestContext: RequestContext {
    var identity: AuthIdentity? { get set }
}

/// The server's request context. Extends Hummingbird's core storage with the
/// authenticated identity. Uses the default JSON decoder/encoder, so protocol
/// value types serve directly as request/response bodies.
struct SphynxRequestContext: AuthenticatedRequestContext {
    var coreContext: CoreRequestContextStorage
    var identity: AuthIdentity?

    init(source: Source) {
        self.coreContext = .init(source: source)
        self.identity = nil
    }
}

extension AuthenticatedRequestContext {
    /// The authenticated subject, or a 401 if the request slipped past the gate.
    func requireIdentity() throws -> AuthIdentity {
        guard let identity else { throw SphynxError.unauthorized("Not authenticated") }
        return identity
    }
}
