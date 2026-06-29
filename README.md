<div align="center">

# Sphynx

**The catalog brain for your movie & TV collection — every poster, every season, every screen.**

**[The complete guide →](https://reckloon.github.io/Sphynx-Media/)** &nbsp;·&nbsp; [Every API endpoint](docs/API.md) &nbsp;·&nbsp; [Changelog](CHANGELOG.md)

</div>

---

## What is Sphynx?

Sphynx keeps the **catalog** of your movies and shows — the posters, descriptions,
seasons, who's-watched-what, where you paused — and tells your player app
*where each video actually lives*. Your player then streams that file **directly
from wherever it sits** (a NAS, a cloud bucket, a web URL, a debrid service). The
video never detours through Sphynx, so there's no transcoding, no beefy CPU, no
heat. It happily runs on a Raspberry Pi or a $5 VPS.

What you get out of the box:

- **Gorgeous libraries, automatically.** Point it at your files, press **Scan**,
  and TMDB fills in posters, cast, episode art, and descriptions — for movies, TV,
  box sets, and extras.
- **A best-in-class identifier.** Sphynx reads the *whole folder path* to get
  titles, years, and season/episode numbers right — in any language, through the
  messiest scene-release naming. It's stress-tested against **500,000** generated
  paths with **zero** misidentifications. [See the proof →](docs/PARSER.md)
- **Passwordless sign-in with passkeys.** Face ID, Touch ID, Windows Hello, or a
  hardware key. No password to type, none to leak.
- **Sign in a TV by scanning a QR code** and approving on your phone — the same
  "scan, Face ID, done" flow you wish everything had.
- **Plug into anything.** Local disk, HTTP/CDN, **SMB**, **WebDAV**, **FTP**, or
  **TorBox** debrid — mix as many sources as you like onto one shelf.
- **Real accounts for real households.** Per-person watch history and resume,
  plus fine-grained permissions you can scope to a single library.
- **Featherweight & private.** No transcoding, no phone-home, no cloud account.
  100% open source (MIT).
- **An open standard.** Any player can speak to it. Today there's a polished
  Apple client called **Ocelot**; tomorrow, anything.

Everything below is done in a **web panel** — no config files, no JSON, no terminal
beyond starting the container.

---

## How Sphynx compares to Plex & Jellyfin

Be honest with yourself first: **Sphynx is only the "librarian" half of a media
server.** It deliberately does *not* transcode video or stream the bytes itself —
that's the "delivery truck" job Plex and Jellyfin also do. So some rows below are a
flat ❌ for Sphynx *on purpose*. In exchange, it's tiny, private, and never becomes
the bottleneck between your files and your TV.

✅ = yes &nbsp;·&nbsp; ⚠️ = partial / with caveats &nbsp;·&nbsp; ❌ = no

### Architecture & footprint

| Capability | Sphynx | Jellyfin | Plex |
|---|:---:|:---:|:---:|
| Transcodes / re-encodes video on the fly | ❌ *by design* | ✅ | ✅ |
| Hardware-accelerated transcoding | ❌ | ✅ free | ⚠️ Plex Pass |
| Streams the video itself | ❌ *player streams direct from source* | ✅ | ✅ |
| Video never passes through the server (no double bandwidth) | ✅ | ❌ | ❌ |
| Runs comfortably on a Pi / $5 VPS | ✅ *always* | ⚠️ only without transcoding | ⚠️ only without transcoding |

### Library & metadata

| Capability | Sphynx | Jellyfin | Plex |
|---|:---:|:---:|:---:|
| Auto posters, cast & overviews (TMDB) | ✅ | ✅ | ✅ |
| Movies, TV (series / season / episode) | ✅ | ✅ | ✅ |
| Collections / box sets | ✅ | ✅ | ✅ |
| Extras (trailers, featurettes) nested under a title | ✅ | ✅ | ✅ |
| Multiple versions/editions of one title (4K + 1080p, Director's Cut) | ✅ | ✅ | ✅ |
| Hand-fix metadata with per-field locks | ✅ | ✅ | ✅ |
| Audio/subtitle track & chapter inspection (ffprobe) | ✅ | ✅ | ✅ |
| Skip-intro / skip-credits markers | ✅ *contributed* | ⚠️ plugin | ⚠️ Plex Pass |
| Music library | ❌ ¹ | ✅ | ✅ |
| Photos | ❌ | ✅ | ✅ |
| Live TV / DVR | ❌ | ✅ | ✅ |

### Accounts & security

| Capability | Sphynx | Jellyfin | Plex |
|---|:---:|:---:|:---:|
| Multiple user accounts | ✅ | ✅ | ✅ |
| Per-library permissions | ✅ | ✅ | ✅ |
| **Passkeys** (Face ID / Touch ID / hardware key) | ✅ | ❌ | ❌ |
| QR / code sign-in for TVs | ✅ | ✅ *Quick Connect* | ✅ *PIN link* |
| Works with **no third-party account** | ✅ | ✅ | ❌ *requires plex.tv* |
| No phone-home / cloud dependency | ✅ | ✅ | ❌ |

### Storage, apps & openness

| Capability | Sphynx | Jellyfin | Plex |
|---|:---:|:---:|:---:|
| Pull straight from cloud / HTTP / CDN URLs | ✅ | ⚠️ needs a mount | ⚠️ needs a mount |
| NAS via SMB / WebDAV / FTP | ✅ *built in* | ⚠️ OS mount | ⚠️ OS mount |
| Debrid (TorBox) built in | ✅ | ❌ | ❌ |
| Open, documented protocol anyone can build on | ✅ | ⚠️ open API, no spec | ❌ proprietary |
| First-party apps on every platform | ❌ *Ocelot (Apple) today* | ✅ | ✅ |
| Offline downloads / sync to device | ❌ | ✅ | ⚠️ Plex Pass |
| Watch-together | ⚠️ *protocol path; client-led* | ✅ SyncPlay | ⚠️ Plex Pass |
| Fully open source | ✅ MIT | ✅ GPL | ❌ |
| 100% free, no paywalled features | ✅ | ✅ | ⚠️ Plex Pass |

<sub>¹ Sphynx's **protocol** fully models music & audiobooks; the reference server
just doesn't enrich audio (TMDB is film/TV only). Another Sphynx-compatible server
could. &nbsp; Comparison reflects Plex/Jellyfin as of 2026; "passkeys" means native
WebAuthn support.</sub>

**The honest catch:** Sphynx does **not** convert video. If a file won't play on
your device as-is, Sphynx can't fix it — that's the player's job. This is for people
whose files are already in a player-friendly format at a reachable location. If you
need on-the-fly transcoding for an old TV, a traditional Plex/Jellyfin setup is the
better fit.

---

## Set it up in 2 minutes (Docker)

You need **Docker** (Docker Desktop on Mac/Windows, or Docker Engine on Linux) and
a couple of minutes. That's it. *No Docker? You can run from source with a Swift 6
toolchain — see [`sphynx-server/README.md`](sphynx-server/README.md).*

### 1. Make a folder, drop in one file

Create an empty folder, and save this as `docker-compose.yml` inside it. Change the
**one** value marked `<--` and you're done:

```yaml
services:
  sphynx:
    # The official pre-built image — downloads in seconds, no compiling.
    image: ghcr.io/reckloon/sphynx-server:latest
    ports:
      - "9410:9410"            # reach the server at http://localhost:9410
    environment:
      SPHYNX_ADMIN_PASSWORD: "change-this-please"   # <-- PICK YOUR OWN PASSWORD
      # Keep the catalog on the saved volume below so it survives updates.
      SPHYNX_DB_PATH: "/data/sphynx.sqlite"
    volumes:
      - sphynx-data:/data      # your catalog + logins live here, across updates
    restart: unless-stopped    # comes back on its own after a crash or reboot

volumes:
  sphynx-data:
```

That is the **entire** minimum configuration. Everything else has a sensible default
and is changed later from the web panel — not by editing this file.

> **About the password:** leave `SPHYNX_ADMIN_PASSWORD` out entirely and the server
> generates a strong random one and **prints it once** to the startup log. Setting
> your own is simpler the first time.

### 2. Start it

From inside that folder:

```sh
docker compose up -d
```

It pulls the image and starts in the background. The image is built for both
**Intel/AMD (amd64)** and **ARM (arm64)**, so the same command works on a NAS, a
VPS, a Raspberry Pi, or an Apple Silicon Mac.

> **Updating later** is the same two-step, any time:
> ```sh
> docker compose pull && docker compose up -d
> ```
> Your catalog and logins are in the `sphynx-data` volume, so they survive untouched,
> and the server applies any database upgrades itself on boot.

### 3. Open the control panel

Go to **http://localhost:9410/admin** and sign in as `admin` with the password you
set. If the panel loads, **you have a working Sphynx server.**

> Prefer the terminal? `curl http://localhost:9410/v1/info` returns your server's
> name as JSON — same confirmation, no browser.

### Optional settings (only if you want them)

You almost never need these — but here's the full menu. Add any to the `environment:`
block. Anything marked *(GUI)* only **seeds** a starting value; after first boot you
change it in **Settings**, not here.

| Setting | Default | What it does |
|---|---|---|
| `SPHYNX_TMDB_API_KEY` | *(empty)* | Free [TMDB key](https://www.themoviedb.org/settings/api) for posters, plots, cast. Blank = plain titles. *(GUI)* |
| `SPHYNX_SERVER_NAME` | `Sphynx Reference Server` | The name your player shows. *(GUI)* |
| `SPHYNX_PORT` | `9410` | Port the server listens on. |
| `SPHYNX_ADMIN_USERNAME` | `admin` | Admin login name (first boot only). |
| `SPHYNX_METADATA_LANGUAGE` | `en-US` | Language for fetched titles/overviews (e.g. `fr-FR`, `de-DE`). *(GUI)* |
| `SPHYNX_PASSKEY_RP_ID` | *(empty)* | Your domain (e.g. `media.example.com`) — **required to turn on passkeys & QR TV sign-in over the internet.** See [Passkeys](#passwordless-sign-in-with-passkeys). *(GUI)* |

The complete list with every tunable lives in
[`sphynx-server/README.md`](sphynx-server/README.md).

---

## Build your first library (all clicking, no typing)

The catalog starts empty. Here's how to fill it — three short steps in the
**/admin** panel.

### Step 1 — Turn on the shelves you want

Open the **Libraries** tab and switch on the shelves your media needs:

- **Movies**
- **TV Shows**
- **Collections** (box sets — Sphynx groups a series of related movies here)

On the Movies shelf you'll see **Group collections at `[N]` movies** — once a box
set has at least that many of its films, Sphynx collapses them into one collection
tile instead of loose movies. Leave it at the default to start. (The same minimum
applies to any library, including hand-made collections of TV series.)

You can also build collections **by hand** on the **Collections** tab — handy for
series box sets (TMDB only auto-groups movies). Name a collection, then add any
movies or series from that library; it follows the same minimum-members rule above.

### Step 2 — Tell it where your files live (add a Storage source)

Still on the **Libraries** tab, scroll to **Storage sources** and pick the driver
that matches where your media sits. Every form has the same two extras at the
bottom: **Scan this source for** (tick *Movies*, *TV Shows*, or both) and
**Auto-refresh every (minutes, 0 = manual)**. Fill the rest in, then **Add source**.

Pick your driver:

<details open>
<summary><b>Local</b> — a folder on the server's own disk</summary>

- **Name** — any label you'll recognize ("My disk").
- **Folder path on the server** — e.g. `/srv/media`.

Good for testing. ⚠️ Sphynx hands players a `file://` path, which only works for a
player on the *same machine*. To serve a local folder to phones and TVs, put an
SMB/WebDAV/HTTP server in front of it and use that driver instead. (Exception:
`.strm` files — text files containing a URL — stream fine to any device.)
</details>

<details>
<summary><b>HTTP</b> — media at web URLs / a CDN</summary>

- **Name** — a label.
- **Base media URL** *(optional)* — prefix for relative entries, e.g. `https://cdn.example`.
- **Manifest URL (JSON listing)** *(optional)* — a small JSON file listing your
  titles (Sphynx reads the *list*, never the videos). The
  [guide's walkthrough](https://reckloon.github.io/Sphynx-Media/#firstlibrary) shows
  exactly what one looks like.
- **Authorization header** *(optional)* — e.g. `Bearer …` if your host needs auth.
</details>

<details>
<summary><b>WebDAV</b> — Nextcloud and other WebDAV servers</summary>

- **Name** — a label.
- **WebDAV URL** — e.g. `https://nas.example/remote.php/dav/files/me/Media`.
- **Username** / **Password** *(optional)* — or leave the username blank and put a
  bearer token in the password field.
</details>

<details>
<summary><b>SMB</b> — Windows shares / Samba on your NAS</summary>

- **Name** — a label.
- **Server / host** — e.g. `nas.local`.
- **Share name** — e.g. `media`.
- **Username** / **Password** *(optional)*.

*Listing needs `smbclient` available to the server; playback doesn't.*
</details>

<details>
<summary><b>FTP</b> — an FTP server</summary>

- **Name** — a label.
- **Server / host** — e.g. `ftp.example`.
- **Port** *(optional, default 21)*.
- **Username** / **Password** *(optional)*.

*Listing needs `curl` available to the server; playback doesn't.*
</details>

<details>
<summary><b>TorBox</b> — stream your TorBox debrid cloud</summary>

- **Name** — a label.
- **API key** — from [torbox.app/settings](https://torbox.app/settings).
- **Categories** *(optional)* — any of `torrents`, `usenet`, `webdl` (blank = all).
- **Link freshness seconds** *(optional — best left blank)*.

No `.strm` files or mounts — Sphynx resolves a fresh stream at play time.
</details>

> **Mix freely.** Add as many sources as you like to the same shelf — an HTTP source
> and an SMB source can both feed "Movies." One source can also feed Movies *and* TV
> at once; Sphynx sorts them apart automatically.

### Step 3 — Press Scan

Find your source under **Storage sources** and click **Scan** (or **Scan all now**
at the top). Sphynx walks everything, files each title onto the right shelf, and — if
you added a TMDB key — fetches posters, descriptions, cast, and episode art.

Watch the **Activity** panel at the top count it up live: **In source** → **In
database** → **Enriched**, with a per-library and per-category **Breakdown**. (Extras
like trailers index but never "enrich" — that's expected, TMDB has no data for them.)

When the scan finishes, **your library is live.** There's nothing left to configure
to start watching.

---

## Make accounts for your household

Don't hand everyone the `admin` login — admins can change server settings. Instead,
open the **Users** tab → **Add a user** (a username and password). New accounts get
**Browse & play** by default: they can watch everything and get their own Continue
Watching and history, but can't touch the server's guts.

### Permissions, in plain English

Each non-admin user has a permission editor. Tick what they get; for the scopable
ones, click **Per-library** to grant it on just one shelf:

| Permission | Lets them… |
|---|---|
| **Browse & play** | See libraries and play their items. |
| **Edit metadata** | Fix titles, lock fields, re-identify/re-enrich (great for a trusted helper). |
| **Scan / refresh** | Re-index a library without bugging you. |
| **Contribute markers** | Add "skip intro" markers (when the server allows it). |

Each user also gets their own **http://localhost:9410/user** page (below).

---

## Passwordless sign-in with passkeys

Passkeys let people sign in with **Face ID, Touch ID, Windows Hello, or a hardware
key** — no password. They're **off until you tell Sphynx your domain**, because the
browser's security model ties a passkey to the exact web address people use.

**Turn them on (operator, one-time):**

1. Put Sphynx behind a real domain with **HTTPS** (a reverse proxy like Caddy or
   Nginx — a couple of lines; see the guide). Passkeys require HTTPS.
2. Set your domain as the relying-party id — either the env var
   `SPHYNX_PASSKEY_RP_ID: "media.example.com"` (no `https://`, no port), or in
   **Settings**. Until this is set, the passkey section stays hidden and
   `capabilities.passkeys` reports `false`.

**Add one (each user):** open **/user** → **Passkeys** → **Add a passkey**, then
approve with your fingerprint/face. Next time, they pick "sign in with a passkey" and
they're in — no password typed.

---

## Sign in a TV by scanning a QR code

Typing a password on a TV remote is misery. Sphynx supports **device-code sign-in**:

1. The TV app shows a **QR code** and a short code like `WXYZ-2345`.
2. On your phone, **scan the QR** (or open the link and type the code). You land on
   the **Approve a device** page (`/link`).
3. Sign in there — or, if you're already signed in on **/user**, it skips straight
   ahead. You'll see **"Sign in *Living Room TV*?"**.
4. Tap **Approve this device**. The TV is in — signed in as *you*. With a passkey,
   the whole thing is "scan → Face ID → done."

> **Important for QR sign-in over the internet:** the QR points at your server's
> public address. If you've set your domain for passkeys (above), that address is
> used automatically. If you **haven't**, the QR falls back to
> `http://<host>:9410`, which a phone on cellular **can't reach** — so configure
> your public domain (the same `SPHYNX_PASSKEY_RP_ID` / origin) for QR sign-in to
> work outside your LAN.

---

## Manage your own account (the /user page)

Every user gets **http://localhost:9410/user** to manage themselves — no admin
needed:

- **Display name** and **profile picture** (avatar upload).
- **Change password.**
- **Passkeys** — add/remove (see above).
- **Signed-in devices** — see every device, **Sign out** any one, or **Sign out
  everywhere**.
- **Reset watch history** — wipe resume positions and watched marks across all your
  devices in one click.
- **Home screen rows** — pick which rows show on your home screen and their order,
  by **genre** or **release decade**, on top of the built-ins (Continue Watching,
  Recently Added, Favorites). Your layout replaces the server default just for you;
  **Reset to default** puts it back. Rows with nothing in the library hide
  themselves. The admin sets the shared default in the **Home** tab.
- **Library correction** *(only if you've been granted **Edit metadata**)* — the same
  browse-and-fix tools as the admin's Items tab, scoped to your libraries.
- **Collections** *(only if you've been granted **Manage collections**)* — create
  box sets by hand and add/remove movies or series, the same as the admin's
  Collections tab, scoped to your libraries.

---

## Fix a title that came out wrong (the Items tab)

Scans get ~99% right; the **Items** tab is for the rest. Search a title or pick a
library to browse into shows and collections, then click **Fix** on any title.

- **Edit any field** — Title, Overview, Year, Runtime, Community rating, Content
  rating, Genres, Poster URL, Backdrop URL.
- **Save & lock edited fields** — your changes are locked, so a future re-scan **never
  overwrites them**. (Changed your mind? **Unlock all**.)
- **Re-enrich** — pull fresh data from TMDB for this title.
- **Re-identify** — pinned to the wrong movie? Paste the correct **TMDB id** and
  **Re-identify & enrich**.
- **Re-map (fix placement)** — a title on the wrong shelf, or a stray episode? Move
  it to another library, set its **Season #/Episode #**, or **nest it under** the
  right series or season.

---

## See real audio & subtitle tracks (Media probe)

By default Sphynx knows *where* a file is, not what's *inside* it. The **Media probe**
extension uses ffmpeg's `ffprobe` to read the real tracks — so your player can show a
proper "Audio: English 5.1 / Subtitles: Spanish" picker.

1. Open **Extensions → Media probe**. If `ffprobe` is on the server's PATH you'll see
   a green ✓ with its version; otherwise set the **ffprobe path** by hand.
2. Tick **Enable media probe** and **Save**.
3. To check one title, paste its **Item id** and click **Probe** — you'll see every
   audio/video/subtitle stream (codec, language, channels), any sidecar subtitle
   files, and embedded chapters.

To probe your **whole library** instead of one title at a time, click **Run probe
pass now**, or set a **background probe interval** (seconds; `0` = manual only) so
Sphynx quietly probes not-yet-probed titles on a schedule. Once cached, probed track
info rides along whenever a player resolves a title.

---

## Choose how tiles blur up (Low-res images)

Apps paint a cheap low-res stand-in while a poster loads so the grid never flashes
empty. **Extensions → Low-res images** picks the form Sphynx sends:

- **BlurHash** *(default)* — a compact hash the app paints *instantly*, with no extra
  request, as a soft blur of the image's colors. Sphynx generates one for **every**
  photographic image — poster, backdrop, episode still, banner, and cast faces — in a
  background pass that fills in lazily without slowing enrichment, so titles gain
  hashes over time (until then they fall back to the URL form automatically;
  transparent logos always use the URL form). A status indicator on the module shows
  the pass's progress, and you can set its **interval** or hit **Generate now**.
- **Image URL** — a tiny image link the app loads and blurs. Looks like a pixelated
  thumbnail, but it's one more image request per tile.
- **Off** — send nothing; apps just show a plain background.

**Which to pick?** BlurHash is the default and usually the best choice: nothing extra
to download, it paints the moment a tile appears, and it's lighter on bandwidth for
big grids — the trade-off is a one-time fetch/encode per image in the background
(and a freshly-changed image shows the URL form until the next pass). The pass runs
with a small, fixed concurrency so it never hammers the image source. Choose
**Image URL** if you'd rather see a recognizable thumbnail or skip the background
image work; **Off** if you want no placeholder at all.

Pick one and **Save** — it applies immediately. BlurHash generation then proceeds in
the background; the module's status line shows how far along it is. The **Activity**
panel's "Next runs" indicator shows when each scheduled task (enrichment refresh,
library index, BlurHash generation, media probe) fires next.

---

## Connect a player

A server with no player is just a fancy JSON spitter. Connecting any
Sphynx-speaking app is the same four steps:

1. **Make the server reachable.** On your home network that's your machine's IP, e.g.
   `http://192.168.1.50:9410`. From outside the house, put it behind a domain with
   HTTPS (a reverse proxy like Caddy/Nginx — see the guide). *This is also what makes
   passkeys and QR TV sign-in work remotely.*
2. **Point the app at that address.** It pings `/v1/info` to confirm it's a Sphynx
   server and learn what it can do.
3. **Log in** — a normal user account (or a passkey, or QR for a TV).
4. **Browse and play.** When someone hits play, the app quietly asks Sphynx "where's
   the file?" and streams it **directly from the source**.

**Ocelot** is the native Apple player (Mac/iOS/tvOS) built alongside Sphynx — install
it, type your server address, sign in, done. Because Sphynx is an open protocol,
other clients connect the same way.

---

## A quick tour of Settings

Almost everything is a checkbox or text box in **Settings** — these are the starting
defaults; tweak and **Save**. Most apply right away; a couple of boot-time settings
(the TMDB key) need a restart — there's a **Restart server** button for that, no shell
needed (your library and settings are preserved).

- **Server name / Server ID** — what players show; a stable identity.
- **Login session length** / **Time before sign-in is required again** — how long a
  player stays logged in.
- **Who can add "skip intro" markers** — off / read-only / let clients contribute.
- **Refresh posters & info every** — how often Sphynx re-checks TMDB.
- **Remember watch progress for** / **Run background cleanup every** — housekeeping.
- **Max profile-picture size** — the avatar upload cap.
- **TMDB API key** — set or change it here any time (no file editing). It's read at
  startup, so click **Restart server** afterward to apply it.
- **Metadata language** — the language for fetched titles and overviews. It applies
  **live**: after changing it, click **Reset enrichment** (Libraries → Storage
  sources) to re-fetch your existing titles, posters, and overviews in the new
  language — manually-locked fields are kept.
- **Sign-in profile picker** — optionally show a Jellyfin-style "who's watching" face
  picker on the sign-in page instead of a username box (off by default).

All time fields are in **minutes** (the panel reminds you: 1 day = 1440, 30 days =
43200, 1 year = 525600).

---

## When something's off

- **"Connection refused" on port 9410** — the container is still pulling on first
  start, or it crashed. Check `docker compose logs`.
- **Lost the admin password** — it's in your Compose file. If you let it auto-generate,
  `docker compose logs | grep -i password`. Worst case `docker compose down -v` starts
  fresh (this also erases your catalog).
- **No posters or descriptions** — no TMDB key yet, or it's wrong. Set it in
  **Settings**, click **Restart server** to apply it (it's read at startup), then re-scan.
- **A file won't play** — that's the *player's* department. Sphynx handed over the
  right URL; the format just isn't one your device plays directly. Sphynx never
  converts video.
- **Player / TV can't reach the server** — check the IP and port and that you're on
  the same network. From outside the house you need a public domain with HTTPS.
- **Diagnostics** — **Extensions → Diagnostics** has a read-only database peek and a
  live log viewer when something's stuck.

More answers live in the guide's
[**FAQ & Troubleshooting**](https://reckloon.github.io/Sphynx-Media/#faq).

---

## What's in this repo

You don't need any of this to *run* Sphynx, but if you're curious:

| Folder / file | What it is |
|---|---|
| [`sphynx-server/`](sphynx-server) | The actual server you just ran. |
| [`sphynx-protocol/`](sphynx-protocol) | The "language" servers and players speak — written once so the two sides can never disagree. |
| [`docs/`](docs/API.md) | The full menu of everything the server can do, request by request. |
| [`CHANGELOG.md`](CHANGELOG.md) | What landed in each release. Currently **v0.2.2**. |

**Want the deep version?** The protocol, how to build your own client or server, and
how to extend it all live in the
**[complete guide](https://reckloon.github.io/Sphynx-Media/)**.

## License

[MIT](LICENSE) — free to use, change, and share.

Third-party components (its Swift dependencies, and the `ffmpeg`/`ffprobe` bundled
in the Docker image for the media-probe extension) keep their own licenses — see
**[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)**. Sphynx invokes `ffprobe` as a
separate process, so its GPL terms don't extend to Sphynx's MIT code.
