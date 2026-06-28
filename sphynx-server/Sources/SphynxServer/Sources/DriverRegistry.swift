/// The driver framework's extension seam.
///
/// A backend is added by writing a `SourceDriver` and a `DriverRegistration` for
/// it, then listing that registration in `DriverFactory.defaultRegistrations` —
/// no central `switch` to edit. Each driver declares the config keys it needs,
/// reads its non-secret settings from `SourceContext.config` and credentials from
/// `SourceContext.secrets`, and stays within the contract: `list()` is a
/// metadata-only walk and `resolve()` returns a direct, client-fetchable URL. The
/// server never moves media bytes.

/// Everything a driver factory needs to build a driver for one source: its id,
/// decoded (non-secret) config and (secret) credentials, the shared HTTP fetcher,
/// and the legacy HTTP-shaped fields still honoured until fully migrated to
/// `config`. Decouples drivers from the `SourceRecord`'s column layout.
struct SourceContext: Sendable {
    let id: String
    let config: [String: String]
    let secrets: [String: String]
    let fetcher: any HTTPFetching
    // Legacy HTTP fields (baseURL/headers/manifestURL) — read as fallbacks.
    let baseURL: String?
    let headers: [String: String]
    let manifestURL: String?
}

/// A driver's self-registration: the kind it serves, the config keys it requires
/// (validated before `make` runs), and how to build it.
struct DriverRegistration: Sendable {
    let kind: String
    let requiredConfigKeys: [String]
    let make: @Sendable (SourceContext) throws -> any SourceDriver

    /// The same registration under a different kind string (e.g. `https` aliasing
    /// `http`).
    func aliased(as kind: String) -> DriverRegistration {
        DriverRegistration(kind: kind, requiredConfigKeys: requiredConfigKeys, make: make)
    }
}

/// Builds a concrete driver for a source by consulting a registry of
/// registrations keyed by driver kind. The one place that knows which drivers
/// exist — and it only knows the *list*, not the *mapping logic*.
struct DriverFactory: Sendable {
    let fetcher: any HTTPFetching
    private let registry: [String: DriverRegistration]

    init(
        fetcher: any HTTPFetching = URLSessionFetcher(),
        registrations: [DriverRegistration] = DriverFactory.defaultRegistrations
    ) {
        self.fetcher = fetcher
        self.registry = Dictionary(registrations.map { ($0.kind, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Every driver the server ships. Add a backend by appending its
    /// registration here (and writing the driver) — nothing else changes.
    static let defaultRegistrations: [DriverRegistration] = [
        HTTPDriver.registration,
        HTTPDriver.registration.aliased(as: "https"),
        LocalDriver.registration,
        WebDAVDriver.registration,
        SMBDriver.registration,
        FTPDriver.registration,
        TorBoxDriver.registration,
    ]

    /// The driver kinds this factory recognises.
    var supportedKinds: [String] { registry.keys.sorted() }

    func makeDriver(for source: SourceRecord) throws -> any SourceDriver {
        guard let registration = registry[source.driver] else {
            throw SphynxError.noMediaSource("Unsupported source driver '\(source.driver)'")
        }
        let config = source.config()
        let missing = registration.requiredConfigKeys.filter { (config[$0] ?? "").isEmpty }
        guard missing.isEmpty else {
            throw SphynxError.badRequest(
                "Source driver '\(registration.kind)' is missing config: \(missing.joined(separator: ", "))"
            )
        }
        let context = SourceContext(
            id: source.id,
            config: config,
            secrets: source.secrets(),
            fetcher: fetcher,
            baseURL: source.baseURL,
            headers: source.headers(),
            manifestURL: source.manifestURL
        )
        return try registration.make(context)
    }

    /// Driver for self-contained items whose key is an absolute URL (no source).
    func inlineHTTPDriver() -> HTTPDriver {
        HTTPDriver(id: "inline", baseURL: nil, headers: [:], ttl: nil, manifestURL: nil, fetcher: fetcher)
    }
}
