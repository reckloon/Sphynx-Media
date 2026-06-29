import Foundation
import Testing
@testable import SphynxServer

@Suite("Deleting a library removes its extras; orphans are swept")
struct OrphanCascadeTests {

    /// Extras nest under a movie/show via `parentId` and carry `libraryId` nil, so a
    /// library deletion (scoped by `libraryId`) used to leave them stranded in the DB.
    @Test("deleteLibrary removes nested extras (libraryId nil), not just library items")
    func deleteLibraryRemovesExtras() async throws {
        let catalog = Catalog(db: try AppDatabase.makeInMemory())
        let lib = try await catalog.createLibrary(title: "Movies", kind: "movies")
        let movie = try await catalog.createItem(
            type: "movie", title: "Big Movie", sourceId: nil, sourceKey: "Big Movie (2020).mkv",
            container: "mkv", tmdbId: nil, libraryId: lib.id, parentId: nil, year: 2020)
        // As the indexer creates them: an extra nested under the movie, libraryId nil.
        let extra = try await catalog.createItem(
            type: "trailer", title: "Behind the Scenes", sourceId: nil,
            sourceKey: "Big Movie (2020)/Extras/BTS.mkv", container: "mkv",
            tmdbId: nil, libraryId: nil, parentId: movie.id, year: nil)

        #expect(try await catalog.item(id: movie.id) != nil)
        #expect(try await catalog.item(id: extra.id) != nil)

        try await catalog.deleteLibrary(id: lib.id)

        // The movie (by libraryId) AND its now-orphaned extra are both gone.
        #expect(try await catalog.item(id: movie.id) == nil)
        #expect(try await catalog.item(id: extra.id) == nil)
    }

    @Test("pruneOrphans removes an item whose parent no longer exists")
    func pruneOrphansSweepsStrays() async throws {
        let catalog = Catalog(db: try AppDatabase.makeInMemory())
        let lib = try await catalog.createLibrary(title: "Movies", kind: "movies")
        let movie = try await catalog.createItem(
            type: "movie", title: "M", sourceId: nil, sourceKey: "m.mkv",
            container: "mkv", tmdbId: nil, libraryId: lib.id, parentId: nil, year: 2020)
        let extra = try await catalog.createItem(
            type: "featurette", title: "F", sourceId: nil, sourceKey: "m/Extras/f.mkv",
            container: "mkv", tmdbId: nil, libraryId: nil, parentId: movie.id, year: nil)

        // Strand the extra the way a pre-fix library delete did: remove only the parent.
        try await catalog.deleteItem(id: movie.id)
        #expect(try await catalog.item(id: extra.id) != nil)   // orphaned but still present

        let removed = try await catalog.pruneOrphans()
        #expect(removed == 1)
        #expect(try await catalog.item(id: extra.id) == nil)
    }
}
