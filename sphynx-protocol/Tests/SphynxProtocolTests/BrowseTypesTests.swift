import Foundation
import Testing
@testable import SphynxProtocol

private func assertRoundTrips<T: Codable & Equatable>(_ value: T) throws {
    let data = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(T.self, from: data)
    #expect(decoded == value, "\(T.self) did not survive a JSON round-trip")
}

@Suite("Browse types")
struct BrowseTypesTests {
    @Test("Libraries response round-trips, including unknown kinds")
    func libraries() throws {
        let response = LibrariesResponse(libraries: [
            Library(id: "lib_movies", title: "Movies", kind: .movies),
            Library(id: "lib_tv", title: "TV", kind: .tvShows),
            Library(id: "lib_x", title: "Podcasts", kind: .unknown("podcasts")),
        ])
        try assertRoundTrips(response)
    }

    @Test("Items response round-trips with and without a cursor")
    func items() throws {
        let page = ItemsResponse(
            items: [Item(id: "it_1", type: .movie, title: "A"), Item(id: "it_2", type: .movie, title: "B")],
            nextCursor: "b2Zmc2V0OjUw"
        )
        try assertRoundTrips(page)
        try assertRoundTrips(ItemsResponse(items: [], nextCursor: nil))
    }

    @Test("Absent nextCursor is omitted on the wire")
    func cursorOmitted() throws {
        let json = String(data: try JSONEncoder().encode(ItemsResponse(items: [])), encoding: .utf8)!
        #expect(!json.contains("nextCursor"))
    }

    @Test("Item carries parentId + collection membership + extras types")
    func parentAndCollection() throws {
        // A bonus clip nested under its movie.
        try assertRoundTrips(Item(id: "it_x", type: .featurette, title: "The Making Of", parentId: "it_movie"))
        // A film that belongs to a collection.
        try assertRoundTrips(Item(id: "it_m", type: .movie, title: "Part One",
                                  collectionId: "it_coll", collectionTitle: "The Saga"))
        // The four new extras types map to/from their wire strings.
        for t: ItemType in [.trailer, .featurette, .deletedScene, .behindTheScenes] {
            #expect(ItemType(rawValue: t.rawValue) == t)
        }
        // An unknown future type still decodes (forward-compat).
        #expect(ItemType(rawValue: "interview") == nil)
        let decoded = try JSONDecoder().decode(ItemType.self, from: Data("\"interview\"".utf8))
        #expect(decoded == .unknown("interview"))
    }

    @Test("Home response round-trips with typed shelves + aspect")
    func home() throws {
        let response = HomeResponse(shelves: [
            Shelf(id: "continue", title: "Continue Watching", kind: .continueWatching, aspect: .landscape,
                  items: [Item(id: "it_e2", type: .episode, title: "Two")]),
            Shelf(id: "recent", title: "Recently Added", kind: .recentlyAdded, aspect: .portrait,
                  items: [Item(id: "it_m", type: .movie, title: "Heat")]),
        ])
        try assertRoundTrips(response)
    }

    @Test("Continue Watching is unified: a separate Next Up kind decodes only as unknown")
    func noNextUpKind() throws {
        // There is deliberately no `.nextUp` case — next-up lives in continueWatching.
        #expect(ShelfKind(rawValue: "nextUp") == nil)
        #expect(ShelfKind(rawValue: "continueWatching") == .continueWatching)
        // An unknown kind still decodes (forward-compat) rather than throwing.
        let decoded = try JSONDecoder().decode(ShelfKind.self, from: Data("\"nextUp\"".utf8))
        #expect(decoded == .unknown("nextUp"))
    }
}
