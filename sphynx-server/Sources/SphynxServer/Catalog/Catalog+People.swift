import Foundation
import GRDB
import SphynxProtocol

/// Person (cast-credit) queries over the catalog.
///
/// People are not a first-class table — there is no person registry. A person is
/// only ever observed as a `StoredCast` entry embedded in an item's `castJSON`,
/// with an id of the form `pe_<tmdbId>` (see `Enricher.storedCast`). The inverse
/// lookup ("everything this person is credited on") is therefore a scan of the
/// items that carry a matching cast id.
///
/// Crew (directors/writers) are stored as plain name strings with no person id,
/// so crew credits cannot participate in this lookup — only on-screen **cast**
/// credits are returned.
extension Catalog {
    /// The distinct items whose stored cast includes `personId` (a `pe_…` id).
    ///
    /// Implementation: a coarse `castJSON LIKE %"pe_…"%` prefilter narrows the
    /// candidate set in SQL, then each candidate's `castJSON` is decoded and the
    /// cast ids checked exactly — so a substring collision (e.g. `pe_12` vs
    /// `pe_123`) can never produce a false match. Results are de-duplicated by
    /// item id. Sorting is the caller's responsibility (done in Swift so it can
    /// use the projected premiere date / year).
    func itemsCreditingPerson(personId: String) async throws -> [ItemRecord] {
        // Escape the id for a SQL LIKE pattern (`%`, `_`, and the escape char).
        let escaped = personId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\"id\":\"\(escaped)\"%"

        let candidates = try await db.writer.read { db in
            try ItemRecord
                .filter(sql: "castJSON IS NOT NULL AND castJSON LIKE ? ESCAPE '\\'", arguments: [pattern])
                .fetchAll(db)
        }

        var seen = Set<String>()
        var result: [ItemRecord] = []
        for record in candidates {
            guard let json = record.castJSON, let data = json.data(using: .utf8),
                  let stored = try? JSONDecoder().decode([StoredCast].self, from: data)
            else { continue }
            guard stored.contains(where: { $0.id == personId }) else { continue }
            if seen.insert(record.id).inserted { result.append(record) }
        }
        return result
    }
}
