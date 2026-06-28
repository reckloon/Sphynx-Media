import Foundation

/// The field keys an admin can edit and lock against auto-refresh.
///
/// A locked field is authoritative: enrichment (index-time, TTL refresh, or a
/// forced re-enrich) and source-driven re-scans skip it, so a manual edit
/// survives. This generalizes the per-item `identityPinned` / `markersAuthoritative`
/// provenance to every field. Lock keys are stored uniformly as JSON text on the
/// item (`lockedFieldsJSON`) and are open-ended: unknown keys are tolerated.
enum LockableField {
    static let title = "title"
    static let overview = "overview"
    static let year = "year"
    static let runtime = "runtime"
    static let genres = "genres"
    static let communityRating = "communityRating"
    static let officialRating = "officialRating"
    /// Covers all artwork (primary/backdrop/thumb) as one unit.
    static let images = "images"
    /// The low-res placeholder.
    static let placeholder = "placeholder"
    static let cast = "cast"
    static let trailers = "trailers"
    static let tags = "tags"

    /// Every well-known lock key (for validation/UX; locking is not restricted to
    /// these — unknown keys are accepted and simply protect nothing today).
    static let wellKnown: [String] = [
        title, overview, year, runtime, genres, communityRating, officialRating,
        images, placeholder, cast, trailers, tags,
    ]
}
