import Foundation
import Logging
import SphynxProtocol
import Testing
@testable import SphynxServer

/// A deterministic stand-in for the real generator: hashes never hit the network,
/// each URL maps to a stable fake "hash" so assertions can tie a role/face back to
/// the image it was generated from. Records every URL it was asked to hash.
private actor StubGenerator: BlurHashGenerating {
    private(set) var requested: [String] = []
    func blurHash(forImageAt url: String) async -> String? {
        requested.append(url)
        return "H(\(url))"
    }
    func urls() -> [String] { requested }
}

@Suite("Low-res images: BlurHash backfill")
struct BlurHashBackfillTests {

    /// Build an item carrying every image role plus a mixed cast (one with a photo,
    /// one without), persisted into a fresh in-memory catalog.
    private func seed(_ catalog: Catalog) async throws -> ItemRecord {
        let lib = try await catalog.createLibrary(title: "L", kind: "movies")
        var item = try await catalog.createItem(
            type: "movie", title: "The Matrix", sourceId: nil, sourceKey: "k",
            container: "mkv", tmdbId: "603", libraryId: lib.id)
        item.primaryImage = "https://image.tmdb.org/t/p/w500/poster.jpg"
        item.placeholderURL = "https://image.tmdb.org/t/p/w92/poster.jpg"
        item.backdropImage = "https://image.tmdb.org/t/p/w1280/back.jpg"
        item.logoImage = "https://image.tmdb.org/t/p/original/logo.png"
        item.castJSON = String(data: try JSONEncoder().encode([
            StoredCast(id: "pe_1", name: "Keanu", role: "Neo",
                       imageURL: "https://image.tmdb.org/t/p/w185/keanu.jpg",
                       placeholderURL: "https://image.tmdb.org/t/p/w92/keanu.jpg"),
            StoredCast(id: "pe_2", name: "Extra", role: "Crowd",
                       imageURL: nil, placeholderURL: nil),  // no photo ⇒ nothing to hash
        ]), encoding: .utf8)
        try await catalog.updateItem(item)
        return try #require(try await catalog.item(id: item.id))
    }

    private func makeService(_ catalog: Catalog, _ settings: SettingsStore, _ gen: StubGenerator)
        -> (BlurHashBackfillService, BackfillProgress) {
        let progress = BackfillProgress()
        let service = BlurHashBackfillService(
            defaultInterval: 60, catalog: catalog, generator: gen, settings: settings,
            progress: progress, schedule: ScheduleCenter(), logger: Logger(label: "test"))
        return (service, progress)
    }

    @Test("hashes every hashable image role + photo'd cast face (not logos); serving then uses the hashes")
    func backfillsAllImages() async throws {
        let db = try AppDatabase.makeInMemory()
        let catalog = Catalog(db: db)
        let settings = SettingsStore(db: db)
        try await settings.set([PlaceholderMode.settingKey: "blurhash"])
        let seeded = try await seed(catalog)
        let gen = StubGenerator()
        let (service, progress) = makeService(catalog, settings, gen)

        await service.runOnce()

        let item = try #require(try await catalog.item(id: seeded.id))
        let hashes = item.imageBlurHashes()
        // Every hashable image role with a URL got a hash, keyed by role.
        #expect(hashes["primary"] == "H(https://image.tmdb.org/t/p/w92/poster.jpg)")
        #expect(hashes["backdrop"] == "H(https://image.tmdb.org/t/p/w300/back.jpg)")
        // Transparent logos are deliberately excluded — they keep the URL form.
        #expect(hashes["logo"] == nil)
        // The photo'd cast face got a hash; the photoless one stayed nil.
        let cast = try JSONDecoder().decode(
            [StoredCast].self, from: Data(try #require(item.castJSON).utf8))
        #expect(cast[0].blurHash == "H(https://image.tmdb.org/t/p/w92/keanu.jpg)")
        #expect(cast[1].blurHash == nil)

        // Progress: a finished pass with done == total (2 hashable roles + 1 face = 3;
        // the logo is excluded).
        let snap = await progress.snapshot()
        #expect(snap.running == false)
        #expect(snap.total == 3)
        #expect(snap.done == 3)
        #expect(snap.lastCompletedAt != nil)

        // Serving in blurhash mode now uses the stored hashes for each role + face.
        let projected = item.toProtocol(full: true, placeholderMode: .blurhash)
        #expect(projected.placeholder == .blurHash(hashes["primary"]!))
        #expect(projected.images?.variants?["backdrop"]?.placeholder == .blurHash(hashes["backdrop"]!))
        // Logo is never a BlurHash — it serves the plain URL form even in blurhash mode.
        #expect(projected.images?.variants?["logo"]?.placeholder == .url("https://image.tmdb.org/t/p/w92/logo.png"))
        #expect(projected.cast?.first?.placeholder == .blurHash(cast[0].blurHash!))
        #expect(projected.cast?.last?.placeholder == nil)  // photoless ⇒ nothing to serve
    }

    @Test("backfill does not bump updatedAt (no mass cache invalidation)")
    func preservesUpdatedAt() async throws {
        let db = try AppDatabase.makeInMemory()
        let catalog = Catalog(db: db)
        let settings = SettingsStore(db: db)
        try await settings.set([PlaceholderMode.settingKey: "blurhash"])
        let seeded = try await seed(catalog)
        let before = seeded.updatedAt
        let gen = StubGenerator()
        let (service, _) = makeService(catalog, settings, gen)

        await service.runOnce()

        let after = try #require(try await catalog.item(id: seeded.id))
        #expect(after.updatedAt == before)            // unchanged
        #expect(after.imageBlurHashes().isEmpty == false)  // but hashes were written
    }

    @Test("a second pass is a no-op once everything is hashed")
    func idempotent() async throws {
        let db = try AppDatabase.makeInMemory()
        let catalog = Catalog(db: db)
        let settings = SettingsStore(db: db)
        try await settings.set([PlaceholderMode.settingKey: "blurhash"])
        let seeded = try await seed(catalog)
        let gen = StubGenerator()
        let (service, _) = makeService(catalog, settings, gen)

        await service.runOnce()
        let firstCount = await gen.urls().count
        await service.runOnce()
        let secondCount = await gen.urls().count
        #expect(firstCount == 3)   // primary + backdrop + 1 cast face (logo excluded)
        #expect(secondCount == 3)  // nothing left to hash ⇒ no further fetches
    }

    @Test("no generation unless the mode is blurhash")
    func gatedOnMode() async throws {
        let db = try AppDatabase.makeInMemory()
        let catalog = Catalog(db: db)
        let settings = SettingsStore(db: db)
        try await settings.set([PlaceholderMode.settingKey: "url"])
        let seeded = try await seed(catalog)
        let gen = StubGenerator()
        let (service, _) = makeService(catalog, settings, gen)

        await service.runOnce()

        #expect(await gen.urls().isEmpty)
        let item = try #require(try await catalog.item(id: seeded.id))
        #expect(item.imageBlurHashes().isEmpty)
    }
}
