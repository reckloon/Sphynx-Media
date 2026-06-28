<div align="center">

# Sphynx

**A tiny "brain" for your movie and TV collection.**

It keeps the catalog — posters, titles, seasons, who's-watched-what — and tells
your player app *where each video actually lives*. It never touches the video
itself.

📖 **[The complete guide →](https://reckloon.github.io/Sphynx-Media/)** &nbsp;·&nbsp; [Every API endpoint](docs/API.md)

</div>

---

## Explain it like I'm tired

You know how Plex or Jellyfin do two jobs at once?

1. **The librarian** — keeps the list of your movies/shows, grabs the posters and
   descriptions, remembers where you paused, who marked what as watched.
2. **The delivery truck** — actually pushes the video bytes down the wire to your
   TV, re-encoding them on the fly if your TV is picky.

**Sphynx is *only* the librarian.** It does zero delivery-truck work. It assumes
your video files already live somewhere a player can reach directly — a cloud
bucket, a CDN, a NAS, a plain web URL — and its whole job is to answer one
question when you hit play: *"Where's the actual file for this?"* Your player then
streams that file **straight from the source**, never through Sphynx.

**Why would you want that?**

- It's **featherweight**. No transcoding means no beefy CPU, no GPU, no giant
  install. It happily runs on a cheap box, a Raspberry Pi, or a $5 VPS.
- Your **video never makes a detour** through the server, so there's no
  middle-man slowing things down or burning bandwidth twice.
- It's an **open standard**. Any player app can speak to it, and any server can
  speak the same language. Today there's a polished Apple player called
  **Ocelot** that connects to it, but nothing about Sphynx is locked to one app.

**The catch (be honest with yourself):** Sphynx does *not* convert video. If a
file won't play on your device as-is, Sphynx can't fix that — that's the player's
job. So this is for people whose files are already in a player-friendly format
sitting at a reachable URL. If that's not you, a traditional Plex/Jellyfin setup
is the better fit.

---

## What you'll need

- **Docker** (Docker Desktop on Mac/Windows, or Docker Engine on Linux). This is
  by far the easiest path and the one this README walks through. *No Docker?* You
  can run it straight from source with a Swift 6 toolchain instead — see
  [`sphynx-server/README.md`](sphynx-server/README.md).
- **A few minutes.** Seriously, that's it for a working server.
- **(Optional) a free TMDB API key** if you want pretty posters, descriptions,
  cast lists, and episode art auto-filled. Grab one at
  [themoviedb.org](https://www.themoviedb.org/settings/api). Skip it and the
  server still runs — your items just show up as plain titles.
- **Some media at a reachable spot** — files at web URLs, or a folder on the
  server's disk. Don't have anything handy? You can still smoke-test the server
  with a free public clip (see the aside at the end of the library walkthrough).

---

## The 5-minute setup (Docker Compose)

This gets you a running, self-restarting server with its database saved safely
outside the container.

### 1. Grab the code

```sh
git clone https://github.com/reckloon/Sphynx-Media.git
cd Sphynx-Media/sphynx-server
```

### 2. Drop in a Compose file

A ready-made `docker-compose.yml` already lives in `sphynx-server/`. Here's the
whole thing, annotated in plain English so you know what every line does — tweak
the two values marked `<--` and you're set:

```yaml
services:
  sphynx:
    build:
      # Build from the parent folder — the server needs its sibling
      # "sphynx-protocol" package, which lives one directory up. Don't change this.
      context: ..
      dockerfile: sphynx-server/Dockerfile
    image: sphynx-server:latest
    ports:
      - "8080:8080"            # reach the server at http://localhost:8080
    environment:
      SPHYNX_SERVER_NAME: "My Living Room Server"   # the name your player shows
      SPHYNX_ADMIN_PASSWORD: "change-this-please"   # <-- PICK YOUR OWN PASSWORD
      SPHYNX_TMDB_API_KEY: ""                       # <-- paste your TMDB key for posters (optional)
      # Keep the catalog DB on the saved volume below, NOT inside the container —
      # otherwise your library vanishes every time you rebuild. Leave this alone.
      SPHYNX_DB_PATH: "/data/sphynx.sqlite"
    volumes:
      - sphynx-data:/data      # your catalog + login live here, and survive restarts
    restart: unless-stopped    # comes back up on its own after a crash or reboot

volumes:
  sphynx-data:
```

> **Heads up on the password:** if you leave `SPHYNX_ADMIN_PASSWORD` out
> entirely, the server generates a strong random one and **prints it once** in
> the startup log. That's fine, but you'll need to go read the log to find it. Setting
> your own is simpler the first time around.

### 3. Start it up

```sh
docker compose up --build
```

First run takes a couple minutes (it's compiling the server). When it's done
you'll see it listening on port 8080. Leave that terminal running, or add `-d` to
run it in the background.

### 4. Open the control panel

Once the build finishes, open **http://localhost:8080/admin** in your browser and
sign in as `admin` with the password you set in the Compose file. If the sign-in
page loads, **you've got a working Sphynx server.** 🎉

> Prefer the terminal? `curl http://localhost:8080/v1/info` returns a little blob
> of JSON with your server's name — same confirmation, no browser needed.

Everything from here on is done in that web panel — no config files, no `curl`.

You'll see five tabs along the top:

- **Settings** — your server's name and behavior (covered [below](#settings-without-the-terminal)).
- **Libraries** — the shelves your media gets sorted onto (Movies, TV Shows, …).
- **Sources** — *where* your media actually lives, and how to find it.
- **Users** — accounts for each person who'll use a player app.
- **Extensions** — a live activity dashboard, a database peek, and logs for when
  you're curious or something's stuck.

That's the whole server. No config files to hand-edit, no JSON to memorize.

---

## Building your first library (all clicking, no typing)

The catalog starts empty. Here's how to fill it from the **/admin** panel. Two
clicks-worth of setup, then Sphynx does the rest.

### Step 1 — Make a shelf (Libraries tab)

Click **Libraries → Add library**. Give it a **Title** (like "Movies") and pick a
**Kind** (Movies, TV Shows, etc.). Done — that's an empty shelf waiting for media.

### Step 2 — Tell it where your media lives (Sources tab)

Click **Sources → Add source**. A *source* is just "here's where my files are and
how to reach them." Fill in:

- **Label** — any name you'll recognize ("My NAS", "Cloud bucket").
- **Driver** — how Sphynx reaches the files. Pick **HTTP** for media at web URLs,
  or **Local** for a folder on the server's disk.
- **Base URL** *(HTTP)* or **Root path** *(Local)* — the web address or folder
  your media sits under.
- **Manifest URL** *(HTTP)* — a small list of what to index (see the note below).
- **Movies library / TV library** — point these at the shelf(s) you made in
  Step 1, so Sphynx knows where to file each thing. It sorts movies and TV apart
  automatically.

Click **Add source** to save it.

> **What's a "manifest"?** For web (HTTP) sources, it's a little text file listing
> your titles — Sphynx reads the list, not the videos. The
> [guide's walkthrough](https://reckloon.github.io/Sphynx-Media/#firstlibrary)
> shows exactly what one looks like. For a **Local** folder source you don't need
> one — Sphynx just walks the folder and figures titles out from the file and
> folder names (`Movie Name (2008)/…`, `Show Name/Season 1/…`).

### Step 3 — Press the button (Scan)

Find your new source in the Sources list and click **Scan**. Sphynx walks through
everything, adds each title to the right shelf, and — if you set a TMDB key —
fetches posters, descriptions, cast, and episode art. Pop over to the
**Extensions → Activity** view to watch it work in real time.

When the scan finishes, your library is live. **That's it** — there's nothing
left to configure to start watching.

### Step 4 — Make accounts for your people (Users tab)

You *could* hand everyone the `admin` login, but don't — admins can change server
settings. Instead click **Users → Add user** and make a normal account (just a
username and password) for each person. Regular users can browse and play
everything, but can't touch the server's guts. This is also how each person gets
their own Continue Watching and watch history.

> **Just kicking the tires with no media of your own?** You can smoke-test the
> whole pipeline from the terminal without setting up a source — there's a tiny
> `curl` recipe using Blender's free *Big Buck Bunny* clip in
> [`sphynx-server/README.md`](sphynx-server/README.md). But for a real
> collection, the GUI flow above is the way.

---

## Connecting a player (the fun part)

A server with no player is just a fancy JSON spitter. Here's how a client app
hooks up — the steps are the same for any Sphynx-speaking app:

1. **Make the server reachable from the player.** On the same home network,
   that's your machine's local IP, e.g. `http://192.168.1.50:8080`. From outside
   the house you'll want it behind a real domain with HTTPS (a reverse proxy like
   Caddy or Nginx makes this a couple of lines — see the guide).
2. **Point the app at that address.** The app pings `/v1/info` to confirm "yep,
   this is a Sphynx server" and learns what it can do.
3. **Log in** with a username and password. Use your `admin` account, or — better
   for everyday use — make a normal user account for each person (in the **/admin**
   panel under Users). Regular users can browse and play but can't change server
   settings.
4. **Browse and play.** The app shows your libraries, posters, Continue Watching,
   etc., and when someone hits play it quietly asks Sphynx "where's the file?" and
   streams it directly.

**Ocelot** is the native Apple player (Mac/iOS/tvOS) built alongside Sphynx — if
you're in the Apple world, that's the turnkey option: install it, type in your
server address, log in, done. Because Sphynx is an open protocol, other clients
can connect the same way.

---

## Settings, without the terminal

Here's the rule of thumb: **almost everything is a checkbox or a text box in the
Settings tab.** The Compose file only sets the handful of things that have to be
in place *before* the server can boot.

**Set-once-in-Compose** (these are "boot-up secrets" — they need to exist before
anything else runs):

| Compose setting | What it does |
|---|---|
| `SPHYNX_ADMIN_PASSWORD` | Your admin login password. (Leave it blank and a random one is printed to the log on first start.) |
| `SPHYNX_TMDB_API_KEY` | Your free TMDB key — fills in posters, plots, cast, episode art. Blank = plain titles only. |
| `SPHYNX_PORT` | The port it listens on. Default `8080`. |
| `SPHYNX_DB_PATH` | Where the catalog database lives. Keep it on the mounted volume (as the Compose file does) so it survives restarts. |

**Change-anytime-in-the-GUI** — open **/admin → Settings** and these are right
there, already in plain English (no codes to look up):

- **Server name** — what your players show for this server.
- **Login session length** / **Time before sign-in is required again** — how long
  a player stays logged in.
- **Who can add "skip intro" markers** — and how soon that data is treated as
  stale.
- **Refresh posters & info every** — how often Sphynx re-checks TMDB for updated
  artwork and details.
- **Remember watch progress for** / **Run background cleanup every** —
  housekeeping schedules.

Change one, click **Save settings**, done. (Under the hood the Compose values for
these just provide the *starting* defaults on first boot; after that the Settings
tab is the source of truth.) The exhaustive list with exact units is in
[`sphynx-server/README.md`](sphynx-server/README.md).

---

## When something's off

- **"Connection refused" / nothing on port 8080** — the container probably isn't
  up yet (first build is slow) or crashed. Check `docker compose logs`.
- **I lost my admin password** — you set one in the Compose file; it's right
  there. If you let it auto-generate, search the startup log
  (`docker compose logs | grep -i password`). Worst case, wipe the data volume
  (`docker compose down -v`) to start fresh — but that erases your catalog too.
- **No posters or descriptions** — you haven't set `SPHYNX_TMDB_API_KEY`, or the
  key is wrong. Add it and re-scan.
- **A file won't play in my app** — that's the *player's* department, not
  Sphynx's. Sphynx handed over the correct URL; the file format just isn't one
  your device can play directly. Remember: Sphynx never converts video.
- **Player can't find the server** — double-check the IP/port and that they're on
  the same network. From outside your home you need a public address with HTTPS.

More answers live in the guide's
[**FAQ & Troubleshooting**](https://reckloon.github.io/Sphynx-Media/#faq).

---

## What's in this repo

You don't need any of this to *run* the server, but if you're curious:

| Folder | What it is |
|---|---|
| [`sphynx-server/`](sphynx-server) | The actual server you just ran. |
| [`sphynx-protocol/`](sphynx-protocol) | The "language" the server and players speak — the exact shape of every message, written once so the two sides can never disagree. |
| [`docs/`](docs/API.md) | The full menu of everything the server can do, request by request. |

**Want the deep version?** Everything here — plus how the protocol works, how to
build your own client or server, and how to extend it — is in the
**[complete guide](https://reckloon.github.io/Sphynx-Media/)**.

## License

[MIT](LICENSE) — free to use, change, and share.
