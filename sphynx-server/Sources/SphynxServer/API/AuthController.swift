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
