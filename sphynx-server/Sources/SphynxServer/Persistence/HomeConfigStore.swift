import Foundation
import GRDB

/// One configured home-screen row, as persisted (admin default or a user's
/// override) and as exposed on the config API. `kind` is a `ShelfKind` raw value;
/// `genre`/`decade` carry the parameter for the two parameterized kinds. The
/// built feed turns each enabled spec into a `Shelf` (and omits it if empty).
struct HomeShelfSpec: Codable, Sendable, Equatable {
    /// Stable row identity, also the wire `Shelf.id`. Core kinds use a short slug
    /// (`continue`/`recent`/`favorites`); parameterized kinds encode the parameter
    /// (`genre:Action`, `decade:1980`).
    var id: String
    /// A `ShelfKind` raw value: continueWatching | recentlyAdded | favorites | genre | releaseDecade.
    var kind: String
    var title: String
    /// Genre name, for `kind == "genre"`.
    var genre: String?
    /// Decade start year (e.g. 1980), for `kind == "releaseDecade"`.
    var decade: Int?
    /// A `ShelfAspect` raw value: portrait | landscape | square.
    var aspect: String
    /// Whether the row is shown. Disabled rows are kept (so the editor can toggle
    /// them) but skipped when building the feed.
    var enabled: Bool

    init(id: String, kind: String, title: String,
         genre: String? = nil, decade: Int? = nil,
         aspect: String = "portrait", enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.title = title
        self.genre = genre
        self.decade = decade
        self.aspect = aspect
        self.enabled = enabled
    }
}

extension HomeShelfSpec {
    /// A genre row (`genre:<Name>`), titled by the genre.
    static func genre(_ name: String) -> HomeShelfSpec {
        HomeShelfSpec(id: "genre:\(name)", kind: "genre", title: name, genre: name)
    }

    /// A decade row (`decade:<startYear>`), titled e.g. "1980s".
    static func decade(_ start: Int) -> HomeShelfSpec {
        HomeShelfSpec(id: "decade:\(start)", kind: "releaseDecade", title: "\(start)s", decade: start)
    }

    static let continueWatching = HomeShelfSpec(
        id: "continue", kind: "continueWatching", title: "Continue Watching", aspect: "landscape")
    static let recentlyAdded = HomeShelfSpec(
        id: "recent", kind: "recentlyAdded", title: "Recently Added")
    static let favorites = HomeShelfSpec(
        id: "favorites", kind: "favorites", title: "Favorites")
}

/// Reads and writes the home-screen layout. The admin **default** layout is a
/// single JSON blob in the `setting` table (same mechanism as other GUI-managed
/// settings); a **user** override lives in `userhomeconfig`. A user with no row
/// inherits the default; the default itself falls back to `builtInDefault` until
/// an admin saves one.
struct HomeConfigStore: Sendable {
    let db: AppDatabase

    /// Setting key holding the admin default layout (JSON `[HomeShelfSpec]`).
    static let defaultSettingKey = "homeShelves"

    // MARK: Default (admin)

    /// The admin default layout — the stored one, or `builtInDefault` if unset.
    func defaultShelves() async throws -> [HomeShelfSpec] {
        let json = try await db.writer.read { db in
            try String.fetchOne(db,
                sql: "SELECT value FROM setting WHERE key = ?",
                arguments: [Self.defaultSettingKey])
        }
        guard let json, let specs = Self.decode(json) else { return Self.builtInDefault }
        return specs
    }

    /// Whether an admin has saved a default layout (vs. still using the built-in
    /// default). Lets the GUI distinguish "shipped default" from "your saved one".
    func storedDefaultExists() async throws -> Bool {
        try await db.writer.read { db in
            try Bool.fetchOne(db,
                sql: "SELECT 1 FROM setting WHERE key = ?",
                arguments: [Self.defaultSettingKey]) ?? false
        }
    }

    /// Replace the admin default layout.
    func setDefaultShelves(_ specs: [HomeShelfSpec]) async throws {
        let json = Self.encode(specs.sanitized())
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO setting(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [Self.defaultSettingKey, json])
        }
    }

    // MARK: Per-user override

    /// A user's saved layout, or `nil` if they haven't customized.
    func userShelves(userId: String) async throws -> [HomeShelfSpec]? {
        let json = try await db.writer.read { db in
            try String.fetchOne(db,
                sql: "SELECT configJSON FROM userhomeconfig WHERE userId = ?",
                arguments: [userId])
        }
        guard let json else { return nil }
        return Self.decode(json)
    }

    /// Save a user's layout override.
    func setUserShelves(userId: String, _ specs: [HomeShelfSpec]) async throws {
        let json = Self.encode(specs.sanitized())
        try await db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO userhomeconfig(userId, configJSON) VALUES(?, ?) ON CONFLICT(userId) DO UPDATE SET configJSON = excluded.configJSON",
                arguments: [userId, json])
        }
    }

    /// Drop a user's override, so they fall back to the admin default ("reset").
    func clearUserShelves(userId: String) async throws {
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM userhomeconfig WHERE userId = ?", arguments: [userId])
        }
    }

    /// The layout in effect for a user: their override if present, else the default.
    func effective(userId: String) async throws -> [HomeShelfSpec] {
        if let mine = try await userShelves(userId: userId) { return mine }
        return try await defaultShelves()
    }

    // MARK: Built-in default

    /// The layout shipped until an admin customizes it. Genre/decade rows that
    /// match nothing are simply omitted from the built feed, so this is safe on a
    /// sparse library.
    static let builtInDefault: [HomeShelfSpec] = [
        .continueWatching,
        .recentlyAdded,
        .favorites,
        .genre("Action"),
        .genre("Comedy"),
        .genre("Science Fiction"),
        .decade(1980),
    ]

    // MARK: JSON

    private static func decode(_ json: String) -> [HomeShelfSpec]? {
        guard let data = json.data(using: .utf8),
              let specs = try? JSONDecoder().decode([HomeShelfSpec].self, from: data) else { return nil }
        return specs.sanitized()
    }

    private static func encode(_ specs: [HomeShelfSpec]) -> String {
        (try? String(data: JSONEncoder().encode(specs), encoding: .utf8)) ?? "[]"
    }
}

extension Array where Element == HomeShelfSpec {
    /// Drop malformed/unknown rows and cap the count, so neither a hand-edited
    /// default nor an API payload can produce an unbuildable feed.
    func sanitized() -> [HomeShelfSpec] {
        let valid = compactMap { spec -> HomeShelfSpec? in
            switch spec.kind {
            case "continueWatching", "recentlyAdded", "favorites":
                return spec
            case "genre":
                guard let g = spec.genre, !g.isEmpty else { return nil }
                return spec
            case "releaseDecade":
                guard let d = spec.decade, d > 0 else { return nil }
                return spec
            default:
                return nil    // unknown kind — never built
            }
        }
        // De-duplicate by id (first wins) and cap to a sane maximum number of rows.
        var seen = Set<String>()
        let unique = valid.filter { seen.insert($0.id).inserted }
        return Array(unique.prefix(50))
    }
}
