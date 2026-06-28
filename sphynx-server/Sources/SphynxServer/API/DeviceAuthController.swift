import Foundation
import Hummingbird
import SphynxProtocol

/// Device authorization grant (RFC 8628-style) — QR/code sign-in for TVs and other
/// limited-input clients.
///
/// - **Public** (no bearer): `auth/device/start` (the device begins) and
///   `auth/device/token` (the device polls). Until approval, `token` returns the
///   error envelope with code `authorization_pending`.
/// - **Secured** (bearer): `auth/device/pending` (the approval UI confirms which
///   device) and `auth/device/approve` (the signed-in user approves it).
struct DeviceAuthController: Sendable {
    let service: DeviceAuthService

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.post("auth/device/start", use: start)
        group.post("auth/device/token", use: token)
    }

    func addSecuredRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("auth/device/pending", use: pending)
        group.post("auth/device/approve", use: approve)
    }

    @Sendable
    func start(_ request: Request, context: SphynxRequestContext) async throws -> DeviceAuthResponse {
        // The body (an optional label) may be omitted entirely.
        let body = (try? await request.decode(as: DeviceAuthStartRequest.self, context: context)) ?? DeviceAuthStartRequest()
        return try await service.start(deviceId: request.sphynxDeviceID, label: body.label)
    }

    @Sendable
    func token(_ request: Request, context: SphynxRequestContext) async throws -> TokenResponse {
        let body = try await request.decode(as: DeviceTokenRequest.self, context: context)
        return try await service.poll(deviceCode: body.deviceCode, deviceId: request.sphynxDeviceID)
    }

    @Sendable
    func pending(_ request: Request, context: SphynxRequestContext) async throws -> DevicePendingResponse {
        _ = try context.requireIdentity()  // any signed-in user may look up a code to approve it
        guard let code = request.uri.queryParameters["code"].map(String.init), !code.isEmpty else {
            throw SphynxError.badRequest("Missing 'code'")
        }
        guard let record = try await service.pending(userCode: code) else {
            throw SphynxError.notFound("No pending sign-in for that code")
        }
        let remaining = max(0, record.expiresAt - Date().timeIntervalSince1970)
        return DevicePendingResponse(label: record.label, expiresIn: remaining)
    }

    @Sendable
    func approve(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let identity = try context.requireIdentity()
        let body = try await request.decode(as: DeviceApproveRequest.self, context: context)
        try await service.approve(userCode: body.userCode, userId: identity.userId)
        return Response(status: .noContent)
    }
}
