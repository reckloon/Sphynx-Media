import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

/// Where hosted avatar images live: an `avatars/` directory beside the database
/// file, so they share the server's data directory. An in-memory database (tests)
/// gets a unique temp directory instead.
func avatarDirectory(for databasePath: String) -> URL {
    if databasePath == ":memory:" {
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sphynx-avatars-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }
    let dbURL = URL(fileURLWithPath: databasePath)
    let dir = dbURL.deletingLastPathComponent()
    return (dir.path.isEmpty ? URL(fileURLWithPath: ".") : dir)
        .appendingPathComponent("avatars", isDirectory: true)
}

/// Bootstraps the logging system once per process so that, alongside normal
/// stdout output, every record is mirrored into `LogStore` for the web admin
/// **Logs** tab. A global `let` runs its initializer exactly once, lazily and
/// thread-safely, so repeated `buildApplication` calls (e.g. the test suite) are
/// safe — `LoggingSystem.bootstrap` may only be called once.
private let loggingBootstrap: Void = {
    LoggingSystem.bootstrap { label in
        var stdout = StreamLogHandler.standardOutput(label: label)
        stdout.logLevel = .info
        var capture = CapturingLogHandler(label: label, store: LogStore.shared)
        capture.logLevel = .info
        return MultiplexLogHandler([stdout, capture])
    }
}()

/// Builds the router mapping the Sphynx protocol surface onto handlers.
///
/// Two route groups share the `/v1` prefix:
/// - a **public** group (`/v1/info`, `/v1/auth/*`) with no auth gate, and
/// - a **secured** group behind `AuthMiddleware` (browse, resolve, admin).
func buildRouter(
    configuration: ServerConfiguration,
    auth: AuthService,
    catalog: Catalog,
    resolver: Resolver,
    indexer: Indexer,
    enrichment: EnrichmentService?,
    languageProvider: MetadataLanguageProvider? = nil,
    playstate: PlaystateService,
    userState: UserStateService,
    policy: AccessPolicy,
    settings: SettingsStore,
    homeConfig: HomeConfigStore,
    events: EventBus,
    blurHashProgress: BackfillProgress? = nil,
    mediaProbeProgress: BackfillProgress? = nil,
    scheduleCenter: ScheduleCenter? = nil,
    runBlurHashNow: (@Sendable () async -> Void)? = nil,
    runMediaProbeNow: (@Sendable () async -> Void)? = nil
) -> Router<SphynxRequestContext> {
    let router = Router(context: SphynxRequestContext.self)

    // Every error leaves as the protocol envelope; log every request.
    router.add(middleware: ErrorMiddleware())
    router.add(middleware: LogRequestsMiddleware(.info))

    // Passkeys (WebAuthn) are available only when a Relying Party is configured;
    // otherwise the routes are absent and `capabilities.passkeys` is false.
    let passkeyController = configuration.relyingParty.map { rp in
        PasskeyController(passkeys: PasskeyService(
            db: auth.db,
            auth: auth,
            relyingPartyID: rp.id,
            relyingPartyName: rp.name,
            relyingPartyOrigin: rp.origin,
            challengeTTL: 300
        ))
    }

    // Device authorization (RFC 8628-style QR/code sign-in for TVs). Always on:
    // the approval step rides whatever auth the user already has (password/passkey).
    let deviceAuthController = DeviceAuthController(service: DeviceAuthService(
        db: auth.db, auth: auth, publicBaseURL: configuration.publicBaseURL))

    // OAuth-style web authorization (same-device web sign-in via a custom URL
    // scheme). Always on: it rides the same password auth as `/auth/login`, so a
    // client that can't add the server host to its Associated Domains can still do
    // a seamless web login. `redirect_uri` targets are constrained by the configured
    // allowlist (empty ⇒ app custom schemes only; web origins must be allowlisted).
    let webAuthController = WebAuthController(service: WebAuthService(
        db: auth.db, auth: auth, redirectAllowlist: configuration.webAuthRedirectList))

    // Public surface: discovery + auth + the static web admin page.
    let authController = AuthController(auth: auth, policy: policy, signInUserList: configuration.signInUserList)
    let publicV1 = router.group("v1")
    InfoController(configuration: configuration, policy: policy).addRoutes(to: publicV1)
    authController.addRoutes(to: publicV1)
    passkeyController?.addRoutes(to: publicV1)
    deviceAuthController.addRoutes(to: publicV1)
    webAuthController.addRoutes(to: publicV1)
    AdminWebController.addRoutes(to: router)
    UserWebController.addRoutes(to: router)
    DeviceLinkWebController.addRoutes(to: router)

    // Secured surface: everything else requires a valid bearer token.
    let securedV1 = router.group("v1").add(middleware: AuthMiddleware(auth: auth))
    authController.addSecuredRoutes(to: securedV1)
    passkeyController?.addSecuredRoutes(to: securedV1)
    deviceAuthController.addSecuredRoutes(to: securedV1)
    webAuthController.addSecuredRoutes(to: securedV1)
    let home = HomeService(catalog: catalog, playstate: playstate, userState: userState)
    BrowseController(catalog: catalog, playstate: playstate, userState: userState,
                     home: home, homeConfig: homeConfig, settings: settings).addRoutes(to: securedV1)
    ChangesController(catalog: catalog, playstate: playstate, userState: userState, settings: settings).addRoutes(to: securedV1)
    PeopleController(catalog: catalog, userState: userState, playstate: playstate, settings: settings).addRoutes(to: securedV1)
    ResolveController(catalog: catalog, resolver: resolver).addRoutes(to: securedV1)
    PlaystateController(playstate: playstate, userState: userState, catalog: catalog, events: events).addRoutes(to: securedV1)
    UserStateController(catalog: catalog, userState: userState, playstate: playstate, events: events, settings: settings).addRoutes(to: securedV1)
    MarkersController(catalog: catalog, policy: policy, staleAfter: configuration.markersStaleAfter, events: events).addRoutes(to: securedV1)
    AdminController(catalog: catalog, indexer: indexer, auth: auth, enrichment: enrichment,
                    settings: settings, homeConfig: homeConfig,
                    configuration: configuration, events: events,
                    languageProvider: languageProvider).addRoutes(to: securedV1)
    EventsController(bus: events, heartbeat: configuration.eventsHeartbeat).addRoutes(to: securedV1)
    DiagnosticsController(catalog: catalog, diagnostics: DiagnosticsCenter.shared,
                          logStore: LogStore.shared, schedule: scheduleCenter,
                          blurHashProgress: blurHashProgress, mediaProbeProgress: mediaProbeProgress).addRoutes(to: securedV1)
    ExtensionsController(
        catalog: catalog, resolver: resolver, settings: settings,
        blurHashProgress: blurHashProgress, mediaProbeProgress: mediaProbeProgress,
        runBlurHashNow: runBlurHashNow, runMediaProbeNow: runMediaProbeNow
    ).addRoutes(to: securedV1)

    return router
}

/// Assembles the runnable application: opens the database, wires the subsystems,
/// bootstraps the admin account, and builds the HTTP service.
///
/// `httpFetcher` is injectable so tests can supply a manifest without network.
func buildApplication(
    configuration envConfiguration: ServerConfiguration,
    httpFetcher: (any HTTPFetching)? = nil,
    tmdbClient: (any TMDBClient)? = nil
) async throws -> some ApplicationProtocol {
    _ = loggingBootstrap  // ensure stdout + LogStore capture are wired before any logging
    var logger = Logger(label: "sphynx")
    logger.logLevel = .info

    let database = try (envConfiguration.databasePath == ":memory:")
        ? AppDatabase.makeInMemory()
        : AppDatabase.makeOnDisk(path: envConfiguration.databasePath)

    // Persisted settings are the source of truth for runtime-tunable config
    // (server name, TTLs, marker access, …). Env vars only seed them on first run.
    let settingsStore = SettingsStore(db: database)
    let homeConfigStore = HomeConfigStore(db: database)
    let configuration = try await envConfiguration.resolvingSettings(store: settingsStore)

    let auth = AuthService(
        db: database,
        hasher: PasswordHasher(cost: configuration.bcryptCost),
        accessTokenTTL: configuration.accessTokenTTL,
        refreshTokenTTL: configuration.refreshTokenTTL,
        avatars: AvatarStore(directory: avatarDirectory(for: configuration.databasePath),
                             maxBytes: configuration.avatarMaxBytes)
    )
    try await auth.bootstrapAdminIfNeeded(
        username: configuration.adminUsername,
        password: configuration.adminPassword,
        logger: logger
    )

    let catalog = Catalog(db: database)
    // Sweep any items orphaned by an earlier library deletion (extras carry a nil
    // libraryId, so a pre-fix library delete left them stranded with no parent).
    if let orphans = try? await catalog.pruneOrphans(), orphans > 0 {
        logger.info("Pruned \(orphans) orphaned item(s) on startup")
    }
    let fetcher = httpFetcher ?? URLSessionFetcher()
    let drivers = DriverFactory(fetcher: fetcher)
    let resolver = Resolver(catalog: catalog, drivers: drivers)

    // TMDB key: core metadata config set in the GUI (Settings), seeded once from
    // the env var, then DB-authoritative. Read here so a GUI change applies on the
    // next restart, like the other runtime settings.
    let tmdbAPIKey: String
    let storedSettings = try await settingsStore.all()
    if let stored = storedSettings[AdminController.tmdbAPIKeySetting] {
        tmdbAPIKey = stored
    } else {
        tmdbAPIKey = envConfiguration.tmdbAPIKey
        if !tmdbAPIKey.isEmpty { try await settingsStore.set([AdminController.tmdbAPIKeySetting: tmdbAPIKey]) }
    }

    // Identification + enrichment are available only when TMDB is configured
    // (an injected client for tests, or a real client from the API key).
    // Live metadata-language holder: an admin's language change updates it so a
    // re-enrich picks up the new language without a restart.
    let languageProvider = MetadataLanguageProvider(configuration.metadataLanguage)
    let tmdb: (any TMDBClient)? = tmdbClient
        ?? (tmdbAPIKey.isEmpty ? nil : TMDBHTTPClient(apiKey: tmdbAPIKey, language: languageProvider, fetcher: fetcher))
    let enrichment: EnrichmentService? = tmdb.map { client in
        EnrichmentService(
            catalog: catalog,
            identifier: HeuristicIdentifier(tmdb: client),
            enricher: Enricher(tmdb: client),
            tv: TVEnricher(tmdb: client),
            ttl: configuration.enrichmentTTL,
            logger: logger,
            settings: settingsStore
        )
    }
    // Shared scheduling state: each background task reports its next run here for the
    // Activity panel's "Next runs" indicator. Plus the two extension backfills' live
    // progress (for their Extensions-tab status indicators) and the image generator.
    let scheduleCenter = ScheduleCenter()
    let blurHashProgress = BackfillProgress()
    let mediaProbeProgress = BackfillProgress()
    let blurHashGenerator = ImageBlurHashGenerator(fetcher: fetcher)
    // The two extension backfills are constructed up front so the Extensions
    // controller can trigger a one-off "Run now" pass even when the periodic loop
    // isn't registered (and so the loops, registered below, share these instances).
    let blurHashBackfill = BlurHashBackfillService(
        defaultInterval: configuration.maintenanceInterval,
        catalog: catalog, generator: blurHashGenerator, settings: settingsStore,
        progress: blurHashProgress, schedule: scheduleCenter, logger: logger)
    let mediaProbeBackfill = MediaProbeBackfillService(
        defaultInterval: 0,  // opt-in: manual-only until an admin sets an interval
        catalog: catalog, resolver: resolver, settings: settingsStore,
        progress: mediaProbeProgress, schedule: scheduleCenter, logger: logger)
    if enrichment == nil {
        logger.warning("TMDB not configured — items will not be identified/enriched (set SPHYNX_TMDB_API_KEY).")
    }
    let indexer = Indexer(
        catalog: catalog,
        drivers: drivers,
        enrichment: enrichment,
        tv: tmdb.map { TVEnricher(tmdb: $0) }
    )
    let playstate = PlaystateService(db: database)
    let userState = UserStateService(db: database)
    let policy = AccessPolicy.fromConfiguration(configuration)
    // In-process pub/sub for the additive SSE event stream (GET /v1/events).
    let events = EventBus()

    let router = buildRouter(
        configuration: configuration,
        auth: auth,
        catalog: catalog,
        resolver: resolver,
        indexer: indexer,
        enrichment: enrichment,
        languageProvider: languageProvider,
        playstate: playstate,
        userState: userState,
        policy: policy,
        settings: settingsStore,
        homeConfig: homeConfigStore,
        events: events,
        blurHashProgress: blurHashProgress,
        mediaProbeProgress: mediaProbeProgress,
        scheduleCenter: scheduleCenter,
        runBlurHashNow: { await blurHashBackfill.runTracked() },
        runMediaProbeNow: { await mediaProbeBackfill.runTracked() }
    )

    // Background tasks. Each reads its own interval live from settings; this gate is
    // the master switch that keeps tests / one-shot runs loop-free.
    var services: [any Service] = []
    if configuration.maintenanceInterval > 0 {
        // Enrichment refresh (TTL-gated) + playstate purge; interval read live.
        services.append(MaintenanceService(
            defaultInterval: configuration.maintenanceInterval,
            enrichment: enrichment,
            playstate: playstate,
            playstateRetention: configuration.playstateRetention,
            settings: settingsStore,
            schedule: scheduleCenter,
            logger: logger
        ))
        // Per-source auto-refresh (index): re-scan each source on its own interval.
        services.append(SourceRefreshService(
            tick: 60, catalog: catalog, indexer: indexer, schedule: scheduleCenter, logger: logger))
        // Lazy BlurHash backfill (low-res-images extension) and the opt-in media-probe
        // background pass — each on its own live interval.
        services.append(blurHashBackfill)
        services.append(mediaProbeBackfill)
    }

    return Application(
        router: router,
        configuration: .init(
            address: .hostname(configuration.hostname, port: configuration.port),
            serverName: "Sphynx"
        ),
        services: services,
        logger: logger
    )
}
