import Hummingbird
import NIOCore

/// The device-authorization **approval page** at `GET /link` — where a user lands
/// after scanning a TV's QR (or following its short URL). It signs the user in
/// (password, or a session carried over from `/user`), shows which device is asking,
/// and lets them approve it. A native client approves via its own
/// passkey-authenticated session by `POST /v1/auth/device/approve` directly; this
/// page is the reference server's browser fallback.
enum DeviceLinkWebController {
    static func addRoutes(to router: Router<SphynxRequestContext>) {
        router.get("link", use: page)
    }

    @Sendable
    static func page(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(string: html)))
    }

    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Approve a device · Sphynx</title>
<style>
  :root { color-scheme: dark; --accent: #FF4D00; }
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 28rem; margin: 4rem auto; padding: 0 1rem; background: #000; color: #e6e6e6; }
  h1 { font-size: 1.4rem; }
  input, button { font: inherit; padding: .55rem .7rem; border-radius: .5rem; border: 1px solid #333; width: 100%; box-sizing: border-box; }
  input { background: #0a0a0a; color: #e6e6e6; }
  button { background: var(--accent); color: #000; border: 0; font-weight: 600; cursor: pointer; margin-top: .5rem; }
  button.secondary { background: transparent; color: #e6e6e6; border: 1px solid #333; }
  .row { margin: .6rem 0; }
  .msg { color: #ff7a7a; min-height: 1.2em; }
  .msg.ok { color: var(--accent); }
  .device { font-weight: 600; }
  .code-in { letter-spacing: .15em; text-transform: uppercase; text-align: center; }
  [hidden] { display: none; }
</style>
</head>
<body>
<h1>Approve a device</h1>

<div id="login">
  <p>Sign in to approve this device.</p>
  <div class="row"><input id="u" placeholder="Username" autocomplete="username"></div>
  <div class="row"><input id="p" type="password" placeholder="Password" autocomplete="current-password"></div>
  <button id="login-btn">Sign in</button>
  <p class="msg" id="login-msg"></p>
</div>

<div id="approve" hidden>
  <div class="row">
    <input id="code" class="code-in" placeholder="ABCD-2345" autocomplete="one-time-code">
  </div>
  <p id="who"></p>
  <button id="approve-btn">Approve this device</button>
  <button id="signout" class="secondary">Sign out</button>
  <p class="msg" id="approve-msg"></p>
</div>

<script>
  var $ = function (s) { return document.querySelector(s); };
  var token = sessionStorage.getItem('sphynxUserToken') || '';

  function qsCode() {
    var m = /[?&]code=([^&]+)/.exec(location.search);
    return m ? decodeURIComponent(m[1]).toUpperCase() : '';
  }
  function api(path, method, body) {
    var headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined });
  }
  function msg(id, text, ok) { var e = $('#' + id); e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); }

  function showApprove() {
    $('#login').hidden = true; $('#approve').hidden = false;
    var code = qsCode(); if (code) $('#code').value = code;
    lookup();
  }
  function lookup() {
    var code = $('#code').value.trim(); if (!code) { $('#who').textContent = ''; return; }
    api('/v1/auth/device/pending?code=' + encodeURIComponent(code), 'GET')
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        if (!d) { $('#who').innerHTML = ''; msg('approve-msg', 'No pending sign-in for that code.'); return; }
        msg('approve-msg', '');
        $('#who').innerHTML = d.label ? 'Sign in <span class="device">' + d.label.replace(/[<>&]/g, '') + '</span>?' : 'Approve this sign-in?';
      });
  }
  $('#code').oninput = lookup;

  $('#login-btn').onclick = function () {
    fetch('/v1/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: $('#u').value, password: $('#p').value }) })
      .then(function (r) { if (!r.ok) { msg('login-msg', 'Invalid username or password.'); return null; } return r.json(); })
      .then(function (d) { if (!d) return; token = d.accessToken; sessionStorage.setItem('sphynxUserToken', token); showApprove(); })
      .catch(function () { msg('login-msg', 'Could not reach the server.'); });
  };
  $('#signout').onclick = function () { token = ''; sessionStorage.removeItem('sphynxUserToken'); $('#approve').hidden = true; $('#login').hidden = false; };

  $('#approve-btn').onclick = function () {
    var code = $('#code').value.trim(); if (!code) { msg('approve-msg', 'Enter the code shown on the device.'); return; }
    api('/v1/auth/device/approve', 'POST', { userCode: code }).then(function (r) {
      if (r.status === 204) { msg('approve-msg', 'Approved — you can return to the device.', true); $('#approve-btn').disabled = true; }
      else if (r.status === 401) { token = ''; sessionStorage.removeItem('sphynxUserToken'); $('#approve').hidden = true; $('#login').hidden = false; }
      else { msg('approve-msg', 'That code is unknown or expired.'); }
    }).catch(function () { msg('approve-msg', 'Could not reach the server.'); });
  };

  if (token) showApprove();
</script>
</body>
</html>
"""#
}
