import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Device authorization (QR/code sign-in)")
struct DeviceAuthFlowTests {

    @Test("a TV pairs: start → pending → user approves → device gets a working session")
    func pairingFlow() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            // 1. The TV (no bearer) starts a device-authorization request.
            let start: DeviceAuthResponse = try await client.execute(
                uri: "/v1/auth/device/start", method: .post,
                headers: jsonHeaders(device: "tv-1"),
                body: try jsonBody(DeviceAuthStartRequest(label: "Living Room TV"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(!start.deviceCode.isEmpty)
            #expect(start.userCode.contains("-"))                     // display form, e.g. WXYZ-2345
            #expect(start.verificationUriComplete.contains(start.userCode))
            #expect(start.interval > 0 && start.expiresIn > 0)

            // 2. Polling before approval → authorization_pending (400).
            try await client.execute(
                uri: "/v1/auth/device/token", method: .post, headers: jsonHeaders(device: "tv-1"),
                body: try jsonBody(DeviceTokenRequest(deviceCode: start.deviceCode))
            ) {
                #expect($0.status == .badRequest)
                let env = try $0.decoded(ErrorEnvelope.self)
                #expect(env.error.code == .unknown("authorization_pending"))
            }

            // 3. The user signs in on their phone and looks up what they're approving.
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            let pending: DevicePendingResponse = try await client.execute(
                uri: "/v1/auth/device/pending?code=\(start.userCode)", method: .get,
                headers: jsonHeaders(bearer: token)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(pending.label == "Living Room TV")

            // 4. The user approves it.
            try await client.execute(
                uri: "/v1/auth/device/approve", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(DeviceApproveRequest(userCode: start.userCode))
            ) { #expect($0.status == .noContent) }

            // 5. The TV's next poll returns a real session.
            let granted: TokenResponse = try await client.execute(
                uri: "/v1/auth/device/token", method: .post, headers: jsonHeaders(device: "tv-1"),
                body: try jsonBody(DeviceTokenRequest(deviceCode: start.deviceCode))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(!granted.accessToken.isEmpty)

            // …and that session actually works.
            let me: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: granted.accessToken)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(me.user.displayName == "admin")

            // 6. The device code is single-use: a second claim fails.
            try await client.execute(
                uri: "/v1/auth/device/token", method: .post, headers: jsonHeaders(device: "tv-1"),
                body: try jsonBody(DeviceTokenRequest(deviceCode: start.deviceCode))
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("approving an unknown code is a 404; /v1/info advertises deviceAuth")
    func unknownCodeAndCapability() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let token: String = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded(TokenResponse.self).accessToken }

            try await client.execute(
                uri: "/v1/auth/device/approve", method: .post, headers: jsonHeaders(bearer: token),
                body: try jsonBody(DeviceApproveRequest(userCode: "ZZZZ-9999"))
            ) { #expect($0.status == .notFound) }

            let info: ServerInfo = try await client.execute(
                uri: "/v1/info", method: .get
            ) { try $0.decoded() }
            #expect(info.capabilities.deviceAuth == true)
        }
    }
}
