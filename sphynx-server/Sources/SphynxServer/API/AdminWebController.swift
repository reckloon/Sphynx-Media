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
  .wrap { max-width:860px; margin:5vh auto; padding:0 20px; }
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
  /* diagnostics: activity */
  .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(110px,1fr)); gap:10px; margin:6px 0 18px; }
  .stat { background:var(--sub); border:1px solid var(--line); border-radius:10px; padding:12px 14px; }
  .stat .n { font-size:23px; font-weight:600; }
  .stat .l { font-size:12px; color:var(--muted); margin-top:2px; }
  .stat.warn .n { color:var(--err); }
  .phase { display:inline-flex; align-items:center; gap:8px; font-size:13px; padding:6px 12px; border-radius:999px; background:var(--sub); border:1px solid var(--line); }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--muted); }
  .dot.scanning { background:var(--accent); } .dot.enriching { background:var(--ok); }
  .dot.pulse { animation:pulse 1.2s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity:.3; } }
  .chip { display:inline-block; padding:2px 7px; border-radius:6px; font-size:11px; border:1px solid var(--line); background:var(--bg); color:var(--muted); }
  .chip.movie { color:var(--accent); } .chip.tv { color:#c89bf0; }
  .res-enriched { color:var(--ok); } .res-skipped { color:var(--muted); } .res-failed { color:var(--err); }
  /* diagnostics: database browser */
  .tablist { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:14px; }
  .tablist button { margin:0; }
  .toolbar { display:flex; gap:8px; align-items:center; margin-bottom:10px; flex-wrap:wrap; }
  .toolbar .spacer { flex:1; }
  .tablebox { overflow:auto; border:1px solid var(--line); border-radius:10px; max-height:52vh; }
  table.db { border-collapse:collapse; width:100%; font-size:12.5px; }
  table.db th, table.db td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); white-space:nowrap; max-width:340px; overflow:hidden; text-overflow:ellipsis; }
  table.db th { position:sticky; top:0; background:var(--sub); color:var(--muted); font-weight:500; z-index:1; }
  table.db td.null { color:#5a6473; font-style:italic; }
  .pager { display:flex; gap:10px; align-items:center; margin-top:10px; font-size:13px; color:var(--muted); }
  /* diagnostics: logs */
  .logbox { background:#0b0e13; border:1px solid var(--line); border-radius:10px; padding:10px 12px; height:54vh; overflow:auto; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; line-height:1.55; }
  .logline { white-space:pre-wrap; word-break:break-word; }
  .logline .t { color:#5a6473; }
  .logline .lvl { display:inline-block; min-width:62px; font-weight:600; }
  .lvl-info { color:var(--accent); } .lvl-notice { color:var(--ok); } .lvl-warning { color:#e8c468; }
  .lvl-error, .lvl-critical { color:var(--err); } .lvl-debug, .lvl-trace { color:var(--muted); }
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
        <button class="tab" data-tab="activity">Activity</button>
        <button class="tab" data-tab="database">Database</button>
        <button class="tab" data-tab="logs">Logs</button>
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

    <section id="tab-activity" hidden>
      <div class="bar" style="margin-bottom:14px;">
        <span id="act-phase" class="phase"><span class="dot"></span> Idle</span>
        <span class="hint" id="act-uptime" style="margin:0;"></span>
      </div>
      <div class="stats">
        <div class="stat"><div class="n" id="act-active">0</div><div class="l">Active</div></div>
        <div class="stat"><div class="n" id="act-queued">0</div><div class="l">Queued</div></div>
        <div class="stat"><div class="n" id="act-enriched">0</div><div class="l">Enriched</div></div>
        <div class="stat"><div class="n" id="act-skipped">0</div><div class="l">Skipped</div></div>
        <div class="stat warn"><div class="n" id="act-failed">0</div><div class="l">Failed</div></div>
      </div>
      <div class="group-title">In progress</div>
      <div id="act-jobs"><div class="empty">Nothing processing right now.</div></div>
      <div class="group-title">Recently finished</div>
      <div id="act-recent"><div class="empty">No recent jobs.</div></div>
      <div class="group-title">Recent scans</div>
      <div id="act-scans"><div class="empty">No scans yet.</div></div>
    </section>

    <section id="tab-database" hidden>
      <h2>Database</h2>
      <p class="hint" style="margin-top:0;">Read-only. Sensitive columns (password &amp; token hashes, source secrets, request headers) are redacted 🔒.</p>
      <div class="tablist" id="db-tables"><div class="empty">Loading tables…</div></div>
      <div id="db-view" hidden>
        <div class="toolbar">
          <strong id="db-title"></strong>
          <span class="hint" id="db-count" style="margin:0;"></span>
          <span class="spacer"></span>
          <button class="mini secondary" id="db-refresh">Refresh</button>
        </div>
        <div class="tablebox"><table class="db"><thead id="db-head"></thead><tbody id="db-body"></tbody></table></div>
        <div class="pager">
          <button class="mini secondary" id="db-prev">‹ Prev</button>
          <span id="db-range"></span>
          <button class="mini secondary" id="db-next">Next ›</button>
        </div>
      </div>
    </section>

    <section id="tab-logs" hidden>
      <h2>Logs</h2>
      <div class="toolbar">
        <label style="margin:0;">Level</label>
        <select id="log-level" style="width:auto;">
          <option value="">all</option>
          <option value="trace">trace</option><option value="debug">debug</option>
          <option value="info" selected>info</option><option value="notice">notice</option>
          <option value="warning">warning</option><option value="error">error</option><option value="critical">critical</option>
        </select>
        <button class="mini secondary" id="log-pause">Pause</button>
        <button class="mini secondary" id="log-clear">Clear view</button>
        <span class="spacer"></span>
        <span class="hint" id="log-status" style="margin:0;"></span>
      </div>
      <div class="logbox" id="log-box"><div class="empty">Waiting for logs…</div></div>
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
  function logout() { stopPoll(); token = ''; sessionStorage.removeItem('sphynxToken'); $('#panel').hidden = true; $('#login').hidden = false; }
  function enter() {
    $('#login').hidden = true; $('#panel').hidden = false;
    loadSettings(); loadLibraries(); loadSources(); loadUsers();
  }

  // ---- tabs ----
  var TABS = ['settings', 'libraries', 'sources', 'users', 'activity', 'database', 'logs'];
  var poll = null;
  function stopPoll() { if (poll) { clearInterval(poll); poll = null; } }
  function startPoll(fn, ms) { stopPoll(); fn(); poll = setInterval(fn, ms); }
  function showTab(name) {
    document.querySelectorAll('.tab').forEach(function (x) { x.classList.toggle('active', x.dataset.tab === name); });
    TABS.forEach(function (n) { $('#tab-' + n).hidden = (n !== name); });
    stopPoll();
    if (name === 'activity') startPoll(loadStatus, 1500);
    else if (name === 'logs') { logState.after = 0; $('#log-box').innerHTML = ''; startPoll(loadLogs, 2000); }
    else if (name === 'database') loadDbTables();
  }
  Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (t) {
    t.onclick = function () { showTab(t.dataset.tab); };
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

  // ---- diagnostics: activity ----
  function fmtMs(ms) { if (ms == null) return ''; return ms < 1000 ? Math.round(ms) + 'ms' : (ms / 1000).toFixed(1) + 's'; }
  function fmtDur(s) { s = Math.floor(s); var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return (h ? h + 'h ' : '') + (m ? m + 'm ' : '') + x + 's'; }
  function jobRow(j, withResult) {
    var right = withResult ? '<span class="meta res-' + esc(j.result) + '">' + esc(j.result) + ' · ' + fmtMs(j.durationMs) + '</span>' : '<span class="meta">' + fmtMs(j.durationMs) + '</span>';
    return '<div class="item"><span><span class="chip ' + esc(j.kind) + '">' + esc(j.kind) + '</span> ' + esc(j.title) + '</span>' + right + '</div>';
  }
  function loadStatus() {
    api('/v1/admin/status', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (s) {
      if (!s) return;
      var live = s.phase !== 'idle';
      $('#act-phase').innerHTML = '<span class="dot ' + esc(s.phase) + (live ? ' pulse' : '') + '"></span> ' + s.phase.charAt(0).toUpperCase() + s.phase.slice(1);
      $('#act-uptime').textContent = 'uptime ' + fmtDur(s.uptimeSeconds) + ' · ' + s.processed + ' processed';
      $('#act-active').textContent = s.active; $('#act-queued').textContent = s.queued;
      $('#act-enriched').textContent = s.enriched; $('#act-skipped').textContent = s.skipped; $('#act-failed').textContent = s.failed;
      $('#act-jobs').innerHTML = s.jobs.length ? s.jobs.map(function (j) { return jobRow(j, false); }).join('') : '<div class="empty">Nothing processing right now.</div>';
      $('#act-recent').innerHTML = s.recent.length ? s.recent.map(function (j) { return jobRow(j, true); }).join('') : '<div class="empty">No recent jobs.</div>';
      $('#act-scans').innerHTML = s.scans.length ? s.scans.map(function (sc) {
        return '<div class="item"><span>' + esc(sc.sourceId) + '</span><span class="meta">scanned ' + sc.scanned + ' · +' + sc.added + ' ~' + sc.updated + ' −' + sc.removed + ' · enriched ' + sc.enriched + ' · ' + fmtMs(sc.durationMs) + '</span></div>';
      }).join('') : '<div class="empty">No scans yet.</div>';
    }).catch(function () {});
  }

  // ---- diagnostics: database browser ----
  var dbState = { table: null, offset: 0, limit: 50, total: 0 };
  function loadDbTables() {
    api('/v1/admin/db/tables', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : { tables: [] }; }).then(function (d) {
      if (!d) return;
      $('#db-tables').innerHTML = d.tables.length ? d.tables.map(function (t) {
        return '<button class="tab' + (dbState.table === t.name ? ' active' : '') + '" data-table="' + esc(t.name) + '">' + esc(t.name) + ' <span class="meta">' + t.rowCount + '</span></button>';
      }).join('') : '<div class="empty">No tables.</div>';
      if (dbState.table) loadDbRows();
    });
  }
  function openTable(name) { dbState.table = name; dbState.offset = 0; loadDbRows();
    Array.prototype.forEach.call(document.querySelectorAll('#db-tables .tab'), function (b) { b.classList.toggle('active', b.dataset.table === name); }); }
  function loadDbRows() {
    if (!dbState.table) return;
    var q = '/v1/admin/db/query?table=' + encodeURIComponent(dbState.table) + '&limit=' + dbState.limit + '&offset=' + dbState.offset;
    api(q, 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      dbState.total = d.total;
      $('#db-view').hidden = false;
      $('#db-title').textContent = d.table;
      $('#db-count').textContent = d.total + ' rows' + (d.redactedColumns.length ? ' · ' + d.redactedColumns.length + ' redacted' : '');
      $('#db-head').innerHTML = '<tr>' + d.columns.map(function (c) { return '<th>' + esc(c) + (d.redactedColumns.indexOf(c) >= 0 ? ' 🔒' : '') + '</th>'; }).join('') + '</tr>';
      $('#db-body').innerHTML = d.rows.length ? d.rows.map(function (r) {
        return '<tr>' + r.map(function (v) { return v === null ? '<td class="null">null</td>' : '<td title="' + esc(v) + '">' + esc(v) + '</td>'; }).join('') + '</tr>';
      }).join('') : '<tr><td class="null">no rows</td></tr>';
      var from = d.total ? d.offset + 1 : 0, to = Math.min(d.offset + d.limit, d.total);
      $('#db-range').textContent = from + '–' + to + ' of ' + d.total;
      $('#db-prev').disabled = d.offset <= 0; $('#db-next').disabled = to >= d.total;
    });
  }
  $('#db-tables').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.table) openTable(b.dataset.table); };
  $('#db-prev').onclick = function () { dbState.offset = Math.max(0, dbState.offset - dbState.limit); loadDbRows(); };
  $('#db-next').onclick = function () { if (dbState.offset + dbState.limit < dbState.total) { dbState.offset += dbState.limit; loadDbRows(); } };
  $('#db-refresh').onclick = function () { loadDbTables(); };

  // ---- diagnostics: logs ----
  var logState = { after: 0, paused: false };
  function loadLogs() {
    if (logState.paused) return;
    var lvl = $('#log-level').value;
    var q = '/v1/admin/logs?limit=300' + (logState.after ? '&after=' + logState.after : '') + (lvl ? '&level=' + lvl : '');
    api(q, 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      var box = $('#log-box');
      var atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
      if (d.lines.length) {
        var empty = box.querySelector('.empty'); if (empty) box.innerHTML = '';
        d.lines.forEach(function (l) {
          if (l.seq > logState.after) logState.after = l.seq;
          var div = document.createElement('div');
          div.className = 'logline';
          var t = (l.time || '').replace('T', ' ').replace(/(\.\d+)?(Z|[+-]\d\d:?\d\d)?$/, '');
          div.innerHTML = '<span class="t">' + esc(t) + '</span> <span class="lvl lvl-' + esc(l.level) + '">' + esc(l.level) + '</span> ' + esc(l.message);
          box.appendChild(div);
        });
        if (atBottom) box.scrollTop = box.scrollHeight;
      }
      $('#log-status').textContent = 'seq ' + d.latestSeq + (logState.paused ? ' · paused' : '');
    }).catch(function () {});
  }
  $('#log-level').onchange = function () { logState.after = 0; $('#log-box').innerHTML = ''; loadLogs(); };
  $('#log-pause').onclick = function () { logState.paused = !logState.paused; $('#log-pause').textContent = logState.paused ? 'Resume' : 'Pause'; };
  $('#log-clear').onclick = function () { $('#log-box').innerHTML = '<div class="empty">cleared</div>'; };

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
