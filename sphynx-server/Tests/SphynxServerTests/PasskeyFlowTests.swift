import Foundation
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// Passkey (WebAuthn) coverage. The full register → authenticate ceremony needs a
/// real authenticator to sign challenges, which a unit test can't do; these tests
/// instead pin the parts the server fully owns: capability advertisement, route
/// gating, the option payloads handed to the client, the begin/finish challenge
/// plumbing, and management. A client drives the signing half against the
/// documented contract.
@Suite("Passkeys")
struct PasskeyFlowTests {

    /// A configuration with a Relying Party set, so passkeys are enabled.
    private func passkeyConfiguration() -> ServerConfiguration {
        var cfg = testConfiguration()
        cfg.passkeyRelyingPartyID = "example.com"
        cfg.passkeyRelyingPartyName = "Example Media"
        cfg.passkeyRelyingPartyOrigin = "https://example.com"
        return cfg
    }

    private func login(_ client: some TestClientProtocol) async throws -> String {
        let tokens: TokenResponse = try await client.execute(
            uri: "/v1/auth/login", method: .post,
            headers: jsonHeaders(),
            body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
        ) { try $0.decoded() }
        return tokens.accessToken
    }

    // MARK: Capability + route gating

    @Test("passkeys are off by default and the routes are absent")
    func disabledByDefault() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let info: ServerInfo = try await client.execute(uri: "/v1/info", method: .get) { try $0.decoded() }
            #expect(info.capabilities.passkeys == false)

            // The public authentication route is not mounted when disabled.
            try await client.execute(uri: "/v1/auth/passkeys/authenticate/begin", method: .post) { response in
                #expect(response.status == .notFound)
            }
        }
    }

    @Test("passkeys capability is advertised when a Relying Party is configured")
    func capabilityAdvertised() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let info: ServerInfo = try await client.execute(uri: "/v1/info", method: .get) { try $0.decoded() }
            #expect(info.capabilities.passkeys == true)
        }
    }

    @Test("registration requires authentication")
    func registrationRequiresAuth() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/auth/passkeys/register/begin", method: .post) { response in
                #expect(response.status == .unauthorized)
            }
        }
    }

    // MARK: Registration begin options

    @Test("register/begin returns options bound to the user and Relying Party")
    func registerBeginOptions() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let token = try await login(client)
            let begin: BeginRegistration = try await client.execute(
                uri: "/v1/auth/passkeys/register/begin", method: .post,
                headers: jsonHeaders(bearer: token)
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(!begin.challengeId.isEmpty)
            #expect(!begin.publicKey.challenge.isEmpty)
            #expect(begin.publicKey.rp.id == "example.com")
            #expect(begin.publicKey.rp.name == "Example Media")
            #expect(begin.publicKey.user.name == "admin")
        }
    }

    @Test("a fresh account has no passkeys")
    func listEmpty() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let token = try await login(client)
            let list: PasskeyListResponse = try await client.execute(
                uri: "/v1/auth/passkeys", method: .get, headers: jsonHeaders(bearer: token)
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(list.passkeys.isEmpty)
        }
    }

    // MARK: Authentication begin + challenge plumbing

    @Test("authenticate/begin is public and returns discoverable-login options")
    func authenticateBeginOptions() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let begin: BeginAuthentication = try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/begin", method: .post, headers: jsonHeaders()
            ) { response in
                #expect(response.status == .ok)
                return try response.decoded()
            }
            #expect(!begin.challengeId.isEmpty)
            #expect(!begin.publicKey.challenge.isEmpty)
            #expect(begin.publicKey.rpId == "example.com")
        }
    }

    @Test("authenticate/finish rejects an unknown challenge id")
    func finishRejectsUnknownChallenge() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let body = PasskeyAuthenticationFinishBody(challengeId: "pkc_does_not_exist", credential: .sample)
            try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/finish", method: .post,
                headers: jsonHeaders(), body: try jsonBody(body)
            ) { response in
                #expect(response.status == .badRequest)
            }
        }
    }

    @Test("authenticate/finish with a real challenge but unknown credential fails as unauthorized")
    func finishRejectsUnknownCredential() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let begin: BeginAuthentication = try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/begin", method: .post, headers: jsonHeaders()
            ) { try $0.decoded() }

            let body = PasskeyAuthenticationFinishBody(challengeId: begin.challengeId, credential: .sample)
            try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/finish", method: .post,
                headers: jsonHeaders(), body: try jsonBody(body)
            ) { response in
                // The challenge resolves, but no stored credential matches the
                // assertion's id, so the ceremony fails — opaquely — as 401.
                #expect(response.status == .unauthorized)
            }
        }
    }

    @Test("a challenge is single-use: replaying the same id fails")
    func challengeIsSingleUse() async throws {
        let app = try await buildApplication(configuration: passkeyConfiguration())
        try await app.test(.router) { client in
            let begin: BeginAuthentication = try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/begin", method: .post, headers: jsonHeaders()
            ) { try $0.decoded() }
            let body = PasskeyAuthenticationFinishBody(challengeId: begin.challengeId, credential: .sample)

            // First attempt consumes the challenge (401 — unknown credential).
            try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/finish", method: .post,
                headers: jsonHeaders(), body: try jsonBody(body)
            ) { #expect($0.status == .unauthorized) }

            // Replaying the now-consumed challenge id is rejected as invalid.
            try await client.execute(
                uri: "/v1/auth/passkeys/authenticate/finish", method: .post,
                headers: jsonHeaders(), body: try jsonBody(body)
            ) { #expect($0.status == .badRequest) }
        }
    }
}

// MARK: - Minimal client-side mirrors of the documented wire shapes
//
// The server uses the WebAuthn package's option types; these decode just the
// fields the tests assert, to avoid importing WebAuthn into the test target.

private struct BeginRegistration: Decodable {
    struct Options: Decodable {
        struct RP: Decodable { let id: String; let name: String }
        struct UserEntity: Decodable { let id: String; let name: String; let displayName: String }
        let challenge: String
        let rp: RP
        let user: UserEntity
    }
    let challengeId: String
    let publicKey: Options
}

private struct BeginAuthentication: Decodable {
    struct Options: Decodable { let challenge: String; let rpId: String }
    let challengeId: String
    let publicKey: Options
}

/// A syntactically valid but cryptographically meaningless assertion, enough to
/// exercise the challenge/credential lookup paths (never the signature check).
private struct SampleAssertion: Encodable {
    struct Response: Encodable {
        var clientDataJSON = "AAAA"
        var authenticatorData = "AAAA"
        var signature = "AAAA"
    }
    var id = "dW5rbm93bg"       // base64url("unknown")
    var rawId = "dW5rbm93bg"
    var type = "public-key"
    var response = Response()

    static let sample = SampleAssertion()
}

private struct PasskeyAuthenticationFinishBody: Encodable {
    let challengeId: String
    let credential: SampleAssertion
}
