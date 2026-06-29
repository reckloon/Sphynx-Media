# Third-party notices

Sphynx itself is licensed under the [MIT License](LICENSE). It builds on the
third-party components below; this file collects their licenses and obligations.
All of them are compatible with redistributing Sphynx under MIT.

## Bundled in the Docker image (runtime)

- **FFmpeg — `ffprobe`.** The published image (`ghcr.io/reckloon/sphynx-server`)
  installs Ubuntu's `ffmpeg` package so the optional **Media probe** extension can
  read audio/subtitle tracks and embedded chapters. FFmpeg's core is
  **LGPL-2.1-or-later**; the Ubuntu build additionally enables **GPL-licensed**
  components, so the distributed `ffmpeg`/`ffprobe` binaries are conveyed under the
  **GPL (v2 or later)**. The authoritative terms ship inside the image at
  `/usr/share/doc/ffmpeg/copyright`, and corresponding source is available from the
  [FFmpeg project](https://ffmpeg.org/download.html) and the Ubuntu archive
  (`apt-get source ffmpeg`).

  **This does not affect Sphynx's MIT license.** Sphynx never links FFmpeg; it
  invokes `ffprobe` as a **separate process** (`ProcessRunner.run`). Running a GPL
  program at arm's length is *mere aggregation* — Sphynx and FFmpeg remain
  independent works under their own licenses. Operators who would rather not
  redistribute the GPL binary can build an image without `ffmpeg` (the extension
  simply stays inert) — see `sphynx-server/Dockerfile`.

## Swift package dependencies (compiled into the server)

| Component | License |
|---|---|
| GRDB.swift | MIT |
| SwiftCBOR | The Unlicense (public domain) |
| Hummingbird, hummingbird-auth | Apache-2.0 |
| swift-webauthn | Apache-2.0 |
| swift-jpeg | Apache-2.0 |
| async-http-client | Apache-2.0 |
| swift-extras-base64 | Apache-2.0 |
| Apple `swift-*` (NIO, Crypto, Certificates, ASN1, Collections, Algorithms, Async-Algorithms, Atomics, Numerics, System, Log, Metrics, HTTP-Types, Service-Lifecycle, Distributed-Tracing, …) | Apache-2.0 |

Apache-2.0 and MIT are permissive and impose only attribution; the Unlicense
imposes none. None are copyleft, so none affect Sphynx's MIT terms. Each project's
full license text lives in its own repository.

## Metadata

Artwork and descriptions are fetched from **TMDB** at the operator's option (with
the operator's own API key). TMDB data is subject to
[The Movie Database terms of use](https://www.themoviedb.org/terms-of-use); Sphynx
is not endorsed or certified by TMDB.
