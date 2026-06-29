import Foundation
import Testing
@testable import SphynxServer

@Suite("Low-res images: BlurHash encode + generate")
struct BlurHashTests {
    /// A tiny (16×11) baseline JPEG, embedded so the decode path is exercised
    /// without a network or filesystem dependency.
    private var sampleJPEG: Data {
        Data(base64Encoded:
            "/9j/4AAQSkZJRgABAQAASABIAAD/4QESRXhpZgAATU0AKgAAAAgACQESAAMAAAABAAEAAAEaAAUAAAABAAAAegEbAAUAAAABAAAAggEoAAMAAAABAAIAAAEx" +
            "AAIAAAAhAAAAigEyAAIAAAAUAAAArAFCAAQAAAABAAACAAFDAAQAAAABAAACAIdpAAQAAAABAAAAwAAAAAAAAABIAAAAAQAAAEgAAAABQWRvYmUgUGhvdG9z" +
            "aG9wIDI3LjQgKE1hY2ludG9zaCkAADIwMjY6MDU6MjggMDk6NTQ6MDgAAASQBAACAAAAFAAAAPagAQADAAAAAQABAACgAgAEAAAAAQAAABCgAwAEAAAAAQAA" +
            "AAsAAAAAMjAyNjowNTowNiAxMzoxNDozNwD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgA" +
            "CwAQAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGh" +
            "CCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeo" +
            "qaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIB" +
            "AgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2Rl" +
            "ZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMA" +
            "AgICAgICAwICAwUDAwMFBgUFBQUGCAYGBgYGCAoICAgICAgKCgoKCgoKCgwMDAwMDA4ODg4ODw8PDw8PDw8PD//bAEMBAgICBAQEBwQEBxALCQsQEBAQEBAQ" +
            "EBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEP/dAAQAAf/aAAwDAQACEQMRAD8A7Cb4daXaeCLzw/f6jFcRvJBdzXUh3Lp1vGQx" +
            "ZSeBLIPlAyMg45OBXoXgzw/4D8d+P/D/AIi0iyFs1rZG1jucBJriGLIe6nIA3Pg7I889OoHH5y3Pi7xLqHw1020vNQlkhvtXWWdCQBI+HILYAzg9B0HGBXvf" +
            "gzxJrlj4mVLO8eFY7KJFC4GFyTjpWOVZEo0OaUrs7cyzR86sj//Z"
        )!
    }

    @Test("solid black, single component → the canonical empty hash")
    func solidBlack() {
        // 2×2 all-black, 1×1 components: only a DC term, which is zero.
        let rgb = [UInt8](repeating: 0, count: 2 * 2 * 3)
        #expect(BlurHash.encode(rgb: rgb, width: 2, height: 2, componentsX: 1, componentsY: 1) == "000000")
    }

    @Test("malformed input returns nil rather than a bogus hash")
    func rejectsMalformed() {
        // Buffer not width*height*3.
        #expect(BlurHash.encode(rgb: [0, 0], width: 1, height: 1) == nil)
        // Components out of the 1...9 range.
        #expect(BlurHash.encode(rgb: [0, 0, 0], width: 1, height: 1, componentsX: 0, componentsY: 1) == nil)
        #expect(BlurHash.encode(rgb: [0, 0, 0], width: 1, height: 1, componentsX: 1, componentsY: 10) == nil)
        // Zero dimensions.
        #expect(BlurHash.encode(rgb: [], width: 0, height: 0) == nil)
    }

    @Test("length follows the component formula, uses only base-83 chars, deterministic")
    func lengthAndAlphabet() throws {
        // A 4×4 RGB gradient.
        var rgb = [UInt8]()
        for y in 0..<4 {
            for x in 0..<4 {
                rgb.append(UInt8(x * 60)); rgb.append(UInt8(y * 60)); rgb.append(128)
            }
        }
        let hash = try #require(BlurHash.encode(rgb: rgb, width: 4, height: 4, componentsX: 4, componentsY: 3))
        // 1 (size) + 1 (max) + 4 (DC) + 2 per AC; 4×3 ⇒ 11 AC ⇒ 28.
        #expect(hash.count == 28)
        let alphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~")
        #expect(hash.allSatisfy { alphabet.contains($0) })
        // Same input ⇒ same hash.
        #expect(BlurHash.encode(rgb: rgb, width: 4, height: 4, componentsX: 4, componentsY: 3) == hash)
    }

    @Test("generator decodes a real JPEG and produces a 4×3 hash")
    func generatesFromJPEG() async throws {
        let url = "https://image.tmdb.org/t/p/w92/poster.jpg"
        let generator = PosterBlurHashGenerator(fetcher: StubFetcher([url: sampleJPEG]))
        let hash = try #require(await generator.blurHash(forImageAt: url))
        #expect(hash.count == 28)  // 4×3 components (the generator's default)
    }

    @Test("generator returns nil for an undecodable / missing image")
    func generatorFailsGracefully() async {
        let url = "https://image.tmdb.org/t/p/w92/poster.jpg"
        // Non-JPEG bytes under the URL.
        let garbage = PosterBlurHashGenerator(fetcher: StubFetcher([url: Data("not an image".utf8)]))
        #expect(await garbage.blurHash(forImageAt: url) == nil)
        // URL the fetcher doesn't know.
        let empty = PosterBlurHashGenerator(fetcher: StubFetcher([:]))
        #expect(await empty.blurHash(forImageAt: url) == nil)
    }
}
