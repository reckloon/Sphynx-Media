import Foundation

/// OAuth-style **web authorization** flow — a same-device, seamless web sign-in for
/// clients that cannot claim the server's host in an Associated Domains entitlement
/// (a self-hosted server the client app can't be re-signed for). It mirrors the
/// authorization-code grant, returning to the app via a custom URL scheme instead
/// of a universal link.
///
/// Flow:
/// 1. The client opens `GET /v1/auth/web/start?redirect_uri=<scheme>&state=<opaque>`
///    (plus optional PKCE `code_challenge` / `code_challenge_method`) in an
///    `ASWebAuthenticationSession`. The server renders its normal login page.
/// 2. On a successful sign-in the page redirects to
///    `redirect_uri?code=<authCode>&state=<state>`. The web session captures the
///    custom-scheme redirect and hands the URL back to the client.
/// 3. The client verifies `state` matches what it sent, then exchanges the code:
///    `POST /v1/auth/web/token { code, codeVerifier? }` ⇒ the same `TokenResponse`
///    as `/v1/auth/login`. The `code` is single-use and short-lived (~60s).
///
/// Advertised via `capabilities.webAuth` in `GET /v1/info`. PKCE is recommended so
/// the code exchange is bound to the client that initiated the flow.
public struct WebTokenRequest: Codable, Hashable, Sendable {
    /// The single-use authorization code delivered to the client's `redirect_uri`.
    public var code: String
    /// The PKCE code verifier (the high-entropy secret whose `code_challenge` was
    /// sent to `/auth/web/start`). Required when the flow was started with a
    /// `code_challenge`; omit it for the (discouraged) non-PKCE flow.
    public var codeVerifier: String?

    public init(code: String, codeVerifier: String? = nil) {
        self.code = code
        self.codeVerifier = codeVerifier
    }
}
