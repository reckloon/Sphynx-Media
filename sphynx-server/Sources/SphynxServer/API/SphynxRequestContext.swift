import Hummingbird
import SphynxProtocol

/// The authenticated subject attached to a request by `AuthMiddleware`.
struct AuthIdentity: Sendable {
    let userId: String
    let isAdmin: Bool
    let displayName: String
    let avatarURL: String?
    let sessionId: String
    /// Metadata fields this user may contribute (admins may write anything).
    let writeGrants: Set<String>

    /// Effective write permission for a field given the server's policy:
    /// the server must allow the field as `readwrite` AND the user must be
    /// granted it (admins are always granted).
    func canWrite(_ field: String, policy: AccessPolicy) -> Bool {
        guard policy.access(field) == .readWrite else { return false }
        return isAdmin || writeGrants.contains(field)
    }

    /// This user's effective access map, given the server policy (for /auth/me).
    func effectiveAccess(policy: AccessPolicy) -> [String: MetadataAccess] {
        var result: [String: MetadataAccess] = [:]
        for (field, level) in policy.advertised {
            switch level {
            case .readWrite:
                result[field] = (isAdmin || writeGrants.contains(field)) ? .readWrite : .read
            default:
                result[field] = level
            }
        }
        return result
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
