import Testing
@testable import SphynxServer

@Suite("MediaVersionParser")
struct MediaVersionParserTests {
    @Test("resolution, dynamic range, remux, and label from a release name")
    func richRelease() {
        let v = MediaVersionParser.version(
            key: "The Matrix (1999)/The.Matrix.1999.2160p.UHD.BluRay.REMUX.HDR10.mkv",
            container: "mkv", size: 60_000_000_000)
        #expect(v.resolution == "4K")
        #expect(v.dynamicRange == "HDR10")
        #expect(v.edition == nil)
        #expect(v.label == "4K · HDR10 · Remux")
    }

    @Test("edition is detected and leads the label")
    func edition() {
        let dc = MediaVersionParser.version(key: "Blade.Runner.Directors.Cut.1080p.BluRay.mkv", container: "mkv", size: nil)
        #expect(dc.edition == "Director's Cut")
        #expect(dc.resolution == "1080p")
        #expect(dc.label == "Director's Cut · 1080p")

        let ext = MediaVersionParser.version(key: "Aliens.Extended.Edition.2160p.DV.mkv", container: "mkv", size: nil)
        #expect(ext.edition == "Extended")
        #expect(ext.dynamicRange == "DV")
        #expect(ext.label == "Extended · 4K · DV")
    }

    @Test("a plain name with no tags falls back to the container label")
    func plainFallback() {
        let v = MediaVersionParser.version(key: "Sintel.mp4", container: "mp4", size: nil)
        #expect(v.resolution == nil)
        #expect(v.edition == nil)
        #expect(v.label == "MP4")
    }

    @Test("rank orders 4K-HDR-remux above 1080p above 720p")
    func ranking() {
        let uhd = MediaVersionParser.version(key: "M.2160p.HDR10.REMUX.mkv", container: "mkv", size: nil)
        let hd = MediaVersionParser.version(key: "M.1080p.BluRay.mkv", container: "mkv", size: nil)
        let sd = MediaVersionParser.version(key: "M.720p.WEB.mkv", container: "mkv", size: nil)
        #expect(MediaVersionParser.rank(uhd) > MediaVersionParser.rank(hd))
        #expect(MediaVersionParser.rank(hd) > MediaVersionParser.rank(sd))
    }

    @Test("the version id is deterministic across calls (stable across re-scans)")
    func stableID() {
        let a = MediaVersionParser.version(key: "Movie.2160p.mkv", container: "mkv", size: nil)
        let b = MediaVersionParser.version(key: "Movie.2160p.mkv", container: "mkv", size: 123)
        #expect(a.id == b.id)            // id depends only on the key
        #expect(a.id.hasPrefix("v_"))
        let other = MediaVersionParser.version(key: "Movie.1080p.mkv", container: "mkv", size: nil)
        #expect(a.id != other.id)        // distinct keys → distinct ids
    }
}
