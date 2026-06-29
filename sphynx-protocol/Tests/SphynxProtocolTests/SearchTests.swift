import Foundation
import Testing
@testable import SphynxProtocol

@Suite("Search: optional, standardized shape")
struct SearchTests {
    @Test("SearchResponse round-trips and mirrors the items shape")
    func roundTrip() throws {
        let response = SearchResponse(
            items: [Item(id: "it_1", type: .movie, title: "Blade Runner")],
            nextCursor: "offset:20",
            query: "blade"
        )
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        #expect(decoded == response)
        #expect(decoded.items.first?.title == "Blade Runner")
        #expect(decoded.query == "blade")
    }

    @Test("a minimal search response omits the optional fields")
    func minimal() throws {
        let json = String(data: try JSONEncoder().encode(SearchResponse(items: [])), encoding: .utf8) ?? ""
        #expect(!json.contains("nextCursor"))
        #expect(!json.contains("query"))
    }

    @Test("search is advertised as a capability and defaults off")
    func capabilityGated() throws {
        // Absent ⇒ false: a server that doesn't offer search just omits the flag.
        let info = try JSONDecoder().decode(Capabilities.self, from: Data("{}".utf8))
        #expect(info.search == false)
    }
}
