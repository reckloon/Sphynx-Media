import Foundation

/// Source-relative track selection hints (§6). All indices are source-relative.
public struct Tracks: Codable, Hashable, Sendable {
    public var preferredAudio: Int?
    public var copyableAudio: Int?
    public var preferredSubtitle: Int?

    public init(preferredAudio: Int? = nil, copyableAudio: Int? = nil, preferredSubtitle: Int? = nil) {
        self.preferredAudio = preferredAudio
        self.copyableAudio = copyableAudio
        self.preferredSubtitle = preferredSubtitle
    }
}

/// A single marker window. `end` is absent for open-ended markers (e.g. credits
/// that run to the end). Times in **seconds**.
public struct Marker: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double? = nil) {
        self.start = start
        self.end = end
    }
}

/// Optional intro/credit markers (§6), e.g. sourced from TheIntroDB by tmdbId.
public struct Markers: Codable, Hashable, Sendable {
    public var intro: Marker?
    public var credits: Marker?

    public init(intro: Marker? = nil, credits: Marker? = nil) {
        self.intro = intro
        self.credits = credits
    }
}

/// A ranked fallback location (§6). Present only if `/info` advertised
/// `capabilities.candidates`.
public struct Candidate: Codable, Hashable, Sendable {
    public var url: String
    public var headers: [String: String]
    public var priority: Int?

    public init(url: String, headers: [String: String] = [:], priority: Int? = nil) {
        self.url = url
        self.headers = headers
        self.priority = priority
    }
}

/// The playback descriptor returned by `GET /v1/resolve/<itemId>` (§6).
///
/// The core of Sphynx: turns an item into a direct, playable location plus the
/// hints a player needs. Called late, at play time — never cached from a browse
/// response — because direct locations may be time-bounded.
public struct ResolveDescriptor: Codable, Hashable, Sendable {
    /// DIRECT location; the client streams this itself.
    public var url: String
    /// Headers the client must send when fetching `url`.
    public var headers: [String: String]
    /// Source container hint (probe budgeting); optional.
    public var container: String?
    /// Seconds this descriptor is valid; absent = no expiry.
    public var ttl: Double?
    /// If true, the client skips its own redirect resolution.
    public var preResolved: Bool?

    public var tracks: Tracks?
    public var markers: Markers?
    /// Optional ranked fallbacks. Present only if `/info` advertised
    /// `capabilities.candidates`.
    public var candidates: [Candidate]?

    public init(
        url: String,
        headers: [String: String] = [:],
        container: String? = nil,
        ttl: Double? = nil,
        preResolved: Bool? = nil,
        tracks: Tracks? = nil,
        markers: Markers? = nil,
        candidates: [Candidate]? = nil
    ) {
        self.url = url
        self.headers = headers
        self.container = container
        self.ttl = ttl
        self.preResolved = preResolved
        self.tracks = tracks
        self.markers = markers
        self.candidates = candidates
    }
}
