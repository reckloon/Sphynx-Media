import Foundation
import SphynxProtocol
import Testing
@testable import SphynxServer

@Suite("Resolve: cached probe folds into tracks")
struct ResolveTracksTests {
    private func makeResolver() throws -> (Catalog, Resolver) {
        let db = try AppDatabase.makeInMemory()
        let catalog = Catalog(db: db)
        let resolver = Resolver(catalog: catalog, drivers: DriverFactory(fetcher: StubFetcher([:])))
        return (catalog, resolver)
    }

    private let sampleProbe = StoredProbe(
        streams: [
            MediaStream(index: 0, kind: "video", codec: "h264"),
            MediaStream(index: 1, kind: "audio", codec: "aac", language: "eng", channels: 2, isDefault: false),
            MediaStream(index: 2, kind: "audio", codec: "eac3", language: "eng", channels: 6, isDefault: true),
            MediaStream(index: 3, kind: "subtitle", codec: "subrip", language: "spa", isForced: true),
        ],
        externalSubtitles: [ExternalSubtitle(url: "file:///m/Movie.en.srt", language: "en", format: "srt")],
        probedAt: 0
    )

    @Test("a probed item resolves with rich tracks + derived selection")
    func foldsCachedTracks() async throws {
        let (catalog, resolver) = try makeResolver()
        // Self-contained item: sourceKey is an absolute URL, resolved inline (no fetch).
        let item = try await catalog.createItem(
            type: "movie", title: "X", sourceId: nil,
            sourceKey: "https://cdn.example/movie.mkv", container: "mkv", tmdbId: nil)

        var record = try #require(try await catalog.item(id: item.id))
        record.probedTracksJSON = String(data: try JSONEncoder().encode(sampleProbe), encoding: .utf8)
        try await catalog.updateItem(record)

        let descriptor = try await resolver.resolve(itemId: item.id)
        let tracks = try #require(descriptor.tracks)
        #expect(tracks.streams?.count == 4)
        // Default 5.1 audio wins over the non-default stereo; forced subtitle wins.
        #expect(tracks.preferredAudio == 2)
        #expect(tracks.preferredSubtitle == 3)
        #expect(tracks.externalSubtitles?.first?.language == "en")
        let surround = try #require(tracks.streams?.first { $0.index == 2 })
        #expect(surround.codec == "eac3")
        #expect(surround.channels == 6)
    }

    @Test("an un-probed item resolves with no tracks (back-compatible)")
    func noTracksWhenUnprobed() async throws {
        let (catalog, resolver) = try makeResolver()
        let item = try await catalog.createItem(
            type: "movie", title: "X", sourceId: nil,
            sourceKey: "https://cdn.example/movie.mkv", container: "mkv", tmdbId: nil)
        let descriptor = try await resolver.resolve(itemId: item.id)
        #expect(descriptor.tracks == nil)
    }
}
