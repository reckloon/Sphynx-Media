import Foundation
import Hummingbird
import SphynxProtocol

/// Implements §3 Authentication: login / refresh / logout. These routes are
/// public (the `/v1/auth/*` group is not behind `AuthMiddleware`).
struct AuthController: Sendable {
    let auth: AuthService
    let policy: AccessPolicy

    /// Public routes (no bearer token required).
    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let authGroup = group.group("auth")
        authGroup.post("login", use: login)
        authGroup.post("refresh", use: refresh)
        authGroup.post("logout", use: logout)
    }

    /// Secured routes (require a valid bearer token).
    func addSecuredRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("auth/me", use: me)
        group.post("auth/password", use: changePassword)
        group.patch("auth/me", use: updateProfile)
        group.put("auth/me/avatar", use: setAvatar)
        group.delete("auth/me/avatar", use: clearAvatar)
        // Serve a user's hosted avatar image (any authenticated user may load it,
        // so clients can show other users' pictures). Bytes only, no envelope.
        group.get("users/:userId/avatar", use: avatar)
    }

    /// The authenticated user + that user's effective permissions and per-field
    /// metadata access.
    @Sendable
    func me(_ request: Request, context: SphynxRequestContext) async throws -> MeResponse {
        guard let identity = context.identity else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        let user = User(id: identity.userId, displayName: identity.displayName, avatarURL: identity.avatarURL)
        return MeResponse(
            user: user,
            permissions: identity.effectivePermissions(),
            metadata: identity.effectiveAccess(policy: policy)
        )
    }

    /// Change the authenticated user's own password (verifies the current one).
    @Sendable
    func changePassword(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        guard let identity = context.identity else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        let body = try await request.decode(as: PasswordChangeRequest.self, context: context)
        try await auth.changePassword(
            userId: identity.userId,
            currentPassword: body.currentPassword,
            newPassword: body.newPassword
        )
        return Response(status: .noContent)
    }

    /// Update the authenticated user's own profile (display name today). Returns
    /// the refreshed `MeResponse` so a client can re-render immediately.
    @Sendable
    func updateProfile(_ request: Request, context: SphynxRequestContext) async throws -> MeResponse {
        let identity = try context.requireIdentity()
        let body = try await request.decode(as: ProfileUpdateRequest.self, context: context)
        let user = try await auth.updateProfile(userId: identity.userId, displayName: body.displayName)
        return meResponse(for: identity, user: user)
    }

    /// Upload (or replace) the authenticated user's avatar. The body is the raw
    /// image bytes (PNG/JPEG/WebP); the type is validated from the bytes and the
    /// size is capped. Returns the refreshed `MeResponse` (with the new `avatarURL`).
    @Sendable
    func setAvatar(_ request: Request, context: SphynxRequestContext) async throws -> MeResponse {
        let identity = try context.requireIdentity()
        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: auth.avatars.maxBytes)
        } catch {
            throw SphynxError.badRequest("Avatar exceeds the maximum size of \(auth.avatars.maxBytes) bytes")
        }
        let user = try await auth.setAvatar(userId: identity.userId, data: Data(buffer: buffer))
        return meResponse(for: identity, user: user)
    }

    /// Remove the authenticated user's avatar. Idempotent.
    @Sendable
    func clearAvatar(_ request: Request, context: SphynxRequestContext) async throws -> MeResponse {
        let identity = try context.requireIdentity()
        let user = try await auth.clearAvatar(userId: identity.userId)
        return meResponse(for: identity, user: user)
    }

    /// Stream a user's hosted avatar image, or 404 if they have none.
    @Sendable
    func avatar(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        _ = try context.requireIdentity()
        guard let userId = context.parameters.get("userId") else {
            throw SphynxError.badRequest("Missing user id")
        }
        guard let stored = auth.avatars.read(userId: userId) else {
            throw SphynxError.notFound("No avatar for '\(userId)'")
        }
        var headers = HTTPFields()
        headers[.contentType] = stored.contentType
        headers[.cacheControl] = "private, max-age=300"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(data: stored.data)))
    }

    /// Build a `MeResponse` for an identity but with a freshly-updated `User`
    /// projection (display name / avatar), reusing the identity's permissions.
    private func meResponse(for identity: AuthIdentity, user: UserRecord) -> MeResponse {
        MeResponse(
            user: user.toProtocol(),
            permissions: identity.effectivePermissions(),
            metadata: identity.effectiveAccess(policy: policy)
        )
    }

    @Sendable
    func login(_ request: Request, context: SphynxRequestContext) async throws -> TokenResponse {
        let body = try await request.decode(as: LoginRequest.self, context: context)
        return try await auth.login(
            username: body.username,
            password: body.password,
            deviceId: request.sphynxDeviceID
        )
    }

    @Sendable
    func refresh(_ request: Request, context: SphynxRequestContext) async throws -> TokenResponse {
        let body = try await request.decode(as: RefreshRequest.self, context: context)
        return try await auth.refresh(refreshToken: body.refreshToken, deviceId: request.sphynxDeviceID)
    }

    @Sendable
    func logout(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let body = try await request.decode(as: LogoutRequest.self, context: context)
        try await auth.logout(refreshToken: body.refreshToken, allDevices: body.allDevices ?? false)
        return Response(status: .noContent)
    }
}
