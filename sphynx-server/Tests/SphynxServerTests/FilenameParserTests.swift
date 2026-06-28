import Testing
@testable import SphynxServer

@Suite("FilenameParser")
struct FilenameParserTests {
    @Test("dotted release name → clean title + year, junk stripped")
    func dottedRelease() {
        let p = FilenameParser.parse("The.Matrix.1999.1080p.BluRay.x264-GROUP.mkv")
        #expect(p.title == "The Matrix")
        #expect(p.year == 1999)
    }

    @Test("bracketed year and a year-like number in the title")
    func bracketedYear() {
        // 2049 is part of the title (and implausible as a year); 2017 is the release year.
        let p = FilenameParser.parse("Blade Runner 2049 (2017) [1080p].mp4")
        #expect(p.title == "Blade Runner 2049")
        #expect(p.year == 2017)
    }

    @Test("no year present")
    func noYear() {
        let p = FilenameParser.parse("Sintel.mp4")
        #expect(p.title == "Sintel")
        #expect(p.year == nil)
    }

    @Test("path components are ignored; only the filename matters")
    func pathStripped() {
        let p = FilenameParser.parse("movies/scifi/Arrival.2016.2160p.HDR.mkv")
        #expect(p.title == "Arrival")
        #expect(p.year == 2016)
    }

    @Test("underscores and mixed separators normalise to spaces")
    func separators() {
        let p = FilenameParser.parse("Spirited_Away_2001_BluRay.mkv")
        #expect(p.title == "Spirited Away")
        #expect(p.year == 2001)
    }

    @Test("a numeric-looking resolution is not mistaken for a year")
    func resolutionNotYear() {
        let p = FilenameParser.parse("BigBuckBunny_320x180.mp4")
        #expect(p.year == nil)  // 320x180 is not a 4-digit year token
    }

    @Test("a WxH resolution token is stripped from the title")
    func resolutionStripped() {
        let p = FilenameParser.parse("BigBuckBunny_1280x720.mp4")
        #expect(p.title == "BigBuckBunny")
        #expect(p.year == nil)
    }

    @Test("a numeric/leading-year title keeps the title and the real release year")
    func leadingYearTitle() {
        // The first year token is part of the title, not the boundary; the second
        // is the release year.
        let p = FilenameParser.parse("1917.2019.1080p.BluRay.x264.mkv")
        #expect(p.title == "1917")
        #expect(p.year == 2019)
    }

    @Test("a title that starts with a year and has no release year stays intact")
    func leadingYearNoRelease() {
        let p = FilenameParser.parse("2001 A Space Odyssey (1968).mkv")
        #expect(p.title == "2001 A Space Odyssey")
        #expect(p.year == 1968)
    }

    @Test("a single-word title that collides with junk vocabulary survives")
    func junkVocabularyTitle() {
        // "cam" is a release-source token, but here it's the whole title (Cam, 2018).
        let p = FilenameParser.parse("Cam.2018.1080p.WEB-DL.mkv")
        #expect(p.title == "Cam")
        #expect(p.year == 2018)
    }

    @Test("a leading [release-group] tag is stripped, not kept as the first word")
    func leadingGroupTag() {
        // Real-world scene/fansub naming: the `[pcela]` group tag must not become
        // part of the title (`pcela Suzume`), or the TMDB search misses.
        let p = FilenameParser.parse("[pcela] Suzume (2022) - [HKG UHD Bluray 2160p Remux][HDR10].mkv")
        #expect(p.title == "Suzume")
        #expect(p.year == 2022)
    }

    @Test("a name that is only a [group] tag keeps it rather than emptying the title")
    func bracketOnlyTitle() {
        let p = FilenameParser.parse("[OnlyTag].mkv")
        #expect(p.title == "OnlyTag")
        #expect(p.year == nil)
    }

    @Test("a full-width-digit year is recognised")
    func fullWidthYear() {
        let p = FilenameParser.parse("君の名は。２０１６.mkv")
        #expect(p.title == "君の名は")
        #expect(p.year == 2016)
    }

    @Test("a leading tracker/site tag is stripped from the title")
    func trackerSiteTagStripped() {
        // The exact real-world miss: a `www.Site.org - ` prefix leaked into the title.
        let p = FilenameParser.parse("www.UIndex.org    -    Planes 2013 BluRay 1080p DTS-HD MA 7.1.mkv")
        #expect(p.title == "Planes")
        #expect(p.year == 2013)

        // A bracketed bare-domain tag is also stripped.
        let b = FilenameParser.parse("[ www.Tracker.to ] Arrival 2016 1080p.mkv")
        #expect(b.title == "Arrival")
        #expect(b.year == 2016)
    }

    @Test("a real title that merely contains a dotted word is not over-stripped")
    func siteTagDoesNotEatRealTitles() {
        // No www / brackets and not a domain prefix → left intact.
        let p = FilenameParser.parse("Up.2009.1080p.BluRay.mkv")
        #expect(p.title == "Up")
        #expect(p.year == 2009)
    }
}
