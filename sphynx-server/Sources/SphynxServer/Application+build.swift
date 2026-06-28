import Hummingbird
import Logging
import ServiceLifecycle

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
    playstate: PlaystateService,
    userState: UserStateService,
    policy: AccessPolicy,
    settings: SettingsStore,
    events: EventBus
) -> Router<SphynxRequestContext> {
    let router = Router(context: SphynxRequestContext.self)

    // Every error leaves as the protocol envelope; log every request.
    router.add(middleware: ErrorMiddleware())
    router.add(middleware: LogRequestsMiddleware(.info))

    // Public surface: discovery + auth + the static web admin page.
    let authController = AuthController(auth: auth, policy: policy)
    let publicV1 = router.group("v1")
    InfoController(configuration: configuration, policy: policy).addRoutes(to: publicV1)
    authController.addRoutes(to: publicV1)
    AdminWebController.addRoutes(to: router)

    // Secured surface: everything else requires a valid bearer token.
    let securedV1 = router.group("v1").add(middleware: AuthMiddleware(auth: auth))
    authController.addSecuredRoutes(to: securedV1)
    let home = HomeService(catalog: catalog, playstate: playstate, userState: userState)
    BrowseController(catalog: catalog, playstate: playstate, userState: userState, home: home).addRoutes(to: securedV1)
    ChangesController(catalog: catalog, playstate: playstate, userState: userState).addRoutes(to: securedV1)
    PeopleController(catalog: catalog, userState: userState, playstate: playstate).addRoutes(to: securedV1)
    ResolveController(catalog: catalog, resolver: resolver).addRoutes(to: securedV1)
    PlaystateController(playstate: playstate, userState: userState, events: events).addRoutes(to: securedV1)
    UserStateController(catalog: catalog, userState: userState, events: events).addRoutes(to: securedV1)
    MarkersController(catalog: catalog, policy: policy, staleAfter: configuration.markersStaleAfter, events: events).addRoutes(to: securedV1)
    AdminController(catalog: catalog, indexer: indexer, auth: auth, enrichment: enrichment,
                    settings: settings, configuration: configuration, events: events).addRoutes(to: securedV1)
    EventsController(bus: events, heartbeat: configuration.eventsHeartbeat).addRoutes(to: securedV1)
    DiagnosticsController(catalog: catalog, diagnostics: DiagnosticsCenter.shared,
                          logStore: LogStore.shared).addRoutes(to: securedV1)

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
    let configuration = try await envConfiguration.resolvingSettings(store: settingsStore)

    let auth = AuthService(
        db: database,
        hasher: PasswordHasher(),
        accessTokenTTL: configuration.accessTokenTTL,
        refreshTokenTTL: configuration.refreshTokenTTL
    )
    try await auth.bootstrapAdminIfNeeded(
        username: configuration.adminUsername,
        password: configuration.adminPassword,
        logger: logger
    )

    let catalog = Catalog(db: database)
    let fetcher = httpFetcher ?? URLSessionFetcher()
    let drivers = DriverFactory(fetcher: fetcher)
    let resolver = Resolver(catalog: catalog, drivers: drivers)

    // Identification + enrichment are available only when TMDB is configured
    // (an injected client for tests, or a real client from the API key).
    let tmdb: (any TMDBClient)? = tmdbClient
        ?? (configuration.tmdbAPIKey.isEmpty ? nil : TMDBHTTPClient(apiKey: configuration.tmdbAPIKey, fetcher: fetcher))
    let enrichment: EnrichmentService? = tmdb.map { client in
        EnrichmentService(
            catalog: catalog,
            identifier: HeuristicIdentifier(tmdb: client),
            enricher: Enricher(tmdb: client),
            tv: TVEnricher(tmdb: client),
            ttl: configuration.enrichmentTTL,
            logger: logger
        )
    }
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
        playstate: playstate,
        userState: userState,
        policy: policy,
        settings: settingsStore,
        events: events
    )

    // Background maintenance: TTL-refresh stale enrichment + purge old playstate.
    // Disabled when the interval is 0 (e.g. tests / one-shot runs).
    var services: [any Service] = []
    if configuration.maintenanceInterval > 0 {
        services.append(MaintenanceService(
            interval: configuration.maintenanceInterval,
            enrichment: enrichment,
            playstate: playstate,
            playstateRetention: configuration.playstateRetention,
            logger: logger
        ))
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
