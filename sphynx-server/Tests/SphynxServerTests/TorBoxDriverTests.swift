import Foundation
import Testing
@testable import SphynxServer

/// The TorBox driver: listing the user's ready cloud files into catalog entries,
/// and minting a direct CDN link on resolve — all over the injected `HTTPFetching`
/// client, so the JSON parsing and key encoding are exercised without the network
/// or a live account.
@Suite("TorBox driver")
struct TorBoxDriverTests {

    /// A fetcher that answers with canned bodies chosen by a substring of the URL,
    /// recording every request so a test can assert on the minted `requestdl` URL.
    private actor RecordingFetcher: HTTPFetching {
        let responses: [String: String]
        private(set) var requestedURLs: [String] = []
        private(set) var lastAuth: String?
        init(_ responses: [String: String]) { self.responses = responses }

        func getData(url: String, headers: [String: String]) async throws -> Data {
            requestedURLs.append(url)
            if let auth = headers["Authorization"] { lastAuth = auth }
            for (needle, body) in responses where url.contains(needle) {
                return Data(body.utf8)
            }
            throw SphynxError.noMediaSource("no canned response for \(url)")
        }
    }

    private static let torrentsList = """
    {"success":true,"data":[
      {"id":10,"name":"Some.Show.S01.1080p.WEB","download_present":true,"files":[
        {"id":20,"name":"Some.Show.S01.1080p.WEB/Some.Show.S01E02.mkv","short_name":"Some.Show.S01E02.mkv","size":123},
        {"id":21,"name":"Some.Show.S01.1080p.WEB/Sample.mkv","short_name":"Sample.mkv","size":5},
        {"id":22,"name":"Some.Show.S01.1080p.WEB/poster.jpg","short_name":"poster.jpg","size":2}
      ]},
      {"id":11,"name":"Big Buck Bunny (2008)","download_present":true,"files":[
        {"id":30,"name":"Big.Buck.Bunny.2008.mkv","short_name":"Big.Buck.Bunny.2008.mkv","size":456}
      ]},
      {"id":12,"name":"Still.Downloading","download_present":false,"files":[
        {"id":40,"name":"Still.Downloading/movie.mkv","short_name":"movie.mkv","size":789}
      ]}
    ]}
    """

    @Test("list() emits one entry per ready media file, skipping junk and unfinished items")
    func listFiltersAndKeys() async throws {
        let fetcher = RecordingFetcher(["torrents/mylist": Self.torrentsList])
        let driver = TorBoxDriver(
            id: "src", apiKey: "KEY", baseURL: TorBoxDriver.defaultBaseURL,
            categories: ["torrents"], linkTTL: 3_600, fetcher: fetcher)

        let entries = try await driver.list()

        // Episode file + movie file only: Sample.mkv (skippable), poster.jpg
        // (not media), and the unfinished item are all dropped. Sorted by key,
        // so the episode (id 10) precedes the movie (id 11).
        #expect(entries.map(\.key) == [
            "torrents/10-20/Some.Show.S01.1080p.WEB/Some.Show.S01E02.mkv",
            "torrents/11-30/Big Buck Bunny (2008)/Big.Buck.Bunny.2008.mkv",
        ])
        #expect(entries.first?.container == "mkv")
        #expect(entries.first?.size == 123)
        // The episode carries explicit hints; the movie is left for the indexer.
        #expect(entries.first?.type == "episode")
        #expect(entries.first?.season == 1)
        #expect(entries.first?.episode == 2)
        #expect(entries.first?.seriesTitle?.localizedCaseInsensitiveContains("Some Show") == true)
        #expect(entries.last?.type == nil)
        // mylist authenticates with the Bearer header (key never in the URL).
        let urls = await fetcher.requestedURLs
        #expect(urls.allSatisfy { !$0.contains("KEY") })
        #expect(await fetcher.lastAuth == "Bearer KEY")
    }

    @Test("the entries list() builds classify correctly through the indexer")
    func entriesClassify() async throws {
        let fetcher = RecordingFetcher(["torrents/mylist": Self.torrentsList])
        let driver = TorBoxDriver(
            id: "src", apiKey: "KEY", baseURL: TorBoxDriver.defaultBaseURL,
            categories: ["torrents"], linkTTL: 3_600, fetcher: fetcher)
        let entries = try await driver.list()

        // The episode's hints survive the opaque routing prefix in the key.
        let episode = Indexer.classify(try #require(entries.first))
        guard case let .episode(info) = episode else {
            Issue.record("expected an episode, got \(episode)"); return
        }
        #expect(info.season == 1)
        #expect(info.episode == 2)
        #expect(info.series.localizedCaseInsensitiveContains("Some Show"))

        // The movie parses cleanly from the key (immediate parent folder).
        let movie = Indexer.classify(try #require(entries.last))
        guard case let .movie(title, year) = movie else {
            Issue.record("expected a movie, got \(movie)"); return
        }
        #expect(title == "Big Buck Bunny")
        #expect(year == 2008)
    }

    @Test("key encoding round-trips")
    func keyRoundTrip() throws {
        let key = TorBoxDriver.makeKey(category: "usenet", parentId: 77, fileId: 88, display: "Movie (2020)/Movie.2020.mkv")
        #expect(key == "usenet/77-88/Movie (2020)/Movie.2020.mkv")
        #expect(try TorBoxDriver.parseKey(key) == .init(category: "usenet", parentId: 77, fileId: 88))
        #expect(throws: SphynxError.self) { try TorBoxDriver.parseKey("garbage") }
    }

    @Test("resolve() mints a tokened requestdl call and returns the CDN link")
    func resolveMintsLink() async throws {
        let cdn = "https://store.torbox.app/cdn/abc/Movie.2020.mkv"
        let fetcher = RecordingFetcher([
            "usenet/requestdl": #"{"success":true,"detail":"ok","data":"\#(cdn)"}"#,
        ])
        let driver = TorBoxDriver(
            id: "src", apiKey: "KEY", baseURL: TorBoxDriver.defaultBaseURL,
            categories: ["usenet"], linkTTL: 1_800, fetcher: fetcher)

        let location = try await driver.resolve(
            ResolveRequest(key: "usenet/77-88/Movie (2020)/Movie.2020.mkv", container: "mkv"))

        #expect(location.url == cdn)
        #expect(location.terminal)
        #expect(location.ttl == 1_800)
        #expect(location.container == "mkv")

        // The mint used the usenet id param, the file id, and the token query param.
        let url = try #require(await fetcher.requestedURLs.first)
        #expect(url.contains("usenet/requestdl"))
        #expect(url.contains("usenet_id=77"))
        #expect(url.contains("file_id=88"))
        #expect(url.contains("token=KEY"))
    }

    @Test("resolve() surfaces a clear error when TorBox returns no link")
    func resolveNoLink() async throws {
        let fetcher = RecordingFetcher([
            "torrents/requestdl": #"{"success":false,"detail":"Download not found.","data":null}"#,
        ])
        let driver = TorBoxDriver(
            id: "src", apiKey: "KEY", baseURL: TorBoxDriver.defaultBaseURL,
            categories: ["torrents"], linkTTL: 3_600, fetcher: fetcher)

        await #expect(throws: SphynxError.self) {
            _ = try await driver.resolve(ResolveRequest(key: "torrents/1-2/x/y.mkv", container: "mkv"))
        }
    }

    @Test("registration requires an apiKey secret and defaults the categories")
    func registration() throws {
        let reg = TorBoxDriver.registration
        #expect(reg.kind == "torbox")

        // Missing key → clear failure.
        let noKey = SourceContext(id: "s", config: [:], secrets: [:], fetcher: URLSessionFetcher(),
                                  baseURL: nil, headers: [:], manifestURL: nil)
        #expect(throws: SphynxError.self) { _ = try reg.make(noKey) }

        // With a key, categories default to all three.
        let ctx = SourceContext(id: "s", config: [:], secrets: ["apiKey": "KEY"], fetcher: URLSessionFetcher(),
                                baseURL: nil, headers: [:], manifestURL: nil)
        let driver = try #require(try reg.make(ctx) as? TorBoxDriver)
        #expect(driver.categories == TorBoxDriver.allCategories)
        #expect(driver.baseURL == TorBoxDriver.defaultBaseURL)
    }
}
