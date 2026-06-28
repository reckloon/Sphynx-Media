import Testing
@testable import SphynxServer

@Suite("EpisodeParser")
struct EpisodeParserTests {
    @Test("S01E02 dotted release")
    func dottedSxxExx() {
        let p = EpisodeParser.parse("Breaking.Bad.S02E05.1080p.BluRay.x264.mkv")
        #expect(p == .init(seriesTitle: "Breaking Bad", season: 2, episode: 5))
    }

    @Test("lowercase s1e2")
    func lowercase() {
        let p = EpisodeParser.parse("the_office_s1e2.mkv")
        #expect(p?.seriesTitle == "the office")
        #expect(p?.season == 1)
        #expect(p?.episode == 2)
    }

    @Test("NxNN form")
    func nxnn() {
        let p = EpisodeParser.parse("Firefly - 1x05 - Safe.mkv")
        #expect(p?.seriesTitle == "Firefly")
        #expect(p?.season == 1)
        #expect(p?.episode == 5)
    }

    @Test("multi-episode file → first episode wins")
    func multiEpisode() {
        let p = EpisodeParser.parse("Show.S03E07E08.mkv")
        #expect(p?.season == 3)
        #expect(p?.episode == 7)
    }

    @Test("path components are ignored")
    func pathStripped() {
        let p = EpisodeParser.parse("TV/Severance/Season 1/Severance.S01E03.mkv")
        #expect(p?.seriesTitle == "Severance")
        #expect(p?.season == 1)
        #expect(p?.episode == 3)
    }

    @Test("a movie (no episode marker) does not parse")
    func movieReturnsNil() {
        #expect(EpisodeParser.parse("The.Matrix.1999.1080p.mkv") == nil)
    }

    @Test("a resolution is not mistaken for an episode marker")
    func resolutionNotEpisode() {
        // 1280x720 must not parse as season 80 / episode 72, etc.
        #expect(EpisodeParser.parse("BigBuckBunny_1280x720.mp4") == nil)
    }

    @Test("a 3-4 digit episode number is not truncated (long-running anime)")
    func largeEpisodeNumber() {
        let p = EpisodeParser.parse("One Piece.S01E1071.mkv")
        #expect(p?.season == 1)
        #expect(p?.episode == 1071)  // not "E10" → 10
    }

    @Test("a year-as-season marker parses (daily shows)")
    func yearAsSeason() {
        let p = EpisodeParser.parse("Doctor Who S2024E01.mkv")
        #expect(p?.season == 2024)
        #expect(p?.episode == 1)
    }
}
