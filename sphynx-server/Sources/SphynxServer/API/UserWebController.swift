import Hummingbird
import NIOCore

/// Serves the end-user self-service page at `GET /user` — a self-contained HTML
/// shell where any signed-in user manages their own profile (display name +
/// server-hosted avatar), changes their password, resets their watch history
/// across devices, and signs out everywhere. It drives only the self-service
/// `/v1/auth/*` and `/v1/playstate` endpoints with the user's own bearer token;
/// it needs no admin rights.
enum UserWebController {
    static func addRoutes(to router: Router<SphynxRequestContext>) {
        router.get("user", use: page)
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

    static let html = #"""
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sphynx — My account</title>
<style>
  :root { --bg:#0f1115; --card:#171a21; --sub:#1d212b; --line:#262b36; --fg:#e6e9ef; --muted:#9aa3b2; --accent:#6ea8fe; --ok:#54d18c; --err:#ff7a7a; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  .wrap { max-width:560px; margin:6vh auto; padding:0 20px 8vh; }
  .brand { display:flex; align-items:center; gap:10px; margin-bottom:4px; }
  .brand h1 { font-size:22px; margin:0; }
  .logo { font-size:26px; }
  .tag { color:var(--muted); margin:0 0 22px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:22px; }
  .card + .card { margin-top:16px; }
  h2 { font-size:16px; margin:0 0 4px; }
  .sub { color:var(--muted); font-size:13px; margin:0 0 14px; }
  label { display:block; font-size:13px; color:var(--muted); margin:14px 0 6px; }
  input { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; }
  input:focus { outline:none; border-color:var(--accent); }
  button { margin-top:18px; padding:10px 16px; background:var(--accent); color:#0b1020; border:0; border-radius:9px; font:inherit; font-weight:600; cursor:pointer; }
  button.secondary { background:transparent; color:var(--muted); border:1px solid var(--line); }
  button.danger { color:var(--err); border:1px solid #3a2730; background:transparent; }
  .msg { min-height:18px; margin-top:12px; font-size:13px; color:var(--err); }
  .msg.ok { color:var(--ok); }
  .hint { font-size:12px; color:var(--muted); margin-top:6px; }
  [hidden] { display:none !important; }
  .me { display:flex; align-items:center; gap:14px; margin-bottom:6px; }
  .avatar { width:64px; height:64px; border-radius:50%; object-fit:cover; background:var(--sub); border:1px solid var(--line); flex:0 0 auto; display:flex; align-items:center; justify-content:center; color:var(--muted); font-size:24px; font-weight:600; }
  .me .who .name { font-weight:600; font-size:16px; }
  .me .who .u { color:var(--muted); font-size:13px; }
  .bar { display:flex; justify-content:space-between; align-items:center; margin-bottom:6px; }
  .row { display:flex; gap:10px; flex-wrap:wrap; align-items:center; }
  .row button { margin-top:0; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand"><span class="logo">🐈‍⬛</span><h1>Sphynx</h1></div>
  <p class="tag">My account</p>

  <div id="login" class="card">
    <h2>Sign in</h2>
    <p class="sub">Sign in to manage your profile and watch history.</p>
    <label for="u">Username</label>
    <input id="u" autocomplete="username" autofocus>
    <label for="p">Password</label>
    <input id="p" type="password" autocomplete="current-password">
    <button id="login-btn">Sign in</button>
    <div id="login-msg" class="msg"></div>
  </div>

  <div id="app" hidden>
    <div class="card">
      <div class="bar"><h2 style="margin:0;">Profile</h2><button id="logout-btn" class="secondary" style="margin:0;">Sign out</button></div>
      <div class="me">
        <span class="avatar" id="avatar"></span>
        <div class="who"><div class="name" id="me-name"></div><div class="u" id="me-user"></div></div>
      </div>
      <label for="dname">Display name</label>
      <input id="dname">
      <button id="save-name-btn">Save name</button>
      <div id="name-msg" class="msg"></div>

      <label for="avatar-file">Profile picture</label>
      <input id="avatar-file" type="file" accept="image/png,image/jpeg,image/webp">
      <p class="hint">PNG, JPEG, or WebP. Replaces your current picture.</p>
      <div class="row">
        <button id="upload-btn">Upload picture</button>
        <button id="remove-avatar-btn" class="secondary">Remove picture</button>
      </div>
      <div id="avatar-msg" class="msg"></div>
    </div>

    <div class="card">
      <h2>Password</h2>
      <p class="sub">Change the password you use to sign in.</p>
      <label for="cur-pw">Current password</label>
      <input id="cur-pw" type="password" autocomplete="current-password">
      <label for="new-pw">New password</label>
      <input id="new-pw" type="password" autocomplete="new-password">
      <button id="pw-btn">Change password</button>
      <div id="pw-msg" class="msg"></div>
    </div>

    <div class="card">
      <h2>Across your devices</h2>
      <p class="sub">These affect your account everywhere you're signed in.</p>
      <div class="row">
        <button id="reset-history-btn" class="danger">Reset watch history</button>
        <button id="logout-all-btn" class="secondary">Sign out everywhere</button>
      </div>
      <p class="hint">Resetting clears your resume positions and watched marks on every device. It can't be undone.</p>
      <div id="device-msg" class="msg"></div>
    </div>
  </div>
</div>

<script>
  var $ = function (s) { return document.querySelector(s); };
  var token = sessionStorage.getItem('sphynxUserToken') || '';
  var refreshToken = sessionStorage.getItem('sphynxUserRefresh') || '';
  var me = null;

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function msg(id, text, ok) { var e = $('#' + id); if (e) { e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); } }

  function api(path, method, body) {
    var headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined });
  }

  function login() {
    msg('login-msg', '');
    fetch('/v1/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: $('#u').value, password: $('#p').value }) })
      .then(function (res) { if (!res.ok) { msg('login-msg', 'Invalid username or password.'); return null; } return res.json(); })
      .then(function (data) { if (!data) return; token = data.accessToken; refreshToken = data.refreshToken; sessionStorage.setItem('sphynxUserToken', token); sessionStorage.setItem('sphynxUserRefresh', refreshToken); enter(); })
      .catch(function () { msg('login-msg', 'Could not reach the server.'); });
  }
  function logout() { token = ''; refreshToken = ''; sessionStorage.removeItem('sphynxUserToken'); sessionStorage.removeItem('sphynxUserRefresh'); $('#app').hidden = true; $('#login').hidden = false; }
  function enter() { $('#login').hidden = true; $('#app').hidden = false; loadMe(); }

  function renderAvatar() {
    var el = $('#avatar');
    if (me && me.user.avatarURL) {
      // The avatar route needs the bearer token, so fetch it and show a blob.
      fetch(me.user.avatarURL, { headers: { 'Authorization': 'Bearer ' + token } })
        .then(function (r) { return r.ok ? r.blob() : null; })
        .then(function (b) { if (b) { el.innerHTML = ''; el.style.backgroundImage = ''; var img = document.createElement('img'); img.className = 'avatar'; img.src = URL.createObjectURL(b); el.replaceWith(img); img.id = 'avatar'; } });
    } else {
      el.textContent = ((me && (me.user.displayName || '')) || '?').charAt(0).toUpperCase();
    }
  }
  function loadMe() {
    api('/v1/auth/me', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      me = d;
      $('#me-name').textContent = d.user.displayName || '';
      $('#me-user').textContent = 'id ' + d.user.id;
      $('#dname').value = d.user.displayName || '';
      renderAvatar();
    });
  }

  function saveName() {
    msg('name-msg', '');
    var name = $('#dname').value.trim();
    if (!name) { msg('name-msg', 'Display name cannot be empty.'); return; }
    api('/v1/auth/me', 'PATCH', { displayName: name }).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { msg('name-msg', 'Could not save your name.'); return; }
      return res.json().then(function (d) { me = d; $('#me-name').textContent = d.user.displayName; msg('name-msg', 'Saved.', true); });
    }).catch(function () { msg('name-msg', 'Could not reach the server.'); });
  }

  function uploadAvatar() {
    msg('avatar-msg', '');
    var f = $('#avatar-file').files[0];
    if (!f) { msg('avatar-msg', 'Choose an image first.'); return; }
    msg('avatar-msg', 'Uploading…');
    fetch('/v1/auth/me/avatar', { method: 'PUT', headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': f.type || 'application/octet-stream' }, body: f })
      .then(function (res) { if (!res.ok) { msg('avatar-msg', res.status === 400 ? 'That image was rejected (use PNG/JPEG/WebP under the size limit).' : 'Upload failed.'); return null; } return res.json(); })
      .then(function (d) { if (!d) return; me = d; $('#avatar-file').value = ''; msg('avatar-msg', 'Picture updated.', true); renderAvatar(); })
      .catch(function () { msg('avatar-msg', 'Could not reach the server.'); });
  }
  function removeAvatar() {
    msg('avatar-msg', '');
    api('/v1/auth/me/avatar', 'DELETE').then(function (res) {
      if (!res.ok) { msg('avatar-msg', 'Could not remove the picture.'); return; }
      return res.json().then(function (d) { me = d; msg('avatar-msg', 'Picture removed.', true); renderAvatar(); });
    }).catch(function () { msg('avatar-msg', 'Could not reach the server.'); });
  }

  function changePassword() {
    msg('pw-msg', '');
    var cur = $('#cur-pw').value, np = $('#new-pw').value;
    if (!cur || !np) { msg('pw-msg', 'Fill in both fields.'); return; }
    api('/v1/auth/password', 'POST', { currentPassword: cur, newPassword: np }).then(function (res) {
      if (res.status === 401) { msg('pw-msg', 'Current password is incorrect.'); return; }
      if (!res.ok) { msg('pw-msg', 'Could not change your password.'); return; }
      $('#cur-pw').value = ''; $('#new-pw').value = ''; msg('pw-msg', 'Password changed.', true);
    }).catch(function () { msg('pw-msg', 'Could not reach the server.'); });
  }

  function resetHistory() {
    if (!confirm('Reset your watch history on every device? This clears resume positions and watched marks and cannot be undone.')) return;
    msg('device-msg', 'Resetting…');
    api('/v1/playstate', 'DELETE').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) { msg('device-msg', 'Could not reset history.'); return; }
      msg('device-msg', 'Watch history reset (' + d.cleared + ' item' + (d.cleared === 1 ? '' : 's') + ' cleared).', true);
    }).catch(function () { msg('device-msg', 'Could not reach the server.'); });
  }
  function logoutEverywhere() {
    if (!confirm('Sign out of every device, including this one?')) return;
    api('/v1/auth/logout', 'POST', { refreshToken: refreshToken, allDevices: true }).then(function () { logout(); }).catch(function () { logout(); });
  }

  $('#login-btn').onclick = login;
  $('#logout-btn').onclick = logout;
  $('#save-name-btn').onclick = saveName;
  $('#upload-btn').onclick = uploadAvatar;
  $('#remove-avatar-btn').onclick = removeAvatar;
  $('#pw-btn').onclick = changePassword;
  $('#reset-history-btn').onclick = resetHistory;
  $('#logout-all-btn').onclick = logoutEverywhere;
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  if (token) enter();
</script>
</body>
</html>
"""#
}
