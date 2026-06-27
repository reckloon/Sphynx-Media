import Hummingbird
import HTTPTypes

/// Bearer-auth gate. Applied to every protected route group; `/v1/info` and
/// `/v1/auth/*` live on a separate, ungated group.
///
/// On success it stashes the resolved `AuthIdentity` on the context so handlers
/// can row-scope to the subject. On failure it throws the `unauthorized`
/// envelope.
struct AuthMiddleware<Context: AuthenticatedRequestContext>: RouterMiddleware {
    let auth: AuthService

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer ") else {
            throw SphynxError.unauthorized("Missing bearer token")
        }
        let token = String(header.dropFirst("Bearer ".count))
        guard let identity = try await auth.authenticate(accessToken: token) else {
            throw SphynxError.unauthorized("Invalid or expired access token")
        }
        var context = context
        context.identity = identity
        return try await next(request, context)
    }
}

extension Request {
    /// The per-install device id (`X-Sphynx-Device`), or "default" if absent.
    /// Device-scoped tokens let one device be revoked without the others.
    var sphynxDeviceID: String {
        guard let name = HTTPField.Name("X-Sphynx-Device"),
              let value = headers[name], !value.isEmpty
        else { return "default" }
        return value
    }
}
