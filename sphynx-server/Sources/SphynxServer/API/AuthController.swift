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
    }

    /// The authenticated user + that user's effective per-field access.
    @Sendable
    func me(_ request: Request, context: SphynxRequestContext) async throws -> MeResponse {
        guard let identity = context.identity else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        let user = User(id: identity.userId, displayName: identity.displayName, avatarURL: identity.avatarURL)
        return MeResponse(user: user, metadata: identity.effectiveAccess(policy: policy))
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
