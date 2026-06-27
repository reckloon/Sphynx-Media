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
}
