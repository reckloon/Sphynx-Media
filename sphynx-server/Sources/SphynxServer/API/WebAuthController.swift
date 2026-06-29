import Foundation
import Hummingbird
import NIOCore
import SphynxProtocol

/// OAuth-style **web authorization** endpoints (`/v1/auth/web/*`) — a seamless
/// same-device web sign-in for clients that can't add the server's host to an
/// Associated Domains entitlement (the self-hosted case). All three routes are
/// public (no bearer): the user proves who they are with their password on the
/// hosted page, and the single-use code + PKCE bind the exchange to the client.
///
/// - `GET  auth/web/start`    — renders the hosted login page (carries the client's
///   `redirect_uri` / `state` / PKCE challenge through the form).
/// - `POST auth/web/authorize`— the page submits credentials; on success the server
///   mints a code and returns the `redirect_uri?code=…&state=…` to navigate to.
/// - `POST auth/web/token`    — the client redeems the code for a `TokenResponse`.
struct WebAuthController: Sendable {
    let service: WebAuthService

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        group.get("auth/web/start", use: start)
        group.post("auth/web/authorize", use: authorize)
        group.post("auth/web/token", use: token)
    }

    /// The hosted login page. Validates `redirect_uri` up front so a bad target never
    /// renders a credential form, then embeds the flow parameters for the page's JS.
    @Sendable
    func start(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        let q = request.uri.queryParameters
        let redirectUri = q["redirect_uri"].map(String.init) ?? ""
        guard service.isAllowed(redirectUri: redirectUri) else {
            return Self.htmlResponse(status: .badRequest, body: Self.errorPage(
                "This sign-in link is invalid (its redirect target isn't allowed). Return to the app and try again."))
        }
        let config = WebAuthPageConfig(
            redirectUri: redirectUri,
            state: q["state"].map(String.init),
            codeChallenge: q["code_challenge"].map(String.init),
            codeChallengeMethod: q["code_challenge_method"].map(String.init)
        )
        return Self.htmlResponse(status: .ok, body: Self.loginPage(config: config))
    }

    /// The page POSTs credentials here. Re-validates the redirect (authoritative),
    /// verifies the password, mints a code, and returns where to navigate.
    @Sendable
    func authorize(_ request: Request, context: SphynxRequestContext) async throws -> WebAuthorizeResponse {
        let body = try await request.decode(as: WebAuthorizeRequest.self, context: context)
        guard service.isAllowed(redirectUri: body.redirectUri) else {
            throw SphynxError.badRequest("redirect_uri is not allowed")
        }
        let userId = try await service.auth.verifyPassword(username: body.username, password: body.password)
        let redirectTo = try await service.issueCode(
            userId: userId,
            redirectUri: body.redirectUri,
            state: body.state,
            codeChallenge: body.codeChallenge,
            codeChallengeMethod: body.codeChallengeMethod
        )
        return WebAuthorizeResponse(redirectTo: redirectTo)
    }

    /// The client redeems the single-use code for a session. Honors `X-Sphynx-Device`
    /// for session scoping, like the other auth routes.
    @Sendable
    func token(_ request: Request, context: SphynxRequestContext) async throws -> TokenResponse {
        let body = try await request.decode(as: WebTokenRequest.self, context: context)
        return try await service.exchange(
            code: body.code, codeVerifier: body.codeVerifier, deviceId: request.sphynxDeviceID)
    }

    // MARK: HTML

    private static func htmlResponse(status: HTTPResponse.Status, body: String) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(string: body)))
    }

    /// Render the login page with the flow parameters injected as a JSON config.
    /// Values originate in the URL, so they're embedded via JSON with `<` escaped —
    /// never interpolated into markup — to avoid breaking out of the `<script>`.
    static func loginPage(config: WebAuthPageConfig) -> String {
        let json = (try? JSONEncoder().encode(config)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let safeJSON = json.replacingOccurrences(of: "<", with: "\\u003c")
        return pageHTML
            .replacingOccurrences(of: "/*__CONFIG__*/", with: "var CFG = \(safeJSON);")
            .replacingOccurrences(of: "__ERROR__", with: "")
    }

    static func errorPage(_ message: String) -> String {
        pageHTML
            .replacingOccurrences(of: "/*__CONFIG__*/", with: "var CFG = null;")
            .replacingOccurrences(of: "__ERROR__", with: message.replacingOccurrences(of: "<", with: "&lt;"))
    }

    /// Self-contained page (no framework, no Associated Domains). On submit it calls
    /// `POST /v1/auth/web/authorize`, then navigates to the returned custom-scheme
    /// URL — which the client's `ASWebAuthenticationSession` captures.
    static let pageHTML = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sign in · Sphynx</title>
<style>
  :root { color-scheme: dark; --accent: #FF4D00; }
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 24rem; margin: 4rem auto; padding: 0 1rem; background: #000; color: #e6e6e6; }
  h1 { font-size: 1.4rem; }
  input, button { font: inherit; padding: .55rem .7rem; border-radius: .5rem; border: 1px solid #333; width: 100%; box-sizing: border-box; }
  input { background: #0a0a0a; color: #e6e6e6; }
  button { background: var(--accent); color: #000; border: 0; font-weight: 600; cursor: pointer; margin-top: .5rem; }
  .row { margin: .6rem 0; }
  .msg { color: #ff7a7a; min-height: 1.2em; }
  .msg.ok { color: var(--accent); }
  [hidden] { display: none; }
</style>
</head>
<body>
<h1>Sign in</h1>
<div id="form">
  <p>Sign in to continue to the app.</p>
  <div class="row"><input id="u" placeholder="Username" autocomplete="username" autofocus></div>
  <div class="row"><input id="p" type="password" placeholder="Password" autocomplete="current-password"></div>
  <button id="go">Sign in</button>
  <p class="msg" id="msg"></p>
</div>
<p class="msg" id="fatal">__ERROR__</p>

<script>
  /*__CONFIG__*/
  var $ = function (s) { return document.querySelector(s); };
  function msg(text, ok) { var e = $('#msg'); e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); }

  // No valid flow config (e.g. a bad redirect) — show the fatal note, hide the form.
  if (!CFG) { $('#form').hidden = true; }
  else { $('#fatal').textContent = ''; }

  function submit() {
    if (!CFG) return;
    var payload = {
      username: $('#u').value,
      password: $('#p').value,
      redirectUri: CFG.redirectUri,
      state: CFG.state,
      codeChallenge: CFG.codeChallenge,
      codeChallengeMethod: CFG.codeChallengeMethod
    };
    $('#go').disabled = true;
    fetch('/v1/auth/web/authorize', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
    }).then(function (r) {
      if (r.status === 401) { msg('Invalid username or password.'); $('#go').disabled = false; return null; }
      if (!r.ok) { msg('Could not sign in. Please try again.'); $('#go').disabled = false; return null; }
      return r.json();
    }).then(function (d) {
      if (!d) return;
      msg('Signed in — returning to the app…', true);
      window.location.href = d.redirectTo;
    }).catch(function () { msg('Could not reach the server.'); $('#go').disabled = false; });
  }

  $('#go').onclick = submit;
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') submit(); });
</script>
</body>
</html>
"""#
}

/// The flow parameters carried from `GET /auth/web/start`'s query into the page.
struct WebAuthPageConfig: Codable, Sendable {
    var redirectUri: String
    var state: String?
    var codeChallenge: String?
    var codeChallengeMethod: String?
}

/// `POST /v1/auth/web/authorize` request body (submitted by the hosted page, not a
/// public client API): the credentials plus the flow parameters to bind the code to.
struct WebAuthorizeRequest: Codable, Sendable {
    var username: String
    var password: String
    var redirectUri: String
    var state: String?
    var codeChallenge: String?
    var codeChallengeMethod: String?
}

/// `POST /v1/auth/web/authorize` response: where the page should navigate to deliver
/// the authorization code to the client (`redirect_uri?code=…&state=…`).
struct WebAuthorizeResponse: Codable, Sendable, ResponseEncodable {
    var redirectTo: String
}
