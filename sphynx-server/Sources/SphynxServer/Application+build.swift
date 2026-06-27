import Hummingbird
import Logging
import ServiceLifecycle

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
    policy: AccessPolicy,
    settings: SettingsStore
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
    BrowseController(catalog: catalog, playstate: playstate).addRoutes(to: securedV1)
    ResolveController(catalog: catalog, resolver: resolver).addRoutes(to: securedV1)
    PlaystateController(playstate: playstate).addRoutes(to: securedV1)
    MarkersController(catalog: catalog, policy: policy, staleAfter: configuration.markersStaleAfter).addRoutes(to: securedV1)
    AdminController(catalog: catalog, indexer: indexer, auth: auth, enrichment: enrichment,
                    settings: settings, configuration: configuration).addRoutes(to: securedV1)

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
    let policy = AccessPolicy.fromConfiguration(configuration)

    let router = buildRouter(
        configuration: configuration,
        auth: auth,
        catalog: catalog,
        resolver: resolver,
        indexer: indexer,
        enrichment: enrichment,
        playstate: playstate,
        policy: policy,
        settings: settingsStore
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
