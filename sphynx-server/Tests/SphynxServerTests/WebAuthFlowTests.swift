import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Web authorization (OAuth-style same-device web sign-in)")
struct WebAuthFlowTests {

    /// PKCE S256 challenge for a verifier, using the server's own base64url helper.
    private func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// The `code` (decoded) from a `redirect_uri?code=…&state=…` redirect.
    private func code(in redirectTo: String) -> String? {
        URLComponents(string: redirectTo)?.queryItems?.first { $0.name == "code" }?.value
    }

    @Test("full PKCE flow: start → authorize → token mints a working, device-scoped session")
    func happyPath() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        let verifier = "verifier-0123456789-abcdefghijklmnop"
        let redirect = "ocelot://auth"
        try await app.test(.router) { client in
            // 1. The client opens the hosted login page in a web session.
            try await client.execute(
                uri: "/v1/auth/web/start?redirect_uri=\(redirect)&state=xyz&code_challenge=\(challenge(for: verifier))&code_challenge_method=S256",
                method: .get
            ) {
                #expect($0.status == .ok)
                let html = String(buffer: $0.body)
                #expect(html.contains("Sign in"))
            }

            // 2. The page submits credentials; the server mints a code and returns
            //    where to navigate (the app's custom scheme, with code + state).
            let authorize: WebAuthorizeResponse = try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "test-password", redirectUri: redirect,
                    state: "xyz", codeChallenge: challenge(for: verifier), codeChallengeMethod: "S256"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(authorize.redirectTo.hasPrefix("ocelot://auth?"))
            #expect(authorize.redirectTo.contains("state=xyz"))
            let authCode = try #require(code(in: authorize.redirectTo))

            // 3. The client redeems the code (with its PKCE verifier) for a session.
            let granted: TokenResponse = try await client.execute(
                uri: "/v1/auth/web/token", method: .post, headers: jsonHeaders(device: "iphone-1"),
                body: try jsonBody(WebTokenRequest(code: authCode, codeVerifier: verifier))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(!granted.accessToken.isEmpty)

            // …and that session actually works.
            let me: MeResponse = try await client.execute(
                uri: "/v1/auth/me", method: .get, headers: jsonHeaders(bearer: granted.accessToken)
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(me.user.displayName == "admin")

            // 4. The code is single-use: a second exchange fails.
            try await client.execute(
                uri: "/v1/auth/web/token", method: .post, headers: jsonHeaders(device: "iphone-1"),
                body: try jsonBody(WebTokenRequest(code: authCode, codeVerifier: verifier))
            ) {
                #expect($0.status == .badRequest)
                let env = try $0.decoded(ErrorEnvelope.self)
                #expect(env.error.code == .unknown("invalid_grant"))
            }
        }
    }

    @Test("authorize/session: a signed-in session (the passkey path) finishes the flow with its bearer")
    func sessionAuthorize() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        let verifier = "verifier-0123456789-abcdefghijklmnop"
        let redirect = "ocelot://auth"
        try await app.test(.router) { client in
            // A session, as the page's passkey ceremony would mint (here via password login).
            let session: TokenResponse = try await client.execute(
                uri: "/v1/auth/login", method: .post, headers: jsonHeaders(),
                body: try jsonBody(LoginRequest(username: "admin", password: "test-password"))
            ) { try $0.decoded() }

            // The page presents that bearer to the secured endpoint to finish the flow.
            let authorize: WebAuthorizeResponse = try await client.execute(
                uri: "/v1/auth/web/authorize/session", method: .post,
                headers: jsonHeaders(bearer: session.accessToken),
                body: try jsonBody(WebAuthorizeSessionRequest(
                    redirectUri: redirect, state: "xyz",
                    codeChallenge: challenge(for: verifier), codeChallengeMethod: "S256"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(authorize.redirectTo.hasPrefix("ocelot://auth?"))
            let authCode = try #require(code(in: authorize.redirectTo))

            // The code redeems for a working session, just like the password path.
            let granted: TokenResponse = try await client.execute(
                uri: "/v1/auth/web/token", method: .post, headers: jsonHeaders(device: "iphone-2"),
                body: try jsonBody(WebTokenRequest(code: authCode, codeVerifier: verifier))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(!granted.accessToken.isEmpty)

            // The endpoint is secured: no bearer ⇒ 401.
            try await client.execute(
                uri: "/v1/auth/web/authorize/session", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeSessionRequest(
                    redirectUri: redirect, state: nil, codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .unauthorized) }

            // And it still enforces the redirect allowlist.
            try await client.execute(
                uri: "/v1/auth/web/authorize/session", method: .post,
                headers: jsonHeaders(bearer: session.accessToken),
                body: try jsonBody(WebAuthorizeSessionRequest(
                    redirectUri: "https://evil.example.com/steal", state: nil, codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .badRequest) }
        }
    }

    @Test("the wrong PKCE verifier is rejected")
    func pkceMismatch() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            let authorize: WebAuthorizeResponse = try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "test-password", redirectUri: "ocelot://auth",
                    state: nil, codeChallenge: challenge(for: "the-real-verifier"), codeChallengeMethod: "S256"))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            let authCode = try #require(code(in: authorize.redirectTo))

            try await client.execute(
                uri: "/v1/auth/web/token", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebTokenRequest(code: authCode, codeVerifier: "a-different-verifier"))
            ) {
                #expect($0.status == .badRequest)
                let env = try $0.decoded(ErrorEnvelope.self)
                #expect(env.error.code == .unknown("invalid_grant"))
            }
        }
    }

    @Test("invalid credentials at authorize are a 401")
    func badCredentials() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "wrong", redirectUri: "ocelot://auth",
                    state: nil, codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .unauthorized) }
        }
    }

    @Test("a web-origin redirect is rejected by default; /v1/info advertises webAuth")
    func openRedirectBlockedAndCapability() async throws {
        let app = try await buildApplication(configuration: testConfiguration())
        try await app.test(.router) { client in
            // No allowlist configured ⇒ http(s) targets are refused (open-redirect guard).
            try await client.execute(
                uri: "/v1/auth/web/start?redirect_uri=https://evil.example.com/steal", method: .get
            ) { #expect($0.status == .badRequest) }

            try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "test-password", redirectUri: "https://evil.example.com/steal",
                    state: nil, codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .badRequest) }

            let info: ServerInfo = try await client.execute(uri: "/v1/info", method: .get) { try $0.decoded() }
            #expect(info.capabilities.webAuth == true)
        }
    }

    @Test("a configured allowlist permits a listed web origin and rejects others")
    func allowlistedWebOrigin() async throws {
        var config = testConfiguration()
        config.webAuthRedirectAllowlist = "https://app.example.com/cb"
        let app = try await buildApplication(configuration: config)
        try await app.test(.router) { client in
            // Listed origin works end-to-end (no PKCE here).
            let authorize: WebAuthorizeResponse = try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "test-password", redirectUri: "https://app.example.com/cb",
                    state: "s1", codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .ok); return try $0.decoded() }
            #expect(authorize.redirectTo.hasPrefix("https://app.example.com/cb?"))

            // A non-listed origin (and now even a custom scheme, since an allowlist
            // is set) is rejected.
            try await client.execute(
                uri: "/v1/auth/web/authorize", method: .post, headers: jsonHeaders(),
                body: try jsonBody(WebAuthorizeRequest(
                    username: "admin", password: "test-password", redirectUri: "https://other.example.com/cb",
                    state: nil, codeChallenge: nil, codeChallengeMethod: nil))
            ) { #expect($0.status == .badRequest) }
        }
    }
}
