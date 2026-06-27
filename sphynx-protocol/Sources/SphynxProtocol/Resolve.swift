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

/// A well-known timeline-segment type. Open enum: a server (or extension) may
/// define additional segment types, and a client tolerates ones it doesn't know.
/// The four built-in types cover the common "skip" affordances.
public enum MarkerType: OpenEnum {
    /// A "previously on…" recap at the head of an episode.
    case recap
    /// The opening title sequence.
    case intro
    /// The closing credits.
    case credits
    /// A "next time on…" / preview tail.
    case preview
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "recap": self = .recap
        case "intro": self = .intro
        case "credits": self = .credits
        case "preview": self = .preview
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .recap: "recap"
        case .intro: "intro"
        case .credits: "credits"
        case .preview: "preview"
        case .unknown(let value): value
        }
    }
}

/// Timeline-segment markers for an item (§6) — recap / intro / credits / preview
/// and beyond. Each segment maps a **type** to a time window, so a client can
/// offer "Skip Recap", "Skip Intro", "Next Episode", etc.
///
/// The type space is **open**: the four well-known types have convenience
/// accessors, but a server or extension may contribute any segment type (the
/// `segments` map is keyed by an arbitrary string) and clients ignore types they
/// don't recognise. On the wire this is a flat object —
/// `{ "intro": {…}, "credits": {…}, "recap": {…} }` — so it stays backward
/// compatible with the original intro/credits shape.
public struct Markers: Codable, Hashable, Sendable {
    /// Segment type (`MarkerType.rawValue`) → window. Open-ended.
    public var segments: [String: Marker]

    public init(segments: [String: Marker] = [:]) {
        self.segments = segments
    }

    /// Convenience initialiser for the well-known segment types.
    public init(
        recap: Marker? = nil,
        intro: Marker? = nil,
        credits: Marker? = nil,
        preview: Marker? = nil
    ) {
        var segments: [String: Marker] = [:]
        segments[MarkerType.recap.rawValue] = recap
        segments[MarkerType.intro.rawValue] = intro
        segments[MarkerType.credits.rawValue] = credits
        segments[MarkerType.preview.rawValue] = preview
        self.segments = segments
    }

    /// Read/write a segment by type (well-known or custom).
    public subscript(type: MarkerType) -> Marker? {
        get { segments[type.rawValue] }
        set { segments[type.rawValue] = newValue }
    }

    public var recap: Marker? {
        get { self[.recap] }
        set { self[.recap] = newValue }
    }
    public var intro: Marker? {
        get { self[.intro] }
        set { self[.intro] = newValue }
    }
    public var credits: Marker? {
        get { self[.credits] }
        set { self[.credits] = newValue }
    }
    public var preview: Marker? {
        get { self[.preview] }
        set { self[.preview] = newValue }
    }

    /// Whether any segment is present.
    public var isEmpty: Bool { segments.isEmpty }

    // Flat wire shape: the segment map IS the JSON object.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.segments = try container.decode([String: Marker].self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(segments)
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
    /// `true` when `url` is the driver's **terminal** location — fetch it
    /// directly, with no further Sphynx-level resolve step. This is the driver's
    /// own assertion about what it produced, **not the result of probing the
    /// origin**: it says nothing about ordinary HTTP redirects (the client's HTTP
    /// stack follows those normally) and nothing about timing (resolution is
    /// always fresh at play time). Absent/`false` would mean the client must
    /// itself resolve `url` further before fetching.
    public var terminal: Bool?

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
        terminal: Bool? = nil,
        tracks: Tracks? = nil,
        markers: Markers? = nil,
        candidates: [Candidate]? = nil
    ) {
        self.url = url
        self.headers = headers
        self.container = container
        self.ttl = ttl
        self.terminal = terminal
        self.tracks = tracks
        self.markers = markers
        self.candidates = candidates
    }
}
