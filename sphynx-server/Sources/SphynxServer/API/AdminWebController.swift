import Hummingbird
import NIOCore

/// Serves the web admin page at `GET /admin` — a self-contained HTML shell
/// (login + Settings / Libraries / Users / Extensions tabs; storage Sources live
/// as per-driver panels under the Extensions tab) that drives the public
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
  .chip.audio { color:var(--ok); } .chip.subtitle { color:#c89bf0; } .chip.video { color:var(--accent); }
  /* extensions: modules */
  .subtabs { display:flex; gap:6px; margin:0 0 16px; }
  .subtab { margin:0; padding:7px 14px; background:transparent; color:var(--muted); border:1px solid var(--line); border-radius:9px; font-weight:500; cursor:pointer; font:inherit; }
  .subtab.active { background:var(--sub); color:var(--fg); border-color:var(--accent); }
  .ext-mod { padding-top:2px; }
  .mp-row { display:flex; align-items:center; gap:12px; flex-wrap:wrap; margin:6px 0 14px; }
  .switch { display:inline-flex; align-items:center; gap:8px; color:var(--fg); font-size:14px; cursor:pointer; margin:0; }
  .switch input { width:auto; }
  .ok-badge { color:var(--ok); font-weight:500; }
  .off-badge { color:var(--err); font-weight:500; }
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
        <button class="tab" data-tab="users">Users</button>
        <button class="tab" data-tab="extensions">Extensions</button>
      </div>
      <button id="logout-btn" class="secondary" style="margin:0;">Sign out</button>
    </div>

    <section id="tab-settings">
      <p class="hint" style="margin-top:0;">All time settings are in <strong>minutes</strong>. Handy conversions: 1 hour = 60 · 1 day = 1440 · 7 days = 10080 · 30 days = 43200 · 1 year = 525600.</p>

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
          <p class="hint">How long the app stays signed in before it quietly re-authenticates. e.g. 60 = 1 hour.</p></div>
        <div><label for="refreshTokenTTL">Time before sign-in is required again</label><input id="refreshTokenTTL" type="number" min="0">
          <p class="hint">After this, the user must type their password again. e.g. 43200 = 30 days.</p></div>
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
          <p class="hint">How old TMDB data can get before it's re-fetched. e.g. 129600 = 90 days.</p></div>
        <div><label for="markersStaleAfter">Mark "skip intro" data old after</label><input id="markersStaleAfter" type="number" min="0">
          <p class="hint">When a client is asked to refresh contributed markers. e.g. 10080 = 7 days.</p></div>
        <div><label for="playstateRetention">Remember watch progress for</label><input id="playstateRetention" type="number" min="0">
          <p class="hint">How long to keep "resume where you left off". e.g. 525600 = 1 year.</p></div>
        <div><label for="maintenanceInterval">Run background cleanup every</label><input id="maintenanceInterval" type="number" min="0">
          <p class="hint">Refreshes stale info and tidies old data. e.g. 1440 = 1 day; 0 = off.</p></div>
      </div>

      <div class="group-title">Metadata (TMDB)</div>
      <label for="tmdb-key">TMDB API key <span id="tmdb-status" class="muted"></span></label>
      <input id="tmdb-key" type="password" placeholder="Paste your TMDB v3 API key" autocomplete="off">
      <p class="hint">Identifies titles and fetches posters, overviews, and cast. <a href="https://www.themoviedb.org/settings/api" target="_blank" rel="noopener">Get a free key →</a> Leave blank to keep the current key; saving applies on the next restart.</p>

      <button id="save-btn">Save settings</button>
      <button id="scan-all-btn" class="secondary" style="margin-left:8px;">Scan all sources now</button>
      <div id="save-msg" class="msg"></div>
      <p class="hint">Saved settings take effect the next time the server restarts. (Network address, database location, and the admin login are set when starting the server. Per-source refresh times are set under <strong>Extensions → Storage</strong>.)</p>
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

    <section id="tab-extensions" hidden>
      <p class="hint" style="margin-top:0;">Optional, self-contained capabilities outside the wire protocol. Each module has its own controls.</p>
      <div class="tablist" id="ext-nav"><div class="empty">Loading extensions…</div></div>

      <!-- Module: Storage (built-in) — one connection panel per driver -->
      <div id="mod-storage" class="ext-mod" hidden>
        <h2 style="margin-bottom:6px;">Storage Sources</h2>
        <p class="hint" style="margin-top:0;">Connect the places your media lives. Each storage driver has its own connection form below; add a source, then <strong>Scan</strong> to import its titles. A source can feed a Movies library and a TV library at once.</p>
        <div class="subtabs" id="stor-subtabs">
          <button class="subtab active" data-drv="local">Local</button>
          <button class="subtab" data-drv="http">HTTP</button>
          <button class="subtab" data-drv="webdav">WebDAV</button>
          <button class="subtab" data-drv="smb">SMB</button>
          <button class="subtab" data-drv="ftp">FTP</button>
        </div>

        <!-- Local -->
        <div class="stor-panel" data-drvpanel="local">
          <div class="group-title">Local sources</div>
          <div id="src-list-local"></div>
          <div class="addbox">
            <div class="group-title">Add a local folder</div>
            <label for="local-label">Name</label>
            <input id="local-label" placeholder="My media drive">
            <label for="local-rootpath">Folder path on the server</label>
            <input id="local-rootpath" placeholder="/srv/media">
            <p class="hint">An absolute path the server can read, e.g. <code>/srv/media</code>.</p>
            <div class="row">
              <div><label for="local-lib-movie">Movies library</label><select id="local-lib-movie" class="lib-movie"></select></div>
              <div><label for="local-lib-tv">TV library</label><select id="local-lib-tv" class="lib-tv"></select></div>
            </div>
            <label for="local-refresh">Auto-refresh every (minutes, 0 = manual)</label>
            <input id="local-refresh" type="number" min="0" value="0" placeholder="0">
            <button data-add="local">Add source</button>
            <div id="local-msg" class="msg"></div>
          </div>
        </div>

        <!-- HTTP -->
        <div class="stor-panel" data-drvpanel="http" hidden>
          <div class="group-title">HTTP sources</div>
          <div id="src-list-http"></div>
          <div class="addbox">
            <div class="group-title">Add an HTTP source</div>
            <label for="http-label">Name</label>
            <input id="http-label" placeholder="My CDN">
            <label for="http-baseurl">Base media URL</label>
            <input id="http-baseurl" placeholder="https://cdn.example">
            <label for="http-manifest">Manifest URL <span class="muted">(JSON listing)</span></label>
            <input id="http-manifest" placeholder="https://cdn.example/manifest.json">
            <label for="http-auth">Authorization header <span class="muted">(optional)</span></label>
            <input id="http-auth" placeholder="Bearer …">
            <p class="hint">Sent as an <code>Authorization</code> header on every request, if your server needs one.</p>
            <div class="row">
              <div><label for="http-lib-movie">Movies library</label><select id="http-lib-movie" class="lib-movie"></select></div>
              <div><label for="http-lib-tv">TV library</label><select id="http-lib-tv" class="lib-tv"></select></div>
            </div>
            <label for="http-refresh">Auto-refresh every (minutes, 0 = manual)</label>
            <input id="http-refresh" type="number" min="0" value="0" placeholder="0">
            <button data-add="http">Add source</button>
            <div id="http-msg" class="msg"></div>
          </div>
        </div>

        <!-- WebDAV -->
        <div class="stor-panel" data-drvpanel="webdav" hidden>
          <div class="group-title">WebDAV sources</div>
          <div id="src-list-webdav"></div>
          <div class="addbox">
            <div class="group-title">Add a WebDAV source</div>
            <label for="webdav-label">Name</label>
            <input id="webdav-label" placeholder="Nextcloud media">
            <label for="webdav-baseurl">WebDAV URL</label>
            <input id="webdav-baseurl" placeholder="https://nas.example/remote.php/dav/files/me/Media">
            <div class="row">
              <div><label for="webdav-username">Username</label><input id="webdav-username" autocomplete="off"></div>
              <div><label for="webdav-password">Password</label><input id="webdav-password" type="password" autocomplete="new-password"></div>
            </div>
            <p class="hint">Leave the username blank and put a bearer token in the password field to authenticate with a token instead.</p>
            <div class="row">
              <div><label for="webdav-lib-movie">Movies library</label><select id="webdav-lib-movie" class="lib-movie"></select></div>
              <div><label for="webdav-lib-tv">TV library</label><select id="webdav-lib-tv" class="lib-tv"></select></div>
            </div>
            <label for="webdav-refresh">Auto-refresh every (minutes, 0 = manual)</label>
            <input id="webdav-refresh" type="number" min="0" value="0" placeholder="0">
            <button data-add="webdav">Add source</button>
            <div id="webdav-msg" class="msg"></div>
          </div>
        </div>

        <!-- SMB -->
        <div class="stor-panel" data-drvpanel="smb" hidden>
          <div class="group-title">SMB sources</div>
          <div id="src-list-smb"></div>
          <div class="addbox">
            <div class="group-title">Add an SMB share</div>
            <p class="hint" style="margin-top:0;">Listing SMB shares needs the <code>smbclient</code> tool installed on the server.</p>
            <label for="smb-label">Name</label>
            <input id="smb-label" placeholder="NAS movies">
            <div class="row">
              <div><label for="smb-host">Server / host</label><input id="smb-host" placeholder="nas.local"></div>
              <div><label for="smb-share">Share name</label><input id="smb-share" placeholder="media"></div>
            </div>
            <div class="row">
              <div><label for="smb-username">Username</label><input id="smb-username" autocomplete="off"></div>
              <div><label for="smb-password">Password</label><input id="smb-password" type="password" autocomplete="new-password"></div>
            </div>
            <div class="row">
              <div><label for="smb-lib-movie">Movies library</label><select id="smb-lib-movie" class="lib-movie"></select></div>
              <div><label for="smb-lib-tv">TV library</label><select id="smb-lib-tv" class="lib-tv"></select></div>
            </div>
            <label for="smb-refresh">Auto-refresh every (minutes, 0 = manual)</label>
            <input id="smb-refresh" type="number" min="0" value="0" placeholder="0">
            <button data-add="smb">Add source</button>
            <div id="smb-msg" class="msg"></div>
          </div>
        </div>

        <!-- FTP -->
        <div class="stor-panel" data-drvpanel="ftp" hidden>
          <div class="group-title">FTP sources</div>
          <div id="src-list-ftp"></div>
          <div class="addbox">
            <div class="group-title">Add an FTP server</div>
            <p class="hint" style="margin-top:0;">Listing FTP servers needs the <code>curl</code> tool installed on the server.</p>
            <label for="ftp-label">Name</label>
            <input id="ftp-label" placeholder="Media FTP">
            <div class="row">
              <div><label for="ftp-host">Server / host</label><input id="ftp-host" placeholder="ftp.example"></div>
              <div><label for="ftp-port">Port (optional)</label><input id="ftp-port" type="number" min="0" placeholder="21"></div>
            </div>
            <div class="row">
              <div><label for="ftp-username">Username</label><input id="ftp-username" autocomplete="off"></div>
              <div><label for="ftp-password">Password</label><input id="ftp-password" type="password" autocomplete="new-password"></div>
            </div>
            <div class="row">
              <div><label for="ftp-lib-movie">Movies library</label><select id="ftp-lib-movie" class="lib-movie"></select></div>
              <div><label for="ftp-lib-tv">TV library</label><select id="ftp-lib-tv" class="lib-tv"></select></div>
            </div>
            <label for="ftp-refresh">Auto-refresh every (minutes, 0 = manual)</label>
            <input id="ftp-refresh" type="number" min="0" value="0" placeholder="0">
            <button data-add="ftp">Add source</button>
            <div id="ftp-msg" class="msg"></div>
          </div>
        </div>
      </div>

      <!-- Module: Diagnostics (built-in) -->
      <div id="mod-diagnostics" class="ext-mod" hidden>
        <div class="subtabs" id="diag-subtabs">
          <button class="subtab active" data-sub="activity">Activity</button>
          <button class="subtab" data-sub="database">Database</button>
          <button class="subtab" data-sub="logs">Logs</button>
        </div>

        <div id="sub-activity">
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
        </div>

        <div id="sub-database" hidden>
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
        </div>

        <div id="sub-logs" hidden>
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
        </div>
      </div>

      <!-- Module: Media probe (optional) -->
      <div id="mod-media-probe" class="ext-mod" hidden>
        <p class="hint" style="margin-top:0;">Inspect a title's audio, subtitle, and video tracks with ffmpeg's <code>ffprobe</code> — the language, codec, and channel detail the wire protocol's track indices can't carry on their own — plus any sidecar subtitle files next to a local file.</p>
        <div class="mp-row">
          <label class="switch"><input type="checkbox" id="mp-enabled"> Enable media probe</label>
          <span id="mp-avail" class="hint" style="margin:0;"></span>
        </div>
        <label for="mp-path">ffprobe path <span class="muted">(blank = auto-discover on PATH)</span></label>
        <input id="mp-path" placeholder="/usr/local/bin/ffprobe">
        <button id="mp-save">Save</button>
        <div class="addbox">
          <div class="group-title">Probe a title</div>
          <label for="mp-item">Item id</label>
          <input id="mp-item" placeholder="it_…">
          <button id="mp-probe-btn">Probe</button>
          <div id="mp-msg" class="msg"></div>
          <div id="mp-result"></div>
        </div>
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
  function logout() { stopPoll(); token = ''; sessionStorage.removeItem('sphynxToken'); $('#panel').hidden = true; $('#login').hidden = false; }
  function enter() {
    $('#login').hidden = true; $('#panel').hidden = false;
    loadSettings(); loadLibraries(); loadUsers();
  }

  // ---- tabs ----
  var TABS = ['settings', 'libraries', 'users', 'extensions'];
  var poll = null;
  function stopPoll() { if (poll) { clearInterval(poll); poll = null; } }
  function startPoll(fn, ms) { stopPoll(); fn(); poll = setInterval(fn, ms); }
  function showTab(name) {
    document.querySelectorAll('.tabs .tab').forEach(function (x) { x.classList.toggle('active', x.dataset.tab === name); });
    TABS.forEach(function (n) { $('#tab-' + n).hidden = (n !== name); });
    stopPoll();
    if (name === 'extensions') enterExtensions();
  }
  Array.prototype.forEach.call(document.querySelectorAll('.tabs .tab'), function (t) {
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
    }).then(function (s) { if (s) sfields.forEach(function (f) { var el = $('#' + f); if (el) el.value = snumbers.indexOf(f) >= 0 ? Math.round(Number(s[f]) / 60) : s[f]; }); });
    loadTMDBStatus();
  }
  function loadTMDBStatus() {
    var el = $('#tmdb-key'); if (el) el.value = '';
    api('/v1/admin/tmdb', 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (c) {
      if (!c) return;
      $('#tmdb-status').innerHTML = c.configured
        ? '— <span class="res-enriched">configured</span>' + (c.keyHint ? ' <span class="meta">' + esc(c.keyHint) + '</span>' : '')
        : '— <span class="muted">not set</span>';
    });
  }
  function saveSettings() {
    msg('save-msg', '');
    var body = {};
    // The number fields are durations shown in minutes; the API stores seconds.
    sfields.forEach(function (f) { var el = $('#' + f); body[f] = snumbers.indexOf(f) >= 0 ? Math.round(Number(el.value) * 60) : el.value; });
    // Save the TMDB key alongside (only when a new one was entered).
    var tmdbKey = ($('#tmdb-key') ? $('#tmdb-key').value : '').trim();
    var tmdbSave = tmdbKey ? api('/v1/admin/tmdb', 'PATCH', { apiKey: tmdbKey }) : Promise.resolve(null);
    api('/v1/admin/settings', 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('save-msg', (e && e.error && e.error.message) || 'Save failed.'); }).catch(function () { msg('save-msg', 'Save failed.'); }); return; }
      return tmdbSave.then(function () {
        msg('save-msg', 'Saved. Restart the server for changes to take effect.', true);
        loadTMDBStatus();
      });
    }).catch(function () { msg('save-msg', 'Could not reach the server.'); });
  }
  function scanAllSources() {
    msg('save-msg', 'Scanning all sources…');
    api('/v1/admin/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) { msg('save-msg', 'Scan failed.'); return; }
      var srcs = d.sources || [];
      var tot = srcs.reduce(function (a, s) { return a + (s.scanned || 0); }, 0);
      msg('save-msg', 'Scanned ' + srcs.length + ' source(s), ' + tot + ' item(s).', true);
    }).catch(function () { msg('save-msg', 'Could not reach the server.'); });
  }

  // ---- libraries ----
  function loadLibraries() {
    api('/v1/admin/libraries', 'GET').then(function (res) { return res.ok ? res.json() : { libraries: [] }; }).then(function (d) {
      libraries = d.libraries || [];
      $('#lib-list').innerHTML = libraries.length
        ? libraries.map(function (l) { return '<div class="item"><span><strong>' + esc(l.title) + '</strong> <span class="meta">' + esc(l.kind) + '</span></span><span class="acts"><button class="mini danger" data-del-lib="' + esc(l.id) + '">Delete</button></span></div>'; }).join('')
        : '<div class="empty">No libraries yet. Add one below.</div>';
      // refresh every storage form's library pickers (all .lib-movie / .lib-tv selects)
      var opts = '<option value="">— none —</option>' + libraries.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join('');
      Array.prototype.forEach.call(document.querySelectorAll('.lib-movie, .lib-tv'), function (sel) {
        var cur = sel.value; sel.innerHTML = opts; sel.value = cur;
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

  // ---- storage: sources (one panel per driver) ----
  var STORAGE_DRIVERS = ['local', 'http', 'webdav', 'smb', 'ftp'];
  var storActive = 'local';

  // Read library-mapping selectors for a driver into a libraryMap.
  function libraryMapFor(driver) {
    var map = {};
    var mv = $('#' + driver + '-lib-movie'), tv = $('#' + driver + '-lib-tv');
    if (mv && mv.value) map.movie = mv.value;
    if (tv && tv.value) map.tv = tv.value;
    return Object.keys(map).length ? map : null;
  }

  // Build the driver-specific body. Returns null (and posts a message) on bad input.
  function buildSourceBody(driver) {
    var val = function (id) { var el = $('#' + driver + '-' + id); return el ? el.value.trim() : ''; };
    var label = val('label');
    if (!label) { msg(driver + '-msg', 'Name is required.'); return null; }
    var body = { label: label, driver: driver };
    if (driver === 'local') {
      body.config = { rootPath: val('rootpath') };
    } else if (driver === 'http') {
      if (val('baseurl')) body.baseURL = val('baseurl');
      if (val('manifest')) body.manifestURL = val('manifest');
      if (val('auth')) body.headers = { Authorization: val('auth') };
    } else if (driver === 'webdav') {
      body.config = { baseURL: val('baseurl') };
      var secrets = {};
      if (val('username')) secrets.username = val('username');
      if (val('password')) { if (val('username')) secrets.password = val('password'); else secrets.token = val('password'); }
      if (Object.keys(secrets).length) body.secrets = secrets;
    } else if (driver === 'smb') {
      body.config = { host: val('host'), share: val('share') };
      var s = {}; if (val('username')) s.username = val('username'); if (val('password')) s.password = val('password');
      if (Object.keys(s).length) body.secrets = s;
    } else if (driver === 'ftp') {
      var cfg = { host: val('host') };
      if (val('port')) cfg.port = Number(val('port'));
      body.config = cfg;
      var f = {}; if (val('username')) f.username = val('username'); if (val('password')) f.password = val('password');
      if (Object.keys(f).length) body.secrets = f;
    }
    var map = libraryMapFor(driver);
    if (map) body.libraryMap = map;
    var refresh = val('refresh');               // minutes in the UI; API stores seconds
    if (refresh !== '') body.refreshInterval = Math.max(0, Math.round(Number(refresh) * 60));
    return body;
  }

  // Clears all add-source inputs for a driver panel.
  function clearSourceForm(driver) {
    var panel = document.querySelector('[data-drvpanel="' + driver + '"]');
    if (!panel) return;
    Array.prototype.forEach.call(panel.querySelectorAll('.addbox input'), function (el) { el.value = ''; });
  }

  // Fetch all sources, then render each driver's filtered list.
  function loadSources() {
    api('/v1/admin/sources', 'GET').then(function (res) { return res.ok ? res.json() : { sources: [] }; }).then(function (d) {
      var srcs = d.sources || [];
      STORAGE_DRIVERS.forEach(function (driver) {
        var list = $('#src-list-' + driver); if (!list) return;
        var mine = srcs.filter(function (s) { return s.driver === driver; });
        list.innerHTML = mine.length
          ? mine.map(function (s) {
              var rm = (s.refreshInterval > 0) ? '<span class="meta">refresh every ' + Math.round(s.refreshInterval / 60) + ' min</span>' : '<span class="meta">manual</span>';
              return '<div class="item"><span><strong>' + esc(s.label) + '</strong> ' + rm + '</span><span class="acts"><button class="mini" data-scan="' + esc(s.id) + '">Scan</button><button class="mini danger" data-del-src="' + esc(s.id) + '">Delete</button></span></div>'; }).join('')
          : '<div class="empty">No ' + driver + ' sources yet. Add one below.</div>';
      });
    });
  }
  function addSource(driver) {
    msg(driver + '-msg', '');
    var body = buildSourceBody(driver);
    if (!body) return;
    api('/v1/admin/sources', 'POST', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg(driver + '-msg', (e && e.error && e.error.message) || 'Could not add source.'); }).catch(function () { msg(driver + '-msg', 'Could not add source.'); }); return; }
      clearSourceForm(driver); msg(driver + '-msg', 'Added.', true); loadSources();
    }).catch(function () { msg(driver + '-msg', 'Could not reach the server.'); });
  }
  function scanSource(driver, id) {
    msg(driver + '-msg', 'Scanning…');
    api('/v1/admin/sources/' + id + '/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (s) {
      if (!s) { msg(driver + '-msg', 'Scan failed.'); return; }
      msg(driver + '-msg', 'Scanned ' + s.scanned + ' · added ' + s.added + ' · updated ' + s.updated + ' · removed ' + s.removed + (s.enriched != null ? ' · enriched ' + s.enriched : ''), true);
    }).catch(function () { msg(driver + '-msg', 'Scan failed.'); });
  }
  function showStorage(driver) {
    storActive = driver;
    Array.prototype.forEach.call(document.querySelectorAll('#stor-subtabs .subtab'), function (b) { b.classList.toggle('active', b.dataset.drv === driver); });
    Array.prototype.forEach.call(document.querySelectorAll('.stor-panel'), function (p) { p.hidden = (p.getAttribute('data-drvpanel') !== driver); });
  }
  $('#stor-subtabs').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.drv) showStorage(b.dataset.drv); };
  // Add-source buttons + per-panel list actions (scan/delete), via delegation on the module.
  $('#mod-storage').onclick = function (e) {
    var add = e.target.getAttribute('data-add');
    if (add) { addSource(add); return; }
    var del = e.target.getAttribute('data-del-src'), scan = e.target.getAttribute('data-scan');
    if (del) { if (confirm('Delete this source and its items?')) api('/v1/admin/sources/' + del, 'DELETE').then(function () { loadSources(); }); }
    else if (scan) scanSource(storActive, scan);
  };

  // event delegation for list buttons
  $('#lib-list').onclick = function (e) {
    var id = e.target.getAttribute('data-del-lib'); if (!id) return;
    if (!confirm('Delete this library and its items?')) return;
    api('/v1/admin/libraries/' + id, 'DELETE').then(function () { loadLibraries(); loadSources(); });
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

  // ---- extensions host (each extension is a self-contained module) ----
  var extState = { active: null };
  function enterExtensions() {
    api('/v1/admin/extensions', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      // Storage is a built-in module surfaced first; the rest come from the server.
      var storBtn = '<button class="tab' + (extState.active === 'storage' ? ' active' : '') + '" data-mod="storage" title="Connect the places your media lives.">Storage</button>';
      $('#ext-nav').innerHTML = storBtn + d.extensions.map(function (x) {
        var tags = '';
        if (x.kind === 'optional' && !x.enabled) tags += ' <span class="meta">off</span>';
        if (!x.available) tags += ' <span class="meta">unavailable</span>';
        return '<button class="tab' + (extState.active === x.id ? ' active' : '') + '" data-mod="' + esc(x.id) + '" title="' + esc(x.description) + '">' + esc(x.name) + tags + '</button>';
      }).join('');
      activateModule(extState.active || 'storage');
    });
  }
  function activateModule(id) {
    if (!id) return;
    extState.active = id;
    stopPoll();
    Array.prototype.forEach.call(document.querySelectorAll('#ext-nav .tab'), function (b) { b.classList.toggle('active', b.dataset.mod === id); });
    document.querySelectorAll('.ext-mod').forEach(function (m) { m.hidden = (m.id !== 'mod-' + id); });
    if (id === 'storage') { showStorage(storActive); loadSources(); }
    else if (id === 'diagnostics') showSub(diagState.sub);
    else if (id === 'media-probe') loadProbeConfig();
  }
  $('#ext-nav').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.mod) activateModule(b.dataset.mod); };

  // ---- module: diagnostics (activity / database / logs sub-views) ----
  var diagState = { sub: 'activity' };
  function showSub(name) {
    diagState.sub = name;
    stopPoll();
    Array.prototype.forEach.call(document.querySelectorAll('#diag-subtabs .subtab'), function (b) { b.classList.toggle('active', b.dataset.sub === name); });
    ['activity', 'database', 'logs'].forEach(function (n) { $('#sub-' + n).hidden = (n !== name); });
    if (name === 'activity') startPoll(loadStatus, 1500);
    else if (name === 'logs') { logState.after = 0; $('#log-box').innerHTML = ''; startPoll(loadLogs, 2000); }
    else if (name === 'database') loadDbTables();
  }
  $('#diag-subtabs').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.sub) showSub(b.dataset.sub); };

  // ---- module: media probe (ffprobe) ----
  function loadProbeConfig() {
    api('/v1/admin/extensions/media-probe', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (c) {
      if (!c) return;
      $('#mp-enabled').checked = c.enabled;
      $('#mp-path').value = c.ffprobePath || '';
      var badge = c.available ? '<span class="ok-badge">' + esc(c.version || 'ffprobe found') + '</span>' : '<span class="off-badge">ffprobe not found</span>';
      $('#mp-avail').innerHTML = badge + (c.resolvedPath ? ' <span class="meta">' + esc(c.resolvedPath) + '</span>' : '');
    });
  }
  function saveProbeConfig() {
    msg('mp-msg', '');
    api('/v1/admin/extensions/media-probe', 'PATCH', { enabled: $('#mp-enabled').checked, ffprobePath: $('#mp-path').value }).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { msg('mp-msg', 'Save failed.'); return; }
      msg('mp-msg', 'Saved.', true); loadProbeConfig(); enterExtensions();
    }).catch(function () { msg('mp-msg', 'Could not reach the server.'); });
  }
  function runProbe() {
    var id = $('#mp-item').value.trim();
    if (!id) { msg('mp-msg', 'Enter an item id.'); return; }
    msg('mp-msg', 'Probing…'); $('#mp-result').innerHTML = '';
    api('/v1/admin/extensions/media-probe/probe?itemId=' + encodeURIComponent(id), 'GET').then(function (res) {
      return res.json().then(function (b) { return { ok: res.ok, body: b }; }).catch(function () { return { ok: res.ok, body: null }; });
    }).then(function (r) {
      if (!r.ok) { msg('mp-msg', (r.body && r.body.error && r.body.error.message) || 'Probe failed.'); return; }
      msg('mp-msg', ''); renderProbe(r.body);
    }).catch(function () { msg('mp-msg', 'Probe failed.'); });
  }
  function renderProbe(p) {
    var rows = p.streams.map(function (s) {
      var extra = [s.channels ? s.channels + 'ch' : '', s.isDefault ? 'default' : '', s.isForced ? 'forced' : ''].filter(Boolean).join(' · ');
      return '<tr><td>' + s.index + '</td><td><span class="chip ' + esc(s.kind) + '">' + esc(s.kind) + '</span></td><td>' + esc(s.codec || '—') + '</td><td>' + esc(s.language || '—') + '</td><td>' + esc(s.title || '') + '</td><td class="meta">' + esc(extra) + '</td></tr>';
    }).join('');
    var subs = p.externalSubtitles.length ? '<div class="group-title">External subtitles</div>' + p.externalSubtitles.map(function (x) {
      return '<div class="item"><span>' + esc(x.url) + '</span><span class="meta">' + esc(x.language || '') + ' · ' + esc(x.format) + '</span></div>';
    }).join('') : '';
    $('#mp-result').innerHTML =
      '<div class="toolbar" style="margin-top:14px;"><strong>' + p.streams.length + ' streams</strong><span class="meta">' + esc(p.prober) + (p.durationSeconds ? ' · ' + Math.round(p.durationSeconds) + 's' : '') + '</span></div>' +
      '<div class="tablebox"><table class="db"><thead><tr><th>#</th><th>kind</th><th>codec</th><th>lang</th><th>title</th><th></th></tr></thead><tbody>' + (rows || '<tr><td class="null">no streams</td></tr>') + '</tbody></table></div>' + subs;
  }

  $('#login-btn').onclick = login;
  $('#logout-btn').onclick = logout;
  $('#save-btn').onclick = saveSettings;
  $('#scan-all-btn').onclick = scanAllSources;
  $('#lib-add-btn').onclick = addLibrary;
  $('#usr-add-btn').onclick = addUser;
  $('#mp-save').onclick = saveProbeConfig;
  $('#mp-probe-btn').onclick = runProbe;
  $('#mp-item').addEventListener('keydown', function (e) { if (e.key === 'Enter') runProbe(); });
  $('#p').addEventListener('keydown', function (e) { if (e.key === 'Enter') login(); });
  if (token) enter();
</script>
</body>
</html>
"""#
}
