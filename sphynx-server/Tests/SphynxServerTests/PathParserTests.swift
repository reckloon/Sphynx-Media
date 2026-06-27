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
}
