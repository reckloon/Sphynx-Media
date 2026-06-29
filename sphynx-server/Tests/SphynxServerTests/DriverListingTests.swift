import Foundation
import Testing
@testable import SphynxServer

/// Listing for the networked drivers: WebDAV (PROPFIND over the HTTP client) and
/// FTP/SMB (parsing `curl`/`smbclient` output via an injected command runner, so
/// the parsing is exercised without the tools or a live server).
@Suite("Remote driver listing")
struct DriverListingTests {

    // MARK: WebDAV

    /// A fetcher that answers PROPFIND with canned multistatus XML, keyed by URL.
    private struct WebDAVStub: HTTPFetching {
        let xmlByURL: [String: String]
        func getData(url: String, headers: [String: String]) async throws -> Data { Data() }
        func sendRequest(method: String, url: String, headers: [String: String], body: Data?) async throws -> Data {
            guard method == "PROPFIND", let xml = xmlByURL[url] else {
                throw SphynxError.noMediaSource("unexpected request \(method) \(url)")
            }
            return Data(xml.utf8)
        }
    }

    @Test("WebDAV PROPFIND walk emits media files with collection-relative keys")
    func webdavList() async throws {
        let root = "https://dav.example/Media/"
        let movies = "https://dav.example/Media/Movies/"
        let stub = WebDAVStub(xmlByURL: [
            root: """
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/Media/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/Media/Movies/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/Media/readme.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>12</d:getcontentlength></d:prop></d:propstat></d:response>
            </d:multistatus>
            """,
            movies: """
            <?xml version="1.0"?><D:multistatus xmlns:D="DAV:">
              <D:response><D:href>/Media/Movies/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop></D:propstat></D:response>
              <D:response><D:href>/Media/Movies/Heat%20(1995).mkv</D:href><D:propstat><D:prop><D:resourcetype/><D:getcontentlength>123</D:getcontentlength></D:prop></D:propstat></D:response>
            </D:multistatus>
            """,
        ])
        let driver = WebDAVDriver(id: "src_x", baseURL: root, headers: [:], fetcher: stub)
        let entries = try await driver.list()
        #expect(entries.map(\.key) == ["Movies/Heat (1995).mkv"])
        #expect(entries.first?.container == "mkv")
        #expect(entries.first?.size == 123)
    }

    @Test("WebDAV uses the Depth:infinity fast path when the server honors it")
    func webdavInfinity() async throws {
        let root = "https://dav.example/Media/"
        // ONLY the root is stubbed: a depth-1 fallback walk would request the
        // subfolders and throw, so this passing proves the whole tree came back in a
        // single Depth:infinity PROPFIND.
        let stub = WebDAVStub(xmlByURL: [
            root: """
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
              <d:response><d:href>/Media/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/Media/Movies/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
              <d:response><d:href>/Media/Movies/Heat%20(1995).mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>123</d:getcontentlength></d:prop></d:propstat></d:response>
              <d:response><d:href>/Media/Shows/Show/S01/E01.mkv</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>9</d:getcontentlength></d:prop></d:propstat></d:response>
            </d:multistatus>
            """,
        ])
        let driver = WebDAVDriver(id: "src_x", baseURL: root, headers: [:], fetcher: stub)
        let entries = try await driver.list()
        #expect(entries.map(\.key) == ["Movies/Heat (1995).mkv", "Shows/Show/S01/E01.mkv"])
        #expect(entries.last?.size == 9)
    }

    // MARK: FTP

    @Test("FTP LIST parser handles Unix and MS-DOS layouts")
    func ftpParse() {
        let unix = """
        drwxr-xr-x   2 owner group       4096 Jan  1 12:00 Movies
        -rw-r--r--   1 owner group     123456 Jan  1 12:00 clip.mp4
        lrwxrwxrwx   1 owner group          7 Jan  1 12:00 link -> Movies
        """
        #expect(FTPDriver.parseList(unix) == [
            .init(name: "Movies", isDirectory: true, size: 4096),
            .init(name: "clip.mp4", isDirectory: false, size: 123456),
        ])
        let dos = """
        01-01-21  12:00PM       <DIR>          Shows
        01-01-21  12:00PM              987654 movie.mkv
        """
        #expect(FTPDriver.parseList(dos) == [
            .init(name: "Shows", isDirectory: true, size: nil),
            .init(name: "movie.mkv", isDirectory: false, size: 987654),
        ])
    }

    @Test("FTP driver walks directories via the injected runner")
    func ftpList() async throws {
        let listings: [String: String] = [
            "ftp://nas/": "drwxr-xr-x 2 o g 4096 Jan 1 12:00 Movies\n-rw-r--r-- 1 o g 10 Jan 1 12:00 a.mkv\n",
            "ftp://nas/Movies/": "-rw-r--r-- 1 o g 20 Jan 1 12:00 Heat.mkv\n-rw-r--r-- 1 o g 5 Jan 1 12:00 poster.jpg\n",
        ]
        let runner: CommandRunner = { _, args in
            let url = args.first { $0.hasPrefix("ftp://") } ?? ""
            let body = listings[url] ?? ""
            return ProcessRunner.Output(stdout: Data(body.utf8), stderr: Data(), exitCode: 0)
        }
        let driver = FTPDriver(id: "src", host: "nas", port: nil, rootPath: "/", credential: "", run: runner)
        let entries = try await driver.list()
        #expect(Set(entries.map(\.key)) == ["a.mkv", "Movies/Heat.mkv"])  // poster.jpg skipped (not media)
    }

    // MARK: SMB

    @Test("smbclient ls parser extracts names, dir flag, and size")
    func smbParse() {
        let out = """
          .                                   D        0  Mon Jan  1 12:00:00 2024
          ..                                  D        0  Mon Jan  1 12:00:00 2024
          Movie (2020)                        D        0  Mon Jan  1 12:00:00 2024
          film.mkv                            A   123456  Mon Jan  1 12:00:00 2024

                12345 blocks of size 524288. 6789 blocks available
        """
        #expect(SMBDriver.parseLS(out) == [
            .init(name: "Movie (2020)", isDirectory: true, size: nil),
            .init(name: "film.mkv", isDirectory: false, size: 123456),
        ])
    }

    @Test("SMB driver walks the share via the injected runner")
    func smbList() async throws {
        let perDir: [String: String] = [
            "": "  Shows                               D     0  Mon Jan  1 12:00:00 2024\n  movie.mkv                           A    10  Mon Jan  1 12:00:00 2024\n",
            "Shows": "  ep.mkv                              A    20  Mon Jan  1 12:00:00 2024\n",
        ]
        let runner: CommandRunner = { _, args in
            // The -D argument (if present) selects the directory; absent = root ("").
            var dir = ""
            if let i = args.firstIndex(of: "-D"), i + 1 < args.count { dir = args[i + 1] }
            let body = perDir[dir] ?? ""
            return ProcessRunner.Output(stdout: Data(body.utf8), stderr: Data(), exitCode: 0)
        }
        let driver = SMBDriver(id: "src", host: "nas", share: "media", credential: "", run: runner)
        let entries = try await driver.list()
        #expect(Set(entries.map(\.key)) == ["movie.mkv", "Shows/ep.mkv"])
    }
}
