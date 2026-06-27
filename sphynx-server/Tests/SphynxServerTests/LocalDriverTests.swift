import Foundation
import Testing
@testable import SphynxServer

/// The local filesystem driver: walking a tree into keyed entries (folders
/// preserved), unwrapping the `.strm` double extension, skipping junk, and
/// resolving a `.strm` pointer to its contained URL.
@Suite("LocalDriver")
struct LocalDriverTests {
    /// Build a throwaway directory tree, run `body`, then clean it up.
    private func withTree(_ files: [String: String], _ body: (String) async throws -> Void) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sphynx-local-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try await body(root.path)
    }

    @Test("walk keys files relative to root, sets container, skips junk")
    func walkAndSkip() async throws {
        try await withTree([
            "Movies/Big Hero 6 (2014)/Big Hero 6 (2014).mkv.strm": "https://example/bh6",
            "Movies/Test (1999)/Test (1999).mp4": "x",
            "Movies/Star Wars (2005)/Sample.mkv.strm": "https://example/sample",
            "Movies/Star Wars (2005)/Star.Wars.2005.mkv.strm": "https://example/sw",
            "Movies/Big Hero 6 (2014)/poster.jpg": "junk",
            "Movies/Big Hero 6 (2014)/movie.nfo": "junk",
        ]) { root in
            let entries = try await LocalDriver(id: "s", root: root).list()
            let keys = Set(entries.map(\.key))

            // Three media files indexed; sidecars + sample dropped.
            #expect(keys == [
                "Movies/Big Hero 6 (2014)/Big Hero 6 (2014).mkv.strm",
                "Movies/Test (1999)/Test (1999).mp4",
                "Movies/Star Wars (2005)/Star.Wars.2005.mkv.strm",
            ])
            // Container is the real media extension, unwrapping `.strm`.
            let bh6 = try #require(entries.first { $0.key.contains("Big Hero 6 (2014).mkv.strm") })
            #expect(bh6.container == "mkv")
            let test = try #require(entries.first { $0.key.hasSuffix("Test (1999).mp4") })
            #expect(test.container == "mp4")
        }
    }

    @Test("container unwraps the .strm double extension")
    func containerUnwrap() {
        #expect(LocalDriver.container(for: "Name.mkv.strm") == "mkv")
        #expect(LocalDriver.container(for: "Name.mp4.strm") == "mp4")
        #expect(LocalDriver.container(for: "Name.mp4") == "mp4")
        #expect(LocalDriver.container(for: "pointer.strm") == "strm")   // bare .strm still resolves
        #expect(LocalDriver.container(for: "poster.jpg") == nil)        // not media
        #expect(LocalDriver.container(for: "notes.txt") == nil)
    }

    @Test("resolve reads a .strm file's contents as the source URL")
    func resolveStrm() async throws {
        try await withTree([
            "Show/Season 1/ep.mkv.strm": "https://cdn.example/stream.mkv\n",
        ]) { root in
            let driver = LocalDriver(id: "s", root: root)
            let location = try await driver.resolve(ResolveRequest(key: "Show/Season 1/ep.mkv.strm", container: "mkv"))
            #expect(location.url == "https://cdn.example/stream.mkv")
            #expect(location.preResolved == true)
            #expect(location.container == "mkv")
        }
    }

    @Test("resolve maps a plain local file to a file:// URL")
    func resolvePlainFile() async throws {
        try await withTree([
            "Movies/Test (1999)/Test (1999).mp4": "bytes",
        ]) { root in
            let driver = LocalDriver(id: "s", root: root)
            let location = try await driver.resolve(ResolveRequest(key: "Movies/Test (1999)/Test (1999).mp4", container: "mp4"))
            #expect(location.url.hasPrefix("file://"))
            #expect(location.url.hasSuffix("Test%20(1999).mp4"))
        }
    }
}
