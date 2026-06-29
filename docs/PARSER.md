# The Sphynx Filename Parser

> **Point Sphynx at the messiest media folder you have. It figures out what
> everything *is*.**

Identifying a movie or episode from a path is the load-bearing, bug-prone heart
of any media server — the place where *"why did it match the wrong title?"*
lives. Sphynx's identifier is **folder-aware** (a clean `Big Hero 6 (2014)`
folder beats a `Тачки.2006…mkv` filename), **language-agnostic** (Latin, CJK,
Cyrillic), and **self-contained** (no network), so it can be tested to
exhaustion.

## The headline

| | |
|---|---|
| **Distinct paths fuzzed** | **500,000** |
| **Misidentifications** | **0** |
| **Structure families covered** | **32** |
| **Random seeds** | **5**, fully reproducible |

Every path is **generated from a known ground-truth identity**, decorated with
real-world noise (resolution/codec junk, release groups, site tags, fansub
brackets, season packs, foreign scripts), then fed through the exact production
parser. The harness asserts the parser recovers the original title, year, season,
and episode. **Zero misses** means it never once disagreed with the truth.

## How it's tested

A seeded, property-based **fuzz harness** compiles the production
`PathParser` / `FilenameParser` verbatim and runs millions of generated paths
through them. Because each case is *built* from a known identity, a mismatch is a
genuine signal — there's no human-curated oracle to drift out of date. The
harness is the regression net: new naming styles become new generators, and the
bar stays at zero.

### Battle scars (bugs the fuzzer caught, now fixed)

- **Episodes named `Show.5x09.mkv` were silently parsed as *movies*.** The
  extension stripper ate `.5x09` as if it were a file extension (4 chars,
  contains an `x`), deleting the episode marker. Two-digit forms `.12x09`
  survived only by length. A `\d+x\d+` token is now never stripped.
- **Yearless scene releases leaked the release group into the title** —
  `Lunar.Monolith…Atmos-YTS` became *"Lunar Monolith YTS"*. With no year to
  bound the title, it's now cut at the first release-junk token.

Both were found by this harness, fixed, and are now permanent regression cases.

## The gallery

Ten real, randomly-generated samples from each structure family — the exact
input path on the left, what the parser returned on the right. (Titles are
nonsense by construction; the *structure* is what's under test.)

### Everyday movies

#### `movie_clean_folder` — Clean `Title (Year)` folder, junk-laden file inside

<sub>3,055 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Media/Mellow Zephyr (1973)/Mellow.Zephyr.1973.480p.DVDRip.XviD-FLUX.mkv` | **Mellow Zephyr** · 1973  ·  movie |
| `Films/Feral (2017)/Feral.2017.1080p.WEBRip.AAC.x264-SPARKS.mkv` | **Feral** · 2017  ·  movie |
| `Plush Meadow (2017)/Plush.Meadow.2017.2160p.UHD.HDR.x265-Erai.mkv` | **Plush Meadow** · 2017  ·  movie |
| `Films/Feral Verdict (2016)/Feral_Verdict.2016.2160p.UHD.HDR.x265-GROUP.mkv` | **Feral Verdict** · 2016  ·  movie |
| `Savage Cipher (1966)/Savage.Cipher.1966.2160p.UHD.HDR.x265-Erai.mkv` | **Savage Cipher** · 1966  ·  movie |
| `Movies/Brittle (1953)/Brittle.1953.2160p.REMUX.TrueHD.Atmos-FGT.mkv` | **Brittle** · 1953  ·  movie |
| `Crimson Foundry (1975)/Crimson_Foundry.1975.1080p.BluRay.x264-YTS.mkv` | **Crimson Foundry** · 1975  ·  movie |
| `Media/Quarry beyond the Estuary (2013)/Quarry beyond the Estuary.2013.720p.WEB-DL.H264-pcela.mkv` | **Quarry beyond the Estuary** · 2013  ·  movie |
| `Iron Tempest (1968)/Iron.Tempest.1968.480p.DVDRip.XviD-GROUP.mkv` | **Iron Tempest** · 1968  ·  movie |
| `Frantic Zephyr (1983)/Frantic Zephyr.1983.2160p.REMUX.TrueHD.Atmos-YTS.mkv` | **Frantic Zephyr** · 1983  ·  movie |

#### `movie_scene_release` — Dotted scene release, no folder authority

<sub>3,103 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Feral_Requiem.1976.480p.DVDRip.XviD-RARBG.mkv` | **Feral Requiem** · 1976  ·  movie |
| `Foundry of the Harbor.2012.480p.DVDRip.XviD-SPARKS.mkv` | **Foundry of the Harbor** · 2012  ·  movie |
| `Velvet_Plinth.1995.480p.DVDRip.XviD-pcela.mkv` | **Velvet Plinth** · 1995  ·  movie |
| `Movies/Iron Bastion.2007.480p.DVDRip.XviD-CMRG.mkv` | **Iron Bastion** · 2007  ·  movie |
| `Stark_Thicket.2010.2160p.REMUX.TrueHD.Atmos-SPARKS.mkv` | **Stark Thicket** · 2010  ·  movie |
| `Quarry and the Vortex.2022.1080p.BluRay.x264-RARBG.mkv` | **Quarry and the Vortex** · 2022  ·  movie |
| `Movies/Quiet.Zephyr.1994.720p.WEB-DL.H264-YTS.mkv` | **Quiet Zephyr** · 1994  ·  movie |
| `Downloads/Pinnacle.without.a.Vortex.1994.720p.WEB-DL.H264-pcela.mkv` | **Pinnacle without a Vortex** · 1994  ·  movie |
| `Downloads/Marble.1954.480p.DVDRip.XviD-RARBG.mkv` | **Marble** · 1954  ·  movie |
| `Downloads/Opal Vortex.1992.1080p.WEBRip.AAC.x264-YTS.mkv` | **Opal Vortex** · 1992  ·  movie |

#### `movie_punctuation_folder` — Folder punctuation (`:`/`-`/`!`) must survive

<sub>3,224 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Foundry and the Maelstrom - Meadow (1966)/release.tag.1080p.mkv` | **Foundry and the Maelstrom - Meadow** · 1966  ·  movie |
| `Movies/Hollow Halcyon: Orchard (1954)/release.tag.1080p.mkv` | **Hollow Halcyon: Orchard** · 1954  ·  movie |
| `Movies/Zephyr in the Orchard: Cipher (1980)/release.tag.1080p.mkv` | **Zephyr in the Orchard: Cipher** · 1980  ·  movie |
| `Movies/Thicket in the Halcyon - Harbor (1989)/release.tag.1080p.mkv` | **Thicket in the Halcyon - Harbor** · 1989  ·  movie |
| `Movies/Amber Reverie: Tempest (1991)/release.tag.1080p.mkv` | **Amber Reverie: Tempest** · 1991  ·  movie |
| `Movies/Crimson Monolith! Zephyr (2004)/release.tag.1080p.mkv` | **Crimson Monolith! Zephyr** · 2004  ·  movie |
| `Movies/Crimson! Cipher (1982)/release.tag.1080p.mkv` | **Crimson! Cipher** · 1982  ·  movie |
| `Movies/Marble Meadow - Harbor (1988)/release.tag.1080p.mkv` | **Marble Meadow - Harbor** · 1988  ·  movie |
| `Movies/Lunar Quarry: Bastion (2021)/release.tag.1080p.mkv` | **Lunar Quarry: Bastion** · 2021  ·  movie |
| `Movies/Verdant Quarry! Harbor (1978)/release.tag.1080p.mkv` | **Verdant Quarry! Harbor** · 1978  ·  movie |

#### `movie_group_tag` — Leading `[release-group]` fansub tag

<sub>3,099 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/[Erai] Lantern beyond the Plinth (2024) [1080p].mkv` | **Lantern beyond the Plinth** · 2024  ·  movie |
| `Movies/[GROUP] Sojourn in the Cipher (2010) [1080p].mkv` | **Sojourn in the Cipher** · 2010  ·  movie |
| `Movies/[FGT] Hollow Quarry (1958) [1080p].mkv` | **Hollow Quarry** · 1958  ·  movie |
| `Movies/[YTS] Cobalt (2012) [1080p].mkv` | **Cobalt** · 2012  ·  movie |
| `Movies/[CMRG] Gilded (2010) [1080p].mkv` | **Gilded** · 2010  ·  movie |
| `Movies/[FLUX] Gilded Plinth (1950) [1080p].mkv` | **Gilded Plinth** · 1950  ·  movie |
| `Movies/[Erai] Orchard under the Nimbus (1969) [1080p].mkv` | **Orchard under the Nimbus** · 1969  ·  movie |
| `Movies/[pcela] Estuary under the Beacon (1983) [1080p].mkv` | **Estuary under the Beacon** · 1983  ·  movie |
| `Movies/[Erai] Languid Cinder (1980) [1080p].mkv` | **Languid Cinder** · 1980  ·  movie |
| `Movies/[FLUX] Nimbus beyond the Pinnacle (2000) [1080p].mkv` | **Nimbus beyond the Pinnacle** · 2000  ·  movie |

#### `movie_site_tag` — Tracker / `www.` site prefix to strip

<sub>3,080 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/www.UIndex.org    -    Brisk.2016.1080p.BluRay.x264-FLUX.mkv` | **Brisk** · 2016  ·  movie |
| `Movies/[ www.Tracker.to ] Verdant.Halcyon.1957.1080p.BluRay.x264-CMRG.mkv` | **Verdant Halcyon** · 1957  ·  movie |
| `Movies/[ www.Tracker.to ] Restless.Vortex.1993.1080p.BluRay.x264-YTS.mkv` | **Restless Vortex** · 1993  ·  movie |
| `Movies/www.UIndex.org    -    Velvet Pinnacle.1954.1080p.BluRay.x264-GROUP.mkv` | **Velvet Pinnacle** · 1954  ·  movie |
| `Movies/www.Torrenting.com - Lunar_Beacon.1998.1080p.BluRay.x264-pcela.mkv` | **Lunar Beacon** · 1998  ·  movie |
| `Movies/[ www.Tracker.to ] Amber.1990.1080p.BluRay.x264-YTS.mkv` | **Amber** · 1990  ·  movie |
| `Movies/[ www.Tracker.to ] Mellow.1967.1080p.BluRay.x264-pcela.mkv` | **Mellow** · 1967  ·  movie |
| `Movies/www.UIndex.org    -    Savage.Cavern.1979.1080p.BluRay.x264-FLUX.mkv` | **Savage Cavern** · 1979  ·  movie |
| `Movies/[ www.Tracker.to ] Orchard.beyond.the.Plinth.2012.1080p.BluRay.x264-Erai.mkv` | **Orchard beyond the Plinth** · 2012  ·  movie |
| `Movies/www.UIndex.org    -    Brittle.2021.1080p.BluRay.x264-CMRG.mkv` | **Brittle** · 2021  ·  movie |

#### `movie_foreign_file` — Foreign-language filename, English folder wins

<sub>3,126 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Restless Reverie (1976)/映画祭.1976.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Restless Reverie** · 1976  ·  movie |
| `Movies/Feral (2017)/映画祭.2017.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Feral** · 2017  ·  movie |
| `Movies/Brittle Beacon (2017)/폭풍.2017.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Brittle Beacon** · 2017  ·  movie |
| `Movies/Rabid (2020)/Вихрь.2020.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Rabid** · 2020  ·  movie |
| `Movies/Rabid Requiem (1970)/비밀.1970.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Rabid Requiem** · 1970  ·  movie |
| `Movies/Iron Plinth (1950)/映画祭.1950.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Iron Plinth** · 1950  ·  movie |
| `Movies/Feral Monolith (1955)/Вихрь.1955.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Feral Monolith** · 1955  ·  movie |
| `Movies/Gilded (2005)/Тачки.2005.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Gilded** · 2005  ·  movie |
| `Movies/Languid Cinder (1957)/映画祭.1957.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Languid Cinder** · 1957  ·  movie |
| `Movies/Quarry without a Reverie (1967)/流星.1967.UHD.Blu-Ray.Remux.2160p.mkv.strm` | **Quarry without a Reverie** · 1967  ·  movie |

#### `movie_deep_nesting` — Deep mount path with generic library roots

<sub>3,085 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `mnt/storage/media/Movies/Crimson Pinnacle (1952)/Crimson Pinnacle.1952.2160p.UHD.BluRay.x265-Erai.mkv` | **Crimson Pinnacle** · 1952  ·  movie |
| `mnt/storage/media/Movies/Rabid Thicket (1964)/Rabid Thicket.1964.2160p.UHD.BluRay.x265-SPARKS.mkv` | **Rabid Thicket** · 1964  ·  movie |
| `mnt/storage/media/Movies/Mellow Estuary (1970)/Mellow Estuary.1970.2160p.UHD.BluRay.x265-NTb.mkv` | **Mellow Estuary** · 1970  ·  movie |
| `mnt/storage/media/Movies/Lunar (2002)/Lunar.2002.2160p.UHD.BluRay.x265-YTS.mkv` | **Lunar** · 2002  ·  movie |
| `mnt/storage/media/Movies/Wary (1954)/Wary.1954.2160p.UHD.BluRay.x265-CMRG.mkv` | **Wary** · 1954  ·  movie |
| `mnt/storage/media/Movies/Marble (1956)/Marble.1956.2160p.UHD.BluRay.x265-YTS.mkv` | **Marble** · 1956  ·  movie |
| `mnt/storage/media/Movies/Stark Harbor (1960)/Stark.Harbor.1960.2160p.UHD.BluRay.x265-pcela.mkv` | **Stark Harbor** · 1960  ·  movie |
| `mnt/storage/media/Movies/Drifting (2011)/Drifting.2011.2160p.UHD.BluRay.x265-RARBG.mkv` | **Drifting** · 2011  ·  movie |
| `mnt/storage/media/Movies/Meadow under the Cavern (1963)/Meadow.under.the.Cavern.1963.2160p.UHD.BluRay.x265-YTS.mkv` | **Meadow under the Cavern** · 1963  ·  movie |
| `mnt/storage/media/Movies/Marble Nimbus (2002)/Marble.Nimbus.2002.2160p.UHD.BluRay.x265-GROUP.mkv` | **Marble Nimbus** · 2002  ·  movie |

#### `movie_no_year` — Yearless scene release (group must not leak)

<sub>3,139 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Drifting_Meadow.720p.WEB-DL.H264-YTS.mkv` | **Drifting Meadow**  ·  movie |
| `Movies/Feral Pinnacle.720p.WEB-DL.H264-YTS.mkv` | **Feral Pinnacle**  ·  movie |
| `Movies/Opal.Cipher.1080p.WEBRip.AAC.x264-Erai.mkv` | **Opal Cipher**  ·  movie |
| `Movies/Gilded_Cavern.1080p.WEBRip.AAC.x264-pcela.mkv` | **Gilded Cavern**  ·  movie |
| `Movies/Lantern without a Reverie.1080p.WEBRip.AAC.x264-RARBG.mkv` | **Lantern without a Reverie**  ·  movie |
| `Movies/Opal_Reverie.1080p.WEBRip.AAC.x264-FLUX.mkv` | **Opal Reverie**  ·  movie |
| `Movies/Opal.Beacon.2160p.UHD.HDR.x265-GROUP.mkv` | **Opal Beacon**  ·  movie |
| `Movies/Amber.2160p.REMUX.TrueHD.Atmos-NTb.mkv` | **Amber**  ·  movie |
| `Movies/Amber.Maelstrom.720p.WEB-DL.H264-GROUP.mkv` | **Amber Maelstrom**  ·  movie |
| `Movies/Gilded.720p.WEB-DL.H264-SPARKS.mkv` | **Gilded**  ·  movie |

#### `movie_number_in_title` — A number that belongs to the title

<sub>3,107 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Estuary 3 (1980)/Estuary.3.1980.1080p.BluRay.x264-Erai.mkv` | **Estuary 3** · 1980  ·  movie |
| `Movies/Cinder 4 (2010)/Cinder_4.2010.1080p.BluRay.x264-GROUP.mkv` | **Cinder 4** · 2010  ·  movie |
| `Movies/Cinder 3 (2006)/Cinder_3.2006.1080p.BluRay.x264-RARBG.mkv` | **Cinder 3** · 2006  ·  movie |
| `Movies/Verdict 1 (2006)/Verdict 1.2006.1080p.BluRay.x264-NTb.mkv` | **Verdict 1** · 2006  ·  movie |
| `Movies/Lantern 8 (2008)/Lantern 8.2008.1080p.BluRay.x264-FLUX.mkv` | **Lantern 8** · 2008  ·  movie |
| `Movies/Halcyon 4 (2000)/Halcyon_4.2000.1080p.BluRay.x264-Erai.mkv` | **Halcyon 4** · 2000  ·  movie |
| `Movies/Beacon 9 (2022)/Beacon.9.2022.1080p.BluRay.x264-CMRG.mkv` | **Beacon 9** · 2022  ·  movie |
| `Movies/Requiem 8 (1990)/Requiem_8.1990.1080p.BluRay.x264-GROUP.mkv` | **Requiem 8** · 1990  ·  movie |
| `Movies/Bastion 7 (1987)/Bastion 7.1987.1080p.BluRay.x264-pcela.mkv` | **Bastion 7** · 1987  ·  movie |
| `Movies/Sojourn 8 (1992)/Sojourn 8.1992.1080p.BluRay.x264-Erai.mkv` | **Sojourn 8** · 1992  ·  movie |

#### `movie_unicode_punct` — Accented Latin, preserved verbatim

<sub>3,114 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Zoë Æther (2008)/release.1080p.mkv` | **Zoë Æther** · 2008  ·  movie |
| `Movies/Zoë Æther (2022)/release.1080p.mkv` | **Zoë Æther** · 2022  ·  movie |
| `Movies/Zoë Æther (2024)/release.1080p.mkv` | **Zoë Æther** · 2024  ·  movie |
| `Movies/Crème Brûlée (2012)/release.1080p.mkv` | **Crème Brûlée** · 2012  ·  movie |
| `Movies/Zoë Æther (2013)/release.1080p.mkv` | **Zoë Æther** · 2013  ·  movie |
| `Movies/Zoë Æther (1996)/release.1080p.mkv` | **Zoë Æther** · 1996  ·  movie |
| `Movies/José's Café (2011)/release.1080p.mkv` | **José's Café** · 2011  ·  movie |
| `Movies/José's Café (1999)/release.1080p.mkv` | **José's Café** · 1999  ·  movie |
| `Movies/Crème Brûlée (2012)/release.1080p.mkv` | **Crème Brûlée** · 2012  ·  movie |
| `Movies/Zoë Æther (1988)/release.1080p.mkv` | **Zoë Æther** · 1988  ·  movie |

### Television

#### `tv_season_marker` — `Series (Year)/Season N/…SxxExx`

<sub>3,126 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `TV/Solemn (1993)/Season 8/Solemn.S08E13.1080p.WEB-DL.mkv` | **Solemn** · S08E13 · 1993  ·  episode |
| `TV/Estuary beyond the Meadow (1995)/Season 1/Estuary beyond the Meadow.S01E03.1080p.WEB-DL.mkv` | **Estuary beyond the Meadow** · S01E03 · 1995  ·  episode |
| `TV/Plush Cavern (1987)/Season 3/Plush Cavern.S03E17.1080p.WEB-DL.mkv` | **Plush Cavern** · S03E17 · 1987  ·  episode |
| `TV/Gilded Orchard (2021)/Season 1/Gilded Orchard.S01E04.1080p.WEB-DL.mkv` | **Gilded Orchard** · S01E04 · 2021  ·  episode |
| `TV/Reverie without a Verdict (2005)/Season 1/Reverie.without.a.Verdict.S01E02.1080p.WEB-DL.mkv` | **Reverie without a Verdict** · S01E02 · 2005  ·  episode |
| `TV/Lantern in the Halcyon (2021)/Season 2/Lantern_in_the_Halcyon.S02E20.1080p.WEB-DL.mkv` | **Lantern in the Halcyon** · S02E20 · 2021  ·  episode |
| `TV/Rabid Orchard (2009)/Season 8/Rabid_Orchard.S08E15.1080p.WEB-DL.mkv` | **Rabid Orchard** · S08E15 · 2009  ·  episode |
| `TV/Lunar (1991)/Season 7/Lunar.S07E11.1080p.WEB-DL.mkv` | **Lunar** · S07E11 · 1991  ·  episode |
| `TV/Feral (1993)/Season 5/Feral.S05E11.1080p.WEB-DL.mkv` | **Feral** · S05E11 · 1993  ·  episode |
| `TV/Foundry and the Meadow (2023)/Season 7/Foundry.and.the.Meadow.S07E09.1080p.WEB-DL.mkv` | **Foundry and the Meadow** · S07E09 · 2023  ·  episode |

#### `tv_scene` — Dotted TV scene release, no season folder

<sub>3,116 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Stark Cinder.S02E04.1080p.WEBRip.AAC.x264-RARBG.mkv` | **Stark Cinder** · S02E04  ·  episode |
| `Vortex.of.the.Reverie.S08E03.2160p.UHD.HDR.x265-FLUX.mkv` | **Vortex of the Reverie** · S08E03  ·  episode |
| `Wary.S07E15.2160p.UHD.HDR.x265-FGT.mkv` | **Wary** · S07E15  ·  episode |
| `Wary.S06E03.2160p.REMUX.TrueHD.Atmos-NTb.mkv` | **Wary** · S06E03  ·  episode |
| `Drifting.Tempest.S02E14.720p.WEB-DL.H264-CMRG.mkv` | **Drifting Tempest** · S02E14  ·  episode |
| `Zephyr_without_a_Cavern.S06E07.2160p.UHD.HDR.x265-RARBG.mkv` | **Zephyr without a Cavern** · S06E07  ·  episode |
| `Orchard.and.the.Cavern.S05E01.2160p.UHD.HDR.x265-SPARKS.mkv` | **Orchard and the Cavern** · S05E01  ·  episode |
| `Velvet.Sojourn.S02E02.1080p.WEBRip.AAC.x264-RARBG.mkv` | **Velvet Sojourn** · S02E02  ·  episode |
| `Foundry.under.the.Requiem.S01E19.2160p.REMUX.TrueHD.Atmos-SPARKS.mkv` | **Foundry under the Requiem** · S01E19  ·  episode |
| `Cavern.without.a.Cinder.S03E02.2160p.REMUX.TrueHD.Atmos-YTS.mkv` | **Cavern without a Cinder** · S03E02  ·  episode |

#### `tv_loose_episode` — Loose `Episode N` under a season folder

<sub>3,192 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Monolith under the Cinder (2025)/Season 7/Episode 2.mkv` | **Monolith under the Cinder** · S07E02 · 2025  ·  episode |
| `Estuary of the Estuary (2020)/Season 2/E05.mkv` | **Estuary of the Estuary** · S02E05 · 2020  ·  episode |
| `Stark (2006)/Season 5/Ep 17.mkv` | **Stark** · S05E17 · 2006  ·  episode |
| `Cobalt Maelstrom (1983)/Season 8/Ep 17.mkv` | **Cobalt Maelstrom** · S08E17 · 1983  ·  episode |
| `Drifting Harbor (2018)/Season 2/Ep 17.mkv` | **Drifting Harbor** · S02E17 · 2018  ·  episode |
| `Plush Nimbus (1994)/Season 5/Ep 1.mkv` | **Plush Nimbus** · S05E01 · 1994  ·  episode |
| `Solemn Halcyon (2007)/Season 6/E04.mkv` | **Solemn Halcyon** · S06E04 · 2007  ·  episode |
| `Requiem under the Tempest (1982)/Season 5/E02.mkv` | **Requiem under the Tempest** · S05E02 · 1982  ·  episode |
| `Brisk Verdict (2012)/Season 3/Episode 1.mkv` | **Brisk Verdict** · S03E01 · 2012  ·  episode |
| `Velvet Verdict (2024)/Season 5/Episode 3.mkv` | **Velvet Verdict** · S05E03 · 2024  ·  episode |

#### `tv_loose_with_title` — Loose episode that also carries a title

<sub>3,116 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Plush Estuary (1995)/Season 5/Episode 9 Cobalt Vortex.mkv` | **Plush Estuary** · S05E09 · "Cobalt Vortex" · 1995  ·  episode |
| `Wary Lantern (1998)/Season 7/Episode 8 Plush Quarry.mkv` | **Wary Lantern** · S07E08 · "Plush Quarry" · 1998  ·  episode |
| `Quarry of the Estuary (2009)/Season 1/Episode 13 Drifting Foundry.mkv` | **Quarry of the Estuary** · S01E13 · "Drifting Foundry" · 2009  ·  episode |
| `Quiet Pinnacle (2008)/Season 5/Episode 1 Lunar Halcyon.mkv` | **Quiet Pinnacle** · S05E01 · "Lunar Halcyon" · 2008  ·  episode |
| `Gilded Reverie (1998)/Season 4/Episode 20 Amber Cavern.mkv` | **Gilded Reverie** · S04E20 · "Amber Cavern" · 1998  ·  episode |
| `Marble (2004)/Season 5/Episode 1 Lunar Estuary.mkv` | **Marble** · S05E01 · "Lunar Estuary" · 2004  ·  episode |
| `Crimson (1994)/Season 6/Episode 8 Brittle Plinth.mkv` | **Crimson** · S06E08 · "Brittle Plinth" · 1994  ·  episode |
| `Iron (1994)/Season 1/Episode 6 Mellow Quarry.mkv` | **Iron** · S01E06 · "Mellow Quarry" · 1994  ·  episode |
| `Plush (2014)/Season 3/Episode 2 Crimson Cinder.mkv` | **Plush** · S03E02 · "Crimson Cinder" · 2014  ·  episode |
| `Lantern under the Quarry (2002)/Season 4/Episode 12 Drifting Cinder.mkv` | **Lantern under the Quarry** · S04E12 · "Drifting Cinder" · 2002  ·  episode |

#### `tv_dash_eptitle` — Curated ` - SxxExx - Title` naming

<sub>3,095 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Restless Harbor/Season 7/Restless Harbor - S07E08 - Lunar Verdict.mkv` | **Restless Harbor** · S07E08 · "Lunar Verdict"  ·  episode |
| `Brisk/Season 1/Brisk - S01E08 - Crimson Vortex.mkv` | **Brisk** · S01E08 · "Crimson Vortex"  ·  episode |
| `Cobalt/Season 2/Cobalt - S02E19 - Mellow Maelstrom.mkv` | **Cobalt** · S02E19 · "Mellow Maelstrom"  ·  episode |
| `Amber Bastion/Season 4/Amber Bastion - S04E06 - Mellow Monolith.mkv` | **Amber Bastion** · S04E06 · "Mellow Monolith"  ·  episode |
| `Verdict beyond the Meadow/Season 4/Verdict beyond the Meadow - S04E17 - Iron Harbor.mkv` | **Verdict beyond the Meadow** · S04E17 · "Iron Harbor"  ·  episode |
| `Marble/Season 5/Marble - S05E12 - Iron Lantern.mkv` | **Marble** · S05E12 · "Iron Lantern"  ·  episode |
| `Crimson Tempest/Season 4/Crimson Tempest - S04E05 - Hollow Nimbus.mkv` | **Crimson Tempest** · S04E05 · "Hollow Nimbus"  ·  episode |
| `Crimson Vortex/Season 8/Crimson Vortex - S08E11 - Cobalt Reverie.mkv` | **Crimson Vortex** · S08E11 · "Cobalt Reverie"  ·  episode |
| `Foundry and the Meadow/Season 7/Foundry and the Meadow - S07E12 - Savage Harbor.mkv` | **Foundry and the Meadow** · S07E12 · "Savage Harbor"  ·  episode |
| `Cobalt Cavern/Season 8/Cobalt Cavern - S08E19 - Velvet Lantern.mkv` | **Cobalt Cavern** · S08E19 · "Velvet Lantern"  ·  episode |

#### `tv_nxnn` — `NxNN` form (space-delimited)

<sub>3,137 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Gilded/Season 5/Gilded 5x21.mkv` | **Gilded** · S05E21  ·  episode |
| `Solemn Cinder/Season 2/Solemn Cinder 2x16.mkv` | **Solemn Cinder** · S02E16  ·  episode |
| `Tempest beyond the Halcyon/Season 9/Tempest beyond the Halcyon 9x11.mkv` | **Tempest beyond the Halcyon** · S09E11  ·  episode |
| `Savage/Season 2/Savage 2x17.mkv` | **Savage** · S02E17  ·  episode |
| `Verdant Plinth/Season 1/Verdant Plinth 1x15.mkv` | **Verdant Plinth** · S01E15  ·  episode |
| `Cobalt Orchard/Season 2/Cobalt Orchard 2x26.mkv` | **Cobalt Orchard** · S02E26  ·  episode |
| `Frantic Plinth/Season 3/Frantic Plinth 3x19.mkv` | **Frantic Plinth** · S03E19  ·  episode |
| `Opal Lantern/Season 5/Opal Lantern 5x24.mkv` | **Opal Lantern** · S05E24  ·  episode |
| `Restless Quarry/Season 9/Restless Quarry 9x25.mkv` | **Restless Quarry** · S09E25  ·  episode |
| `Rabid Orchard/Season 9/Rabid Orchard 9x17.mkv` | **Rabid Orchard** · S09E17  ·  episode |

#### `tv_lowercase_marker` — `s01e05` / `5x09` lowercase + dotted

<sub>3,003 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Tempest in the Halcyon/Season 2/Tempest in the Halcyon.2x02.mkv` | **Tempest in the Halcyon** · S02E02  ·  episode |
| `Solemn Estuary/Season 7/Solemn Estuary.7x08.mkv` | **Solemn Estuary** · S07E08  ·  episode |
| `Opal Pinnacle/Season 2/Opal.Pinnacle.s02e12.mkv` | **Opal Pinnacle** · S02E12  ·  episode |
| `Stark Verdict/Season 8/Stark.Verdict.s08e12.mkv` | **Stark Verdict** · S08E12  ·  episode |
| `Savage Cipher/Season 1/Savage Cipher.1x20.mkv` | **Savage Cipher** · S01E20  ·  episode |
| `Amber/Season 6/Amber.6x03.mkv` | **Amber** · S06E03  ·  episode |
| `Estuary and the Requiem/Season 5/Estuary.and.the.Requiem.5x10.mkv` | **Estuary and the Requiem** · S05E10  ·  episode |
| `Estuary and the Cipher/Season 1/Estuary and the Cipher.1x07.mkv` | **Estuary and the Cipher** · S01E07  ·  episode |
| `Foundry beyond the Zephyr/Season 6/Foundry_beyond_the_Zephyr.6x14.mkv` | **Foundry beyond the Zephyr** · S06E14  ·  episode |
| `Brisk/Season 1/Brisk.1x06.mkv` | **Brisk** · S01E06  ·  episode |

#### `tv_multiep_range` — Multi-episode range `S01E05-E06`

<sub>3,229 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Hollow Maelstrom/Season 4/Hollow.Maelstrom.S04E03-E04.1080p.mkv` | **Hollow Maelstrom** · S04E03  ·  episode |
| `Marble Cinder/Season 5/Marble Cinder.S05E15-E16.1080p.mkv` | **Marble Cinder** · S05E15  ·  episode |
| `Rabid Beacon/Season 8/Rabid.Beacon.S08E09-E10.1080p.mkv` | **Rabid Beacon** · S08E09  ·  episode |
| `Solemn Halcyon/Season 2/Solemn_Halcyon.S02E08-E09.1080p.mkv` | **Solemn Halcyon** · S02E08  ·  episode |
| `Velvet/Season 4/Velvet.S04E01-E02.1080p.mkv` | **Velvet** · S04E01  ·  episode |
| `Stark Zephyr/Season 4/Stark Zephyr.S04E15-E16.1080p.mkv` | **Stark Zephyr** · S04E15  ·  episode |
| `Stark Sojourn/Season 4/Stark_Sojourn.S04E08-E09.1080p.mkv` | **Stark Sojourn** · S04E08  ·  episode |
| `Orchard of the Vortex/Season 1/Orchard_of_the_Vortex.S01E02-E03.1080p.mkv` | **Orchard of the Vortex** · S01E02  ·  episode |
| `Gilded Monolith/Season 8/Gilded.Monolith.S08E16-E17.1080p.mkv` | **Gilded Monolith** · S08E16  ·  episode |
| `Brisk Nimbus/Season 5/Brisk_Nimbus.S05E04-E05.1080p.mkv` | **Brisk Nimbus** · S05E04  ·  episode |

#### `tv_3digit_ep` — High episode numbers `S01E105`

<sub>3,223 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Savage/Season 5/Savage.S05E243.mkv` | **Savage** · S05E243  ·  episode |
| `Drifting Thicket/Season 6/Drifting Thicket.S06E128.mkv` | **Drifting Thicket** · S06E128  ·  episode |
| `Mellow Orchard/Season 6/Mellow.Orchard.S06E150.mkv` | **Mellow Orchard** · S06E150  ·  episode |
| `Sojourn in the Orchard/Season 8/Sojourn in the Orchard.S08E258.mkv` | **Sojourn in the Orchard** · S08E258  ·  episode |
| `Cavern under the Sojourn/Season 4/Cavern.under.the.Sojourn.S04E297.mkv` | **Cavern under the Sojourn** · S04E297  ·  episode |
| `Plinth without a Estuary/Season 4/Plinth.without.a.Estuary.S04E253.mkv` | **Plinth without a Estuary** · S04E253  ·  episode |
| `Amber Harbor/Season 5/Amber Harbor.S05E251.mkv` | **Amber Harbor** · S05E251  ·  episode |
| `Lunar Plinth/Season 2/Lunar_Plinth.S02E188.mkv` | **Lunar Plinth** · S02E188  ·  episode |
| `Plinth without a Beacon/Season 2/Plinth_without_a_Beacon.S02E175.mkv` | **Plinth without a Beacon** · S02E175  ·  episode |
| `Opal Harbor/Season 2/Opal.Harbor.S02E190.mkv` | **Opal Harbor** · S02E190  ·  episode |

#### `tv_multiseason_pack` — Multi-season pack folder, file SxxExx wins

<sub>3,088 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Languid Estuary/Seasons 1-8/Languid.Estuary.S01E12.720p.mkv` | **Languid Estuary** · S01E12  ·  episode |
| `Cipher and the Lantern/Seasons 1-8/Cipher and the Lantern.S03E04.720p.mkv` | **Cipher and the Lantern** · S03E04  ·  episode |
| `Solemn/Seasons 1-8/Solemn.S02E05.720p.mkv` | **Solemn** · S02E05  ·  episode |
| `Opal Cipher/Seasons 1-8/Opal_Cipher.S06E13.720p.mkv` | **Opal Cipher** · S06E13  ·  episode |
| `Crimson Pinnacle/Seasons 1-8/Crimson.Pinnacle.S03E20.720p.mkv` | **Crimson Pinnacle** · S03E20  ·  episode |
| `Halcyon of the Beacon/Seasons 1-8/Halcyon_of_the_Beacon.S04E14.720p.mkv` | **Halcyon of the Beacon** · S04E14  ·  episode |
| `Velvet Orchard/Seasons 1-8/Velvet Orchard.S03E15.720p.mkv` | **Velvet Orchard** · S03E15  ·  episode |
| `Requiem of the Verdict/Seasons 1-8/Requiem of the Verdict.S05E18.720p.mkv` | **Requiem of the Verdict** · S05E18  ·  episode |
| `Rabid Orchard/Seasons 1-8/Rabid Orchard.S01E01.720p.mkv` | **Rabid Orchard** · S01E01  ·  episode |
| `Estuary and the Beacon/Seasons 1-8/Estuary_and_the_Beacon.S07E20.720p.mkv` | **Estuary and the Beacon** · S07E20  ·  episode |

#### `tv_specials` — `Specials/` folder → season 0

<sub>3,112 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Savage Zephyr (2007)/Specials/Savage Zephyr.S00E11.mkv` | **Savage Zephyr** · S00E11 · 2007  ·  episode |
| `Crimson (1995)/Specials/Crimson.S00E03.mkv` | **Crimson** · S00E03 · 1995  ·  episode |
| `Mellow Estuary (2008)/Specials/Mellow_Estuary.S00E09.mkv` | **Mellow Estuary** · S00E09 · 2008  ·  episode |
| `Languid Cavern (2011)/Specials/Languid Cavern.S00E07.mkv` | **Languid Cavern** · S00E07 · 2011  ·  episode |
| `Gilded Pinnacle (2011)/Specials/Gilded Pinnacle.S00E11.mkv` | **Gilded Pinnacle** · S00E11 · 2011  ·  episode |
| `Requiem without a Reverie (2023)/Specials/Requiem without a Reverie.S00E12.mkv` | **Requiem without a Reverie** · S00E12 · 2023  ·  episode |
| `Cobalt Reverie (2013)/Specials/Cobalt.Reverie.S00E08.mkv` | **Cobalt Reverie** · S00E08 · 2013  ·  episode |
| `Savage Halcyon (2012)/Specials/Savage.Halcyon.S00E08.mkv` | **Savage Halcyon** · S00E08 · 2012  ·  episode |
| `Brisk Tempest (2007)/Specials/Brisk.Tempest.S00E09.mkv` | **Brisk Tempest** · S00E09 · 2007  ·  episode |
| `Orchard without a Harbor (2006)/Specials/Orchard.without.a.Harbor.S00E09.mkv` | **Orchard without a Harbor** · S00E09 · 2006  ·  episode |

#### `date_episode` — Date-stamped daily `YYYY-MM-DD`

<sub>3,184 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Vortex without a Pinnacle/2024-03-05.mkv` | **Vortex without a Pinnacle** · S2024E305  ·  episode |
| `Savage Meadow/2004-10-23.mkv` | **Savage Meadow** · S2004E1023  ·  episode |
| `Marble Monolith/2010-10-15.mkv` | **Marble Monolith** · S2010E1015  ·  episode |
| `Bastion under the Foundry/2005-08-17.mkv` | **Bastion under the Foundry** · S2005E817  ·  episode |
| `Mellow Zephyr/2002-06-02.mkv` | **Mellow Zephyr** · S2002E602  ·  episode |
| `Quiet Nimbus/2018-08-19.mkv` | **Quiet Nimbus** · S2018E819  ·  episode |
| `Opal Harbor/2012-09-28.mkv` | **Opal Harbor** · S2012E928  ·  episode |
| `Cinder of the Bastion/2007-05-12.mkv` | **Cinder of the Bastion** · S2007E512  ·  episode |
| `Foundry beyond the Vortex/2015-06-16.mkv` | **Foundry beyond the Vortex** · S2015E616  ·  episode |
| `Wary/2020-07-04.mkv` | **Wary** · S2020E704  ·  episode |

#### `anime_absolute` — Absolute-numbered anime `Series - 1071`

<sub>3,137 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Anime/Mellow Lantern/[Erai] Mellow Lantern - 984 [1080p].mkv` | **Mellow Lantern** · S01E984  ·  episode |
| `Anime/Frantic Pinnacle/[FLUX] Frantic Pinnacle - 982 [1080p].mkv` | **Frantic Pinnacle** · S01E982  ·  episode |
| `Anime/Brisk Foundry/[Erai] Brisk Foundry - 742 [1080p].mkv` | **Brisk Foundry** · S01E742  ·  episode |
| `Anime/Verdant/[GROUP] Verdant - 728 [1080p].mkv` | **Verdant** · S01E728  ·  episode |
| `Anime/Quiet Harbor/[GROUP] Quiet Harbor - 695 [1080p].mkv` | **Quiet Harbor** · S01E695  ·  episode |
| `Anime/Frantic Reverie/[FLUX] Frantic Reverie - 989 [1080p].mkv` | **Frantic Reverie** · S01E989  ·  episode |
| `Anime/Drifting/[YTS] Drifting - 394 [1080p].mkv` | **Drifting** · S01E394  ·  episode |
| `Anime/Nimbus without a Requiem/[FLUX] Nimbus without a Requiem - 149 [1080p].mkv` | **Nimbus without a Requiem** · S01E149  ·  episode |
| `Anime/Amber Beacon/[RARBG] Amber Beacon - 377 [1080p].mkv` | **Amber Beacon** · S01E377  ·  episode |
| `Anime/Amber Lantern/[pcela] Amber Lantern - 391 [1080p].mkv` | **Amber Lantern** · S01E391  ·  episode |

### Extras & bonus content

#### `extras` — Movie featurette/trailer nested under its title

<sub>3,137 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Rabid Estuary (1971)/Behind the Scenes/Plush Zephyr.1080p.mkv` | extra of **Rabid Estuary** |
| `Movies/Wary Nimbus (1966)/Behind the Scenes/Feral Foundry.1080p.mkv` | extra of **Wary Nimbus** |
| `Movies/Drifting (2025)/Interviews/Lunar.1080p.mkv` | extra of **Drifting** |
| `Movies/Verdict without a Lantern (2009)/Trailers/Zephyr beyond the Plinth.1080p.mkv` | extra of **Verdict without a Lantern** |
| `Movies/Opal (1960)/Featurettes/Savage.1080p.mkv` | extra of **Opal** |
| `Movies/Cobalt Pinnacle (2012)/Trailers/Monolith of the Monolith.1080p.mkv` | extra of **Cobalt Pinnacle** |
| `Movies/Quarry of the Estuary (2017)/Featurettes/Languid Orchard.1080p.mkv` | extra of **Quarry of the Estuary** |
| `Movies/Brisk Reverie (1972)/Interviews/Sojourn under the Foundry.1080p.mkv` | extra of **Brisk Reverie** |
| `Movies/Crimson Foundry (1997)/Behind the Scenes/Hollow Estuary.1080p.mkv` | extra of **Crimson Foundry** |
| `Movies/Restless Cinder (1982)/Behind the Scenes/Thicket beyond the Pinnacle.1080p.mkv` | extra of **Restless Cinder** |

#### `show_extras` — Show extras attach to the series, not a phantom movie

<sub>3,242 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `TV/Gilded Verdict/Season 1-8 S01-S08 (1080p)/Featurettes/Reverie in the Quarry.mkv` | extra of **Gilded Verdict** |
| `TV/Savage Halcyon/Season 1-8 S01-S08 (1080p)/Behind the Scenes/Hollow Harbor.mkv` | extra of **Savage Halcyon** |
| `TV/Brittle Cinder/Season 1-8 S01-S08 (1080p)/Behind the Scenes/Velvet.mkv` | extra of **Brittle Cinder** |
| `TV/Requiem in the Pinnacle/Season 1-8 S01-S08 (1080p)/Featurettes/Vortex in the Monolith.mkv` | extra of **Requiem in the Pinnacle** |
| `TV/Verdant Beacon/Season 1-8 S01-S08 (1080p)/Featurettes/Quarry beyond the Maelstrom.mkv` | extra of **Verdant Beacon** |
| `TV/Cavern under the Cipher/Season 1-8 S01-S08 (1080p)/Featurettes/Hollow Orchard.mkv` | extra of **Cavern under the Cipher** |
| `TV/Hollow/Season 1-8 S01-S08 (1080p)/Deleted Scenes/Cobalt Foundry.mkv` | extra of **Hollow** |
| `TV/Frantic/Season 1-8 S01-S08 (1080p)/Featurettes/Marble.mkv` | extra of **Frantic** |
| `TV/Harbor and the Vortex/Season 1-8 S01-S08 (1080p)/Deleted Scenes/Solemn.mkv` | extra of **Harbor and the Vortex** |
| `TV/Maelstrom without a Zephyr/Season 1-8 S01-S08 (1080p)/Deleted Scenes/Beacon of the Cipher.mkv` | extra of **Maelstrom without a Zephyr** |

### Tough mode — punctuation, scripts, length

#### `movie_tough_punct` — Ampersands, colons, commas, `'s`, `Part N`, roman numerals

<sub>3,190 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Requiem - Velvet Thicket (2003)/비밀.2003.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **Requiem - Velvet Thicket** · 2003  ·  movie |
| `Movies/Plinth III (1983)/流星.1983.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **Plinth III** · 1983  ·  movie |
| `Movies/Hollow Beacon Part 7 (1981)/映画祭.1981.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **Hollow Beacon Part 7** · 1981  ·  movie |
| `Movies/Zephyr's Maelstrom (2008)/비밀.2008.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **Zephyr's Maelstrom** · 2008  ·  movie |
| `Movies/Hollow Quarry Part 7 (2019)/비밀.2019.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **Hollow Quarry Part 7** · 2019  ·  movie |
| `Movies/Lunar Halcyon Vol. 5 (2012)/Тачки.2012.2160p.UHD.BluRay.x265-FGT.mkv.strm` | **Lunar Halcyon Vol. 5** · 2012  ·  movie |
| `Movies/Plush Halcyon Vol. 2 (2003)/春の嵐.2003.2160p.UHD.BluRay.x265-NTb.mkv.strm` | **Plush Halcyon Vol. 2** · 2003  ·  movie |
| `Movies/Brisk & Pinnacle (2019)/春の嵐.2019.2160p.UHD.BluRay.x265-RARBG.mkv.strm` | **Brisk & Pinnacle** · 2019  ·  movie |
| `Movies/Crimson Foundry Vol. 6 (1971)/비밀.1971.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **Crimson Foundry Vol. 6** · 1971  ·  movie |
| `Movies/Velvet Cipher, Meadow (1956)/폭풍.1956.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **Velvet Cipher, Meadow** · 1956  ·  movie |

#### `movie_long_title` — 6–9 word titles with stop-words

<sub>3,090 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Opal Harbor Maelstrom Velvet beyond Cavern (1963)/流星.1963.2160p.UHD.BluRay.x265-pcela.mkv.strm` | **Opal Harbor Maelstrom Velvet beyond Cavern** · 1963  ·  movie |
| `Movies/Cobalt Vortex beneath Meadow Quarry Feral Thicket Cavern (1986)/映画祭.1986.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **Cobalt Vortex beneath Meadow Quarry Feral Thicket Cavern** · 1986  ·  movie |
| `Movies/Verdant Verdict Savage Frantic under Quiet (2006)/映画祭.2006.2160p.UHD.BluRay.x265-FLUX.mkv.strm` | **Verdant Verdict Savage Frantic under Quiet** · 2006  ·  movie |
| `Movies/Brittle Estuary of Languid Cipher the Harbor Wary (2017)/流星.2017.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **Brittle Estuary of Languid Cipher the Harbor Wary** · 2017  ·  movie |
| `Movies/Frantic Zephyr Nimbus Quiet beneath Wary without (1950)/春の嵐.1950.2160p.UHD.BluRay.x265-RARBG.mkv.strm` | **Frantic Zephyr Nimbus Quiet beneath Wary without** · 1950  ·  movie |
| `Movies/Hollow Cavern under beyond Rabid Meadow the Orchard Solemn (1970)/Вихрь.1970.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **Hollow Cavern under beyond Rabid Meadow the Orchard Solemn** · 1970  ·  movie |
| `Movies/Lunar Vortex the Lantern Bastion without and Savage (2000)/Метель.2000.2160p.UHD.BluRay.x265-FLUX.mkv.strm` | **Lunar Vortex the Lantern Bastion without and Savage** · 2000  ·  movie |
| `Movies/Brittle Meadow Halcyon the Thicket and under (1988)/Тачки.1988.2160p.UHD.BluRay.x265-FGT.mkv.strm` | **Brittle Meadow Halcyon the Thicket and under** · 1988  ·  movie |
| `Movies/Feral Harbor Halcyon Halcyon Drifting the Brisk (1979)/비밀.1979.2160p.UHD.BluRay.x265-YTS.mkv.strm` | **Feral Harbor Halcyon Halcyon Drifting the Brisk** · 1979  ·  movie |
| `Movies/Brittle Verdict Velvet Foundry Savage beyond Thicket Solemn (1950)/비밀.1950.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **Brittle Verdict Velvet Foundry Savage beyond Thicket Solemn** · 1950  ·  movie |

#### `movie_cjk` — CJK (Japanese/Chinese) titles

<sub>3,066 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/鋼の錬金物語 (1988)/春の嵐.1988.2160p.UHD.BluRay.x265-FGT.mkv.strm` | **鋼の錬金物語** · 1988  ·  movie |
| `Movies/春の嵐 (1956)/流星.1956.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **春の嵐** · 1956  ·  movie |
| `Movies/沈黙の海 (2021)/Тачки.2021.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **沈黙の海** · 2021  ·  movie |
| `Movies/百年の孤独風 (2013)/비밀.2013.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **百年の孤独風** · 2013  ·  movie |
| `Movies/流星物語 (1956)/Вихрь.1956.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **流星物語** · 1956  ·  movie |
| `Movies/千年女優夢 (1988)/春の嵐.1988.2160p.UHD.BluRay.x265-FLUX.mkv.strm` | **千年女優夢** · 1988  ·  movie |
| `Movies/千年女優夢 (1987)/映画祭.1987.2160p.UHD.BluRay.x265-pcela.mkv.strm` | **千年女優夢** · 1987  ·  movie |
| `Movies/春の嵐 (2024)/春の嵐.2024.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **春の嵐** · 2024  ·  movie |
| `Movies/東京暮色 (1978)/Метель.1978.2160p.UHD.BluRay.x265-SPARKS.mkv.strm` | **東京暮色** · 1978  ·  movie |
| `Movies/春の嵐 (1954)/Тачки.1954.2160p.UHD.BluRay.x265-FGT.mkv.strm` | **春の嵐** · 1954  ·  movie |

#### `movie_cyrillic` — Cyrillic titles

<sub>3,083 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/Тайна Старого Маяка (1999)/Тачки.1999.2160p.UHD.BluRay.x265-pcela.mkv.strm` | **Тайна Старого Маяка** · 1999  ·  movie |
| `Movies/Полночный Экспресс (1969)/Метель.1969.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **Полночный Экспресс** · 1969  ·  movie |
| `Movies/Вихрь Теней (2006)/流星.2006.2160p.UHD.BluRay.x265-RARBG.mkv.strm` | **Вихрь Теней** · 2006  ·  movie |
| `Movies/Метель и Пламя (2003)/映画祭.2003.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **Метель и Пламя** · 2003  ·  movie |
| `Movies/Тихий Дозор Зимы (1995)/Вихрь.1995.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **Тихий Дозор Зимы** · 1995  ·  movie |
| `Movies/Тихий Дозор Зимы (2010)/流星.2010.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **Тихий Дозор Зимы** · 2010  ·  movie |
| `Movies/Сердце Бури (1999)/Метель.1999.2160p.UHD.BluRay.x265-NTb.mkv.strm` | **Сердце Бури** · 1999  ·  movie |
| `Movies/Тихий Дозор Зимы (1990)/Метель.1990.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **Тихий Дозор Зимы** · 1990  ·  movie |
| `Movies/Тихий Дозор Зимы (1985)/春の嵐.1985.2160p.UHD.BluRay.x265-YTS.mkv.strm` | **Тихий Дозор Зимы** · 1985  ·  movie |
| `Movies/Полночный Экспресс (1962)/Тачки.1962.2160p.UHD.BluRay.x265-NTb.mkv.strm` | **Полночный Экспресс** · 1962  ·  movie |

#### `movie_allcaps` — ALL-CAPS titles

<sub>3,161 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `Movies/MARBLE CIPHER (1986)/Тачки.1986.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **MARBLE CIPHER** · 1986  ·  movie |
| `Movies/AMBER VERDICT (2021)/流星.2021.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **AMBER VERDICT** · 2021  ·  movie |
| `Movies/COBALT FOUNDRY (2007)/春の嵐.2007.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **COBALT FOUNDRY** · 2007  ·  movie |
| `Movies/AMBER SOJOURN (1975)/폭풍.1975.2160p.UHD.BluRay.x265-Erai.mkv.strm` | **AMBER SOJOURN** · 1975  ·  movie |
| `Movies/MARBLE MONOLITH (1963)/映画祭.1963.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **MARBLE MONOLITH** · 1963  ·  movie |
| `Movies/HOLLOW REQUIEM (1990)/Вихрь.1990.2160p.UHD.BluRay.x265-CMRG.mkv.strm` | **HOLLOW REQUIEM** · 1990  ·  movie |
| `Movies/HOLLOW TEMPEST (1954)/비밀.1954.2160p.UHD.BluRay.x265-GROUP.mkv.strm` | **HOLLOW TEMPEST** · 1954  ·  movie |
| `Movies/LUNAR SOJOURN (1999)/Вихрь.1999.2160p.UHD.BluRay.x265-FLUX.mkv.strm` | **LUNAR SOJOURN** · 1999  ·  movie |
| `Movies/DRIFTING TEMPEST (1990)/映画祭.1990.2160p.UHD.BluRay.x265-NTb.mkv.strm` | **DRIFTING TEMPEST** · 1990  ·  movie |
| `Movies/WARY SOJOURN (2025)/Тачки.2025.2160p.UHD.BluRay.x265-pcela.mkv.strm` | **WARY SOJOURN** · 2025  ·  movie |

#### `movie_mixed_script` — Foreign folder + foreign filename, both carry the year

<sub>3,034 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `媒体/紅の翼 (2013)/Тачки 2013 WEBRip.mkv` | **紅の翼** · 2013  ·  movie |
| `媒体/Вихрь Теней (1997)/폭풍 1997 WEBRip.mkv` | **Вихрь Теней** · 1997  ·  movie |
| `媒体/百年の孤独風 (2017)/비밀 2017 WEBRip.mkv` | **百年の孤独風** · 2017  ·  movie |
| `媒体/Север Зовёт (1999)/春の嵐 1999 WEBRip.mkv` | **Север Зовёт** · 1999  ·  movie |
| `媒体/Тихий Дозор Зимы (2019)/映画祭 2019 WEBRip.mkv` | **Тихий Дозор Зимы** · 2019  ·  movie |
| `媒体/東京暮色 (2015)/비밀 2015 WEBRip.mkv` | **東京暮色** · 2015  ·  movie |
| `媒体/Вихрь Теней (1992)/Тачки 1992 WEBRip.mkv` | **Вихрь Теней** · 1992  ·  movie |
| `媒体/Тихий Дозор Зимы (1980)/春の嵐 1980 WEBRip.mkv` | **Тихий Дозор Зимы** · 1980  ·  movie |
| `媒体/Сердце Бури (2001)/폭풍 2001 WEBRip.mkv` | **Сердце Бури** · 2001  ·  movie |
| `媒体/鋼の錬金物語 (2013)/映画祭 2013 WEBRip.mkv` | **鋼の錬金物語** · 2013  ·  movie |

#### `tv_tough_series` — Punctuation-heavy series name from the folder

<sub>3,107 cases in the headline run · 0 misses</sub>

| Input path | Parsed as |
|---|---|
| `TV/Marble Cinder, Verdict (2025)/Season 4/ep.S04E18.1080p.WEB-DL.mkv` | **Marble Cinder, Verdict** · S04E18 · 2025  ·  episode |
| `TV/Plinth V (2014)/Season 8/ep.S08E06.1080p.WEB-DL.mkv` | **Plinth V** · S08E06 · 2014  ·  episode |
| `TV/Maelstrom's Quarry (1992)/Season 8/ep.S08E08.1080p.WEB-DL.mkv` | **Maelstrom's Quarry** · S08E08 · 1992  ·  episode |
| `TV/Nimbus IV (2025)/Season 8/ep.S08E10.1080p.WEB-DL.mkv` | **Nimbus IV** · S08E10 · 2025  ·  episode |
| `TV/Foundry: Restless Orchard (2002)/Season 8/ep.S08E19.1080p.WEB-DL.mkv` | **Foundry: Restless Orchard** · S08E19 · 2002  ·  episode |
| `TV/Iron Bastion, Vortex (1987)/Season 4/ep.S04E15.1080p.WEB-DL.mkv` | **Iron Bastion, Vortex** · S04E15 · 1987  ·  episode |
| `TV/Halcyon: Restless Maelstrom (2021)/Season 5/ep.S05E04.1080p.WEB-DL.mkv` | **Halcyon: Restless Maelstrom** · S05E04 · 2021  ·  episode |
| `TV/Wary Verdict Vol. 6 (2011)/Season 3/ep.S03E14.1080p.WEB-DL.mkv` | **Wary Verdict Vol. 6** · S03E14 · 2011  ·  episode |
| `TV/Amber & Cinder (1991)/Season 3/ep.S03E16.1080p.WEB-DL.mkv` | **Amber & Cinder** · S03E16 · 1991  ·  episode |
| `TV/Iron Quarry, Maelstrom (1986)/Season 4/ep.S04E19.1080p.WEB-DL.mkv` | **Iron Quarry, Maelstrom** · S04E19 · 1986  ·  episode |

---

<sub>Generated by the parser fuzz harness · 500,000 paths ·
32 families · 0 misses · seed-reproducible.</sub>
