import Hummingbird
import NIOCore

/// Serves the minimal web admin page at `GET /admin` — a self-contained HTML shell
/// (login + a settings form) that drives the public `/v1/auth/login` and
/// `/v1/admin/settings` endpoints from the browser. The page itself is
/// unauthenticated (it's just static markup); every privileged action it performs
/// goes through the authenticated API with the admin's bearer token.
enum AdminWebController {
    static func addRoutes(to router: Router<SphynxRequestContext>) {
        router.get("admin", use: page)
    }

    @Sendable
    static func page(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "text/html; charset=utf-8"
        return Response(
            status: .ok,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(string: html))
        )
    }

    /// The whole page — markup, style, and script in one file, no build step.
    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sphynx — Admin</title>
<style>
  :root { --bg:#0f1115; --card:#171a21; --line:#262b36; --fg:#e6e9ef; --muted:#9aa3b2; --accent:#6ea8fe; --ok:#54d18c; --err:#ff7a7a; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  .wrap { max-width:680px; margin:6vh auto; padding:0 20px; }
  .brand { display:flex; align-items:center; gap:10px; margin-bottom:6px; }
  .brand h1 { font-size:22px; margin:0; }
  .logo { font-size:26px; }
  .tag { color:var(--muted); margin:0 0 24px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:22px; }
  h2 { font-size:16px; margin:0 0 16px; }
  label { display:block; font-size:13px; color:var(--muted); margin:14px 0 6px; }
  input, select { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; }
  input:focus, select:focus { outline:none; border-color:var(--accent); }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:0 16px; }
  .hint { font-size:12px; color:var(--muted); margin-top:4px; }
  button { margin-top:20px; padding:10px 16px; background:var(--accent); color:#0b1020; border:0; border-radius:9px; font:inherit; font-weight:600; cursor:pointer; }
  button.secondary { background:transparent; color:var(--muted); border:1px solid var(--line); }
  .bar { display:flex; justify-content:space-between; align-items:center; }
  .msg { min-height:18px; margin-top:12px; font-size:13px; color:var(--err); }
  .msg.ok { color:var(--ok); }
  .group-title { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:22px 0 2px; }
  [hidden] { display:none !important; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand"><span class="logo">🐈‍⬛</span><h1>Sphynx</h1></div>
  <p class="tag">Server settings</p>

  <div id="login" class="card">
    <h2>Sign in</h2>
    <label for="u">Admin username</label>
    <input id="u" autocomplete="username" autofocus>
    <label for="p">Password</label>
    <input id="p" type="password" autocomplete="current-password">
    <button id="login-btn">Sign in</button>
    <div id="login-msg" class="msg"></div>
  </div>

  <div id="panel" class="card" hidden>
    <div class="bar"><h2>Runtime settings</h2><button id="logout-btn" class="secondary" style="margin:0;">Sign out</button></div>

    <div class="group-title">Identity</div>
    <div class="row">
      <div><label for="serverName">Server name</label><input id="serverName"></div>
      <div><label for="serverID">Server id</label><input id="serverID"></div>
    </div>

    <div class="group-title">Sessions (seconds)</div>
    <div class="row">
      <div><label for="accessTokenTTL">Access token lifetime</label><input id="accessTokenTTL" type="number" min="0"></div>
      <div><label for="refreshTokenTTL">Refresh token lifetime</label><input id="refreshTokenTTL" type="number" min="0"></div>
    </div>

    <div class="group-title">Metadata &amp; maintenance (seconds)</div>
    <div class="row">
      <div><label for="markersAccess">Markers access</label>
        <select id="markersAccess"><option>none</option><option>read</option><option>readwrite</option></select></div>
      <div><label for="enrichmentTTL">Enrichment freshness</label><input id="enrichmentTTL" type="number" min="0"></div>
      <div><label for="markersStaleAfter">Markers stale after</label><input id="markersStaleAfter" type="number" min="0"></div>
      <div><label for="playstateRetention">Playstate retention</label><input id="playstateRetention" type="number" min="0"></div>
      <div><label for="maintenanceInterval">Maintenance interval</label><input id="maintenanceInterval" type="number" min="0"></div>
    </div>

    <button id="save-btn">Save</button>
    <div id="save-msg" class="msg"></div>
    <p class="hint">Saved settings apply on the next server restart. Host, port, database path, the admin login, and the TMDB key stay environment variables.</p>
  </div>
</div>

<script>
  var $ = function (s) { return document.querySelector(s); };
  var fields = ['serverName','serverID','accessTokenTTL','refreshTokenTTL','enrichmentTTL','markersAccess','markersStaleAfter','playstateRetention','maintenanceInterval'];
  var numbers = ['accessTokenTTL','refreshTokenTTL','enrichmentTTL','markersStaleAfter','playstateRetention','maintenanceInterval'];
  var token = sessionStorage.getItem('sphynxToken') || '';

  function msg(id, text, ok) { var e = $('#' + id); e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); }

  function api(path, method, body) {
    var headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined });
  }

  function login() {
    msg('login-msg', '');
    api('/v1/auth/login', 'POST', { username: $('#u').value, password: $('#p').value })
      .then(function (res) {
        if (!res.ok) { msg('login-msg', 'Invalid username or password.'); return null; }
        return res.json();
      })
      .then(function (data) { if (!data) return; token = data.accessToken; sessionStorage.setItem('sphynxToken', token); loadSettings(); })
      .catch(function () { msg('login-msg', 'Could not reach the server.'); });
  }

  function loadSettings() {
    api('/v1/admin/settings', 'GET').then(function (res) {
      if (res.status === 401) { logout(); return null; }
      if (res.status === 403) { msg('login-msg', 'That account is not the admin.'); return null; }
      if (!res.ok) { msg('login-msg', 'Could not load settings.'); return null; }
      return res.json();
    }).then(function (s) {
      if (!s) return;
      fields.forEach(function (f) { var el = $('#' + f); if (el) el.value = s[f]; });
      $('#login').hidden = true; $('#panel').hidden = false; msg('save-msg', '');
    });
  }

  function save() {
    msg('save-msg', '');
    var body = {};
    fields.forEach(function (f) {
      var el = $('#' + f);
      body[f] = numbers.indexOf(f) >= 0 ? Number(el.value) : el.value;
    });
    api('/v1/admin/settings', 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) {
        res.json().then(function (e) { msg('save-msg', (e && e.error && e.error.message) || 'Save failed.'); }).catch(function () { msg('save-msg', 'Save failed.'); });
        return;
      }
      msg('save-msg', 'Saved. Restart the server for changes to take effect.', true);
    }).catch(function () { msg('save-msg', 'Could not reach the server.'); });
  }

  function logout() { token = ''; sessionStorage.removeItem('sphynxToken'); $('#panel').hidden = true; $('#login').hidden = false; }

  $('#login-btn').onclick = login;
  $('#save-btn').onclick = save;
  $('#logout-btn').onclick = logout;
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  if (token) loadSettings();
</script>
</body>
</html>
"""#
}
