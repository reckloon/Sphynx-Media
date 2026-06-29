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
  .row2 { display:grid; grid-template-columns:1fr 1fr; gap:0 14px; }
  .group-title { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:18px 0 8px; }
  .item { display:flex; justify-content:space-between; align-items:center; gap:12px; padding:10px 12px; background:#0e1117; border:1px solid var(--line); border-radius:10px; margin-bottom:8px; }
  .item .meta { font-size:13px; color:var(--muted); }
  .empty { color:var(--muted); font-size:14px; padding:6px 0; }
  .chip { display:inline-block; padding:2px 7px; border-radius:6px; font-size:11px; border:1px solid var(--line); background:var(--bg); color:var(--muted); }
  .crumbs { font-size:13px; color:var(--muted); margin:10px 0; }
  .crumbs a { color:var(--accent); cursor:pointer; }
  .it-row { display:flex; align-items:center; gap:11px; min-width:0; }
  .it-thumb { width:30px; height:44px; object-fit:cover; border-radius:4px; background:var(--bg); border:1px solid var(--line); flex:0 0 auto; display:inline-flex; align-items:center; justify-content:center; font-size:16px; }
  button.mini { margin:0; padding:5px 11px; font-size:13px; font-weight:500; }
  .editor { border-top:1px solid var(--line); margin-top:16px; padding-top:6px; }
  .lockbadge { font-size:11px; color:#e8c468; }
  textarea { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; resize:vertical; }
  textarea:focus { outline:none; border-color:var(--accent); }
  select { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; }
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

    <div class="card">
      <h2>Signed-in devices</h2>
      <p class="sub">Each device you've signed in from. Sign out any you don't recognize.</p>
      <div id="sessions-list"><div class="empty">Loading…</div></div>
      <div id="sessions-msg" class="msg"></div>
    </div>

    <div class="card">
      <h2>Passkeys</h2>
      <p class="sub">Passwordless sign-in with Face ID, Touch ID, Windows Hello, or a security key. <span id="pk-unavailable" class="muted" hidden>This server doesn't have passkeys enabled.</span></p>
      <div id="passkeys-list"><div class="empty">Loading…</div></div>
      <div class="row"><button id="pk-add-btn">Add a passkey</button></div>
      <div id="passkeys-msg" class="msg"></div>
    </div>

    <div class="card" id="correction-card" hidden>
      <h2>Library correction</h2>
      <p class="sub">You can fix titles in the libraries you have edit access to. Browse the library, open a title, and correct its details. Anything you change is <strong>locked</strong> 🔒 so a re-scan won't overwrite it.</p>
      <label for="cx-lib">Library</label>
      <select id="cx-lib"></select>
      <div class="row2" style="margin-top:8px; align-items:center;">
        <input id="cx-search" placeholder="…or search all titles you can edit">
        <label style="display:flex; align-items:center; gap:6px; white-space:nowrap; margin:0;"><input type="checkbox" id="cx-needs" style="width:auto;"> Needs metadata</label>
      </div>
      <div id="cx-crumbs" class="crumbs"></div>
      <div id="cx-list"><div class="empty">Pick a library to browse its titles.</div></div>

      <div id="cx-editor" class="editor" hidden>
        <div class="group-title">Editing <span id="cx-ed-title" class="muted"></span></div>
        <div class="lockrow"><label for="cx-f-title">Title <span class="lockbadge" data-lb="title"></span></label><input id="cx-f-title"></div>
        <div class="lockrow"><label for="cx-f-overview">Overview <span class="lockbadge" data-lb="overview"></span></label><textarea id="cx-f-overview" rows="3"></textarea></div>
        <div class="row2">
          <div class="lockrow"><label for="cx-f-year">Year <span class="lockbadge" data-lb="year"></span></label><input id="cx-f-year" type="number"></div>
          <div class="lockrow"><label for="cx-f-runtime">Runtime (min) <span class="lockbadge" data-lb="runtime"></span></label><input id="cx-f-runtime" type="number" min="0"></div>
        </div>
        <div class="row2">
          <div class="lockrow"><label for="cx-f-rating">Community rating <span class="lockbadge" data-lb="communityRating"></span></label><input id="cx-f-rating" type="number" step="0.1" min="0" max="10"></div>
          <div class="lockrow"><label for="cx-f-official">Content rating <span class="lockbadge" data-lb="officialRating"></span></label><input id="cx-f-official" placeholder="PG-13"></div>
        </div>
        <div class="lockrow"><label for="cx-f-genres">Genres (comma-separated) <span class="lockbadge" data-lb="genres"></span></label><input id="cx-f-genres" placeholder="Action, Drama"></div>
        <div class="lockrow"><label for="cx-f-primary">Poster URL <span class="lockbadge" data-lb="images"></span></label><input id="cx-f-primary" placeholder="https://…"></div>
        <div class="lockrow"><label for="cx-f-backdrop">Backdrop URL <span class="lockbadge" data-lb="images"></span></label><input id="cx-f-backdrop" placeholder="https://…"></div>
        <div class="row">
          <button id="cx-save-btn">Save &amp; lock edited fields</button>
          <button id="cx-unlock-btn" class="secondary">Unlock all</button>
          <button id="cx-enrich-btn" class="secondary">Re-enrich</button>
        </div>

        <div class="group-title" style="margin-top:16px;">Re-identify</div>
        <p class="sub">Pin this title to the correct TMDB entry, then re-fetch its details.</p>
        <div class="row2">
          <div><label for="cx-f-tmdb">TMDB id</label><input id="cx-f-tmdb" placeholder="603"></div>
          <div><label for="cx-f-tmdb-type">As type</label><select id="cx-f-tmdb-type"><option value="">(keep)</option><option value="movie">movie</option><option value="series">series</option></select></div>
        </div>
        <button id="cx-identify-btn" class="secondary">Re-identify &amp; enrich</button>

        <div class="group-title" style="margin-top:16px;">Re-map (fix placement)</div>
        <p class="sub">Wrong library, or an episode/season not linked to its show? Change its type, move it to another library, set its season/episode number, or nest it under the right series or season. Needs edit rights on both the current and destination library.</p>
        <div class="row2">
          <div><label for="cx-f-type">Type</label><select id="cx-f-type"><option value="">(keep)</option><option>movie</option><option>series</option><option>season</option><option>episode</option><option>collection</option><option>trailer</option><option>featurette</option><option>deletedScene</option><option>behindTheScenes</option></select></div>
          <div><label for="cx-f-library">Move to library</label><select id="cx-f-library"></select></div>
        </div>
        <div class="row2">
          <div><label for="cx-f-season">Season #</label><input id="cx-f-season" type="number" min="0"></div>
          <div><label for="cx-f-episode">Episode #</label><input id="cx-f-episode" type="number" min="0"></div>
        </div>
        <label for="cx-parent-search">Nest under a series or season</label>
        <div class="row2" style="align-items:center;">
          <input id="cx-parent-search" placeholder="Search series or seasons by name…">
          <button id="cx-parent-find" class="secondary" type="button" style="white-space:nowrap;">Find</button>
        </div>
        <select id="cx-parent-pick" style="margin-top:6px;"><option value="">(keep current parent)</option></select>
        <div class="row" style="margin-top:12px;">
          <button id="cx-remap-btn">Apply re-map</button>
          <button id="cx-close-btn" class="secondary">Close</button>
        </div>
        <div id="cx-msg" class="msg"></div>
      </div>
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
      initCorrection(d.permissions || []);
      loadSessions();
      loadPasskeys();
    });
  }

  // ---- signed-in devices (sessions) ----
  function loadSessions() {
    api('/v1/auth/sessions', 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      var list = d.sessions || [];
      $('#sessions-list').innerHTML = list.length ? list.map(function (s) {
        var when = (s.lastActiveAt || '').replace('T', ' ').replace(/(\.\d+)?(Z|[+-]\d\d:?\d\d)?$/, '');
        var tag = s.current ? ' <span class="muted">· this device</span>' : '';
        return '<div class="item"><span><strong>' + esc(s.deviceId || 'device') + '</strong>' + tag + ' <span class="meta">last active ' + esc(when) + '</span></span>' +
          '<button class="mini ' + (s.current ? 'secondary' : 'danger') + '" data-revoke="' + esc(s.id) + '">' + (s.current ? 'Sign out' : 'Sign out') + '</button></div>';
      }).join('') : '<div class="empty">No active sessions.</div>';
    });
  }
  $('#sessions-list').onclick = function (e) {
    var id = e.target.getAttribute('data-revoke'); if (!id) return;
    if (!confirm('Sign out this device?')) return;
    api('/v1/auth/sessions/' + id, 'DELETE').then(function (res) {
      if (!res.ok) { msg('sessions-msg', 'Could not sign that device out.'); return; }
      // If it was the current session, the next request will 401 and bounce to login.
      msg('sessions-msg', 'Signed out.', true); loadSessions();
    });
  };

  // ---- passkeys ----
  function b64urlToBuf(s) { s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '='; var bin = atob(s); var b = new Uint8Array(bin.length); for (var i = 0; i < bin.length; i++) b[i] = bin.charCodeAt(i); return b.buffer; }
  function bufToB64url(buf) { var b = new Uint8Array(buf), s = ''; for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); }
  function loadPasskeys() {
    api('/v1/auth/passkeys', 'GET').then(function (res) {
      if (res.status === 404) { $('#pk-unavailable').hidden = false; $('#pk-add-btn').disabled = true; $('#passkeys-list').innerHTML = ''; return null; }
      return res.ok ? res.json() : null;
    }).then(function (d) {
      if (!d) return;
      var list = d.passkeys || [];
      $('#passkeys-list').innerHTML = list.length ? list.map(function (p) {
        return '<div class="item"><span><strong>' + esc(p.label || 'Passkey') + '</strong>' + (p.backedUp ? ' <span class="muted">· synced</span>' : '') + '</span><button class="mini danger" data-pk="' + esc(p.id) + '">Remove</button></div>';
      }).join('') : '<div class="empty">No passkeys yet. Add one to sign in without a password.</div>';
    });
  }
  $('#passkeys-list').onclick = function (e) {
    var id = e.target.getAttribute('data-pk'); if (!id) return;
    if (!confirm('Remove this passkey?')) return;
    api('/v1/auth/passkeys/' + id, 'DELETE').then(function (res) { if (res.ok) { msg('passkeys-msg', 'Removed.', true); loadPasskeys(); } else msg('passkeys-msg', 'Could not remove it.'); });
  };
  function addPasskey() {
    if (!window.PublicKeyCredential) { msg('passkeys-msg', 'This browser does not support passkeys.'); return; }
    msg('passkeys-msg', 'Follow your device prompt…');
    api('/v1/auth/passkeys/register/begin', 'POST', {}).then(function (res) { return res.ok ? res.json() : null; }).then(function (opts) {
      if (!opts) { msg('passkeys-msg', 'Could not start registration.'); return; }
      var pk = opts.publicKey || opts;
      pk.challenge = b64urlToBuf(pk.challenge);
      pk.user.id = b64urlToBuf(pk.user.id);
      if (pk.excludeCredentials) pk.excludeCredentials = pk.excludeCredentials.map(function (c) { return { id: b64urlToBuf(c.id), type: c.type, transports: c.transports }; });
      return navigator.credentials.create({ publicKey: pk }).then(function (cred) {
        var body = { id: cred.id, rawId: bufToB64url(cred.rawId), type: cred.type,
          response: { clientDataJSON: bufToB64url(cred.response.clientDataJSON), attestationObject: bufToB64url(cred.response.attestationObject) } };
        return api('/v1/auth/passkeys/register/finish', 'POST', body).then(function (r) {
          if (!r.ok) { msg('passkeys-msg', 'Registration failed.'); return; }
          msg('passkeys-msg', 'Passkey added.', true); loadPasskeys();
        });
      });
    }).catch(function () { msg('passkeys-msg', 'Registration was cancelled or failed.'); });
  }

  // ---- library correction (shown only to users who hold metadata.edit) ----
  var CX_LOCKABLE = ['title', 'overview', 'year', 'runtime', 'communityRating', 'officialRating', 'genres', 'images'];
  var cxNav = [], cxEditing = null, cxOrig = {}, cxInited = false, cxLibs = [];
  function canEdit(perms) { return perms.some(function (p) { return p === 'metadata.edit' || p.indexOf('metadata.edit:') === 0; }); }
  function initCorrection(perms) {
    if (!canEdit(perms)) { $('#correction-card').hidden = true; return; }
    $('#correction-card').hidden = false;
    if (cxInited) return; cxInited = true;
    api('/v1/libraries', 'GET').then(function (res) { return res.ok ? res.json() : { libraries: [] }; }).then(function (d) {
      var libs = d.libraries || []; cxLibs = libs;
      $('#cx-lib').innerHTML = '<option value="">— pick —</option>' + libs.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join('');
    });
  }
  $('#cx-lib').onchange = function () {
    cxNav = []; var id = $('#cx-lib').value;
    if (id) { $('#cx-search').value = ''; $('#cx-needs').checked = false; cxNav.push({ id: id, title: $('#cx-lib').selectedOptions[0].textContent }); cxList(); }
    else { $('#cx-list').innerHTML = '<div class="empty">Pick a library to browse its titles.</div>'; $('#cx-crumbs').innerHTML = ''; cxClose(); }
  };
  function cxRow(it) {
    var container = it.type === 'collection' || it.type === 'series' || it.type === 'season' || (it.childCount && it.childCount > 0);
    var poster = (it.images && it.images.primary)
      ? '<img class="it-thumb" loading="lazy" src="' + esc(it.images.primary) + '" alt="">'
      : '<span class="it-thumb">' + (container ? '📁' : '🎞️') + '</span>';
    var open = container ? '<button class="mini secondary" data-open="' + esc(it.id) + '" data-title="' + esc(it.title) + '">Open</button>' : '';
    var sub = it.childCount ? (it.childCount + ' inside') : (it.year ? String(it.year) : '');
    return '<div class="item"><span class="it-row">' + poster + '<span><span class="chip">' + esc(it.type || 'item') + '</span> ' + esc(it.title) + (sub ? ' <span class="meta">' + esc(sub) + '</span>' : '') + '</span></span><span class="row">' + open + '<button class="mini" data-fix="' + esc(it.id) + '">Fix</button></span></div>';
  }
  function cxList() {
    var top = cxNav[cxNav.length - 1]; if (!top) return;
    var up = cxNav.length > 1 ? '<a data-up="1">⬆ Up</a> · ' : '';
    $('#cx-crumbs').innerHTML = up + cxNav.map(function (n, i) { return '<a data-crumb="' + i + '">' + esc(n.title) + '</a>'; }).join(' › ');
    api('/v1/admin/items?parent=' + encodeURIComponent(top.id) + '&limit=500', 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = d.items || [];
      $('#cx-list').innerHTML = items.length ? items.map(cxRow).join('') : '<div class="empty">Nothing here.</div>';
    });
  }
  $('#cx-crumbs').onclick = function (e) {
    if (e.target.getAttribute('data-up') != null) { if (cxNav.length > 1) { cxNav.pop(); cxClose(); cxList(); } return; }
    var i = e.target.getAttribute('data-crumb'); if (i == null) return;
    cxNav = cxNav.slice(0, Number(i) + 1); cxClose(); cxList();
  };
  $('#cx-list').onclick = function (e) {
    var open = e.target.getAttribute('data-open');
    if (open) { cxNav.push({ id: open, title: e.target.getAttribute('data-title') }); cxClose(); cxList(); return; }
    var fix = e.target.getAttribute('data-fix'); if (fix) cxOpen(fix);
  };
  function cxBadges(locked) { CX_LOCKABLE.forEach(function (f) { var el = document.querySelector('#cx-editor .lockbadge[data-lb="' + f + '"]'); if (el) el.textContent = locked.indexOf(f) >= 0 ? '🔒 locked' : ''; }); }
  function cxOpen(id) {
    msg('cx-msg', '');
    api('/v1/admin/items/' + id, 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (r) {
      if (!r) { msg('cx-msg', 'Could not load item.'); return; }
      cxEditing = id; var it = r.item; $('#cx-editor').hidden = false;
      $('#cx-ed-title').textContent = it.title || id;
      $('#cx-f-title').value = it.title || ''; $('#cx-f-overview').value = it.overview || '';
      $('#cx-f-year').value = it.year || ''; $('#cx-f-runtime').value = it.runtime ? Math.round(it.runtime / 60) : '';
      $('#cx-f-rating').value = it.communityRating != null ? it.communityRating : ''; $('#cx-f-official').value = it.officialRating || '';
      $('#cx-f-genres').value = (it.genres || []).join(', ');
      $('#cx-f-primary').value = (it.images && it.images.primary) || ''; $('#cx-f-backdrop').value = (it.images && it.images.backdrop) || '';
      $('#cx-f-tmdb').value = ''; $('#cx-f-tmdb-type').value = '';
      $('#cx-f-library').innerHTML = '<option value="">(keep)</option>' + cxLibs.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join('');
      $('#cx-f-library').value = ''; $('#cx-f-type').value = '';
      $('#cx-f-season').value = (it.seasonIndex != null ? it.seasonIndex : '');
      $('#cx-f-episode').value = (it.episodeIndex != null ? it.episodeIndex : '');
      $('#cx-parent-search').value = ''; $('#cx-parent-pick').innerHTML = '<option value="">(keep current parent)</option>';
      cxOrig = { title: $('#cx-f-title').value, overview: $('#cx-f-overview').value, year: $('#cx-f-year').value, runtime: $('#cx-f-runtime').value, rating: $('#cx-f-rating').value, official: $('#cx-f-official').value, genres: $('#cx-f-genres').value, primary: $('#cx-f-primary').value, backdrop: $('#cx-f-backdrop').value, season: $('#cx-f-season').value, episode: $('#cx-f-episode').value };
      cxBadges(r.lockedFields || []);
      $('#cx-editor').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });
  }
  function cxClose() { $('#cx-editor').hidden = true; cxEditing = null; }
  function cxSave() {
    if (!cxEditing) return;
    var body = {}, o = cxOrig;
    if ($('#cx-f-title').value !== o.title) body.title = $('#cx-f-title').value;
    if ($('#cx-f-overview').value !== o.overview) body.overview = $('#cx-f-overview').value;
    if ($('#cx-f-year').value !== o.year) { var y = $('#cx-f-year').value; if (y !== '') body.year = Number(y); }
    if ($('#cx-f-runtime').value !== o.runtime) { var rt = $('#cx-f-runtime').value; if (rt !== '') body.runtime = Math.round(Number(rt) * 60); }
    if ($('#cx-f-rating').value !== o.rating) { var cr = $('#cx-f-rating').value; if (cr !== '') body.communityRating = Number(cr); }
    if ($('#cx-f-official').value !== o.official) body.officialRating = $('#cx-f-official').value;
    if ($('#cx-f-genres').value !== o.genres) { var g = $('#cx-f-genres').value.trim(); if (g) body.genres = g.split(',').map(function (x) { return x.trim(); }).filter(Boolean); }
    if ($('#cx-f-primary').value !== o.primary || $('#cx-f-backdrop').value !== o.backdrop) body.images = { primary: $('#cx-f-primary').value || null, backdrop: $('#cx-f-backdrop').value || null };
    if (!Object.keys(body).length) { msg('cx-msg', 'No changes to save.'); return; }
    msg('cx-msg', 'Saving…');
    api('/v1/admin/items/' + cxEditing, 'PATCH', body).then(function (res) { return res.ok ? res.json() : null; }).then(function (r) {
      if (!r) { msg('cx-msg', 'Save failed.'); return; }
      msg('cx-msg', 'Saved and locked the edited fields.', true);
      cxOrig = { title: $('#cx-f-title').value, overview: $('#cx-f-overview').value, year: $('#cx-f-year').value, runtime: $('#cx-f-runtime').value, rating: $('#cx-f-rating').value, official: $('#cx-f-official').value, genres: $('#cx-f-genres').value, primary: $('#cx-f-primary').value, backdrop: $('#cx-f-backdrop').value };
      cxBadges(r.lockedFields || []); cxList();
    }).catch(function () { msg('cx-msg', 'Could not reach the server.'); });
  }
  function cxUnlock() {
    if (!cxEditing) return;
    api('/v1/admin/items/' + cxEditing, 'PATCH', { unlockAll: true }).then(function (res) { return res.ok ? res.json() : null; }).then(function (r) { if (r) { cxBadges([]); msg('cx-msg', 'Unlocked.', true); } });
  }
  function cxEnrich() {
    if (!cxEditing) return;
    msg('cx-msg', 'Re-enriching…');
    api('/v1/admin/items/' + cxEditing + '/enrich', 'POST').then(function (res) {
      if (!res.ok) { msg('cx-msg', res.status === 400 ? 'Enrichment needs a TMDB key (ask an admin).' : 'Enrich failed.'); return; }
      msg('cx-msg', 'Re-enriched.', true); cxOpen(cxEditing); cxList();
    }).catch(function () { msg('cx-msg', 'Could not reach the server.'); });
  }
  function cxIdentify() {
    if (!cxEditing) return;
    var tmdb = $('#cx-f-tmdb').value.trim();
    if (!tmdb) { msg('cx-msg', 'Enter a TMDB id.'); return; }
    var body = { tmdbId: tmdb }; var t = $('#cx-f-tmdb-type').value; if (t) body.type = t;
    msg('cx-msg', 'Re-identifying…');
    api('/v1/admin/items/' + cxEditing + '/identity', 'POST', body).then(function (res) {
      if (!res.ok) { msg('cx-msg', res.status === 400 ? 'Re-identify needs a TMDB key (ask an admin).' : 'Re-identify failed.'); return; }
      msg('cx-msg', 'Re-identified and enriched.', true); cxOpen(cxEditing); cxList();
    }).catch(function () { msg('cx-msg', 'Could not reach the server.'); });
  }
  function cxFindParents() {
    var q = $('#cx-parent-search').value.trim();
    if (!q) { msg('cx-msg', 'Type a series or season name to search.'); return; }
    msg('cx-msg', 'Searching…');
    api('/v1/admin/items?search=' + encodeURIComponent(q), 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = (d.items || []).filter(function (x) { return x.type === 'series' || x.type === 'season'; });
      $('#cx-parent-pick').innerHTML = '<option value="">(keep current parent)</option>' + items.map(function (x) {
        var lbl = x.title + ' · ' + x.type + (x.seasonIndex != null ? ' ' + x.seasonIndex : '');
        return '<option value="' + esc(x.id) + '">' + esc(lbl) + '</option>';
      }).join('');
      msg('cx-msg', items.length ? 'Pick a parent below, then Apply re-map.' : 'No series or seasons match.', items.length > 0);
    }).catch(function () { msg('cx-msg', 'Search failed.'); });
  }
  function cxRemap() {
    if (!cxEditing) return;
    var body = {};
    var ty = $('#cx-f-type').value; if (ty) body.type = ty;
    var lib = $('#cx-f-library').value; if (lib) body.libraryId = lib;
    var par = $('#cx-parent-pick').value; if (par) body.parentId = par;
    if ($('#cx-f-season').value !== cxOrig.season) { var sv = $('#cx-f-season').value; if (sv !== '') body.seasonIndex = Number(sv); }
    if ($('#cx-f-episode').value !== cxOrig.episode) { var ev = $('#cx-f-episode').value; if (ev !== '') body.episodeIndex = Number(ev); }
    if (!Object.keys(body).length) { msg('cx-msg', 'Nothing to re-map.'); return; }
    msg('cx-msg', 'Applying…');
    api('/v1/admin/items/' + cxEditing, 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('cx-msg', (e && e.error && e.error.message) || 'Re-map failed.'); }).catch(function () { msg('cx-msg', 'Re-map failed.'); }); return; }
      msg('cx-msg', 'Re-mapped.', true); cxOpen(cxEditing); cxList();
    }).catch(function () { msg('cx-msg', 'Could not reach the server.'); });
  }
  var cxSearchT = null;
  function cxRunSearch() {
    var term = $('#cx-search').value.trim(), needs = $('#cx-needs').checked;
    if (!term && !needs) { cxNav = []; $('#cx-crumbs').innerHTML = ''; $('#cx-list').innerHTML = '<div class="empty">Pick a library to browse its titles.</div>'; return; }
    cxNav = []; cxClose(); $('#cx-lib').value = '';
    var qs = '/v1/admin/items?limit=500';
    if (term) qs += '&search=' + encodeURIComponent(term);
    if (needs) qs += '&needsAttention=true';
    $('#cx-crumbs').innerHTML = '<span class="meta">' + (needs ? 'Items needing metadata' : 'Search results') + (term ? ' for “' + esc(term) + '”' : '') + '</span>';
    api(qs, 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = d.items || [];
      $('#cx-list').innerHTML = items.length ? items.map(cxRow).join('') : '<div class="empty">No matching titles.</div>';
    });
  }
  $('#cx-search').oninput = function () { clearTimeout(cxSearchT); cxSearchT = setTimeout(cxRunSearch, 250); };
  $('#cx-needs').onchange = cxRunSearch;
  $('#cx-save-btn').onclick = cxSave;
  $('#cx-unlock-btn').onclick = cxUnlock;
  $('#cx-enrich-btn').onclick = cxEnrich;
  $('#cx-identify-btn').onclick = cxIdentify;
  $('#cx-parent-find').onclick = cxFindParents;
  $('#cx-remap-btn').onclick = cxRemap;
  $('#cx-close-btn').onclick = cxClose;

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
  $('#pk-add-btn').onclick = addPasskey;
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  if (token) enter();
</script>
</body>
</html>
"""#
}
