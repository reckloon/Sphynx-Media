import Testing
@testable import SphynxServer

/// Folder-aware parsing across the structure variants a real library throws at
/// us. Kept lean: one case per behaviour that matters, not exhaustive.
@Suite("PathParser (folder-aware)")
struct PathParserTests {
    // MARK: Movies

    @Test("movie identity comes from the folder, not a foreign filename")
    func folderWinsOverForeignFilename() {
        // The folder is the clean English title; the file is Russian + release junk.
        let p = PathParser.parse("Movies/Cars (2006)/Тачки.2006.Hybrid.UHD.Blu-Ray.Remux.2160p.mkv.strm")
        #expect(p == .movie(title: "Cars", year: 2006))
    }

    @Test("folder punctuation is preserved (dashes kept)")
    func folderPunctuationPreserved() {
        let p = PathParser.parse("Movies/Rogue One - A Star Wars Story (2016)/whatever.release.tag.mkv.strm")
        #expect(p == .movie(title: "Rogue One - A Star Wars Story", year: 2016))
    }

    @Test("a generic parent folder falls back to filename parsing")
    func genericFolderFallsBack() {
        let p = PathParser.parse("Movies/Arrival.2016.2160p.HDR.mkv")
        #expect(p == .movie(title: "Arrival", year: 2016))
    }

    // MARK: TV — season/episode detection across structures

    @Test("series + season folder + SxxExx file")
    func seasonFolderWithMarker() {
        let p = PathParser.parse("Friends (1994)/Season 2/Friends.S02E01.mkv")
        #expect(p == .episode(series: "Friends", season: 2, episode: 1, episodeTitle: nil, year: 1994))
    }

    @Test("loose episode number in a season folder (no SxxExx)")
    func looseEpisodeFromFolder() {
        let p = PathParser.parse("Friends/Season 1/Ep 01.mkv")
        #expect(p == .episode(series: "Friends", season: 1, episode: 1, episodeTitle: nil, year: nil))
    }

    @Test("loose 'Episode N Title' keeps the title (Scooby-Doo style)")
    func looseEpisodeWithTitle() {
        let p = PathParser.parse("Scooby-Doo! Mystery Incorporated (2010)/Season 1/Episode 1 Beware the Beast from Below.mp4.strm")
        #expect(p == .episode(series: "Scooby-Doo! Mystery Incorporated", season: 1, episode: 1,
                              episodeTitle: "Beware the Beast from Below", year: 2010))
    }

    @Test("a straight episode file with no season folder")
    func straightEpisodeFile() {
        let p = PathParser.parse("Friends.S01E02.mkv")
        #expect(p == .episode(series: "Friends", season: 1, episode: 2, episodeTitle: nil, year: nil))
    }

    @Test("multi-season folder: the SxxExx in the filename wins for the season")
    func multiSeasonFolderMarkerWins() {
        let p = PathParser.parse("Friends/Seasons 1-3/Friends.S02E05.mkv")
        #expect(p == .episode(series: "Friends", season: 2, episode: 5, episodeTitle: nil, year: nil))
    }

    @Test("season-folder naming variants all resolve")
    func seasonFolderVariants() {
        let variants = ["Season 2", "Season 02", "S2", "S02", "season 2", "Series 2"]
        for folder in variants {
            let p = PathParser.parse("Friends/\(folder)/Ep 3.mkv")
            #expect(p == .episode(series: "Friends", season: 2, episode: 3, episodeTitle: nil, year: nil),
                    "variant '\(folder)' should give season 2")
        }
    }

    @Test("curated ' - SxxExx - Title' yields a clean episode title")
    func curatedEpisodeTitle() {
        let p = PathParser.parse("Game of Thrones (2011)/Season 1/Game of Thrones - S01E01 - Winter Is Coming [2160p] [HDR].mkv.strm")
        #expect(p == .episode(series: "Game of Thrones", season: 1, episode: 1,
                              episodeTitle: "Winter Is Coming", year: 2011))
    }

    @Test("a dotted release tail is not mistaken for an episode title")
    func dottedTailIsNotATitle() {
        // Only language/resolution tags follow the marker → fall back to Episode N.
        let p = PathParser.parse("The Boys (2019)/Season 2/The.Boys.S02E01.2160p.AMZN.WEB-DL.mkv.strm")
        #expect(p == .episode(series: "The Boys", season: 2, episode: 1, episodeTitle: nil, year: 2019))
    }

    @Test("Cyrillic series title in the filename passes through when there's no folder")
    func unicodeSeriesFromFilename() {
        let p = PathParser.parse("Тед Лассо.S01E01.WEB-DL.2160p.mkv.strm")
        #expect(p == .episode(series: "Тед Лассо", season: 1, episode: 1, episodeTitle: nil, year: nil))
    }

    @Test("a multi-episode file takes the first episode")
    func multiEpisodeFirstWins() {
        let p = PathParser.parse("Parks and Recreation (2009)/Season 6/Parks.and.Recreation.S06E01-02.mkv.strm")
        #expect(p == .episode(series: "Parks and Recreation", season: 6, episode: 1, episodeTitle: nil, year: 2009))
    }

    // MARK: - Localized library roots (folder language-agnostic)

    @Test("a localized library root is treated as a bucket, not the title")
    func localizedLibraryRoots() {
        // The root is the wrong title; the filename carries the real title + year.
        #expect(PathParser.parse("Фильмы/Тачки.2006.1080p.mkv") == .movie(title: "Тачки", year: 2006))
        #expect(PathParser.parse("映画/千と千尋の神隠し.2001.mkv") == .movie(title: "千と千尋の神隠し", year: 2001))
        #expect(PathParser.parse("Películas/Coco.2017.1080p.mkv") == .movie(title: "Coco", year: 2017))
    }

    @Test("an unlisted root with no year defers to a filename that has one")
    func unlistedBucketDefersToFilename() {
        // "Кинокартины" isn't in the bucket list; it carries no year and is
        // unrelated to the file's title, so the richer filename wins.
        let p = PathParser.parse("Кинокартины/Coco.2017.1080p.mkv")
        #expect(p == .movie(title: "Coco", year: 2017))
    }

    @Test("a yearless title folder borrows the year from the filename")
    func folderTitleBorrowsFileYear() {
        let p = PathParser.parse("Big Hero 6/Big.Hero.6.2014.1080p.mkv")
        #expect(p == .movie(title: "Big Hero 6", year: 2014))
    }

    @Test("a scene-style dotted release folder is cleaned like a filename")
    func dottedReleaseFolder() {
        let p = PathParser.parse("Cars.2006.1080p.BluRay.x264-GROUP/Cars.2006.1080p.BluRay.x264.mkv")
        #expect(p == .movie(title: "Cars", year: 2006))
    }

    // MARK: - Numeric / leading-year titles (flat files)

    @Test("a flat numeric-title file keeps the title and real year")
    func flatNumericTitle() {
        #expect(PathParser.parse("1917.2019.1080p.BluRay.x264.mkv") == .movie(title: "1917", year: 2019))
    }

    @Test("a movie ending in a number is not mistaken for an absolute episode")
    func numericMovieNotEpisode() {
        #expect(PathParser.parse("Blade Runner 2049 (2017).mkv") == .movie(title: "Blade Runner 2049", year: 2017))
        #expect(PathParser.parse("Ocean's 11 (2001)/Oceans.Eleven.2001.mkv") == .movie(title: "Ocean's 11", year: 2001))
    }

    // MARK: - Long-running / absolute / date-based episodes

    @Test("a 3-4 digit episode number is not truncated")
    func largeEpisodeNumber() {
        let p = PathParser.parse("One Piece/Season 1/One Piece.S01E1071.mkv")
        #expect(p == .episode(series: "One Piece", season: 1, episode: 1071, episodeTitle: nil, year: nil))
    }

    @Test("an absolute-numbered anime episode is detected")
    func absoluteEpisode() {
        // Flat (4-digit number is enough signal):
        #expect(PathParser.parse("One Piece - 1071.mkv")
            == .episode(series: "One Piece", season: 1, episode: 1071, episodeTitle: nil, year: nil))
        // With a fansub group tag, even a small number is recognised, tag dropped:
        #expect(PathParser.parse("[SubsPlease] One Piece - 1071 (1080p).mkv")
            == .episode(series: "One Piece", season: 1, episode: 1071, episodeTitle: nil, year: nil))
        // In a season folder, the folder supplies the season:
        #expect(PathParser.parse("One Piece/Season 1/One Piece - 1071.mkv")
            == .episode(series: "One Piece", season: 1, episode: 1071, episodeTitle: nil, year: nil))
    }

    @Test("a bare single-digit trailing number without TV signal stays a movie")
    func absoluteRequiresSignal() {
        // No season folder, no group tag, single digit → don't hijack as episode.
        if case .episode = PathParser.parse("Naruto - 5.mkv") {
            Issue.record("single-digit bare number should not be an absolute episode")
        }
    }

    @Test("a date-stamped daily episode is detected (season=year, episode=MMDD)")
    func dateStampedEpisode() {
        #expect(PathParser.parse("The Daily Show/2024-01-15.mkv")
            == .episode(series: "The Daily Show", season: 2024, episode: 115, episodeTitle: nil, year: nil))
        #expect(PathParser.parse("The.Daily.Show.2024.01.15.1080p.WEB.mkv")
            == .episode(series: "The Daily Show", season: 2024, episode: 115, episodeTitle: nil, year: nil))
    }

    // MARK: - Scene-release folders (raw downloads, not a curated library)

    @Test("a flat dotted scene pack gives a clean series title (cut at the marker)")
    func sceneSeriesDotted() {
        let p = PathParser.parse("Foundation.S01.2160p.Hybrid.ATVP.WEB-DL.DoVi.HDR10.HEVC-Rutracker/Foundation.S01E01.The.Emperors.Peace.2160p.WEB-DL.mkv.strm")
        #expect(p == .episode(series: "Foundation", season: 1, episode: 1, episodeTitle: nil, year: nil))
    }

    @Test("a space-delimited scene pack gives a clean series title")
    func sceneSeriesSpaced() {
        let p = PathParser.parse("The Boys S02 Eng Fre Ger Ita Por Spa WEBMux HDR10Plus DDP-SGF/The.Boys.S02E03.2160p.mkv.strm")
        #expect(p == .episode(series: "The Boys", season: 2, episode: 3, episodeTitle: nil, year: nil))
    }

    @Test("a dotted title before the marker isn't mistaken for a file extension")
    func sceneSeriesDottedTitleNotExtension() {
        // `The.Boys` must clean to `The Boys`, not `The` (`.Boys` is not an extension).
        let p = PathParser.parse("The.Boys.S01.2019.2160p.AMZN.WEB-DL/The.Boys.S01E01.2160p.AMZN.WEB-DL.mkv.strm")
        #expect(p == .episode(series: "The Boys", season: 1, episode: 1, episodeTitle: nil, year: nil))
    }

    @Test("an embedded 'Season N' folder with loose 'Episode N' is detected")
    func embeddedSeasonFolderLooseEpisode() {
        let p = PathParser.parse("Scooby-Doo! Mystery Incorporated Complete Season 1 (2010-11)/Episode 1 Beware the Beast from Below.mp4.strm")
        #expect(p == .episode(series: "Scooby-Doo! Mystery Incorporated", season: 1, episode: 1,
                              episodeTitle: "Beware the Beast from Below", year: nil))
    }

    @Test("a clean inner file wins over a junk scene movie folder")
    func sceneMoviePrefersCleanInnerFile() {
        let p = PathParser.parse("Big Hero 6 2014 UHD BluRay 2160p HDR10 DV HEVC TrueHD Atmos 7.1 x265-E/Big Hero 6 (2014).mkv.strm")
        #expect(p == .movie(title: "Big Hero 6", year: 2014))
    }

    @Test("a dotted scene movie folder is cleaned to title + year")
    func sceneMovieDotted() {
        let p = PathParser.parse("Тачки 2.2011.Hybrid.UHD.Blu-Ray.Remux.2160p/Тачки 2.2011.Hybrid.UHD.Blu-Ray.Remux.2160p.mkv.strm")
        #expect(p == .movie(title: "Тачки 2", year: 2011))
    }

    @Test("a stacked .mkv.strm container suffix never leaks into a clip title")
    func stackedExtensionStripped() {
        // This now classifies as a featurette (a bonus clip), not a movie; the
        // container suffix still must not leak into the clip's own title.
        let p = PathParser.parse("Some Show/Featurettes/Season 3/Get Your Cop On.mkv.strm")
        #expect(p == .extras(bucket: .featurette, parentTitle: "Some Show", parentYear: nil,
                             title: "Get Your Cop On"))  // not "Get Your Cop On mkv"
    }

    // MARK: - Extras / bonus content (nested under the enclosing title)

    @Test("a show featurette nests under the series, not a standalone movie")
    func showFeaturetteUnderSeries() {
        // The bug: this used to classify as a `.movie`. It must be a featurette
        // whose parent is the show above the bucket.
        let p = PathParser.parse("Some Show/Featurettes/Season 3/Get Your Cop On.mkv.strm")
        #expect(p == .extras(bucket: .featurette, parentTitle: "Some Show", parentYear: nil,
                             title: "Get Your Cop On"))
    }

    @Test("a movie extra names its parent movie (folder year → movie parent)")
    func movieExtraNamesParent() {
        let p = PathParser.parse("Sky Harbor (2020)/Extras/Making Of.mkv")
        #expect(p == .extras(bucket: .featurette, parentTitle: "Sky Harbor", parentYear: 2020,
                             title: "Making Of"))
    }

    @Test("each extras bucket maps to the right type")
    func extrasBucketTypeMapping() {
        #expect(PathParser.parse("Lantern Bay (2018)/Trailers/Teaser.mkv")
            == .extras(bucket: .trailer, parentTitle: "Lantern Bay", parentYear: 2018, title: "Teaser"))
        #expect(PathParser.parse("Lantern Bay (2018)/Deleted Scenes/Alternate Ending.mkv")
            == .extras(bucket: .deletedScene, parentTitle: "Lantern Bay", parentYear: 2018, title: "Alternate Ending"))
        #expect(PathParser.parse("Lantern Bay (2018)/Behind The Scenes/On Set.mkv")
            == .extras(bucket: .behindTheScenes, parentTitle: "Lantern Bay", parentYear: 2018, title: "On Set"))
        // Interviews / bonus collapse to the generic featurette type.
        #expect(PathParser.parse("Pinewood Hollow/Interviews/Director Chat.mkv")
            == .extras(bucket: .featurette, parentTitle: "Pinewood Hollow", parentYear: nil, title: "Director Chat"))
    }

    @Test("a real episode is unchanged — extras detection doesn't hijack a season tree")
    func episodeUnaffectedByExtras() {
        // The canonical curated layout must still classify as an episode.
        let p = PathParser.parse("Riverside (2017)/Season 2/Riverside - S02E03.mkv")
        #expect(p == .episode(series: "Riverside", season: 2, episode: 3, episodeTitle: nil, year: 2017))
    }

    @Test("a TV-pack's extras attach to the show, not a phantom movie (year dropped)")
    func showPackExtrasAttachToSeries() {
        // The enclosing folder carries a year AND season markers; left as-is the
        // year would route the clip to a phantom *movie* parent. The season markers
        // (and the clip's own episode marker) mark it a SHOW, so parentYear is nil
        // and the Indexer nests it under the series.
        let deleted = PathParser.parse(
            "Brooklyn Nine-Nine (2013) Season 1-8 S01-S08 (1080p)/Deleted Scenes/S01E21 Unsolvable.mkv")
        #expect(deleted == .extras(bucket: .deletedScene, parentTitle: "Brooklyn Nine-Nine",
                                   parentYear: nil, title: "S01E21 Unsolvable"))

        // A featurette with no episode marker still attaches via the folder's range.
        let feat = PathParser.parse(
            "Brooklyn Nine-Nine (2013) Season 1-8 S01-S08 (1080p)/Featurettes/Get Your Cop On.mkv")
        #expect(feat == .extras(bucket: .featurette, parentTitle: "Brooklyn Nine-Nine",
                                parentYear: nil, title: "Get Your Cop On"))

        // Regression: a genuine MOVIE's extras still keep their year (no season marker).
        let movie = PathParser.parse("Sky Harbor (2020)/Extras/Making Of.mkv")
        #expect(movie == .extras(bucket: .featurette, parentTitle: "Sky Harbor",
                                 parentYear: 2020, title: "Making Of"))
    }
}
