import Hummingbird
import NIOCore

/// Serves the web admin page at `GET /admin` — a self-contained HTML shell
/// (login + Settings / Libraries / Sources tabs) that drives the public
/// `/v1/auth/login` and the `/v1/admin/*` endpoints from the browser. The page is
/// unauthenticated static markup; every privileged action it performs goes through
/// the authenticated API with the admin's bearer token.
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
  :root { --bg:#0f1115; --card:#171a21; --sub:#1d212b; --line:#262b36; --fg:#e6e9ef; --muted:#9aa3b2; --accent:#6ea8fe; --ok:#54d18c; --err:#ff7a7a; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  .wrap { max-width:720px; margin:5vh auto; padding:0 20px; }
  .brand { display:flex; align-items:center; gap:10px; margin-bottom:4px; }
  .brand h1 { font-size:22px; margin:0; }
  .logo { font-size:26px; }
  .tag { color:var(--muted); margin:0 0 22px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:22px; }
  h2 { font-size:16px; margin:0 0 16px; }
  label { display:block; font-size:13px; color:var(--muted); margin:14px 0 6px; }
  input, select, textarea { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; }
  textarea { resize:vertical; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; }
  input:focus, select:focus, textarea:focus { outline:none; border-color:var(--accent); }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:0 16px; }
  .hint { font-size:12px; color:var(--muted); margin-top:6px; }
  button { margin-top:18px; padding:10px 16px; background:var(--accent); color:#0b1020; border:0; border-radius:9px; font:inherit; font-weight:600; cursor:pointer; }
  button.secondary { background:transparent; color:var(--muted); border:1px solid var(--line); }
  button.mini { margin:0; padding:5px 11px; font-size:13px; font-weight:500; }
  button.danger { color:var(--err); border-color:#3a2730; }
  .bar { display:flex; justify-content:space-between; align-items:center; margin-bottom:18px; }
  .tabs { display:flex; gap:6px; }
  .tab { margin:0; padding:7px 14px; background:transparent; color:var(--muted); border:1px solid var(--line); border-radius:9px; font-weight:500; }
  .tab.active { background:var(--sub); color:var(--fg); border-color:var(--accent); }
  .msg { min-height:18px; margin-top:12px; font-size:13px; color:var(--err); }
  .msg.ok { color:var(--ok); }
  .group-title { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:22px 0 2px; }
  .item { display:flex; justify-content:space-between; align-items:center; gap:12px; padding:11px 13px; background:var(--sub); border:1px solid var(--line); border-radius:10px; margin-bottom:8px; }
  .item .meta { font-size:13px; color:var(--muted); }
  .item .acts { display:flex; gap:8px; }
  .muted { color:var(--muted); }
  .empty { color:var(--muted); font-size:14px; padding:6px 0; }
  .addbox { margin-top:18px; padding-top:6px; border-top:1px solid var(--line); }
  .urow { display:grid; grid-template-columns:1.4fr repeat(4, 1fr) 70px; align-items:center; gap:8px; padding:9px 11px; border:1px solid var(--line); border-radius:10px; margin-bottom:6px; background:var(--sub); }
  .urow.uhead { background:transparent; border:0; padding:2px 11px; margin-bottom:2px; }
  .urow.uhead span { font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
  .uname { font-weight:500; overflow:hidden; text-overflow:ellipsis; }
  .uperm { text-align:center; }
  .uperm input { width:auto; }
  .uact { text-align:right; }
  [hidden] { display:none !important; }
</style>
</head>
<body>
<div class="wrap">
  <div class="brand"><span class="logo">🐈‍⬛</span><h1>Sphynx</h1></div>
  <p class="tag">Server admin</p>

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
    <div class="bar">
      <div class="tabs">
        <button class="tab active" data-tab="settings">Settings</button>
        <button class="tab" data-tab="libraries">Libraries</button>
        <button class="tab" data-tab="sources">Sources</button>
        <button class="tab" data-tab="users">Users</button>
      </div>
      <button id="logout-btn" class="secondary" style="margin:0;">Sign out</button>
    </div>

    <section id="tab-settings">
      <p class="hint" style="margin-top:0;">All time settings are in <strong>seconds</strong>. Handy conversions: 1 hour = 3600 · 1 day = 86400 · 30 days = 2592000 · 1 year = 31536000.</p>

      <div class="group-title">Server identity</div>
      <div class="row">
        <div><label for="serverName">Server name</label><input id="serverName">
          <p class="hint">The friendly name apps show when they connect.</p></div>
        <div><label for="serverID">Server ID</label><input id="serverID">
          <p class="hint">A stable identifier for this server. You rarely need to change this.</p></div>
      </div>

      <div class="group-title">Signing in</div>
      <div class="row">
        <div><label for="accessTokenTTL">Login session length</label><input id="accessTokenTTL" type="number" min="0">
          <p class="hint">How long the app stays signed in before it quietly re-authenticates. e.g. 3600 = 1 hour.</p></div>
        <div><label for="refreshTokenTTL">Time before sign-in is required again</label><input id="refreshTokenTTL" type="number" min="0">
          <p class="hint">After this, the user must type their password again. e.g. 2592000 = 30 days.</p></div>
      </div>

      <div class="group-title">Library &amp; upkeep</div>
      <div class="row">
        <div><label for="markersAccess">Who can add "skip intro" markers</label>
          <select id="markersAccess">
            <option value="none">Off — not offered</option>
            <option value="read">Read only — clients can use them, not add</option>
            <option value="readwrite">Read &amp; let clients contribute</option>
          </select>
          <p class="hint">Whether apps may read and/or submit intro/credits markers.</p></div>
        <div><label for="enrichmentTTL">Refresh posters &amp; info every</label><input id="enrichmentTTL" type="number" min="0">
          <p class="hint">How old TMDB data can get before it's re-fetched. e.g. 7776000 = 90 days.</p></div>
        <div><label for="markersStaleAfter">Mark "skip intro" data old after</label><input id="markersStaleAfter" type="number" min="0">
          <p class="hint">When a client is asked to refresh contributed markers. e.g. 604800 = 7 days.</p></div>
        <div><label for="playstateRetention">Remember watch progress for</label><input id="playstateRetention" type="number" min="0">
          <p class="hint">How long to keep "resume where you left off". e.g. 31536000 = 1 year.</p></div>
        <div><label for="maintenanceInterval">Run background cleanup every</label><input id="maintenanceInterval" type="number" min="0">
          <p class="hint">Refreshes stale info and tidies old data. e.g. 86400 = 1 day; 0 = off.</p></div>
      </div>

      <button id="save-btn">Save settings</button>
      <div id="save-msg" class="msg"></div>
      <p class="hint">Saved settings take effect the next time the server restarts. (Network address, database location, the admin login, and the TMDB key are set when starting the server, not here.)</p>
    </section>

    <section id="tab-libraries" hidden>
      <h2>Libraries</h2>
      <div id="lib-list"></div>
      <div class="addbox">
        <div class="group-title">Add a library</div>
        <div class="row">
          <div><label for="lib-title">Title</label><input id="lib-title" placeholder="Movies"></div>
          <div><label for="lib-kind">Kind</label>
            <select id="lib-kind"><option>movies</option><option>tvShows</option><option>homeVideos</option><option>musicVideos</option><option>boxSets</option><option>collection</option><option>other</option></select></div>
        </div>
        <button id="lib-add-btn">Add library</button>
        <div id="lib-msg" class="msg"></div>
      </div>
    </section>

    <section id="tab-sources" hidden>
      <h2>Sources</h2>
      <div id="src-list"></div>
      <div class="addbox">
        <div class="group-title">Add a source</div>
        <label for="src-label">Label</label>
        <input id="src-label" placeholder="My CDN">
        <div class="row">
          <div><label for="src-driver">Driver</label>
            <select id="src-driver"><option>http</option><option>local</option><option>webdav</option><option>smb</option><option>ftp</option></select></div>
          <div></div>
          <div><label for="src-lib-movie">Movies library</label><select id="src-lib-movie"></select></div>
          <div><label for="src-lib-tv">TV library</label><select id="src-lib-tv"></select></div>
        </div>
        <div id="drv-http" class="drv">
          <label for="src-baseurl">Base URL</label><input id="src-baseurl" placeholder="https://cdn.example">
          <label for="src-manifest">Manifest URL</label><input id="src-manifest" placeholder="https://cdn.example/manifest.json">
        </div>
        <div id="drv-local" class="drv" hidden>
          <label for="src-rootpath">Root path</label><input id="src-rootpath" placeholder="/srv/media">
        </div>
        <div id="drv-remote" class="drv" hidden>
          <label for="src-config">Config (JSON)</label>
          <textarea id="src-config" rows="3" placeholder='{ "baseURL": "https://nas.example/remote.php/dav" }'></textarea>
          <label for="src-secrets">Secrets (JSON) — stored, never shown again</label>
          <textarea id="src-secrets" rows="2" placeholder='{ "username": "alice", "password": "•••" }'></textarea>
        </div>
        <button id="src-add-btn">Add source</button>
        <div id="src-msg" class="msg"></div>
        <p class="hint">A source can map a Movies library and a TV library; one scan walks the folder once and routes movies and TV to the right library.</p>
      </div>
    </section>

    <section id="tab-users" hidden>
      <h2>Users &amp; permissions</h2>
      <p class="hint" style="margin-top:0;">Tick a box to grant a permission; it saves immediately. The admin holds every permission and can't be changed or deleted.</p>
      <div id="user-list"></div>
      <div class="addbox">
        <div class="group-title">Add a user</div>
        <div class="row">
          <div><label for="usr-name">Username</label><input id="usr-name" autocomplete="off"></div>
          <div><label for="usr-pass">Password</label><input id="usr-pass" type="password" autocomplete="new-password"></div>
        </div>
        <button id="usr-add-btn">Add user</button>
        <div id="usr-msg" class="msg"></div>
        <p class="hint">New users start with "Browse &amp; play" so they can use the library right away.</p>
      </div>
    </section>
  </div>
</div>

<script>
  var $ = function (s) { return document.querySelector(s); };
  var token = sessionStorage.getItem('sphynxToken') || '';
  var libraries = [];

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function msg(id, text, ok) { var e = $('#' + id); e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); }

  function api(path, method, body) {
    var headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = 'Bearer ' + token;
    return fetch(path, { method: method, headers: headers, body: body ? JSON.stringify(body) : undefined });
  }

  // ---- auth ----
  function login() {
    msg('login-msg', '');
    api('/v1/auth/login', 'POST', { username: $('#u').value, password: $('#p').value })
      .then(function (res) { if (!res.ok) { msg('login-msg', 'Invalid username or password.'); return null; } return res.json(); })
      .then(function (data) { if (!data) return; token = data.accessToken; sessionStorage.setItem('sphynxToken', token); enter(); })
      .catch(function () { msg('login-msg', 'Could not reach the server.'); });
  }
  function logout() { token = ''; sessionStorage.removeItem('sphynxToken'); $('#panel').hidden = true; $('#login').hidden = false; }
  function enter() {
    $('#login').hidden = true; $('#panel').hidden = false;
    loadSettings(); loadLibraries(); loadSources(); loadUsers();
  }

  // ---- tabs ----
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (t) {
    t.onclick = function () {
      document.querySelectorAll('.tab').forEach(function (x) { x.classList.remove('active'); });
      t.classList.add('active');
      ['settings', 'libraries', 'sources', 'users'].forEach(function (name) { $('#tab-' + name).hidden = (name !== t.dataset.tab); });
    };
  });

  // ---- settings ----
  var sfields = ['serverName', 'serverID', 'accessTokenTTL', 'refreshTokenTTL', 'enrichmentTTL', 'markersAccess', 'markersStaleAfter', 'playstateRetention', 'maintenanceInterval'];
  var snumbers = ['accessTokenTTL', 'refreshTokenTTL', 'enrichmentTTL', 'markersStaleAfter', 'playstateRetention', 'maintenanceInterval'];
  function loadSettings() {
    api('/v1/admin/settings', 'GET').then(function (res) {
      if (res.status === 401) { logout(); return null; }
      if (res.status === 403) { msg('login-msg', 'That account is not the admin.'); logout(); return null; }
      return res.ok ? res.json() : null;
    }).then(function (s) { if (s) sfields.forEach(function (f) { var el = $('#' + f); if (el) el.value = s[f]; }); });
  }
  function saveSettings() {
    msg('save-msg', '');
    var body = {};
    sfields.forEach(function (f) { var el = $('#' + f); body[f] = snumbers.indexOf(f) >= 0 ? Number(el.value) : el.value; });
    api('/v1/admin/settings', 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('save-msg', (e && e.error && e.error.message) || 'Save failed.'); }).catch(function () { msg('save-msg', 'Save failed.'); }); return; }
      msg('save-msg', 'Saved. Restart the server for changes to take effect.', true);
    }).catch(function () { msg('save-msg', 'Could not reach the server.'); });
  }

  // ---- libraries ----
  function loadLibraries() {
    api('/v1/admin/libraries', 'GET').then(function (res) { return res.ok ? res.json() : { libraries: [] }; }).then(function (d) {
      libraries = d.libraries || [];
      $('#lib-list').innerHTML = libraries.length
        ? libraries.map(function (l) { return '<div class="item"><span><strong>' + esc(l.title) + '</strong> <span class="meta">' + esc(l.kind) + '</span></span><span class="acts"><button class="mini danger" data-del-lib="' + esc(l.id) + '">Delete</button></span></div>'; }).join('')
        : '<div class="empty">No libraries yet. Add one below.</div>';
      // refresh the source-form library pickers
      ['src-lib-movie', 'src-lib-tv'].forEach(function (id) {
        var sel = $('#' + id), cur = sel.value;
        sel.innerHTML = '<option value="">— none —</option>' + libraries.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join('');
        sel.value = cur;
      });
    });
  }
  function addLibrary() {
    msg('lib-msg', '');
    var title = $('#lib-title').value;
    if (!title) { msg('lib-msg', 'Title is required.'); return; }
    api('/v1/admin/libraries', 'POST', { title: title, kind: $('#lib-kind').value }).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { msg('lib-msg', 'Could not add library.'); return; }
      $('#lib-title').value = ''; msg('lib-msg', 'Added.', true); loadLibraries();
    });
  }

  // ---- sources ----
  function driverBlocks() {
    var d = $('#src-driver').value;
    $('#drv-http').hidden = d !== 'http';
    $('#drv-local').hidden = d !== 'local';
    $('#drv-remote').hidden = (d === 'http' || d === 'local');
  }
  function loadSources() {
    api('/v1/admin/sources', 'GET').then(function (res) { return res.ok ? res.json() : { sources: [] }; }).then(function (d) {
      var srcs = d.sources || [];
      $('#src-list').innerHTML = srcs.length
        ? srcs.map(function (s) { return '<div class="item"><span><strong>' + esc(s.label) + '</strong> <span class="meta">' + esc(s.driver) + '</span></span><span class="acts"><button class="mini" data-scan="' + esc(s.id) + '">Scan</button><button class="mini danger" data-del-src="' + esc(s.id) + '">Delete</button></span></div>'; }).join('')
        : '<div class="empty">No sources yet. Add one below.</div>';
    });
  }
  function addSource() {
    msg('src-msg', '');
    var driver = $('#src-driver').value;
    var body = { label: $('#src-label').value, driver: driver };
    if (!body.label) { msg('src-msg', 'Label is required.'); return; }
    var map = {};
    if ($('#src-lib-movie').value) map.movie = $('#src-lib-movie').value;
    if ($('#src-lib-tv').value) map.tv = $('#src-lib-tv').value;
    if (Object.keys(map).length) body.libraryMap = map;
    if (driver === 'http') {
      if ($('#src-baseurl').value) body.baseURL = $('#src-baseurl').value;
      if ($('#src-manifest').value) body.manifestURL = $('#src-manifest').value;
    } else if (driver === 'local') {
      body.config = { rootPath: $('#src-rootpath').value };
    } else {
      try {
        if ($('#src-config').value.trim()) body.config = JSON.parse($('#src-config').value);
        if ($('#src-secrets').value.trim()) body.secrets = JSON.parse($('#src-secrets').value);
      } catch (e) { msg('src-msg', 'Config / Secrets must be valid JSON.'); return; }
    }
    api('/v1/admin/sources', 'POST', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('src-msg', (e && e.error && e.error.message) || 'Could not add source.'); }).catch(function () { msg('src-msg', 'Could not add source.'); }); return; }
      $('#src-label').value = ''; $('#src-baseurl').value = ''; $('#src-manifest').value = ''; $('#src-rootpath').value = ''; $('#src-config').value = ''; $('#src-secrets').value = '';
      msg('src-msg', 'Added.', true); loadSources();
    });
  }
  function scanSource(id) {
    msg('src-msg', 'Scanning…');
    api('/v1/admin/sources/' + id + '/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (s) {
      if (!s) { msg('src-msg', 'Scan failed.'); return; }
      msg('src-msg', 'Scanned ' + s.scanned + ' · added ' + s.added + ' · updated ' + s.updated + ' · removed ' + s.removed + (s.enriched != null ? ' · enriched ' + s.enriched : ''), true);
    }).catch(function () { msg('src-msg', 'Scan failed.'); });
  }

  // event delegation for list buttons
  $('#lib-list').onclick = function (e) {
    var id = e.target.getAttribute('data-del-lib'); if (!id) return;
    if (!confirm('Delete this library and its items?')) return;
    api('/v1/admin/libraries/' + id, 'DELETE').then(function () { loadLibraries(); loadSources(); });
  };
  $('#src-list').onclick = function (e) {
    var del = e.target.getAttribute('data-del-src'), scan = e.target.getAttribute('data-scan');
    if (del) { if (confirm('Delete this source and its items?')) api('/v1/admin/sources/' + del, 'DELETE').then(function () { loadSources(); }); }
    else if (scan) scanSource(scan);
  };

  // ---- users & permissions ----
  var PERMS = [
    ['library.read', 'Browse &amp; play'],
    ['metadata.markers.write', 'Add markers'],
    ['metadata.images.write', 'Add artwork'],
    ['metadata.edit', 'Edit metadata']
  ];
  function loadUsers() {
    api('/v1/admin/users', 'GET').then(function (res) { return res.ok ? res.json() : { users: [] }; }).then(function (d) {
      var users = d.users || [];
      var head = '<div class="urow uhead"><span class="uname">User</span>' +
        PERMS.map(function (p) { return '<span class="uperm">' + p[1] + '</span>'; }).join('') + '<span class="uact"></span></div>';
      var rows = users.map(function (u) {
        var checks = PERMS.map(function (p) {
          var on = (u.permissions || []).indexOf(p[0]) >= 0;
          var attrs = u.isAdmin ? ' checked disabled' : (on ? ' checked' : '');
          return '<span class="uperm"><input type="checkbox" data-uid="' + esc(u.id) + '" data-perm="' + p[0] + '"' + attrs + '></span>';
        }).join('');
        var act = u.isAdmin
          ? '<span class="uact"><span class="meta">owner</span></span>'
          : '<span class="uact"><button class="mini danger" data-del-user="' + esc(u.id) + '">Delete</button></span>';
        return '<div class="urow"><span class="uname" title="' + esc(u.username) + '">' + esc(u.username) + '</span>' + checks + act + '</div>';
      }).join('');
      $('#user-list').innerHTML = head + rows;
    });
  }
  function savePermsFor(uid) {
    var boxes = document.querySelectorAll('#user-list input[data-uid="' + uid + '"]');
    var perms = [];
    Array.prototype.forEach.call(boxes, function (b) { if (b.checked) perms.push(b.getAttribute('data-perm')); });
    api('/v1/admin/users/' + uid + '/permissions', 'PUT', { permissions: perms }).then(function (res) {
      if (res.status === 401) { logout(); }
    });
  }
  function addUser() {
    msg('usr-msg', '');
    var name = $('#usr-name').value, pass = $('#usr-pass').value;
    if (!name || !pass) { msg('usr-msg', 'Username and password are required.'); return; }
    api('/v1/admin/users', 'POST', { username: name, password: pass }).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('usr-msg', (e && e.error && e.error.message) || 'Could not add user.'); }).catch(function () { msg('usr-msg', 'Could not add user.'); }); return; }
      $('#usr-name').value = ''; $('#usr-pass').value = ''; msg('usr-msg', 'Added.', true); loadUsers();
    });
  }
  $('#user-list').onclick = function (e) {
    var del = e.target.getAttribute && e.target.getAttribute('data-del-user');
    if (del) { if (confirm('Delete this user?')) api('/v1/admin/users/' + del, 'DELETE').then(function () { loadUsers(); }); }
  };
  $('#user-list').onchange = function (e) {
    var uid = e.target.getAttribute && e.target.getAttribute('data-uid');
    if (uid) savePermsFor(uid);
  };

  $('#login-btn').onclick = login;
  $('#logout-btn').onclick = logout;
  $('#save-btn').onclick = saveSettings;
  $('#lib-add-btn').onclick = addLibrary;
  $('#src-add-btn').onclick = addSource;
  $('#usr-add-btn').onclick = addUser;
  $('#src-driver').onchange = driverBlocks;
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  if (token) enter();
</script>
</body>
</html>
"""#
}
