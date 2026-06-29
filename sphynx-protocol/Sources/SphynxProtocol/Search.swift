import Foundation

/// Response for the **optional** search endpoint, `GET /v1/search?q=…` (§5.3).
/// Shaped deliberately like `ItemsResponse` so a client reuses the same result
/// rendering and cursor pagination.
///
/// **Search is optional — and often best done client-side.** A server advertises
/// whether it implements server-side search via `capabilities.search`. When that
/// is `false` (the reference server's default), the endpoint is simply absent and
/// the client searches its **own** synced catalogue instead — and is encouraged
/// to. A client already mirrors the library (browse + the `/v1/changes` delta
/// feed), so it can search locally however it likes:
///
/// - a substring / fuzzy match over the cached items;
/// - a query against the client's own local store (e.g. SQLite/Core Data);
/// - or something richer — **Ocelot ships a proprietary on-device LLM search**
///   over its synced catalogue, answering natural-language queries with zero
///   server cost or round-trip.
///
/// The protocol standardises only the **shape** of a server that *does* offer
/// search (so any such server is interchangeable); it never requires one to, and
/// it places no constraint on how matching or ranking is done. Request query
/// parameters: `q` (the query, required), `type` (optional `ItemType` filter),
/// `limit`, and `cursor` (opaque, from a prior `nextCursor`).
public struct SearchResponse: Codable, Hashable, Sendable {
    /// Matching items, server-ranked (most relevant first).
    public var items: [Item]
    /// Opaque forward cursor for the next page; absent ⇒ end of results.
    public var nextCursor: String?
    /// The query this response answers, echoed back. Optional.
    public var query: String?

    public init(items: [Item], nextCursor: String? = nil, query: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
        self.query = query
    }
}
