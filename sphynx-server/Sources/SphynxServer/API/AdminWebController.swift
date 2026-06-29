import Hummingbird
import NIOCore

/// Serves the web admin page at `GET /admin` — a self-contained HTML shell with
/// an always-visible **Activity** panel (catalog coverage + live parse/enrich
/// status) above tabbed sections: **Libraries** (which now own their storage
/// Sources + scan controls), **Users** (a full permission editor with per-library
/// scoping, avatars, and password resets), **Items** (admin metadata correction
/// via field locks), **Settings**, and **Extensions** (Diagnostics + Media Probe).
///
/// The page is unauthenticated static markup; every privileged action goes through
/// the authenticated `/v1/admin/*` API with the admin's bearer token.
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
  :root { --bg:#0f1115; --card:#171a21; --sub:#1d212b; --line:#262b36; --fg:#e6e9ef; --muted:#9aa3b2; --accent:#6ea8fe; --ok:#54d18c; --warn:#e8c468; --err:#ff7a7a; --tv:#c89bf0; }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; }
  .wrap { max-width:960px; margin:4vh auto; padding:0 20px 8vh; }
  .brand { display:flex; align-items:center; gap:10px; margin-bottom:4px; }
  .brand h1 { font-size:22px; margin:0; }
  .logo { font-size:26px; }
  .tag { color:var(--muted); margin:0 0 22px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:14px; padding:22px; }
  .card + .card { margin-top:16px; }
  h2 { font-size:16px; margin:0 0 16px; }
  label { display:block; font-size:13px; color:var(--muted); margin:14px 0 6px; }
  input, select, textarea { width:100%; padding:9px 11px; background:#0e1117; color:var(--fg); border:1px solid var(--line); border-radius:9px; font:inherit; }
  textarea { resize:vertical; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:13px; }
  input:focus, select:focus, textarea:focus { outline:none; border-color:var(--accent); }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:0 16px; }
  .scanrow { display:flex; gap:22px; align-items:center; margin-top:4px; }
  .scanopt { display:flex; align-items:center; gap:7px; margin:0; color:var(--fg); font-size:13.5px; cursor:pointer; }
  .scanopt input { width:auto; margin:0; padding:0; }
  .scanopt input:disabled + *, .scanopt:has(input:disabled) { color:var(--muted); cursor:not-allowed; }
  .hint { font-size:12px; color:var(--muted); margin-top:6px; }
  button { margin-top:18px; padding:10px 16px; background:var(--accent); color:#0b1020; border:0; border-radius:9px; font:inherit; font-weight:600; cursor:pointer; }
  button.secondary { background:transparent; color:var(--muted); border:1px solid var(--line); }
  button.mini { margin:0; padding:5px 11px; font-size:13px; font-weight:500; }
  button.danger { color:var(--err); border-color:#3a2730; background:transparent; }
  .bar { display:flex; justify-content:space-between; align-items:center; margin-bottom:18px; gap:12px; flex-wrap:wrap; }
  .tabs { display:flex; gap:6px; flex-wrap:wrap; }
  .tab { margin:0; padding:7px 14px; background:transparent; color:var(--muted); border:1px solid var(--line); border-radius:9px; font-weight:500; cursor:pointer; font:inherit; }
  .tab.active { background:var(--sub); color:var(--fg); border-color:var(--accent); }
  .msg { min-height:18px; margin-top:12px; font-size:13px; color:var(--err); }
  .msg.ok { color:var(--ok); }
  .group-title { font-size:12px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:22px 0 8px; }
  .item { display:flex; justify-content:space-between; align-items:center; gap:12px; padding:11px 13px; background:var(--sub); border:1px solid var(--line); border-radius:10px; margin-bottom:8px; }
  .item .meta { font-size:13px; color:var(--muted); }
  .item .acts { display:flex; gap:8px; align-items:center; }
  .muted { color:var(--muted); }
  .empty { color:var(--muted); font-size:14px; padding:6px 0; }
  .addbox { margin-top:18px; padding-top:6px; border-top:1px solid var(--line); }
  [hidden] { display:none !important; }
  /* ---- persistent activity / dashboard panel ---- */
  #dash { padding:18px 20px; }
  .dash-head { display:flex; align-items:center; justify-content:space-between; gap:12px; margin-bottom:14px; }
  .dash-head .title { font-weight:600; font-size:15px; }
  .phase { display:inline-flex; align-items:center; gap:8px; font-size:13px; padding:6px 12px; border-radius:999px; background:var(--sub); border:1px solid var(--line); }
  .dot { width:8px; height:8px; border-radius:50%; background:var(--muted); }
  .dot.scanning { background:var(--accent); } .dot.enriching { background:var(--ok); }
  .dot.pulse { animation:pulse 1.2s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity:.3; } }
  .stats { display:grid; grid-template-columns:repeat(auto-fit,minmax(96px,1fr)); gap:10px; }
  .stat { background:var(--sub); border:1px solid var(--line); border-radius:10px; padding:11px 13px; }
  .stat .n { font-size:21px; font-weight:600; }
  .stat .l { font-size:11.5px; color:var(--muted); margin-top:2px; }
  .stat.warn .n { color:var(--err); }
  .covbar { height:8px; border-radius:5px; background:#0e1117; border:1px solid var(--line); overflow:hidden; display:flex; margin:14px 0 4px; }
  .covbar .seg-idx { background:var(--accent); } .covbar .seg-enr { background:var(--ok); }
  .coverlegend { display:flex; gap:16px; font-size:12px; color:var(--muted); flex-wrap:wrap; }
  .coverlegend b { color:var(--fg); font-weight:600; }
  .swatch { display:inline-block; width:9px; height:9px; border-radius:2px; margin-right:5px; vertical-align:middle; }
  .swatch.idx { background:var(--accent); } .swatch.enr { background:var(--ok); } .swatch.src { background:var(--muted); }
  details.scans { margin-top:14px; } details.scans > summary { cursor:pointer; font-size:12px; color:var(--muted); }
  details.breakdown { margin-top:14px; } details.breakdown > summary { cursor:pointer; font-size:12px; color:var(--muted); }
  .bd-cols { display:grid; grid-template-columns:1fr 1fr; gap:8px 28px; }
  @media (max-width:640px) { .bd-cols { grid-template-columns:1fr; } }
  .bd-row { display:grid; grid-template-columns:1fr auto; align-items:center; gap:8px; padding:4px 0; border-bottom:1px solid var(--line); }
  .bd-row:last-child { border-bottom:0; }
  .bd-row .bd-name { font-size:13px; color:var(--fg); }
  .bd-row.bd-extra .bd-name { color:var(--muted); }
  .bd-row .bd-num { font-size:12px; color:var(--muted); white-space:nowrap; }
  .bd-row .bd-num b { color:var(--fg); font-weight:600; }
  .bd-row .bd-num .bd-not { color:var(--muted); }
  .bd-row .bd-num .bd-tag { font-size:11px; color:var(--muted); border:1px solid var(--line); border-radius:5px; padding:0 5px; }
  .bd-bar { grid-column:1 / -1; height:5px; border-radius:4px; background:#0e1117; border:1px solid var(--line); overflow:hidden; }
  .bd-bar > span { display:block; height:100%; background:var(--ok); }
  .chip { display:inline-block; padding:2px 7px; border-radius:6px; font-size:11px; border:1px solid var(--line); background:var(--bg); color:var(--muted); }
  .chip.movie { color:var(--accent); } .chip.tv { color:var(--tv); } .chip.audio { color:var(--ok); } .chip.subtitle { color:var(--tv); } .chip.video { color:var(--accent); }
  .res-enriched { color:var(--ok); } .res-alreadyComplete { color:var(--ok); opacity:.6; } .res-skipped { color:var(--muted); } .res-failed { color:var(--err); }
  /* ---- avatars ---- */
  .avatar { width:30px; height:30px; border-radius:50%; object-fit:cover; background:var(--sub); border:1px solid var(--line); flex:0 0 auto; }
  .avatar.ph { display:inline-flex; align-items:center; justify-content:center; color:var(--muted); font-size:13px; font-weight:600; }
  /* ---- users / permission editor ---- */
  .user { border:1px solid var(--line); border-radius:11px; margin-bottom:10px; background:var(--sub); }
  .user-top { display:flex; align-items:center; gap:11px; padding:11px 13px; }
  .user-top .uname { font-weight:600; } .user-top .usub { font-size:12px; color:var(--muted); }
  .user-top .spacer { flex:1; }
  .perms { display:flex; gap:14px; flex-wrap:wrap; padding:2px 13px 13px; }
  .perm { display:inline-flex; align-items:center; gap:7px; font-size:13px; color:var(--fg); cursor:pointer; }
  .perm input { width:auto; } .perm.reserved { opacity:.6; }
  .scopes { border-top:1px solid var(--line); padding:11px 13px; }
  .scopes table { border-collapse:collapse; width:100%; font-size:12.5px; }
  .scopes th, .scopes td { padding:5px 8px; text-align:center; border-bottom:1px solid var(--line); }
  .scopes th:first-child, .scopes td:first-child { text-align:left; color:var(--muted); }
  .scopes input { width:auto; }
  /* ---- item correction ---- */
  .crumbs { font-size:13px; color:var(--muted); margin-bottom:10px; }
  .crumbs a { color:var(--accent); cursor:pointer; text-decoration:none; }
  .it-row { display:flex; align-items:center; gap:11px; min-width:0; }
  .it-thumb { width:34px; height:50px; object-fit:cover; border-radius:4px; background:var(--bg); border:1px solid var(--line); flex:0 0 auto; display:inline-flex; align-items:center; justify-content:center; font-size:18px; }
  .lockrow label { display:flex; align-items:center; justify-content:space-between; }
  .lockbadge { font-size:11px; color:var(--warn); }
  /* ---- diagnostics: database + logs ---- */
  .subtabs { display:flex; gap:6px; margin:0 0 16px; }
  .subtab { margin:0; padding:7px 14px; background:transparent; color:var(--muted); border:1px solid var(--line); border-radius:9px; font-weight:500; cursor:pointer; font:inherit; }
  .subtab.active { background:var(--sub); color:var(--fg); border-color:var(--accent); }
  .ext-mod { padding-top:2px; }
  .tablist { display:flex; flex-wrap:wrap; gap:6px; margin-bottom:14px; }
  .toolbar { display:flex; gap:8px; align-items:center; margin-bottom:10px; flex-wrap:wrap; }
  .toolbar .spacer { flex:1; }
  .tablebox { overflow:auto; border:1px solid var(--line); border-radius:10px; max-height:52vh; }
  table.db { border-collapse:collapse; width:100%; font-size:12.5px; }
  table.db th, table.db td { text-align:left; padding:7px 10px; border-bottom:1px solid var(--line); white-space:nowrap; max-width:340px; overflow:hidden; text-overflow:ellipsis; }
  table.db th { position:sticky; top:0; background:var(--sub); color:var(--muted); font-weight:500; z-index:1; }
  table.db td.null { color:#5a6473; font-style:italic; }
  .pager { display:flex; gap:10px; align-items:center; margin-top:10px; font-size:13px; color:var(--muted); }
  .logbox { background:#0b0e13; border:1px solid var(--line); border-radius:10px; padding:10px 12px; height:54vh; overflow:auto; font-family:ui-monospace,SFMono-Regular,Menlo,monospace; font-size:12px; line-height:1.55; }
  .logline { white-space:pre-wrap; word-break:break-word; }
  .logline .t { color:#5a6473; }
  .logline .lvl { display:inline-block; min-width:62px; font-weight:600; }
  .lvl-info { color:var(--accent); } .lvl-notice { color:var(--ok); } .lvl-warning { color:var(--warn); }
  .lvl-error, .lvl-critical { color:var(--err); } .lvl-debug, .lvl-trace { color:var(--muted); }
  .switch { display:inline-flex; align-items:center; gap:8px; color:var(--fg); font-size:14px; cursor:pointer; margin:0; }
  .switch input { width:auto; }
  .ok-badge { color:var(--ok); font-weight:500; } .off-badge { color:var(--err); font-weight:500; }
  .mp-row { display:flex; align-items:center; gap:12px; flex-wrap:wrap; margin:6px 0 14px; }
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

  <div id="app" hidden>
    <!-- Always-visible activity panel (catalog coverage + live status). -->
    <div id="dash" class="card">
      <div class="dash-head">
        <span class="title">Activity</span>
        <span id="act-phase" class="phase"><span class="dot"></span> Idle</span>
      </div>
      <div class="stats">
        <div class="stat"><div class="n" id="cov-source">0</div><div class="l">In source</div></div>
        <div class="stat"><div class="n" id="cov-indexed">0</div><div class="l">In database</div></div>
        <div class="stat"><div class="n" id="cov-enriched">0</div><div class="l">Enriched</div></div>
        <div class="stat"><div class="n" id="act-active">0</div><div class="l">Active</div></div>
        <div class="stat"><div class="n" id="act-queued">0</div><div class="l">Queued</div></div>
        <div class="stat warn"><div class="n" id="act-failed">0</div><div class="l">Failed</div></div>
      </div>
      <div class="covbar" title="Indexed and enriched share of items in source">
        <div class="seg-idx" id="cov-seg-idx" style="width:0"></div>
        <div class="seg-enr" id="cov-seg-enr" style="width:0"></div>
      </div>
      <div class="coverlegend">
        <span><span class="swatch src"></span>Items in source</span>
        <span><span class="swatch idx"></span><b id="cov-pct-idx">0%</b> indexed</span>
        <span><span class="swatch enr"></span><b id="cov-pct-enr">0%</b> enriched</span>
        <span class="spacer"></span>
        <span id="act-uptime"></span>
      </div>
      <details class="breakdown" open>
        <summary>Breakdown</summary>
        <div class="bd-cols">
          <div>
            <div class="group-title">Items per library</div>
            <div id="cov-bylib"><div class="empty">No libraries yet.</div></div>
          </div>
          <div>
            <div class="group-title">Enriched by category</div>
            <div id="cov-bytype"><div class="empty">Nothing indexed yet.</div></div>
          </div>
        </div>
      </details>
      <details class="scans">
        <summary>Recent scans &amp; jobs</summary>
        <div class="group-title">In progress</div>
        <div id="act-jobs"><div class="empty">Nothing running right now.</div></div>
        <div class="group-title">Recent scans</div>
        <div id="act-scans"><div class="empty">No scans yet this session.</div></div>
      </details>
    </div>

    <div id="panel" class="card">
      <div class="bar">
        <div class="tabs">
          <button class="tab active" data-tab="libraries">Libraries</button>
          <button class="tab" data-tab="users">Users</button>
          <button class="tab" data-tab="items">Items</button>
          <button class="tab" data-tab="settings">Settings</button>
          <button class="tab" data-tab="extensions">Extensions</button>
        </div>
        <button id="logout-btn" class="secondary" style="margin:0;">Sign out</button>
      </div>

      <!-- ============ LIBRARIES (own their storage sources) ============ -->
      <section id="tab-libraries">
        <h2>Libraries</h2>
        <p class="hint" style="margin-top:0;">A library is what apps browse. Sphynx serves <strong>video only</strong>, so it offers three fixed library types — flip on the ones you want. Then connect storage sources below, <strong>tick the content types each one holds</strong>, and <strong>Scan</strong> to import titles. Turning a library <strong>off deletes it and everything in it</strong>.</p>
        <div id="lib-list"></div>
        <div id="lib-msg" class="msg"></div>

        <div class="addbox">
          <div class="bar" style="margin-bottom:8px;">
            <div class="group-title" style="margin:0;">Storage sources</div>
            <button id="scan-all-btn" class="mini">Scan all now</button>
          </div>
          <p class="hint" style="margin-top:0;">Connect the places your media lives. Pick a driver, add a source, tick whether it holds Movies, TV Shows, or both, then scan. You can add several sources — any mix of drivers — and a single source can feed both the Movies and TV libraries at once. (The <strong>Local</strong> driver is for testing on this machine only; Sphynx doesn't serve files — use SMB/WebDAV/HTTP to stream to other devices.)</p>
          <p class="hint" style="margin-top:0;"><strong>Scan vs Refresh:</strong> both pull the latest from your sources — adding new titles, updating changed ones, removing deleted ones. <strong>Scan</strong> (<em>Scan all now</em> here, or <em>Scan</em> on a single source) runs it against the sources directly; <strong>Refresh</strong> (on a library, under Libraries) re-scans every source feeding that library. To run scans automatically, set a source's <strong>Auto-refresh every (minutes)</strong> when you add or edit it (0 = manual only). Separately, <strong>Settings → Refresh posters &amp; info every</strong> controls how often already-imported items re-fetch artwork/metadata from TMDB.</p>
          <div class="subtabs" id="stor-subtabs">
            <button class="subtab active" data-drv="local">Local</button>
            <button class="subtab" data-drv="http">HTTP</button>
            <button class="subtab" data-drv="webdav">WebDAV</button>
            <button class="subtab" data-drv="smb">SMB</button>
            <button class="subtab" data-drv="ftp">FTP</button>
            <button class="subtab" data-drv="torbox">TorBox</button>
          </div>

          <div class="stor-panel" data-drvpanel="local">
            <div id="src-list-local"></div>
            <div class="addbox">
              <div class="group-title">Add a local folder</div>
              <label for="local-label">Name</label><input id="local-label" placeholder="My media drive">
              <label for="local-rootpath">Folder path on the server</label><input id="local-rootpath" placeholder="/srv/media">
              <p class="hint">An absolute path the server can read, e.g. <code>/srv/media</code>.</p>
              <p class="hint">⚠️ <strong>Local is for testing on this machine only — Sphynx doesn't serve the files.</strong> They resolve to a <code>file://</code> path that only plays on the server host. To stream to phones, TVs, or other devices, run an SMB share, WebDAV, or an HTTP file server over your folder and add it with that driver instead.</p>
              <p class="hint">💡 <strong><code>.strm</code> files work in Local mode</strong> and are the exception to the warning above: a <code>.strm</code> file's contents are a URL, so it resolves to that URL (not a <code>file://</code> path) and <em>does</em> stream to other devices. Name them after the real media — <code>Movie.mkv.strm</code> indexes as an <code>mkv</code> — and put one URL per file.</p>
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="local-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="local-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="local-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="local-refresh" type="number" min="0" value="0">
              <button data-add="local">Add source</button><div id="local-msg" class="msg"></div>
            </div>
          </div>

          <div class="stor-panel" data-drvpanel="http" hidden>
            <div id="src-list-http"></div>
            <div class="addbox">
              <div class="group-title">Add an HTTP source</div>
              <label for="http-label">Name</label><input id="http-label" placeholder="My CDN">
              <label for="http-baseurl">Base media URL</label><input id="http-baseurl" placeholder="https://cdn.example">
              <label for="http-manifest">Manifest URL <span class="muted">(JSON listing)</span></label><input id="http-manifest" placeholder="https://cdn.example/manifest.json">
              <label for="http-auth">Authorization header <span class="muted">(optional)</span></label><input id="http-auth" placeholder="Bearer …">
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="http-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="http-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="http-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="http-refresh" type="number" min="0" value="0">
              <button data-add="http">Add source</button><div id="http-msg" class="msg"></div>
            </div>
          </div>

          <div class="stor-panel" data-drvpanel="webdav" hidden>
            <div id="src-list-webdav"></div>
            <div class="addbox">
              <div class="group-title">Add a WebDAV source</div>
              <label for="webdav-label">Name</label><input id="webdav-label" placeholder="Nextcloud media">
              <label for="webdav-baseurl">WebDAV URL</label><input id="webdav-baseurl" placeholder="https://nas.example/remote.php/dav/files/me/Media">
              <div class="row">
                <div><label for="webdav-username">Username</label><input id="webdav-username" autocomplete="off"></div>
                <div><label for="webdav-password">Password</label><input id="webdav-password" type="password" autocomplete="new-password"></div>
              </div>
              <p class="hint">Leave the username blank and put a bearer token in the password field to authenticate with a token instead.</p>
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="webdav-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="webdav-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="webdav-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="webdav-refresh" type="number" min="0" value="0">
              <button data-add="webdav">Add source</button><div id="webdav-msg" class="msg"></div>
            </div>
          </div>

          <div class="stor-panel" data-drvpanel="smb" hidden>
            <div id="src-list-smb"></div>
            <div class="addbox">
              <div class="group-title">Add an SMB share</div>
              <p class="hint" style="margin-top:0;">Listing SMB shares needs <code>smbclient</code> installed on the server.</p>
              <label for="smb-label">Name</label><input id="smb-label" placeholder="NAS movies">
              <div class="row">
                <div><label for="smb-host">Server / host</label><input id="smb-host" placeholder="nas.local"></div>
                <div><label for="smb-share">Share name</label><input id="smb-share" placeholder="media"></div>
              </div>
              <div class="row">
                <div><label for="smb-username">Username</label><input id="smb-username" autocomplete="off"></div>
                <div><label for="smb-password">Password</label><input id="smb-password" type="password" autocomplete="new-password"></div>
              </div>
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="smb-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="smb-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="smb-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="smb-refresh" type="number" min="0" value="0">
              <button data-add="smb">Add source</button><div id="smb-msg" class="msg"></div>
            </div>
          </div>

          <div class="stor-panel" data-drvpanel="ftp" hidden>
            <div id="src-list-ftp"></div>
            <div class="addbox">
              <div class="group-title">Add an FTP server</div>
              <p class="hint" style="margin-top:0;">Listing FTP servers needs <code>curl</code> installed on the server.</p>
              <label for="ftp-label">Name</label><input id="ftp-label" placeholder="Media FTP">
              <div class="row">
                <div><label for="ftp-host">Server / host</label><input id="ftp-host" placeholder="ftp.example"></div>
                <div><label for="ftp-port">Port (optional)</label><input id="ftp-port" type="number" min="0" placeholder="21"></div>
              </div>
              <div class="row">
                <div><label for="ftp-username">Username</label><input id="ftp-username" autocomplete="off"></div>
                <div><label for="ftp-password">Password</label><input id="ftp-password" type="password" autocomplete="new-password"></div>
              </div>
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="ftp-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="ftp-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="ftp-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="ftp-refresh" type="number" min="0" value="0">
              <button data-add="ftp">Add source</button><div id="ftp-msg" class="msg"></div>
            </div>
          </div>

          <div class="stor-panel" data-drvpanel="torbox" hidden>
            <div id="src-list-torbox"></div>
            <div class="addbox">
              <div class="group-title">Add a TorBox cloud</div>
              <p class="hint" style="margin-top:0;">Streams your <a href="https://torbox.app" target="_blank" rel="noopener">TorBox</a> torrents, usenet, and web downloads directly — no <code>.strm</code> files or mount. Get your API key from TorBox → Settings.</p>
              <label for="torbox-label">Name</label><input id="torbox-label" placeholder="TorBox">
              <label for="torbox-apikey">API key</label><input id="torbox-apikey" type="password" autocomplete="new-password" placeholder="from torbox.app/settings">
              <label for="torbox-categories">Categories <span class="muted">(optional)</span></label><input id="torbox-categories" placeholder="torrents,usenet,webdl">
              <p class="hint">Which buckets to index — any of <code>torrents</code>, <code>usenet</code>, <code>webdl</code>. Blank indexes all three.</p>
              <label for="torbox-linkttl">Link freshness seconds <span class="muted">(optional — best left blank)</span></label><input id="torbox-linkttl" type="number" min="0" placeholder="leave blank">
              <p class="hint">⚠️ <strong>Recommended: leave this empty.</strong> Sphynx re-resolves every link <em>fresh at play time and never caches it</em>, so a freshness window mostly adds a moving part with its own failure mode (a link that expires mid-session). Only set it if TorBox links are genuinely time-bounded <em>and</em> you hit playback failures after long pauses — see the guide's <a href="https://reckloon.github.io/Sphynx-Media/#api-resolve" target="_blank" rel="noopener">resolve note</a>.</p>
              <label>Scan this source for</label>
              <div class="row scanrow">
                <label class="scanopt"><input type="checkbox" id="torbox-scan-movie" class="lib-movie-cb" checked> Movies</label>
                <label class="scanopt"><input type="checkbox" id="torbox-scan-tv" class="lib-tv-cb" checked> TV Shows</label>
              </div>
              <label for="torbox-refresh">Auto-refresh every (minutes, 0 = manual)</label><input id="torbox-refresh" type="number" min="0" value="0">
              <p class="hint">TorBox allows 300 requests/min per token; even frequent refreshes stay well under it.</p>
              <button data-add="torbox">Add source</button><div id="torbox-msg" class="msg"></div>
            </div>
          </div>
        </div>
      </section>

      <!-- ============ USERS & PERMISSIONS ============ -->
      <section id="tab-users" hidden>
        <h2>Users &amp; permissions</h2>
        <p class="hint" style="margin-top:0;">Tick a permission to grant it (saves immediately). Use <strong>Per-library</strong> to grant a permission for one library only. The admin holds everything and can't be changed or deleted.</p>
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

      <!-- ============ ITEMS (admin metadata correction) ============ -->
      <section id="tab-items" hidden>
        <h2>Item correction</h2>
        <p class="hint" style="margin-top:0;">Search every title, filter to the ones still missing metadata, or browse a library. Open a title and fix its metadata — any field you edit is <strong>locked</strong> 🔒 so a re-scan or refresh won't overwrite it. Re-identify points the title at the right TMDB id.</p>
        <div class="toolbar">
          <input id="it-search" placeholder="Search all titles…" style="flex:1; min-width:160px;">
          <label class="scanopt" style="margin:0;" title="Show only items still missing TMDB metadata (excludes extras that never enrich)"><input type="checkbox" id="it-needs"> Needs metadata</label>
          <span class="meta">or browse</span>
          <select id="it-lib" style="width:auto; min-width:150px;"></select>
        </div>
        <div id="it-crumbs" class="crumbs"></div>
        <div id="it-list"><div class="empty">Search, tick <strong>Needs metadata</strong>, or pick a library to begin.</div></div>

        <div id="it-editor" class="addbox" hidden>
          <div class="group-title">Editing <span id="it-ed-title" class="muted"></span></div>
          <div class="lockrow"><label for="it-f-title">Title <span class="lockbadge" data-lb="title"></span></label><input id="it-f-title"></div>
          <div class="lockrow"><label for="it-f-overview">Overview <span class="lockbadge" data-lb="overview"></span></label><textarea id="it-f-overview" rows="3"></textarea></div>
          <div class="row">
            <div class="lockrow"><label for="it-f-year">Year <span class="lockbadge" data-lb="year"></span></label><input id="it-f-year" type="number"></div>
            <div class="lockrow"><label for="it-f-runtime">Runtime (minutes) <span class="lockbadge" data-lb="runtime"></span></label><input id="it-f-runtime" type="number" min="0"></div>
          </div>
          <div class="row">
            <div class="lockrow"><label for="it-f-rating">Community rating <span class="lockbadge" data-lb="communityRating"></span></label><input id="it-f-rating" type="number" step="0.1" min="0" max="10"></div>
            <div class="lockrow"><label for="it-f-official">Content rating <span class="lockbadge" data-lb="officialRating"></span></label><input id="it-f-official" placeholder="PG-13"></div>
          </div>
          <div class="lockrow"><label for="it-f-genres">Genres (comma-separated) <span class="lockbadge" data-lb="genres"></span></label><input id="it-f-genres" placeholder="Action, Drama"></div>
          <div class="lockrow"><label for="it-f-primary">Poster URL <span class="lockbadge" data-lb="images"></span></label><input id="it-f-primary" placeholder="https://…"></div>
          <div class="lockrow"><label for="it-f-backdrop">Backdrop URL <span class="lockbadge" data-lb="images"></span></label><input id="it-f-backdrop" placeholder="https://…"></div>
          <button id="it-save-btn">Save &amp; lock edited fields</button>
          <button id="it-unlock-btn" class="secondary" style="margin-left:8px;">Unlock all</button>
          <button id="it-enrich-btn" class="secondary" style="margin-left:8px;">Re-enrich</button>
          <div class="row" style="margin-top:16px;">
            <div><label for="it-f-tmdb">Re-identify: TMDB id</label><input id="it-f-tmdb" placeholder="603"></div>
            <div><label for="it-f-tmdb-type">As type</label><select id="it-f-tmdb-type"><option value="">(keep)</option><option value="movie">movie</option><option value="series">series</option></select></div>
          </div>
          <button id="it-identify-btn" class="secondary">Re-identify &amp; enrich</button>

          <div class="group-title" style="margin-top:18px;">Re-map (fix placement)</div>
          <p class="hint" style="margin-top:0;">For an item in the wrong place — wrong library, or an episode/season that never got linked to its show. Change its type, move it to another library, set its season/episode number, or nest it under the right series or season. Needs edit rights on both the current and destination library.</p>
          <div class="row">
            <div><label for="it-f-type">Type</label><select id="it-f-type"><option value="">(keep)</option><option>movie</option><option>series</option><option>season</option><option>episode</option><option>collection</option><option>trailer</option><option>featurette</option><option>deletedScene</option><option>behindTheScenes</option></select></div>
            <div><label for="it-f-library">Move to library</label><select id="it-f-library"></select></div>
          </div>
          <div class="row">
            <div><label for="it-f-season">Season #</label><input id="it-f-season" type="number" min="0"></div>
            <div><label for="it-f-episode">Episode #</label><input id="it-f-episode" type="number" min="0"></div>
          </div>
          <label for="it-parent-search">Nest under a series or season</label>
          <div class="bar" style="gap:8px;">
            <input id="it-parent-search" placeholder="Search series or seasons by name…" style="flex:1; min-width:160px;">
            <button id="it-parent-find" class="mini secondary" type="button">Find</button>
          </div>
          <select id="it-parent-pick"><option value="">(keep current parent)</option></select>
          <div style="margin-top:12px;">
            <button id="it-remap-btn">Apply re-map</button>
            <button id="it-close-btn" class="secondary" style="margin-left:8px;">Close</button>
          </div>
          <div id="it-msg" class="msg"></div>
        </div>
      </section>

      <!-- ============ SETTINGS ============ -->
      <section id="tab-settings" hidden>
        <p class="hint" style="margin-top:0;">All time settings are in <strong>minutes</strong>. Handy conversions: 1 hour = 60 · 1 day = 1440 · 7 days = 10080 · 30 days = 43200 · 1 year = 525600.</p>
        <div class="group-title">Server identity</div>
        <div class="row">
          <div><label for="serverName">Server name</label><input id="serverName"><p class="hint">The friendly name apps show when they connect.</p></div>
          <div><label for="serverID">Server ID</label><input id="serverID"><p class="hint">A stable identifier for this server. You rarely need to change this.</p></div>
        </div>
        <div class="group-title">Signing in</div>
        <div class="row">
          <div><label for="accessTokenTTL">Login session length</label><input id="accessTokenTTL" type="number" min="0"><p class="hint">How long the app stays signed in before it quietly re-authenticates. e.g. 60 = 1 hour.</p></div>
          <div><label for="refreshTokenTTL">Time before sign-in is required again</label><input id="refreshTokenTTL" type="number" min="0"><p class="hint">After this, the user must type their password again. e.g. 43200 = 30 days.</p></div>
        </div>
        <div class="group-title">Library &amp; upkeep</div>
        <div class="row">
          <div><label for="markersAccess">Who can add "skip intro" markers</label>
            <select id="markersAccess"><option value="none">Off — not offered</option><option value="read">Read only — clients can use them, not add</option><option value="readwrite">Read &amp; let clients contribute</option></select>
            <p class="hint">Whether apps may read and/or submit intro/credits markers.</p></div>
          <div><label for="enrichmentTTL">Refresh posters &amp; info every</label><input id="enrichmentTTL" type="number" min="0"><p class="hint">How old TMDB data can get before it's re-fetched. e.g. 129600 = 90 days.</p></div>
          <div><label for="markersStaleAfter">Mark "skip intro" data old after</label><input id="markersStaleAfter" type="number" min="0"><p class="hint">When a client is asked to refresh contributed markers. e.g. 10080 = 7 days.</p></div>
          <div><label for="playstateRetention">Remember watch progress for</label><input id="playstateRetention" type="number" min="0"><p class="hint">How long to keep "resume where you left off". e.g. 525600 = 1 year.</p></div>
          <div><label for="maintenanceInterval">Run background cleanup every</label><input id="maintenanceInterval" type="number" min="0"><p class="hint">Refreshes stale info and tidies old data. e.g. 1440 = 1 day; 0 = off.</p></div>
          <div><label for="avatarMaxBytes">Max profile-picture size (bytes)</label><input id="avatarMaxBytes" type="number" min="0"><p class="hint">Upload limit for user avatars on the /user page. e.g. 2000000 = 2 MB.</p></div>
        </div>
        <div class="group-title">Metadata (TMDB)</div>
        <label for="tmdb-key">TMDB API key <span id="tmdb-status" class="muted"></span></label>
        <input id="tmdb-key" type="password" placeholder="Paste your TMDB v3 API key" autocomplete="off">
        <p class="hint">Identifies titles and fetches posters, overviews, and cast. <a href="https://www.themoviedb.org/settings/api" target="_blank" rel="noopener">Get a free key →</a> Leave blank to keep the current key; saving applies on the next restart.</p>
        <label for="metadataLanguage">Metadata language</label>
        <select id="metadataLanguage">
          <option value="en-US">English (US)</option>
          <option value="en-GB">English (UK)</option>
          <option value="es-ES">Español</option>
          <option value="es-MX">Español (México)</option>
          <option value="fr-FR">Français</option>
          <option value="de-DE">Deutsch</option>
          <option value="it-IT">Italiano</option>
          <option value="pt-BR">Português (Brasil)</option>
          <option value="ru-RU">Русский</option>
          <option value="uk-UA">Українська</option>
          <option value="ja-JP">日本語</option>
          <option value="ko-KR">한국어</option>
          <option value="zh-CN">中文 (简体)</option>
          <option value="zh-TW">中文 (繁體)</option>
        </select>
        <p class="hint">Titles, overviews, and episode names are normalised to this language during enrichment — so a foreign-named release (e.g. <code>Бэтмен</code>) shows in your language regardless of how the file was named. Manually-edited titles 🔒 are never overwritten. Applies on the next scan/refresh.</p>
        <button id="save-btn">Save settings</button>
        <div id="save-msg" class="msg"></div>
        <p class="hint">Saved settings take effect the next time the server restarts. (Network address, database location, and the admin login are set when starting the server.)</p>
      </section>

      <!-- ============ EXTENSIONS ============ -->
      <section id="tab-extensions" hidden>
        <p class="hint" style="margin-top:0;">Optional, self-contained capabilities outside the wire protocol. Each module has its own controls.</p>
        <div class="tablist" id="ext-nav"><div class="empty">Loading extensions…</div></div>

        <div id="mod-diagnostics" class="ext-mod" hidden>
          <div class="subtabs" id="diag-subtabs">
            <button class="subtab active" data-sub="database">Database</button>
            <button class="subtab" data-sub="logs">Logs</button>
          </div>
          <div id="sub-database">
            <p class="hint" style="margin-top:0;">Read-only. Sensitive columns (password &amp; token hashes, source secrets, request headers) are redacted 🔒.</p>
            <div class="tablist" id="db-tables"><div class="empty">Loading tables…</div></div>
            <div id="db-view" hidden>
              <div class="toolbar"><strong id="db-title"></strong><span class="hint" id="db-count" style="margin:0;"></span><span class="spacer"></span>
                <input id="db-search-tmdb" placeholder="TMDB id" style="width:auto;" inputmode="numeric">
                <input id="db-search-name" placeholder="Name contains…" style="width:auto;">
                <button class="mini secondary" id="db-search-clear">Clear</button>
                <button class="mini secondary" id="db-refresh">Refresh</button></div>
              <div class="tablebox"><table class="db"><thead id="db-head"></thead><tbody id="db-body"></tbody></table></div>
              <div class="pager"><button class="mini secondary" id="db-prev">‹ Prev</button><span id="db-range"></span><button class="mini secondary" id="db-next">Next ›</button></div>
            </div>
          </div>
          <div id="sub-logs" hidden>
            <div class="toolbar">
              <label style="margin:0;">Level</label>
              <select id="log-level" style="width:auto;"><option value="">all</option><option value="trace">trace</option><option value="debug">debug</option><option value="info" selected>info</option><option value="notice">notice</option><option value="warning">warning</option><option value="error">error</option><option value="critical">critical</option></select>
              <button class="mini secondary" id="log-pause">Pause</button>
              <button class="mini secondary" id="log-clear">Clear view</button>
              <span class="spacer"></span><span class="hint" id="log-status" style="margin:0;"></span>
            </div>
            <div class="logbox" id="log-box"><div class="empty">Waiting for logs…</div></div>
          </div>
        </div>

        <div id="mod-media-probe" class="ext-mod" hidden>
          <p class="hint" style="margin-top:0;">Inspect a title's audio, subtitle, and video tracks with ffmpeg's <code>ffprobe</code>, plus any sidecar subtitle files next to a local file. Probing <strong>caches</strong> the result so <code>/v1/resolve</code> serves rich <code>tracks</code>.</p>
          <div class="mp-row">
            <label class="switch"><input type="checkbox" id="mp-enabled"> Enable media probe</label>
            <span id="mp-avail" class="hint" style="margin:0;"></span>
          </div>
          <label for="mp-path">ffprobe path <span class="muted">(blank = auto-discover on PATH)</span></label>
          <input id="mp-path" placeholder="/usr/local/bin/ffprobe">
          <button id="mp-save">Save</button>
          <div class="addbox">
            <div class="group-title">Probe a title</div>
            <label for="mp-item">Item id</label><input id="mp-item" placeholder="it_…">
            <button id="mp-probe-btn">Probe</button>
            <div id="mp-msg" class="msg"></div>
            <div id="mp-result"></div>
          </div>
        </div>
      </section>
    </div>
  </div>
</div>

<script>
  var $ = function (s) { return document.querySelector(s); };
  var token = sessionStorage.getItem('sphynxToken') || '';
  var libraries = [];
  var permCatalog = { permissions: [], libraries: [] };

  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function msg(id, text, ok) { var e = $('#' + id); if (e) { e.textContent = text || ''; e.className = 'msg' + (ok ? ' ok' : ''); } }

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
  function logout() { stopPoll(); stopDash(); token = ''; sessionStorage.removeItem('sphynxToken'); $('#app').hidden = true; $('#login').hidden = false; }
  function enter() {
    $('#login').hidden = true; $('#app').hidden = false;
    loadSettings(); loadLibraries(); loadPermCatalog(); loadUsers();
    startDash();
  }

  // ---- tabs ----
  var TABS = ['libraries', 'users', 'items', 'settings', 'extensions'];
  var poll = null;
  function stopPoll() { if (poll) { clearInterval(poll); poll = null; } }
  function startPoll(fn, ms) { stopPoll(); fn(); poll = setInterval(fn, ms); }
  function showTab(name) {
    document.querySelectorAll('.tabs .tab').forEach(function (x) { x.classList.toggle('active', x.dataset.tab === name); });
    TABS.forEach(function (n) { $('#tab-' + n).hidden = (n !== name); });
    stopPoll();
    if (name === 'extensions') enterExtensions();
    else if (name === 'items') enterItems();
  }
  Array.prototype.forEach.call(document.querySelectorAll('.tabs .tab'), function (t) {
    t.onclick = function () { showTab(t.dataset.tab); };
  });

  // ---- persistent dashboard (coverage + status), adaptive polling ----
  // One self-scheduling loop: fast while the server is scanning/enriching so the
  // dashboard and library counts update in near-realtime, relaxed when idle, and
  // nearly paused when the tab is hidden — so it costs nothing when no one is
  // looking and never runs at all unless the admin panel is open.
  var dashTimer = null, dashPhase = 'idle';
  function stopDash() { if (dashTimer) { clearTimeout(dashTimer); dashTimer = null; } }
  function scheduleDash() {
    stopDash();
    var ms = document.hidden ? 20000 : (dashPhase !== 'idle' ? 1000 : 6000);
    dashTimer = setTimeout(tickDash, ms);
  }
  function tickDash() {
    if (!token) return;
    if (document.hidden) { scheduleDash(); return; }
    Promise.all([loadStatus(), loadOverview()]).then(scheduleDash, scheduleDash);
  }
  function startDash() { stopDash(); tickDash(); }
  // Catch up instantly when the tab regains focus.
  document.addEventListener('visibilitychange', function () { if (!document.hidden && token) startDash(); });
  function fmtMs(ms) { if (ms == null) return ''; return ms < 1000 ? Math.round(ms) + 'ms' : (ms / 1000).toFixed(1) + 's'; }
  function fmtDur(s) { s = Math.floor(s); var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60; return (h ? h + 'h ' : '') + (m ? m + 'm ' : '') + x + 's'; }
  var RESULT_LABELS = { enriched: 'enriched', alreadyComplete: 'already complete', skipped: 'skipped (unidentified)', failed: 'failed' };
  function jobRow(j) {
    var label = j.result ? (RESULT_LABELS[j.result] || j.result) : '';
    var right = j.result ? '<span class="meta res-' + esc(j.result) + '">' + esc(label) + ' · ' + fmtMs(j.durationMs) + '</span>' : '<span class="meta">' + fmtMs(j.durationMs) + '</span>';
    return '<div class="item"><span><span class="chip ' + esc(j.kind) + '">' + esc(j.kind) + '</span> ' + esc(j.title) + '</span>' + right + '</div>';
  }
  function loadStatus() {
    return api('/v1/admin/status', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (s) {
      if (!s) return;
      dashPhase = s.phase;
      var live = s.phase !== 'idle';
      $('#act-phase').innerHTML = '<span class="dot ' + esc(s.phase) + (live ? ' pulse' : '') + '"></span> ' + s.phase.charAt(0).toUpperCase() + s.phase.slice(1);
      $('#act-uptime').textContent = 'uptime ' + fmtDur(s.uptimeSeconds) + ' · ' + s.processed + ' processed';
      $('#act-active').textContent = s.active; $('#act-queued').textContent = s.queued; $('#act-failed').textContent = s.failed;
      // "In progress" lists only jobs actively being worked. Finished jobs
      // (enriched / already complete / skipped) must NOT linger here — when
      // nothing is active the list clears to the placeholder.
      var jobs = (s.jobs || []).slice(0, 8);
      $('#act-jobs').innerHTML = jobs.length ? jobs.map(jobRow).join('') : '<div class="empty">Nothing running right now.</div>';
      $('#act-scans').innerHTML = (s.scans || []).length ? s.scans.map(function (sc) {
        return '<div class="item"><span>' + esc(sc.sourceId) + '</span><span class="meta">scanned ' + sc.scanned + ' · +' + sc.added + ' ~' + sc.updated + ' −' + sc.removed + ' · enriched ' + sc.enriched + ' · ' + fmtMs(sc.durationMs) + '</span></div>';
      }).join('') : '<div class="empty">No scans yet this session.</div>';
    }).catch(function () {});
  }
  function loadOverview() {
    return api('/v1/admin/overview', 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (o) {
      if (!o) return;
      $('#cov-source').textContent = o.inSource; $('#cov-indexed').textContent = o.indexed; $('#cov-enriched').textContent = o.enriched;
      var base = Math.max(o.inSource, o.indexed, 1);
      var idxPct = Math.min(100, Math.round(o.indexed / base * 100));
      var enrPct = Math.min(100, Math.round(o.enriched / base * 100));
      $('#cov-seg-idx').style.width = Math.max(0, idxPct - enrPct) + '%';
      $('#cov-seg-enr').style.width = enrPct + '%';
      $('#cov-pct-idx').textContent = idxPct + '%';
      $('#cov-pct-enr').textContent = (o.indexed ? Math.round(o.enriched / o.indexed * 100) : 0) + '%';
      renderBreakdown(o);
      // Keep the per-library counts live straight from the overview we just
      // fetched (no extra request), so the Libraries tab tracks a scan in realtime.
      // If the set of libraries changed, do a full resync to pick up new ones.
      libCounts = {}; (o.libraries || []).forEach(function (l) { libCounts[l.id] = l; });
      if (!$('#tab-libraries').hidden) {
        if ((o.libraries || []).length !== libraries.length) loadLibraries();
        else renderLibraries();
      }
    }).catch(function () {});
  }
  var TYPE_LABELS = {
    collection: 'Collections', movie: 'Movies', series: 'Series', season: 'Seasons',
    episode: 'Episodes', trailer: 'Trailers', featurette: 'Featurettes',
    deletedScene: 'Deleted scenes', behindTheScenes: 'Behind the scenes'
  };
  // Extras carry no TMDB metadata, so they never enrich — shown as a count with
  // an "extras" tag rather than a 0-of-N deficit (which would read as a failure).
  var EXTRA_TYPES = { trailer: 1, featurette: 1, deletedScene: 1, behindTheScenes: 1 };
  // One breakdown row: name, the enriched/indexed split (or an "extras" tag), a bar.
  function bdRow(name, indexed, enriched, isExtra) {
    var pct = indexed ? Math.round(enriched / indexed * 100) : 0;
    var unenriched = indexed - enriched;
    var num = isExtra
      ? indexed + ' <span class="bd-tag">extras</span>'
      : '<b>' + enriched + '</b> / ' + indexed +
        (unenriched > 0 ? ' <span class="bd-not">(' + unenriched + ' not)</span>' : '');
    return '<div class="bd-row' + (isExtra ? ' bd-extra' : '') + '"><span class="bd-name">' + esc(name) + '</span>' +
      '<span class="bd-num">' + num + '</span>' +
      '<span class="bd-bar"><span style="width:' + (isExtra ? 0 : pct) + '%"></span></span></div>';
  }
  function renderBreakdown(o) {
    var libs = o.libraries || [];
    $('#cov-bylib').innerHTML = libs.length
      ? libs.map(function (l) { return bdRow(l.title, l.indexed, l.enriched, false); }).join('')
      : '<div class="empty">No libraries yet.</div>';
    var types = o.byType || [];
    $('#cov-bytype').innerHTML = types.length
      ? types.map(function (t) { return bdRow(TYPE_LABELS[t.type] || t.type, t.indexed, t.enriched, !!EXTRA_TYPES[t.type]); }).join('')
      : '<div class="empty">Nothing indexed yet.</div>';
  }

  // ---- settings ----
  var sfields = ['serverName', 'serverID', 'accessTokenTTL', 'refreshTokenTTL', 'enrichmentTTL', 'metadataLanguage', 'markersAccess', 'markersStaleAfter', 'playstateRetention', 'maintenanceInterval', 'avatarMaxBytes'];
  var snumbers = ['accessTokenTTL', 'refreshTokenTTL', 'enrichmentTTL', 'markersStaleAfter', 'playstateRetention', 'maintenanceInterval'];
  function loadSettings() {
    api('/v1/admin/settings', 'GET').then(function (res) {
      if (res.status === 401) { logout(); return null; }
      if (res.status === 403) { msg('login-msg', 'That account is not the admin.'); logout(); return null; }
      return res.ok ? res.json() : null;
    }).then(function (s) { if (s) sfields.forEach(function (f) { var el = $('#' + f); if (el && s[f] != null) el.value = snumbers.indexOf(f) >= 0 ? Math.round(Number(s[f]) / 60) : s[f]; }); });
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
    sfields.forEach(function (f) { var el = $('#' + f); if (!el) return; body[f] = snumbers.indexOf(f) >= 0 ? Math.round(Number(el.value) * 60) : (f === 'avatarMaxBytes' ? Math.max(0, Math.round(Number(el.value))) : el.value); });
    var tmdbKey = ($('#tmdb-key') ? $('#tmdb-key').value : '').trim();
    var tmdbSave = tmdbKey ? api('/v1/admin/tmdb', 'PATCH', { apiKey: tmdbKey }) : Promise.resolve(null);
    api('/v1/admin/settings', 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('save-msg', (e && e.error && e.error.message) || 'Save failed.'); }).catch(function () { msg('save-msg', 'Save failed.'); }); return; }
      return tmdbSave.then(function () { msg('save-msg', 'Saved. Restart the server for changes to take effect.', true); loadTMDBStatus(); });
    }).catch(function () { msg('save-msg', 'Could not reach the server.'); });
  }
  function scanAllSources() {
    msg('lib-msg', 'Scanning all sources…');
    api('/v1/admin/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) { msg('lib-msg', 'Scan failed.'); return; }
      var srcs = d.sources || [];
      var tot = srcs.reduce(function (a, s) { return a + (s.scanned || 0); }, 0);
      msg('lib-msg', 'Scanned ' + srcs.length + ' source(s), ' + tot + ' item(s).', true);
      loadSources(); loadLibraries(); loadOverview();
    }).catch(function () { msg('lib-msg', 'Could not reach the server.'); });
  }

  // ---- libraries ----
  var libCounts = {};
  function loadLibraries() {
    api('/v1/admin/overview', 'GET').then(function (r) { return r.ok ? r.json() : null; }).then(function (o) {
      libCounts = {}; if (o) (o.libraries || []).forEach(function (l) { libCounts[l.id] = l; });
      renderLibraries();
    });
    api('/v1/admin/libraries', 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      // Only replace the cache on a SUCCESSFUL load — a transient failure must not
      // blank `libraries` and disable every source's scan checkbox with no recovery.
      if (d) libraries = d.libraries || [];
      renderLibraries(); refreshLibPickers();
    });
  }
  var SERVER_LIB_TYPES = [
    { kind: 'movies', title: 'Movies' },
    { kind: 'tvShows', title: 'TV Shows' },
    { kind: 'collection', title: 'Collections' }
  ];
  function renderLibraries() {
    if (!$('#lib-list')) return;
    $('#lib-list').innerHTML = SERVER_LIB_TYPES.map(function (t) {
      var l = libraries.filter(function (x) { return x.kind === t.kind; })[0];
      var on = !!l;
      var c = on ? libCounts[l.id] : null;
      var counts = c ? '<span class="meta">' + c.indexed + ' items · ' + c.enriched + ' enriched</span>'
        : (on ? '<span class="meta">empty</span>' : '<span class="meta">off</span>');
      var acts = '';
      if (on && t.kind === 'movies') {
        acts += '<label class="meta" title="Collapse a movie collection into one box-set tile once it has at least this many of its movies in this library; below the number, those movies show individually. Set higher than any collection (e.g. 999) to never group.">Group collections at <input class="mini" type="number" min="1" style="width:3.6em" value="' + (l.collectionThreshold == null ? 1 : l.collectionThreshold) + '" data-thr-lib="' + esc(l.id) + '"> movies</label> ';
      }
      if (on) {
        acts += '<button class="mini" data-scan-lib="' + esc(l.id) + '" title="Re-scan every source feeding this library">Refresh</button> ';
      }
      acts += '<label class="meta" title="Toggle this library on or off. Turning it off deletes the library and everything in it."><input type="checkbox" data-lib-toggle="' + t.kind + '"' + (on ? ' data-lib-id="' + esc(l.id) + '" checked' : '') + '> ' + (on ? 'On' : 'Off') + '</label>';
      return '<div class="item"><span><strong>' + esc(t.title) + '</strong> ' + counts + '</span><span class="acts">' + acts + '</span></div>';
    }).join('');
  }
  function refreshLibPickers() {
    // Enable a source's content-type checkbox only when that library type is on;
    // disable (and clear) it otherwise so you can't route into a library that
    // doesn't exist.
    var movieOn = libraries.some(function (l) { return l.kind === 'movies'; });
    var tvOn = libraries.some(function (l) { return l.kind === 'tvShows'; });
    Array.prototype.forEach.call(document.querySelectorAll('.lib-movie-cb'), function (cb) {
      var wasDisabled = cb.disabled;
      cb.disabled = !movieOn;
      if (!movieOn) cb.checked = false;        // library off → can't route into it
      else if (wasDisabled) cb.checked = true; // just came back on → restore the default-on checkbox
      cb.parentNode.title = movieOn ? '' : 'Turn on the Movies library first';
    });
    Array.prototype.forEach.call(document.querySelectorAll('.lib-tv-cb'), function (cb) {
      var wasDisabled = cb.disabled;
      cb.disabled = !tvOn;
      if (!tvOn) cb.checked = false;
      else if (wasDisabled) cb.checked = true;
      cb.parentNode.title = tvOn ? '' : 'Turn on the TV Shows library first';
    });
    var itLib = $('#it-lib'); if (itLib) { var cur = itLib.value; itLib.innerHTML = '<option value="">— pick —</option>' + libraries.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join(''); itLib.value = cur; }
  }
  function toggleLibrary(kind, on, id, checkbox) {
    msg('lib-msg', '');
    if (on) {
      api('/v1/admin/libraries', 'POST', { kind: kind }).then(function (res) {
        if (res.status === 401) { logout(); return; }
        if (!res.ok) { msg('lib-msg', 'Could not enable that library.'); if (checkbox) checkbox.checked = false; return; }
        loadLibraries();
      }).catch(function () { if (checkbox) checkbox.checked = false; });
    } else {
      var t = (SERVER_LIB_TYPES.filter(function (x) { return x.kind === kind; })[0] || {}).title || 'this';
      if (!confirm('Turn off the ' + t + ' library? This deletes the library and every item in it.')) { if (checkbox) checkbox.checked = true; return; }
      api('/v1/admin/libraries/' + id, 'DELETE').then(function (res) {
        if (res.status === 401) { logout(); return; }
        loadLibraries(); loadSources();
      });
    }
  }

  // ---- storage sources (per-driver) ----
  var STORAGE_DRIVERS = ['local', 'http', 'webdav', 'smb', 'ftp', 'torbox'];
  var storActive = 'local';
  function libraryMapFor(driver) {
    // Libraries are fixed on/off types now: a source ticks the content types it
    // holds and routes to whichever of those libraries is enabled.
    var map = {};
    var movieLib = libraries.filter(function (l) { return l.kind === 'movies'; })[0];
    var tvLib = libraries.filter(function (l) { return l.kind === 'tvShows'; })[0];
    var mv = $('#' + driver + '-scan-movie'), tv = $('#' + driver + '-scan-tv');
    if (mv && mv.checked && movieLib) map.movie = movieLib.id;
    if (tv && tv.checked && tvLib) map.tv = tvLib.id;
    return Object.keys(map).length ? map : null;
  }
  function buildSourceBody(driver) {
    var val = function (id) { var el = $('#' + driver + '-' + id); return el ? el.value.trim() : ''; };
    var label = val('label');
    if (!label) { msg(driver + '-msg', 'Name is required.'); return null; }
    var body = { label: label, driver: driver };
    if (driver === 'local') { body.config = { rootPath: val('rootpath') }; }
    else if (driver === 'http') { if (val('baseurl')) body.baseURL = val('baseurl'); if (val('manifest')) body.manifestURL = val('manifest'); if (val('auth')) body.headers = { Authorization: val('auth') }; }
    else if (driver === 'webdav') { body.config = { baseURL: val('baseurl') }; var secrets = {}; if (val('username')) secrets.username = val('username'); if (val('password')) { if (val('username')) secrets.password = val('password'); else secrets.token = val('password'); } if (Object.keys(secrets).length) body.secrets = secrets; }
    else if (driver === 'smb') { body.config = { host: val('host'), share: val('share') }; var s = {}; if (val('username')) s.username = val('username'); if (val('password')) s.password = val('password'); if (Object.keys(s).length) body.secrets = s; }
    else if (driver === 'ftp') { var cfg = { host: val('host') }; if (val('port')) cfg.port = Number(val('port')); body.config = cfg; var f = {}; if (val('username')) f.username = val('username'); if (val('password')) f.password = val('password'); if (Object.keys(f).length) body.secrets = f; }
    else if (driver === 'torbox') { if (!val('apikey')) { msg(driver + '-msg', 'API key is required.'); return null; } var tc = {}; if (val('categories')) tc.categories = val('categories'); if (val('linkttl')) tc.linkTTL = val('linkttl'); if (Object.keys(tc).length) body.config = tc; body.secrets = { apiKey: val('apikey') }; }
    var map = libraryMapFor(driver); if (map) body.libraryMap = map;
    var refresh = val('refresh'); if (refresh !== '') body.refreshInterval = Math.max(0, Math.round(Number(refresh) * 60));
    return body;
  }
  function clearSourceForm(driver) {
    var panel = document.querySelector('[data-drvpanel="' + driver + '"]');
    if (panel) Array.prototype.forEach.call(panel.querySelectorAll('.addbox input'), function (el) { el.value = ''; });
  }
  function loadSources() {
    api('/v1/admin/sources', 'GET').then(function (res) { return res.ok ? res.json() : { sources: [] }; }).then(function (d) {
      var srcs = d.sources || [];
      STORAGE_DRIVERS.forEach(function (driver) {
        var list = $('#src-list-' + driver); if (!list) return;
        var mine = srcs.filter(function (s) { return s.driver === driver; });
        list.innerHTML = mine.length ? mine.map(function (s) {
          var rm = (s.refreshInterval > 0) ? 'refresh every ' + Math.round(s.refreshInterval / 60) + ' min' : 'manual';
          return '<div class="item"><span><strong>' + esc(s.label) + '</strong> <span class="meta">' + rm + '</span></span><span class="acts"><button class="mini" data-scan="' + esc(s.id) + '">Scan</button><button class="mini danger" data-del-src="' + esc(s.id) + '">Delete</button></span></div>';
        }).join('') : '<div class="empty">No ' + driver + ' sources yet. Add one below.</div>';
      });
    });
  }
  function addSource(driver) {
    msg(driver + '-msg', '');
    var body = buildSourceBody(driver); if (!body) return;
    api('/v1/admin/sources', 'POST', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg(driver + '-msg', (e && e.error && e.error.message) || 'Could not add source.'); }).catch(function () { msg(driver + '-msg', 'Could not add source.'); }); return; }
      clearSourceForm(driver); msg(driver + '-msg', 'Added.', true); loadSources(); loadLibraries();
    }).catch(function () { msg(driver + '-msg', 'Could not reach the server.'); });
  }
  function scanSource(driver, id) {
    msg(driver + '-msg', 'Scanning…');
    api('/v1/admin/sources/' + id + '/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (s) {
      if (!s) { msg(driver + '-msg', 'Scan failed.'); return; }
      msg(driver + '-msg', 'Scanned ' + s.scanned + ' · added ' + s.added + ' · updated ' + s.updated + ' · removed ' + s.removed + (s.enriched != null ? ' · enriched ' + s.enriched : ''), true);
      loadLibraries(); loadOverview();
    }).catch(function () { msg(driver + '-msg', 'Scan failed.'); });
  }
  function showStorage(driver) {
    storActive = driver;
    Array.prototype.forEach.call(document.querySelectorAll('#stor-subtabs .subtab'), function (b) { b.classList.toggle('active', b.dataset.drv === driver); });
    Array.prototype.forEach.call(document.querySelectorAll('.stor-panel'), function (p) { p.hidden = (p.getAttribute('data-drvpanel') !== driver); });
  }
  $('#stor-subtabs').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.drv) showStorage(b.dataset.drv); };
  $('#tab-libraries').onclick = function (e) {
    var add = e.target.getAttribute('data-add'); if (add) { addSource(add); return; }
    var del = e.target.getAttribute('data-del-src'), scan = e.target.getAttribute('data-scan');
    if (del) { if (confirm('Delete this source and its items?')) api('/v1/admin/sources/' + del, 'DELETE').then(function () { loadSources(); loadLibraries(); }); return; }
    if (scan) { scanSource(storActive, scan); return; }
    var rl = e.target.getAttribute('data-scan-lib');
    if (rl) {
      msg('lib-msg', 'Refreshing…');
      api('/v1/admin/libraries/' + rl + '/scan', 'POST').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
        if (!d) { msg('lib-msg', 'Refresh failed.'); return; }
        var n = (d.sources || []).reduce(function (a, s) { return a + (s.scanned || 0); }, 0);
        msg('lib-msg', 'Refreshed ' + (d.sources || []).length + ' source(s), ' + n + ' item(s).', true);
        loadLibraries(); loadOverview();
      }).catch(function () { msg('lib-msg', 'Refresh failed.'); });
      return;
    }
  };
  $('#lib-list').onchange = function (e) {
    var tk = e.target.getAttribute('data-lib-toggle');
    if (tk !== null) { toggleLibrary(tk, e.target.checked, e.target.getAttribute('data-lib-id'), e.target); return; }
    var id = e.target.getAttribute('data-thr-lib'); if (!id) return;
    var v = parseInt(e.target.value, 10); if (isNaN(v) || v < 0) v = 0;
    api('/v1/admin/libraries/' + id, 'PATCH', { collectionThreshold: v }).then(function () { loadLibraries(); });
  };

  // ---- users & permissions (data-driven from /v1/admin/permissions) ----
  function loadPermCatalog() {
    return api('/v1/admin/permissions', 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (d) {
      if (d) permCatalog = d;
    });
  }
  function loadUsers() {
    api('/v1/admin/users', 'GET').then(function (res) { return res.ok ? res.json() : { users: [] }; }).then(function (d) {
      var users = d.users || [];
      $('#user-list').innerHTML = users.map(renderUser).join('');
    });
  }
  function avatarHTML(u) {
    if (u.avatarURL) return '<img class="avatar" src="' + esc(u.avatarURL) + '" alt="">';
    var initial = (u.displayName || u.username || '?').charAt(0).toUpperCase();
    return '<span class="avatar ph">' + esc(initial) + '</span>';
  }
  function renderUser(u) {
    var held = u.permissions || [];
    var caps = permCatalog.permissions || [];
    var perms = caps.map(function (c) {
      var on = held.indexOf(c.key) >= 0;
      var attrs = u.isAdmin ? ' checked disabled' : (on ? ' checked' : '');
      return '<label class="perm' + (c.reserved ? ' reserved' : '') + '" title="' + esc(c.description) + '"><input type="checkbox" data-uid="' + esc(u.id) + '" data-perm="' + esc(c.key) + '"' + attrs + '>' + esc(c.label) + '</label>';
    }).join('');
    var top = '<div class="user-top">' + avatarHTML(u) +
      '<div><div class="uname">' + esc(u.displayName || u.username) + '</div><div class="usub">' + esc(u.username) + (u.isAdmin ? ' · admin' : '') + '</div></div>' +
      '<span class="spacer"></span>' +
      (u.isAdmin ? '<span class="meta">owner</span>' :
        '<button class="mini secondary" data-scopes="' + esc(u.id) + '">Per-library</button>' +
        '<button class="mini secondary" data-pw="' + esc(u.id) + '">Reset password</button>' +
        '<button class="mini danger" data-del-user="' + esc(u.id) + '">Delete</button>') +
      '</div>';
    var permsRow = '<div class="perms">' + (perms || '<span class="empty">Loading permissions…</span>') + '</div>';
    var scopes = u.isAdmin ? '' : '<div class="scopes" id="scopes-' + esc(u.id) + '" hidden>' + scopeMatrix(u) + '</div>';
    return '<div class="user" data-user="' + esc(u.id) + '">' + top + permsRow + scopes + '</div>';
  }
  function scopeMatrix(u) {
    var libs = permCatalog.libraries || [];
    var scopable = (permCatalog.permissions || []).filter(function (c) { return c.scopable; });
    if (!libs.length) return '<div class="empty">Add a library to grant per-library access.</div>';
    var held = u.permissions || [];
    var head = '<tr><th>Library</th>' + scopable.map(function (c) { return '<th>' + esc(c.label) + '</th>'; }).join('') + '</tr>';
    var rows = libs.map(function (l) {
      var cells = scopable.map(function (c) {
        var key = c.key + ':' + l.id;
        var on = held.indexOf(key) >= 0 ? ' checked' : '';
        return '<td><input type="checkbox" data-uid="' + esc(u.id) + '" data-perm="' + esc(key) + '"' + on + '></td>';
      }).join('');
      return '<tr><td>' + esc(l.title) + '</td>' + cells + '</tr>';
    }).join('');
    return '<p class="hint" style="margin-top:0;">Grant a permission for one library only. A global tick above already covers every library.</p><table>' + head + rows + '</table>';
  }
  function savePermsFor(uid) {
    var boxes = document.querySelectorAll('.user[data-user="' + uid + '"] input[data-uid="' + uid + '"]');
    var perms = [];
    Array.prototype.forEach.call(boxes, function (b) { if (b.checked && !b.disabled) perms.push(b.getAttribute('data-perm')); });
    api('/v1/admin/users/' + uid + '/permissions', 'PUT', { permissions: perms }).then(function (res) { if (res.status === 401) logout(); });
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
    var del = e.target.getAttribute('data-del-user');
    if (del) { if (confirm('Delete this user?')) api('/v1/admin/users/' + del, 'DELETE').then(function () { loadUsers(); }); return; }
    var sc = e.target.getAttribute('data-scopes');
    if (sc) { var box = $('#scopes-' + sc); if (box) box.hidden = !box.hidden; return; }
    var pw = e.target.getAttribute('data-pw');
    if (pw) {
      var np = prompt('New password for this user:');
      if (np) api('/v1/admin/users/' + pw + '/password', 'PUT', { newPassword: np }).then(function (res) { alert(res.ok ? 'Password reset. The user must sign in again on their devices.' : 'Could not reset password.'); });
    }
  };
  $('#user-list').onchange = function (e) {
    var uid = e.target.getAttribute && e.target.getAttribute('data-uid');
    if (uid) savePermsFor(uid);
  };

  // ---- items: admin metadata correction ----
  var LOCKABLE = ['title', 'overview', 'year', 'runtime', 'communityRating', 'officialRating', 'genres', 'images'];
  var itNav = []; // breadcrumb stack of {id, title}
  var itEditing = null;
  var itOriginal = {};  // loaded field values, so Save only locks what changed
  function enterItems() { refreshLibPickers(); }
  var EMPTY_ITEMS = '<div class="empty">Search, tick <strong>Needs metadata</strong>, or pick a library to begin.</div>';
  $('#it-lib').onchange = function () {
    itNav = []; closeEditor();
    var id = $('#it-lib').value;
    if (id) { $('#it-search').value = ''; $('#it-needs').checked = false; itNav.push({ id: id, title: $('#it-lib').selectedOptions[0].textContent }); loadItemList(); }
    else { $('#it-list').innerHTML = EMPTY_ITEMS; $('#it-crumbs').innerHTML = ''; }
  };
  // Catalog-wide search + "needs metadata" filter (no library drill-down needed).
  var itSearchT = null;
  function runItemSearch() {
    var term = $('#it-search').value.trim();
    var needs = $('#it-needs').checked;
    if (!term && !needs) { itNav = []; $('#it-crumbs').innerHTML = ''; $('#it-list').innerHTML = EMPTY_ITEMS; return; }
    itNav = []; closeEditor(); $('#it-lib').value = '';
    var qs = '/v1/admin/items?limit=500';
    if (term) qs += '&search=' + encodeURIComponent(term);
    if (needs) qs += '&needsAttention=true';
    $('#it-crumbs').innerHTML = '<span class="meta">' + (needs ? 'Items needing metadata' : 'Search results') + (term ? ' for “' + esc(term) + '”' : '') + '</span>';
    api(qs, 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = d.items || [];
      $('#it-list').innerHTML = items.length ? items.map(itemRow).join('') : '<div class="empty">No matching titles.</div>';
    });
  }
  $('#it-search').oninput = function () { clearTimeout(itSearchT); itSearchT = setTimeout(runItemSearch, 250); };
  $('#it-needs').onchange = runItemSearch;
  // Renders the raw, ungrouped catalog hierarchy (a 1-to-1 view of the indexed
  // source tree) — collections are openable folders, movies appear individually.
  function itemRow(it) {
    var isTV = it.type === 'series' || it.type === 'episode' || it.type === 'season';
    var container = it.type === 'collection' || it.type === 'series' || it.type === 'season' || (it.childCount && it.childCount > 0);
    var poster = (it.images && it.images.primary)
      ? '<img class="it-thumb" loading="lazy" src="' + esc(it.images.primary) + '" alt="">'
      : '<span class="it-thumb">' + (container ? '📁' : '🎞️') + '</span>';
    var open = container ? '<button class="mini secondary" data-open="' + esc(it.id) + '" data-title="' + esc(it.title) + '">Open</button>' : '';
    var sub = it.childCount ? (it.childCount + ' inside') : (it.year ? String(it.year) : '');
    return '<div class="item"><span class="it-row">' + poster +
      '<span><span class="chip ' + (isTV ? 'tv' : 'movie') + '">' + esc(it.type || 'item') + '</span> ' + esc(it.title) +
      (sub ? ' <span class="meta">' + esc(sub) + '</span>' : '') + '</span></span>' +
      '<span class="acts">' + open + '<button class="mini" data-fix="' + esc(it.id) + '">Fix</button></span></div>';
  }
  function loadItemList() {
    var top = itNav[itNav.length - 1];
    if (!top) return;
    var up = itNav.length > 1 ? '<a data-up="1">⬆ Up</a> · ' : '';
    $('#it-crumbs').innerHTML = up + itNav.map(function (n, i) { return '<a data-crumb="' + i + '">' + esc(n.title) + '</a>'; }).join(' › ');
    api('/v1/admin/items?parent=' + encodeURIComponent(top.id) + '&limit=500', 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = d.items || [];
      $('#it-list').innerHTML = items.length ? items.map(itemRow).join('') : '<div class="empty">Nothing here.</div>';
    });
  }
  $('#it-crumbs').onclick = function (e) {
    if (e.target.getAttribute('data-up') != null) { if (itNav.length > 1) { itNav.pop(); closeEditor(); loadItemList(); } return; }
    var i = e.target.getAttribute('data-crumb'); if (i == null) return;
    itNav = itNav.slice(0, Number(i) + 1); closeEditor(); loadItemList();
  };
  $('#it-list').onclick = function (e) {
    var open = e.target.getAttribute('data-open');
    if (open) { itNav.push({ id: open, title: e.target.getAttribute('data-title') }); closeEditor(); loadItemList(); return; }
    var fix = e.target.getAttribute('data-fix'); if (fix) openEditor(fix);
  };
  function setLockBadges(locked) {
    LOCKABLE.forEach(function (f) {
      var el = document.querySelector('.lockbadge[data-lb="' + f + '"]');
      if (el) el.textContent = locked.indexOf(f) >= 0 ? '🔒 locked' : '';
    });
  }
  function openEditor(id) {
    msg('it-msg', '');
    api('/v1/admin/items/' + id, 'GET').then(function (res) { return res.ok ? res.json() : null; }).then(function (r) {
      if (!r) { msg('it-msg', 'Could not load item.'); return; }
      itEditing = id;
      var it = r.item;
      $('#it-editor').hidden = false;
      $('#it-ed-title').textContent = it.title || id;
      $('#it-f-title').value = it.title || '';
      $('#it-f-overview').value = it.overview || '';
      $('#it-f-year').value = it.year || '';
      $('#it-f-runtime').value = it.runtime ? Math.round(it.runtime / 60) : '';
      $('#it-f-rating').value = it.communityRating != null ? it.communityRating : '';
      $('#it-f-official').value = it.officialRating || '';
      $('#it-f-genres').value = (it.genres || []).join(', ');
      $('#it-f-primary').value = (it.images && it.images.primary) || '';
      $('#it-f-backdrop').value = (it.images && it.images.backdrop) || '';
      $('#it-f-tmdb').value = ''; $('#it-f-tmdb-type').value = '';
      // Re-map controls: library options, type/parent reset to "keep", TV position prefilled.
      $('#it-f-library').innerHTML = '<option value="">(keep)</option>' + libraries.map(function (l) { return '<option value="' + esc(l.id) + '">' + esc(l.title) + '</option>'; }).join('');
      $('#it-f-library').value = ''; $('#it-f-type').value = '';
      $('#it-f-season').value = (it.seasonIndex != null ? it.seasonIndex : '');
      $('#it-f-episode').value = (it.episodeIndex != null ? it.episodeIndex : '');
      $('#it-parent-search').value = ''; $('#it-parent-pick').innerHTML = '<option value="">(keep current parent)</option>';
      // Snapshot current field strings so Save only writes/locks what changed.
      itOriginal = {
        title: $('#it-f-title').value, overview: $('#it-f-overview').value,
        year: $('#it-f-year').value, runtime: $('#it-f-runtime').value,
        rating: $('#it-f-rating').value, official: $('#it-f-official').value,
        genres: $('#it-f-genres').value, primary: $('#it-f-primary').value, backdrop: $('#it-f-backdrop').value,
        season: $('#it-f-season').value, episode: $('#it-f-episode').value
      };
      setLockBadges(r.lockedFields || []);
      $('#it-editor').scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });
  }
  function closeEditor() { $('#it-editor').hidden = true; itEditing = null; }
  function saveItem() {
    if (!itEditing) return;
    // Only send fields the admin actually changed, so Save locks exactly those.
    var body = {};
    var o = itOriginal;
    if ($('#it-f-title').value !== o.title) body.title = $('#it-f-title').value;
    if ($('#it-f-overview').value !== o.overview) body.overview = $('#it-f-overview').value;
    if ($('#it-f-year').value !== o.year) { var y = $('#it-f-year').value; if (y !== '') body.year = Number(y); }
    if ($('#it-f-runtime').value !== o.runtime) { var rt = $('#it-f-runtime').value; if (rt !== '') body.runtime = Math.round(Number(rt) * 60); }
    if ($('#it-f-rating').value !== o.rating) { var cr = $('#it-f-rating').value; if (cr !== '') body.communityRating = Number(cr); }
    if ($('#it-f-official').value !== o.official) body.officialRating = $('#it-f-official').value;
    if ($('#it-f-genres').value !== o.genres) { var g = $('#it-f-genres').value.trim(); if (g) body.genres = g.split(',').map(function (x) { return x.trim(); }).filter(Boolean); }
    if ($('#it-f-primary').value !== o.primary || $('#it-f-backdrop').value !== o.backdrop) {
      body.images = { primary: $('#it-f-primary').value || null, backdrop: $('#it-f-backdrop').value || null };
    }
    if (!Object.keys(body).length) { msg('it-msg', 'No changes to save.'); return; }
    msg('it-msg', 'Saving…');
    api('/v1/admin/items/' + itEditing, 'PATCH', body).then(function (res) { return res.ok ? res.json() : null; }).then(function (r) {
      if (!r) { msg('it-msg', 'Save failed.'); return; }
      msg('it-msg', 'Saved and locked the edited fields.', true);
      itOriginal.title = $('#it-f-title').value; itOriginal.overview = $('#it-f-overview').value;
      itOriginal.year = $('#it-f-year').value; itOriginal.runtime = $('#it-f-runtime').value;
      itOriginal.rating = $('#it-f-rating').value; itOriginal.official = $('#it-f-official').value;
      itOriginal.genres = $('#it-f-genres').value; itOriginal.primary = $('#it-f-primary').value; itOriginal.backdrop = $('#it-f-backdrop').value;
      setLockBadges(r.lockedFields || []); loadItemList(); loadOverview();
    }).catch(function () { msg('it-msg', 'Could not reach the server.'); });
  }
  function unlockItem() {
    if (!itEditing) return;
    api('/v1/admin/items/' + itEditing, 'PATCH', { unlockAll: true }).then(function (res) { return res.ok ? res.json() : null; }).then(function (r) {
      if (r) { setLockBadges([]); msg('it-msg', 'Unlocked. A refresh can repopulate these fields.', true); }
    });
  }
  function enrichItem() {
    if (!itEditing) return;
    msg('it-msg', 'Re-enriching…');
    api('/v1/admin/items/' + itEditing + '/enrich', 'POST').then(function (res) {
      if (!res.ok) { msg('it-msg', res.status === 400 ? 'Enrichment needs a TMDB key (Settings).' : 'Enrich failed.'); return; }
      msg('it-msg', 'Re-enriched.', true); openEditor(itEditing); loadOverview();
    }).catch(function () { msg('it-msg', 'Could not reach the server.'); });
  }
  function identifyItem() {
    if (!itEditing) return;
    var tmdb = $('#it-f-tmdb').value.trim();
    if (!tmdb) { msg('it-msg', 'Enter a TMDB id.'); return; }
    var body = { tmdbId: tmdb };
    var t = $('#it-f-tmdb-type').value; if (t) body.type = t;
    msg('it-msg', 'Re-identifying…');
    api('/v1/admin/items/' + itEditing + '/identity', 'POST', body).then(function (res) {
      if (!res.ok) { msg('it-msg', res.status === 400 ? 'Re-identify needs a TMDB key (Settings).' : 'Re-identify failed.'); return; }
      msg('it-msg', 'Re-identified and enriched.', true); openEditor(itEditing); loadItemList(); loadOverview();
    }).catch(function () { msg('it-msg', 'Could not reach the server.'); });
  }
  function findParents() {
    var q = $('#it-parent-search').value.trim();
    if (!q) { msg('it-msg', 'Type a series or season name to search.'); return; }
    msg('it-msg', 'Searching…');
    api('/v1/admin/items?search=' + encodeURIComponent(q), 'GET').then(function (res) { return res.ok ? res.json() : { items: [] }; }).then(function (d) {
      var items = (d.items || []).filter(function (x) { return x.type === 'series' || x.type === 'season'; });
      $('#it-parent-pick').innerHTML = '<option value="">(keep current parent)</option>' + items.map(function (x) {
        var lbl = x.title + ' · ' + x.type + (x.seasonIndex != null ? ' ' + x.seasonIndex : '');
        return '<option value="' + esc(x.id) + '">' + esc(lbl) + '</option>';
      }).join('');
      msg('it-msg', items.length ? 'Pick a parent below, then Apply re-map.' : 'No series or seasons match.', items.length > 0);
    }).catch(function () { msg('it-msg', 'Search failed.'); });
  }
  function remapItem() {
    if (!itEditing) return;
    var body = {};
    var ty = $('#it-f-type').value; if (ty) body.type = ty;
    var lib = $('#it-f-library').value; if (lib) body.libraryId = lib;
    var par = $('#it-parent-pick').value; if (par) body.parentId = par;
    if ($('#it-f-season').value !== itOriginal.season) { var sv = $('#it-f-season').value; if (sv !== '') body.seasonIndex = Number(sv); }
    if ($('#it-f-episode').value !== itOriginal.episode) { var ev = $('#it-f-episode').value; if (ev !== '') body.episodeIndex = Number(ev); }
    if (!Object.keys(body).length) { msg('it-msg', 'Nothing to re-map.'); return; }
    msg('it-msg', 'Applying…');
    api('/v1/admin/items/' + itEditing, 'PATCH', body).then(function (res) {
      if (res.status === 401) { logout(); return; }
      if (!res.ok) { res.json().then(function (e) { msg('it-msg', (e && e.error && e.error.message) || 'Re-map failed.'); }).catch(function () { msg('it-msg', 'Re-map failed.'); }); return; }
      msg('it-msg', 'Re-mapped.', true); openEditor(itEditing); loadItemList(); loadOverview();
    }).catch(function () { msg('it-msg', 'Could not reach the server.'); });
  }
  $('#it-save-btn').onclick = saveItem;
  $('#it-unlock-btn').onclick = unlockItem;
  $('#it-enrich-btn').onclick = enrichItem;
  $('#it-identify-btn').onclick = identifyItem;
  $('#it-parent-find').onclick = findParents;
  $('#it-remap-btn').onclick = remapItem;
  $('#it-close-btn').onclick = closeEditor;

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
  function openTable(name) { dbState.table = name; dbState.offset = 0; $('#db-search-tmdb').value = ''; $('#db-search-name').value = ''; loadDbRows(); Array.prototype.forEach.call(document.querySelectorAll('#db-tables .tab'), function (b) { b.classList.toggle('active', b.dataset.table === name); }); }
  function loadDbRows() {
    if (!dbState.table) return;
    var tmdb = ($('#db-search-tmdb').value || '').trim();
    var name = ($('#db-search-name').value || '').trim();
    var q = '/v1/admin/db/query?table=' + encodeURIComponent(dbState.table) + '&limit=' + dbState.limit + '&offset=' + dbState.offset
      + (tmdb ? '&tmdbId=' + encodeURIComponent(tmdb) : '')
      + (name ? '&name=' + encodeURIComponent(name) : '');
    api(q, 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      dbState.total = d.total; $('#db-view').hidden = false; $('#db-title').textContent = d.table;
      $('#db-count').textContent = d.total + ' rows' + (d.redactedColumns.length ? ' · ' + d.redactedColumns.length + ' redacted' : '');
      $('#db-head').innerHTML = '<tr>' + d.columns.map(function (c) { return '<th>' + esc(c) + (d.redactedColumns.indexOf(c) >= 0 ? ' 🔒' : '') + '</th>'; }).join('') + '</tr>';
      $('#db-body').innerHTML = d.rows.length ? d.rows.map(function (r) { return '<tr>' + r.map(function (v) { return v === null ? '<td class="null">null</td>' : '<td title="' + esc(v) + '">' + esc(v) + '</td>'; }).join('') + '</tr>'; }).join('') : '<tr><td class="null">no rows</td></tr>';
      var from = d.total ? d.offset + 1 : 0, to = Math.min(d.offset + d.limit, d.total);
      $('#db-range').textContent = from + '–' + to + ' of ' + d.total;
      $('#db-prev').disabled = d.offset <= 0; $('#db-next').disabled = to >= d.total;
    });
  }
  $('#db-tables').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.table) openTable(b.dataset.table); };
  $('#db-prev').onclick = function () { dbState.offset = Math.max(0, dbState.offset - dbState.limit); loadDbRows(); };
  $('#db-next').onclick = function () { if (dbState.offset + dbState.limit < dbState.total) { dbState.offset += dbState.limit; loadDbRows(); } };
  $('#db-refresh').onclick = function () { loadDbTables(); };
  var dbSearch = function () { dbState.offset = 0; loadDbRows(); };
  $('#db-search-tmdb').addEventListener('input', dbSearch);
  $('#db-search-name').addEventListener('input', dbSearch);
  $('#db-search-clear').onclick = function () { $('#db-search-tmdb').value = ''; $('#db-search-name').value = ''; dbSearch(); };

  // ---- diagnostics: logs ----
  var logState = { after: 0, paused: false };
  function loadLogs() {
    if (logState.paused) return;
    var lvl = $('#log-level').value;
    var q = '/v1/admin/logs?limit=300' + (logState.after ? '&after=' + logState.after : '') + (lvl ? '&level=' + lvl : '');
    api(q, 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      var box = $('#log-box'); var atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 40;
      if (d.lines.length) {
        var empty = box.querySelector('.empty'); if (empty) box.innerHTML = '';
        d.lines.forEach(function (l) {
          if (l.seq > logState.after) logState.after = l.seq;
          var div = document.createElement('div'); div.className = 'logline';
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

  // ---- extensions host ----
  var extState = { active: null };
  function enterExtensions() {
    api('/v1/admin/extensions', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (d) {
      if (!d) return;
      $('#ext-nav').innerHTML = (d.extensions || []).map(function (x) {
        var tags = '';
        if (x.kind === 'optional' && !x.enabled) tags += ' <span class="meta">off</span>';
        if (!x.available) tags += ' <span class="meta">unavailable</span>';
        return '<button class="tab' + (extState.active === x.id ? ' active' : '') + '" data-mod="' + esc(x.id) + '" title="' + esc(x.description) + '">' + esc(x.name) + tags + '</button>';
      }).join('') || '<div class="empty">No extensions.</div>';
      var first = extState.active || ((d.extensions && d.extensions[0]) ? d.extensions[0].id : null);
      if (first) activateModule(first);
    });
  }
  function activateModule(id) {
    if (!id) return;
    extState.active = id; stopPoll();
    Array.prototype.forEach.call(document.querySelectorAll('#ext-nav .tab'), function (b) { b.classList.toggle('active', b.dataset.mod === id); });
    document.querySelectorAll('.ext-mod').forEach(function (m) { m.hidden = (m.id !== 'mod-' + id); });
    if (id === 'diagnostics') showSub(diagState.sub);
    else if (id === 'media-probe') loadProbeConfig();
  }
  $('#ext-nav').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.mod) activateModule(b.dataset.mod); };

  var diagState = { sub: 'database' };
  function showSub(name) {
    diagState.sub = name; stopPoll();
    Array.prototype.forEach.call(document.querySelectorAll('#diag-subtabs .subtab'), function (b) { b.classList.toggle('active', b.dataset.sub === name); });
    ['database', 'logs'].forEach(function (n) { $('#sub-' + n).hidden = (n !== name); });
    if (name === 'logs') { logState.after = 0; $('#log-box').innerHTML = ''; startPoll(loadLogs, 2000); }
    else if (name === 'database') loadDbTables();
  }
  $('#diag-subtabs').onclick = function (e) { var b = e.target.closest('button'); if (b && b.dataset.sub) showSub(b.dataset.sub); };

  // ---- module: media probe ----
  function loadProbeConfig() {
    api('/v1/admin/extensions/media-probe', 'GET').then(function (res) { if (res.status === 401) { logout(); return null; } return res.ok ? res.json() : null; }).then(function (c) {
      if (!c) return;
      $('#mp-enabled').checked = c.enabled; $('#mp-path').value = c.ffprobePath || '';
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
    var subs = p.externalSubtitles.length ? '<div class="group-title">External subtitles</div>' + p.externalSubtitles.map(function (x) { return '<div class="item"><span>' + esc(x.url) + '</span><span class="meta">' + esc(x.language || '') + ' · ' + esc(x.format) + '</span></div>'; }).join('') : '';
    var chapters = (p.chapters && p.chapters.length) ? '<div class="group-title">Chapters</div>' + p.chapters.map(function (c) { return '<div class="item"><span>' + esc(c.title || 'Chapter') + '</span><span class="meta">' + Math.round(c.start) + 's</span></div>'; }).join('') : '';
    $('#mp-result').innerHTML =
      '<div class="toolbar" style="margin-top:14px;"><strong>' + p.streams.length + ' streams</strong><span class="meta">' + esc(p.prober) + (p.durationSeconds ? ' · ' + Math.round(p.durationSeconds) + 's' : '') + (p.chapters && p.chapters.length ? ' · ' + p.chapters.length + ' chapters' : '') + '</span></div>' +
      '<div class="tablebox"><table class="db"><thead><tr><th>#</th><th>kind</th><th>codec</th><th>lang</th><th>title</th><th></th></tr></thead><tbody>' + (rows || '<tr><td class="null">no streams</td></tr>') + '</tbody></table></div>' + subs + chapters;
  }

  $('#login-btn').onclick = login;
  $('#logout-btn').onclick = logout;
  $('#save-btn').onclick = saveSettings;
  $('#scan-all-btn').onclick = scanAllSources;
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
