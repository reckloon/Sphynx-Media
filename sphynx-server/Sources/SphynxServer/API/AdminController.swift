import Foundation
import Hummingbird
import SphynxProtocol

/// Admin-only endpoints for catalog setup + manual entry. These are
/// server-specific (not part of the client-facing wire protocol) and live under
/// `/v1/admin/*`, behind `AuthMiddleware` + an admin-role check.
struct AdminController: Sendable {
    let catalog: Catalog
    let indexer: Indexer
    let auth: AuthService
    /// Present only when TMDB is configured.
    let enrichment: EnrichmentService?
    /// Persisted runtime settings (server name, TTLs, marker access, …).
    let settings: SettingsStore
    /// The default home-screen layout (admin-owned) + per-user overrides.
    let homeConfig: HomeConfigStore
    /// The effective configuration this process booted with (for GET fallback).
    let configuration: ServerConfiguration
    /// Live updates: scans + library edits publish library-scoped `library` events
    /// nudging clients to refresh "recently added" / library views.
    let events: EventBus

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let admin = group.group("admin")
        admin.get("settings", use: getSettings)
        admin.patch("settings", use: updateSettings)
        admin.get("home", use: getHomeDefault)
        admin.put("home", use: setHomeDefault)
        admin.get("genres", use: listGenres)
        admin.get("tmdb", use: getTMDB)
        admin.patch("tmdb", use: updateTMDB)
        admin.post("libraries", use: createLibrary)
        admin.get("libraries", use: listLibraries)
        admin.patch("libraries/:libraryId", use: updateLibrary)
        admin.delete("libraries/:libraryId", use: deleteLibrary)
        admin.post("sources", use: createSource)
        admin.get("sources", use: listSources)
        admin.patch("sources/:sourceId", use: updateSource)
        admin.delete("sources/:sourceId", use: deleteSource)
        admin.post("sources/:sourceId/scan", use: scanSource)
        admin.post("libraries/:libraryId/scan", use: scanLibrary)
        admin.post("scan", use: scanAll)
        admin.post("items", use: createItem)
        admin.get("items", use: listItems)
        admin.get("items/:itemId", use: getItem)
        admin.patch("items/:itemId", use: editItem)
        admin.delete("items/:itemId", use: deleteItem)
        admin.post("items/:itemId/identity", use: setIdentity)
        admin.post("items/:itemId/enrich", use: enrichItem)
        admin.post("enrich", use: enrichAll)
        admin.get("collections", use: listCollections)
        admin.get("collections/candidates", use: collectionCandidates)
        admin.post("collections", use: createCollection)
        admin.patch("collections/:collectionId", use: updateCollection)
        admin.delete("collections/:collectionId", use: deleteCollection)
        admin.get("permissions", use: listPermissions)
        admin.get("users", use: listUsers)
        admin.post("users", use: createUser)
        admin.delete("users/:userId", use: deleteUser)
        admin.put("users/:userId/permissions", use: setPermissions)
        admin.put("users/:userId/password", use: resetPassword)
    }

    @Sendable
    func listUsers(_ request: Request, context: SphynxRequestContext) async throws -> AdminUsersResponse {
        try requireAdmin(context)
        let users = try await auth.listUsers()
        return AdminUsersResponse(users: users.map(AdminUserResponse.init(from:)))
    }

    /// The permission vocabulary for the admin editor: well-known capabilities plus
    /// the libraries each can be scoped to. Lets the UI render a data-driven matrix.
    @Sendable
    func listPermissions(_ request: Request, context: SphynxRequestContext) async throws -> PermissionsCatalogResponse {
        try requireAdmin(context)
        let libraries = try await catalog.libraries()
        return PermissionsCatalogResponse(
            permissions: Permissions.catalog,
            libraries: libraries.map { ScopeLibrary(id: $0.id, title: $0.title) }
        )
    }

    /// Create a non-admin user. There is exactly one admin (the bootstrap
    /// account), so any `isAdmin` in the body is ignored. New users default to
    /// `library.read` (browse + play) when no permissions are supplied.
    @Sendable
    func createUser(_ request: Request, context: SphynxRequestContext) async throws -> AdminUserResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateUserRequest.self, context: context)
        guard !body.username.isEmpty, !body.password.isEmpty else {
            throw SphynxError.badRequest("username and password are required")
        }
        let user = try await auth.createUser(
            username: body.username,
            password: body.password,
            displayName: body.displayName,
            permissions: body.permissions ?? Permissions.newUserDefault
        )
        return AdminUserResponse(from: user)
    }

    @Sendable
    func setPermissions(_ request: Request, context: SphynxRequestContext) async throws -> AdminUserResponse {
        try requireAdmin(context)
        guard let userId = context.parameters.get("userId") else {
            throw SphynxError.badRequest("Missing user id")
        }
        let body = try await request.decode(as: SetPermissionsRequest.self, context: context)
        let user = try await auth.setPermissions(userId: userId, permissions: body.permissions)
        return AdminUserResponse(from: user)
    }

    @Sendable
    func deleteUser(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        try requireAdmin(context)
        guard let userId = context.parameters.get("userId") else {
            throw SphynxError.badRequest("Missing user id")
        }
        try await auth.deleteUser(userId: userId)
        return Response(status: .noContent)
    }

    /// Admin reset of another user's password (no current password required).
    @Sendable
    func resetPassword(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        try requireAdmin(context)
        guard let userId = context.parameters.get("userId") else {
            throw SphynxError.badRequest("Missing user id")
        }
        let body = try await request.decode(as: ResetPasswordRequest.self, context: context)
        try await auth.adminSetPassword(userId: userId, newPassword: body.newPassword)
        return Response(status: .noContent)
    }

    /// The video-only library kinds the reference server manages, each with a
    /// fixed display name. The protocol's `LibraryKind` stays deliberately wider
    /// (homeVideos, musicVideos, boxSets, …); the server intentionally exposes
    /// just these three — it serves no audio — as on/off toggles in the admin
    /// UI, one library per kind with a fixed name.
    static let serverLibraryKinds: [(kind: String, title: String)] = [
        ("movies", "Movies"),
        ("tvShows", "TV Shows"),
        ("collection", "Collections"),
    ]

    /// Item types a manual correction may assign (mirrors the protocol's ItemType).
    static let knownItemTypes: Set<String> = [
        "movie", "series", "season", "episode", "collection",
        "trailer", "featurette", "deletedScene", "behindTheScenes",
    ]

    @Sendable
    func createLibrary(_ request: Request, context: SphynxRequestContext) async throws -> LibraryResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateLibraryRequest.self, context: context)
        guard let canon = Self.serverLibraryKinds.first(where: { $0.kind == body.kind }) else {
            throw SphynxError.badRequest("Unsupported library kind. Allowed: movies, tvShows, collection.")
        }
        // One library per kind: these are fixed-name on/off toggles, not free-form.
        guard try await catalog.libraries().allSatisfy({ $0.kind != canon.kind }) else {
            throw SphynxError.badRequest("A \(canon.title) library already exists.")
        }
        let record = try await catalog.createLibrary(title: canon.title, kind: canon.kind)
        await notifyLibrariesChanged([record.id], action: "added")
        return LibraryResponse(record)
    }

    /// Current persisted runtime settings (stored values, falling back to what the
    /// server booted with for any not-yet-stored key).
    @Sendable
    func getSettings(_ request: Request, context: SphynxRequestContext) async throws -> SettingsResponse {
        try requireAdmin(context)
        let effective = configuration.applying(try await settings.all())
        return SettingsResponse(from: effective)
    }

    /// Update runtime settings. Only the provided keys change; values are
    /// persisted and take effect on the next restart.
    @Sendable
    func updateSettings(_ request: Request, context: SphynxRequestContext) async throws -> SettingsResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: UpdateSettingsRequest.self, context: context)
        var updates: [String: String] = [:]
        // TTLs must be strictly positive — a non-positive access-token TTL would
        // issue already-expired tokens and break login after the next restart.
        func requirePositive(_ v: Double, _ label: String) throws -> Double {
            guard v > 0 else { throw SphynxError.badRequest("\(label) must be greater than 0") }
            return v
        }
        if let v = body.serverName { updates[SettingKey.serverName.rawValue] = v }
        if let v = body.serverID { updates[SettingKey.serverID.rawValue] = v }
        if let v = body.accessTokenTTL { updates[SettingKey.accessTokenTTL.rawValue] = String(try requirePositive(v, "accessTokenTTL")) }
        if let v = body.refreshTokenTTL { updates[SettingKey.refreshTokenTTL.rawValue] = String(try requirePositive(v, "refreshTokenTTL")) }
        if let v = body.enrichmentTTL { updates[SettingKey.enrichmentTTL.rawValue] = String(try requirePositive(v, "enrichmentTTL")) }
        if let v = body.metadataLanguage { updates[SettingKey.metadataLanguage.rawValue] = v.trimmingCharacters(in: .whitespaces) }
        if let v = body.markersAccess {
            guard ["none", "read", "readwrite"].contains(v) else {
                throw SphynxError.badRequest("markersAccess must be none | read | readwrite")
            }
            updates[SettingKey.markersAccess.rawValue] = v
        }
        // Non-negative durations/limits; a negative maintenanceInterval simply disables it.
        if let v = body.markersStaleAfter { updates[SettingKey.markersStaleAfter.rawValue] = String(max(0, v)) }
        if let v = body.playstateRetention { updates[SettingKey.playstateRetention.rawValue] = String(max(0, v)) }
        if let v = body.maintenanceInterval { updates[SettingKey.maintenanceInterval.rawValue] = String(v) }
        if let v = body.avatarMaxBytes { updates[SettingKey.avatarMaxBytes.rawValue] = String(max(0, v)) }
        if let v = body.signInUserList { updates[SettingKey.signInUserList.rawValue] = String(v) }
        // Passkey Relying Party. The RP id is a bare registrable domain — reject a
        // scheme/port/path so a misconfiguration fails loudly instead of silently
        // breaking every ceremony. Empty disables passkeys.
        if let v = body.passkeyRelyingPartyID {
            let id = v.trimmingCharacters(in: .whitespaces)
            if !id.isEmpty, id.contains("/") || id.contains(":") {
                throw SphynxError.badRequest("passkeyRelyingPartyID must be a bare domain (no scheme, port, or path), e.g. media.example.com")
            }
            updates[SettingKey.passkeyRelyingPartyID.rawValue] = id
        }
        if let v = body.passkeyRelyingPartyName { updates[SettingKey.passkeyRelyingPartyName.rawValue] = v }
        if let v = body.passkeyRelyingPartyOrigin {
            let origin = v.trimmingCharacters(in: .whitespaces)
            if !origin.isEmpty, !(origin.hasPrefix("https://") || origin.hasPrefix("http://")) {
                throw SphynxError.badRequest("passkeyRelyingPartyOrigin must include a scheme, e.g. https://media.example.com")
            }
            updates[SettingKey.passkeyRelyingPartyOrigin.rawValue] = origin
        }
        // Web-auth redirect allowlist: newline/comma-separated exact URIs or scheme
        // prefixes. Stored verbatim (trimmed); empty restores the default policy
        // (custom schemes allowed, http(s) origins rejected).
        if let v = body.webAuthRedirectAllowlist {
            updates[SettingKey.webAuthRedirectAllowlist.rawValue] = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        try await settings.set(updates)
        let effective = configuration.applying(try await settings.all())
        return SettingsResponse(from: effective)
    }

    /// The admin **default** home-screen layout (the ordered rows new/unconfigured
    /// users see). Falls back to the built-in default until an admin saves one.
    @Sendable
    func getHomeDefault(_ request: Request, context: SphynxRequestContext) async throws -> HomeConfigResponse {
        try requireAdmin(context)
        let specs = try await homeConfig.defaultShelves()
        // `customized` here means "an admin has saved a layout" — distinct from the
        // per-user flag, but the same wire shape so the GUI can reuse it.
        let stored = try await homeConfig.storedDefaultExists()
        return HomeConfigResponse(shelves: specs.map(HomeShelfDTO.init), customized: stored)
    }

    /// Replace the admin default home layout. Malformed rows are dropped server-side.
    @Sendable
    func setHomeDefault(_ request: Request, context: SphynxRequestContext) async throws -> HomeConfigResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: HomeConfigRequest.self, context: context)
        try await homeConfig.setDefaultShelves(body.shelves.map(\.spec))
        let specs = try await homeConfig.defaultShelves()
        return HomeConfigResponse(shelves: specs.map(HomeShelfDTO.init), customized: true)
    }

    /// Distinct genres present in the catalog — to populate the Home-tab row picker.
    @Sendable
    func listGenres(_ request: Request, context: SphynxRequestContext) async throws -> GenresResponse {
        try requireAdmin(context)
        return GenresResponse(genres: try await catalog.distinctGenres())
    }

    /// Persisted-settings key for the TMDB v3 API key. Core metadata config (not an
    /// extension): identification + enrichment depend on it. Seeded once from
    /// `SPHYNX_TMDB_API_KEY`; read at boot, so a change applies on the next restart.
    static let tmdbAPIKeySetting = "tmdb.apiKey"

    /// Masked view of the TMDB key — never returns the full value.
    @Sendable
    func getTMDB(_ request: Request, context: SphynxRequestContext) async throws -> TMDBKeyStatus {
        try requireAdmin(context)
        return try await tmdbStatus()
    }

    @Sendable
    func updateTMDB(_ request: Request, context: SphynxRequestContext) async throws -> TMDBKeyStatus {
        try requireAdmin(context)
        let body = try await request.decode(as: TMDBKeyUpdate.self, context: context)
        if let key = body.apiKey {
            try await settings.set([Self.tmdbAPIKeySetting: key.trimmingCharacters(in: .whitespaces)])
        }
        return try await tmdbStatus()
    }

    private func tmdbStatus() async throws -> TMDBKeyStatus {
        let key = (try await settings.all())[Self.tmdbAPIKeySetting] ?? ""
        let hint = key.count >= 4 ? "…" + String(key.suffix(4)) : (key.isEmpty ? nil : "set")
        return TMDBKeyStatus(configured: !key.isEmpty, keyHint: hint, appliesOnRestart: true)
    }

    @Sendable
    func listLibraries(_ request: Request, context: SphynxRequestContext) async throws -> AdminLibrariesResponse {
        try requireAdmin(context)
        let records = try await catalog.libraries()
        return AdminLibrariesResponse(libraries: records.map(LibraryResponse.init))
    }

    @Sendable
    func updateLibrary(_ request: Request, context: SphynxRequestContext) async throws -> LibraryResponse {
        try requireAdmin(context)
        guard let libraryId = context.parameters.get("libraryId") else {
            throw SphynxError.badRequest("Missing library id")
        }
        let body = try await request.decode(as: UpdateLibraryRequest.self, context: context)
        let record = try await catalog.updateLibrary(
            id: libraryId, title: body.title, kind: body.kind,
            collectionThreshold: body.collectionThreshold
        )
        await notifyLibrariesChanged([record.id], action: "updated")
        return LibraryResponse(record)
    }

    /// Delete a library, cascading to its items + the sources that feed it.
    @Sendable
    func deleteLibrary(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        try requireAdmin(context)
        guard let libraryId = context.parameters.get("libraryId") else {
            throw SphynxError.badRequest("Missing library id")
        }
        try await catalog.deleteLibrary(id: libraryId)
        await notifyLibrariesChanged([libraryId], action: "removed")
        return Response(status: .noContent)
    }

    @Sendable
    func listSources(_ request: Request, context: SphynxRequestContext) async throws -> SourcesResponse {
        try requireAdmin(context)
        let records = try await catalog.sources()
        return SourcesResponse(sources: records.map(SourceResponse.init(from:)))
    }

    @Sendable
    func updateSource(_ request: Request, context: SphynxRequestContext) async throws -> SourceResponse {
        try requireAdmin(context)
        guard let sourceId = context.parameters.get("sourceId") else {
            throw SphynxError.badRequest("Missing source id")
        }
        let body = try await request.decode(as: UpdateSourceRequest.self, context: context)
        if let libraryId = body.libraryId, try await catalog.library(id: libraryId) == nil {
            throw SphynxError.badRequest("No library '\(libraryId)'")
        }
        try await requireLibrariesExist(body.libraryMap)
        let record = try await catalog.updateSource(
            id: sourceId,
            label: body.label,
            baseURL: body.baseURL,
            headers: body.headers,
            manifestURL: body.manifestURL,
            libraryId: body.libraryId,
            config: body.config,
            secrets: body.secrets,
            libraryMap: body.libraryMap,
            refreshInterval: body.refreshInterval
        )
        return SourceResponse(from: record)
    }

    /// Validate that every library referenced by a source's type→library map
    /// actually exists.
    private func requireLibrariesExist(_ map: [String: String]?) async throws {
        guard let map else { return }
        for libraryId in Set(map.values) where try await catalog.library(id: libraryId) == nil {
            throw SphynxError.badRequest("No library '\(libraryId)'")
        }
    }

    /// Delete a source, cascading to its items + now-empty containers.
    @Sendable
    func deleteSource(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        try requireAdmin(context)
        guard let sourceId = context.parameters.get("sourceId") else {
            throw SphynxError.badRequest("Missing source id")
        }
        try await catalog.deleteSource(id: sourceId)
        return Response(status: .noContent)
    }

    /// Delete an item, cascading to its subtree + pruning emptied containers.
    @Sendable
    func deleteItem(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        try requireAdmin(context)
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        try await catalog.deleteItemTree(id: itemId)
        return Response(status: .noContent)
    }

    @Sendable
    func createSource(_ request: Request, context: SphynxRequestContext) async throws -> SourceResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateSourceRequest.self, context: context)
        if let libraryId = body.libraryId, try await catalog.library(id: libraryId) == nil {
            throw SphynxError.badRequest("No library '\(libraryId)'")
        }
        try await requireLibrariesExist(body.libraryMap)
        let record = try await catalog.createSource(
            label: body.label,
            driver: body.driver ?? "http",
            baseURL: body.baseURL,
            headers: body.headers,
            libraryId: body.libraryId,
            manifestURL: body.manifestURL,
            config: body.config,
            secrets: body.secrets,
            libraryMap: body.libraryMap,
            refreshInterval: body.refreshInterval ?? 0
        )
        return SourceResponse(from: record)
    }

    /// Scanning is gated by `catalog.scan` (admin always passes; source config and
    /// credentials stay admin-only). Held globally or scoped to any library the
    /// target feeds.
    private func requireScan(_ context: SphynxRequestContext, libraries: Set<String>) throws {
        let identity = try context.requireIdentity()
        if identity.has(Permissions.catalogScan) { return }
        for lib in libraries where identity.has(Permissions.catalogScan, inLibrary: lib) { return }
        throw SphynxError.forbidden("You don't have permission to scan")
    }

    @Sendable
    func scanSource(_ request: Request, context: SphynxRequestContext) async throws -> IndexSummary {
        guard let sourceId = context.parameters.get("sourceId") else {
            throw SphynxError.badRequest("Missing source id")
        }
        guard let source = try await catalog.source(id: sourceId) else {
            throw SphynxError.notFound("No source '\(sourceId)'")
        }
        try requireScan(context, libraries: source.feedsLibraries())
        let summary = try await indexer.scan(sourceId: sourceId)
        await notifyLibrariesChanged(source.feedsLibraries(), action: "scanned")
        return summary
    }

    /// Re-scan every source feeding one library. Per-library refresh, gated by
    /// `catalog.scan` for that library (or globally / admin).
    @Sendable
    func scanLibrary(_ request: Request, context: SphynxRequestContext) async throws -> IndexAllSummary {
        guard let libraryId = context.parameters.get("libraryId") else {
            throw SphynxError.badRequest("Missing library id")
        }
        try requireScan(context, libraries: [libraryId])
        let sources = try await catalog.sources().filter { $0.feedsLibraries().contains(libraryId) }
        var summaries: [IndexSummary] = []
        for source in sources { summaries.append(try await indexer.scan(sourceId: source.id)) }
        await notifyLibrariesChanged([libraryId], action: "scanned")
        return IndexAllSummary(sources: summaries)
    }

    @Sendable
    func scanAll(_ request: Request, context: SphynxRequestContext) async throws -> IndexAllSummary {
        // Scanning everything needs the unscoped grant (a per-library scope can't
        // authorize a full-catalog scan).
        let identity = try context.requireIdentity()
        guard identity.has(Permissions.catalogScan) else {
            throw SphynxError.forbidden("You don't have permission to scan")
        }
        let summary = IndexAllSummary(sources: try await indexer.scanAll())
        var libs: Set<String> = []
        for source in try await catalog.sources() { libs.formUnion(source.feedsLibraries()) }
        await notifyLibrariesChanged(libs, action: "scanned")
        return summary
    }

    /// Emit a `library` event per affected library so clients refresh their views.
    private func notifyLibrariesChanged(_ libraryIds: Set<String>, action: String) async {
        let now = Date().timeIntervalSince1970
        for libraryId in libraryIds {
            await events.publish(.library(libraryId: libraryId, action: action, ts: now),
                                 to: .library(libraryId))
        }
    }

    @Sendable
    func createItem(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateItemRequest.self, context: context)
        guard !body.title.isEmpty, !body.sourceKey.isEmpty else {
            throw SphynxError.badRequest("title and sourceKey are required")
        }
        let record = try await catalog.createItem(
            type: body.type ?? "movie",
            title: body.title,
            sourceId: body.sourceId,
            sourceKey: body.sourceKey,
            container: body.container,
            tmdbId: body.tmdbId,
            libraryId: body.libraryId,
            parentId: body.parentId,
            year: body.year,
            extra: body.extra
        )
        return record.toProtocol(full: true)
    }

    /// Edit an item's metadata and **lock** each edited field against
    /// auto-refresh. Gated by the `metadata.edit` permission (scoped to the
    /// item's library), so a non-admin editor can be granted it. A locked field
    /// survives every scan, TTL refresh, and forced enrich; `unlock`/`unlockAll`
    /// re-enables auto-refresh for those fields.
    /// Browse the catalog as a **raw file hierarchy** for the correction UI: the
    /// direct children of `parent` (a library id → its ungrouped top level; an item
    /// id → that container's children). No collection grouping, so movies show
    /// individually and collections appear as openable folders — a 1-to-1 reflection
    /// of the indexed source tree that touches no driver/CDN (it reads the catalog).
    /// Gated by `metadata.edit` for the resolved library (admins always pass), so a
    /// non-admin editor can use it too.
    @Sendable
    func listItems(_ request: Request, context: SphynxRequestContext) async throws -> AdminItemsResponse {
        let identity = try context.requireIdentity()
        let query = try request.uri.decodeQuery(as: AdminItemsQuery.self, context: context)
        let limit = min(max(query.limit ?? 250, 1), 500)

        // Catalog-wide search / "needs metadata" filter: spans every library the
        // caller can edit, so you can find a title (or everything still unenriched)
        // without first drilling into a library.
        let searchTerm = query.search?.trimmingCharacters(in: .whitespaces)
        let needsAttention = query.needsAttention == true
        if (searchTerm?.isEmpty == false) || needsAttention {
            let records = try await catalog.searchItems(
                titleQuery: searchTerm, unenrichedOnly: needsAttention, limit: limit)
            // Admins edit everywhere; otherwise keep only items in editable libraries.
            let editsEverywhere = identity.has(Permissions.metadataEdit)
            var allowed: [ItemRecord] = []
            for record in records {
                if editsEverywhere {
                    allowed.append(record)
                } else {
                    let lib = try await catalog.owningLibraryId(of: record)
                    if identity.has(Permissions.metadataEdit, inLibrary: lib) { allowed.append(record) }
                }
            }
            return AdminItemsResponse(items: allowed.map { $0.toProtocol(full: true) })
        }

        guard let parent = query.parent, !parent.isEmpty else {
            throw SphynxError.badRequest("query parameter 'parent' is required")
        }
        let records: [ItemRecord]
        let libraryId: String?
        if try await catalog.library(id: parent) != nil {
            libraryId = parent
            records = try await catalog.rawTopLevel(libraryId: parent, limit: limit, offset: 0)
        } else if let parentItem = try await catalog.item(id: parent) {
            libraryId = try await catalog.owningLibraryId(of: parentItem)
            records = try await catalog.childItems(parentId: parent, limit: limit, offset: 0)
        } else {
            throw SphynxError.notFound("No library or item '\(parent)'")
        }
        guard identity.has(Permissions.metadataEdit, inLibrary: libraryId) else {
            throw SphynxError.forbidden("You don't have permission to edit metadata here")
        }
        return AdminItemsResponse(items: records.prefix(limit).map { $0.toProtocol(full: true) })
    }

    /// Read one item with its current lock state, for the admin correction UI.
    /// Gated by `metadata.edit` for the item's library (admins always pass).
    @Sendable
    func getItem(_ request: Request, context: SphynxRequestContext) async throws -> AdminItemResponse {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.has(Permissions.metadataEdit, inLibrary: libraryId, forItem: itemId) else {
            throw SphynxError.forbidden("You don't have permission to edit metadata")
        }
        return AdminItemResponse(item: item.toProtocol(full: true), lockedFields: item.lockedFields().sorted())
    }

    @Sendable
    func editItem(_ request: Request, context: SphynxRequestContext) async throws -> AdminItemResponse {
        let identity = try context.requireIdentity()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard var item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.has(Permissions.metadataEdit, inLibrary: libraryId, forItem: itemId) else {
            throw SphynxError.forbidden("You don't have permission to edit metadata")
        }
        let body = try await request.decode(as: EditItemRequest.self, context: context)

        var locked = item.lockedFields()
        var changed = false
        // Each provided field is written AND locked (manual edit is authoritative).
        if let title = body.title {
            guard !title.isEmpty else { throw SphynxError.badRequest("title cannot be empty") }
            item.title = title; locked.insert(LockableField.title); changed = true
        }
        if let overview = body.overview { item.overview = overview; locked.insert(LockableField.overview); changed = true }
        if let year = body.year { item.year = year; locked.insert(LockableField.year); changed = true }
        if let runtime = body.runtime { item.runtime = runtime; locked.insert(LockableField.runtime); changed = true }
        if let genres = body.genres { item.genresJSON = Self.encodeJSON(genres); locked.insert(LockableField.genres); changed = true }
        if let rating = body.communityRating { item.communityRating = rating; locked.insert(LockableField.communityRating); changed = true }
        if let official = body.officialRating { item.officialRating = official; locked.insert(LockableField.officialRating); changed = true }
        if let images = body.images {
            item.primaryImage = images.primary
            item.backdropImage = images.backdrop
            item.thumbImage = images.thumb
            locked.insert(LockableField.images); changed = true
        }
        if let placeholder = body.placeholder { item.placeholderURL = placeholder; locked.insert(LockableField.placeholder); changed = true }

        // --- Structural re-mapping: type / library / parent / TV position ---
        // Moving across libraries or re-parenting changes who can see the item and
        // the catalog tree, so each DESTINATION is permission-checked too (edit on
        // BOTH source and destination; the admin role bypasses via `has`).
        if let newType = body.type, newType != item.type {
            guard Self.knownItemTypes.contains(newType) else { throw SphynxError.badRequest("Unknown item type '\(newType)'") }
            item.type = newType; changed = true
        }
        if let newLibraryId = body.libraryId, !newLibraryId.isEmpty, newLibraryId != item.libraryId {
            guard try await catalog.library(id: newLibraryId) != nil else { throw SphynxError.badRequest("No library '\(newLibraryId)'") }
            guard identity.has(Permissions.metadataEdit, inLibrary: newLibraryId) else {
                throw SphynxError.forbidden("You don't have permission to edit the destination library")
            }
            // Becomes a top-level item: drop any parent / series nesting.
            item.libraryId = newLibraryId
            item.parentId = nil; item.seriesId = nil; item.seriesTitle = nil
            item.seasonIndex = nil; item.episodeIndex = nil
            changed = true
        }
        if let newParentId = body.parentId, !newParentId.isEmpty, newParentId != item.parentId {
            guard newParentId != item.id else { throw SphynxError.badRequest("An item cannot be its own parent") }
            guard let parent = try await catalog.item(id: newParentId) else { throw SphynxError.badRequest("No item '\(newParentId)'") }
            let destLibrary = try await catalog.owningLibraryId(of: parent)
            guard identity.has(Permissions.metadataEdit, inLibrary: destLibrary) else {
                throw SphynxError.forbidden("You don't have permission to edit the destination")
            }
            // Becomes nested: derive the denormalized series/season linkage from the parent.
            item.parentId = newParentId; item.libraryId = nil
            switch parent.type {
            case "series":
                item.seriesId = parent.id
                item.seriesTitle = parent.seriesTitle ?? parent.title
            case "season":
                item.seriesId = parent.seriesId
                item.seriesTitle = parent.seriesTitle
                item.seasonIndex = parent.seasonIndex
            default:
                break
            }
            changed = true
        }
        if let s = body.seasonIndex { item.seasonIndex = s; changed = true }
        if let e = body.episodeIndex { item.episodeIndex = e; changed = true }

        // Unlock re-enables auto-refresh for those fields (next enrich repopulates).
        if body.unlockAll == true {
            locked.removeAll(); changed = true
        } else if let unlock = body.unlock, !unlock.isEmpty {
            for key in unlock { locked.remove(key) }
            changed = true
        }

        if changed {
            item.lockedFieldsJSON = Self.encodeJSON(locked.sorted())
            // An edit is a data change → bump updatedAt so client caches refresh.
            item.updatedAt = Date().timeIntervalSince1970
            try await catalog.updateItem(item)
        }
        return AdminItemResponse(item: item.toProtocol(full: true), lockedFields: item.lockedFields().sorted())
    }

    private static func encodeJSON(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Pin an item to a specific TMDB id and re-enrich. Part of metadata
    /// correction, so gated by `metadata.edit` (honoring per-library / per-item
    /// scoping), not the admin role.
    @Sendable
    func setIdentity(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        let identity = try context.requireIdentity()
        let enrichment = try requireEnrichment()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        let body = try await request.decode(as: SetIdentityRequest.self, context: context)
        guard var item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.has(Permissions.metadataEdit, inLibrary: libraryId, forItem: itemId) else {
            throw SphynxError.forbidden("You don't have permission to edit metadata")
        }
        item.tmdbId = body.tmdbId
        item.identityPinned = true
        if let type = body.type { item.type = type }
        try await catalog.updateItem(item)

        await enrichment.process(item, force: true)
        guard let refreshed = try await catalog.item(id: itemId) else {
            throw SphynxError.serverError("Item vanished after enrichment")
        }
        // Re-pointing a SERIES must reach its children: each season/episode carries
        // the show's TMDB id plus a (season, episode) index, so it only re-enriches
        // against the new show once that stored id is updated. Without this, "Fix"
        // corrected the series tile but left every season and episode pinned to the
        // old show's metadata.
        if refreshed.type == "series" {
            try await cascadeSeriesIdentity(of: refreshed)
        }
        return refreshed.toProtocol(full: true)
    }

    /// Push a re-identified series' identity down onto its seasons and episodes,
    /// then force-re-enrich each so its overview/images/title come from the new
    /// show. Seasons are the series' direct children; episodes are fetched across
    /// all seasons. The backdrop (hero art) is inherited from the show.
    private func cascadeSeriesIdentity(of series: ItemRecord) async throws {
        let enrichment = try requireEnrichment()
        var children = try await catalog.childItems(parentId: series.id, limit: 10_000, offset: 0)
            .filter { $0.type == "season" }
        children += try await catalog.episodes(seriesId: series.id)
        for var child in children {
            child.tmdbId = series.tmdbId
            child.seriesTitle = series.seriesTitle ?? series.title
            child.backdropImage = series.backdropImage
            try await catalog.updateItem(child)
            await enrichment.process(child, force: true)
        }
    }

    /// Force re-identification + enrichment of one item. Part of metadata
    /// correction, so gated by `metadata.edit` (per-library / per-item scoping).
    @Sendable
    func enrichItem(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        let identity = try context.requireIdentity()
        let enrichment = try requireEnrichment()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: item)
        guard identity.has(Permissions.metadataEdit, inLibrary: libraryId, forItem: itemId) else {
            throw SphynxError.forbidden("You don't have permission to edit metadata")
        }
        await enrichment.process(item, force: true)
        guard let refreshed = try await catalog.item(id: itemId) else {
            throw SphynxError.serverError("Item vanished after enrichment")
        }
        return refreshed.toProtocol(full: true)
    }

    /// Enrich every item that needs it. `?force=true` ignores the freshness TTL and
    /// re-fetches every identified item — e.g. to backfill new artwork roles after a
    /// server upgrade ("refresh all artwork").
    @Sendable
    func enrichAll(_ request: Request, context: SphynxRequestContext) async throws -> EnrichSummary {
        try requireAdmin(context)
        let enrichment = try requireEnrichment()
        let force = (try? request.uri.decodeQuery(as: ForceQuery.self, context: context))?.force == true
        let count = try await enrichment.enrichAll(force: force)
        return EnrichSummary(enriched: count)
    }

    private func requireEnrichment() throws -> EnrichmentService {
        guard let enrichment else {
            throw SphynxError.badRequest("TMDB is not configured (set SPHYNX_TMDB_API_KEY)")
        }
        return enrichment
    }

    // MARK: - Collections (manual box sets)

    /// Manual collection curation is gated by `collections.edit`, held globally or
    /// scoped to the target library (admins always pass). Mirrors how `metadata.edit`
    /// gates the correction endpoints, so curation can be delegated on its own.
    private func requireCollections(_ context: SphynxRequestContext, inLibrary libraryId: String) throws {
        let identity = try context.requireIdentity()
        guard identity.has(Permissions.collectionsEdit, inLibrary: libraryId) else {
            throw SphynxError.forbidden("You don't have permission to manage collections here")
        }
    }

    /// Build the response view of a collection: its tile id/title/library plus the
    /// members currently nested under it (full projection so the UI shows posters).
    private func collectionView(_ record: ItemRecord) async throws -> AdminCollection {
        let members = try await catalog.childItems(parentId: record.id, limit: 1000, offset: 0)
        return AdminCollection(
            id: record.id, title: record.title, libraryId: record.libraryId ?? "",
            memberCount: members.count, members: members.map { $0.toProtocol(full: true) }
        )
    }

    /// List a library's collections (manual + TMDB) with their members, for the
    /// curation UI. `?library=<id>` required; gated by `collections.edit`.
    @Sendable
    func listCollections(_ request: Request, context: SphynxRequestContext) async throws -> AdminCollectionsResponse {
        let query = try request.uri.decodeQuery(as: CollectionsQuery.self, context: context)
        guard let libraryId = query.library, !libraryId.isEmpty else {
            throw SphynxError.badRequest("query parameter 'library' is required")
        }
        try requireCollections(context, inLibrary: libraryId)
        let records = try await catalog.collectionsIn(libraryId: libraryId)
        var collections: [AdminCollection] = []
        for record in records { collections.append(try await collectionView(record)) }
        return AdminCollectionsResponse(collections: collections)
    }

    /// Candidate items to add to a collection: a library's top-level movies/series,
    /// optionally filtered by `?search=`. `?library=<id>` required; gated the same.
    @Sendable
    func collectionCandidates(_ request: Request, context: SphynxRequestContext) async throws -> AdminItemsResponse {
        let query = try request.uri.decodeQuery(as: CollectionsQuery.self, context: context)
        guard let libraryId = query.library, !libraryId.isEmpty else {
            throw SphynxError.badRequest("query parameter 'library' is required")
        }
        try requireCollections(context, inLibrary: libraryId)
        let records = try await catalog.groupableItems(
            libraryId: libraryId, search: query.search?.trimmingCharacters(in: .whitespaces), limit: 250)
        return AdminItemsResponse(items: records.map { $0.toProtocol(full: true) })
    }

    /// Create a manual collection in a library and (optionally) seed its members.
    @Sendable
    func createCollection(_ request: Request, context: SphynxRequestContext) async throws -> AdminCollection {
        let body = try await request.decode(as: CreateCollectionRequest.self, context: context)
        let title = body.title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { throw SphynxError.badRequest("title is required") }
        guard try await catalog.library(id: body.libraryId) != nil else {
            throw SphynxError.badRequest("No library '\(body.libraryId)'")
        }
        try requireCollections(context, inLibrary: body.libraryId)
        let record = try await catalog.createManualCollection(libraryId: body.libraryId, title: title)
        if let itemIds = body.itemIds, !itemIds.isEmpty {
            _ = try await catalog.assignToCollection(record, itemIds: itemIds)
        }
        await notifyLibrariesChanged([body.libraryId], action: "updated")
        return try await collectionView(record)
    }

    /// Rename a collection and/or add/remove members. Gated on the collection's own
    /// library; added items must be top-level items of that same library.
    @Sendable
    func updateCollection(_ request: Request, context: SphynxRequestContext) async throws -> AdminCollection {
        guard let collectionId = context.parameters.get("collectionId") else {
            throw SphynxError.badRequest("Missing collection id")
        }
        guard var record = try await catalog.item(id: collectionId), record.type == "collection" else {
            throw SphynxError.notFound("No collection '\(collectionId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: record) ?? ""
        try requireCollections(context, inLibrary: libraryId)
        let body = try await request.decode(as: UpdateCollectionRequest.self, context: context)

        if let title = body.title?.trimmingCharacters(in: .whitespaces) {
            guard !title.isEmpty else { throw SphynxError.badRequest("title cannot be empty") }
            record.title = title
            record.updatedAt = Date().timeIntervalSince1970
            try await catalog.updateItem(record)
            // Keep members' denormalized collectionTitle in sync with the rename.
            let existing = try await catalog.childItems(parentId: record.id, limit: 1000, offset: 0)
            _ = try await catalog.assignToCollection(record, itemIds: existing.map(\.id))
        }
        if let add = body.addItems, !add.isEmpty {
            _ = try await catalog.assignToCollection(record, itemIds: add)
        }
        if let remove = body.removeItems, !remove.isEmpty {
            _ = try await catalog.removeFromCollection(collectionId: record.id, itemIds: remove)
        }
        if !libraryId.isEmpty { await notifyLibrariesChanged([libraryId], action: "updated") }
        return try await collectionView(record)
    }

    /// Delete a collection tile, orphaning its members back to the top level.
    @Sendable
    func deleteCollection(_ request: Request, context: SphynxRequestContext) async throws -> Response {
        guard let collectionId = context.parameters.get("collectionId") else {
            throw SphynxError.badRequest("Missing collection id")
        }
        guard let record = try await catalog.item(id: collectionId), record.type == "collection" else {
            throw SphynxError.notFound("No collection '\(collectionId)'")
        }
        let libraryId = try await catalog.owningLibraryId(of: record) ?? ""
        try requireCollections(context, inLibrary: libraryId)
        try await catalog.deleteCollection(id: collectionId)
        if !libraryId.isEmpty { await notifyLibrariesChanged([libraryId], action: "updated") }
        return Response(status: .noContent)
    }

    private func requireAdmin(_ context: SphynxRequestContext) throws {
        guard let identity = context.identity else {
            throw SphynxError.unauthorized("Not authenticated")
        }
        guard identity.isAdmin else {
            throw SphynxError.forbidden("Admin role required")
        }
    }
}

// MARK: - Admin DTOs (server-specific, not part of the wire protocol)

struct CreateLibraryRequest: Codable, Sendable {
    // Title is derived server-side from `kind` (fixed names), so callers only
    // need to send the kind. Kept optional/decodable for backward compatibility.
    var title: String?
    var kind: String?
}

struct LibraryResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var title: String
    var kind: String
    /// Minimum present members for a collection to group into a box-set tile (see
    /// `LibraryRecord.collectionThreshold`). `1` groups any non-empty collection.
    var collectionThreshold: Int

    init(_ record: LibraryRecord) {
        self.id = record.id
        self.title = record.title
        self.kind = record.kind
        self.collectionThreshold = record.collectionThreshold
    }
}

/// The runtime-tunable settings (the ones configured via the API/GUI rather than
/// an environment variable). Durations are in **seconds**.
struct SettingsResponse: Codable, Sendable, ResponseEncodable {
    var serverName: String
    var serverID: String
    var accessTokenTTL: Double
    var refreshTokenTTL: Double
    var enrichmentTTL: Double
    var metadataLanguage: String
    var markersAccess: String
    var markersStaleAfter: Double
    var playstateRetention: Double
    var maintenanceInterval: Double
    var avatarMaxBytes: Int
    var signInUserList: Bool
    var passkeyRelyingPartyID: String
    var passkeyRelyingPartyName: String
    var passkeyRelyingPartyOrigin: String
    var webAuthRedirectAllowlist: String

    init(from c: ServerConfiguration) {
        self.serverName = c.serverName
        self.serverID = c.serverID
        self.accessTokenTTL = c.accessTokenTTL
        self.refreshTokenTTL = c.refreshTokenTTL
        self.enrichmentTTL = c.enrichmentTTL
        self.metadataLanguage = c.metadataLanguage
        self.markersAccess = c.markersAccess
        self.markersStaleAfter = c.markersStaleAfter
        self.playstateRetention = c.playstateRetention
        self.maintenanceInterval = c.maintenanceInterval
        self.avatarMaxBytes = c.avatarMaxBytes
        self.signInUserList = c.signInUserList
        self.passkeyRelyingPartyID = c.passkeyRelyingPartyID
        self.passkeyRelyingPartyName = c.passkeyRelyingPartyName
        self.passkeyRelyingPartyOrigin = c.passkeyRelyingPartyOrigin
        self.webAuthRedirectAllowlist = c.webAuthRedirectAllowlist
    }
}

/// Partial update of the runtime settings — only the keys present are changed.
struct UpdateSettingsRequest: Codable, Sendable {
    var serverName: String?
    var serverID: String?
    var accessTokenTTL: Double?
    var refreshTokenTTL: Double?
    var enrichmentTTL: Double?
    var metadataLanguage: String?
    var markersAccess: String?
    var markersStaleAfter: Double?
    var playstateRetention: Double?
    var maintenanceInterval: Double?
    var avatarMaxBytes: Int?
    var signInUserList: Bool?
    var passkeyRelyingPartyID: String?
    var passkeyRelyingPartyName: String?
    var passkeyRelyingPartyOrigin: String?
    var webAuthRedirectAllowlist: String?
}

/// Masked TMDB-key status: never returns the full key.
struct TMDBKeyStatus: Codable, Sendable, ResponseEncodable {
    var configured: Bool
    /// A short, non-secret hint (e.g. `…1b87`); nil when unset.
    var keyHint: String?
    /// A changed key takes effect on the next server restart.
    var appliesOnRestart: Bool
}

struct TMDBKeyUpdate: Codable, Sendable {
    var apiKey: String?
}

struct UpdateLibraryRequest: Codable, Sendable {
    var title: String?
    var kind: String?
    /// Minimum present members for a collection to group into a box-set tile.
    /// `1` groups any non-empty collection; raise it to ungroup small box sets.
    /// Clamped to `>= 0`.
    var collectionThreshold: Int?
}

struct AdminLibrariesResponse: Codable, Sendable, ResponseEncodable {
    var libraries: [LibraryResponse]
}

struct UpdateSourceRequest: Codable, Sendable {
    var label: String?
    var baseURL: String?
    var headers: [String: String]?
    var manifestURL: String?
    var libraryId: String?
    var config: [String: String]?
    var secrets: [String: String]?
    /// Content-category → library id (`{ "movie": "lib_x", "tv": "lib_y" }`).
    var libraryMap: [String: String]?
    /// Auto-refresh cadence in **seconds** (0 = manual only).
    var refreshInterval: Double?
}

struct SourcesResponse: Codable, Sendable, ResponseEncodable {
    var sources: [SourceResponse]
}

struct CreateSourceRequest: Codable, Sendable {
    var label: String
    var driver: String?
    var baseURL: String?
    var headers: [String: String]?
    var libraryId: String?
    var manifestURL: String?
    /// Driver-specific, non-secret config (host, port, share, rootPath, …).
    var config: [String: String]?
    /// Driver credentials (username, password, token, …). Stored but never
    /// returned or logged.
    var secrets: [String: String]?
    /// Route items to libraries by content category instead of a single
    /// `libraryId` (`{ "movie": "lib_x", "tv": "lib_y" }`). Unmapped categories
    /// fall back to `libraryId`.
    var libraryMap: [String: String]?
    /// Auto-refresh cadence in **seconds** (0 = manual only).
    var refreshInterval: Double?
}

/// A source as exposed by the API — non-secret fields only. Credentials
/// (`secrets`, and the HTTP driver's request headers) are deliberately omitted.
struct SourceResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var label: String
    var driver: String
    var config: [String: String]?
    var libraryId: String?
    var libraryMap: [String: String]?
    /// Auto-refresh cadence in **seconds** (0 = manual only).
    var refreshInterval: Double
    /// Epoch seconds of the last completed scan (nil = never).
    var lastScannedAt: Double?

    init(from record: SourceRecord) {
        self.id = record.id
        self.label = record.label
        self.driver = record.driver
        let config = record.config()
        self.config = config.isEmpty ? nil : config
        self.libraryId = record.libraryId
        let map = record.libraryMap()
        self.libraryMap = map.isEmpty ? nil : map
        self.refreshInterval = record.refreshInterval
        self.lastScannedAt = record.lastScannedAt
    }
}

struct CreateItemRequest: Codable, Sendable {
    var type: String?
    var title: String
    var sourceId: String?
    /// Absolute URL (self-contained) or a key relative to the source's base URL.
    var sourceKey: String
    var container: String?
    var tmdbId: String?
    var libraryId: String?
    var parentId: String?
    var year: Int?
    /// Open server-defined metadata stored on the item and projected to `extra`.
    var extra: [String: JSONValue]?
}

struct CreateUserRequest: Codable, Sendable {
    var username: String
    var password: String
    var displayName: String?
    /// Ignored — there is exactly one admin (the bootstrap account). Kept for
    /// forward/backward compatibility of the request shape.
    var isAdmin: Bool?
    /// Initial permission keys. Defaults to `library.read` when omitted.
    var permissions: [String]?
}

struct SetPermissionsRequest: Codable, Sendable {
    var permissions: [String]
}

struct ResetPasswordRequest: Codable, Sendable {
    var newPassword: String
}

struct AdminItemsQuery: Codable, Sendable {
    var parent: String?
    var limit: Int?
    /// Catalog-wide title search (substring, case-insensitive). When set, results
    /// span every library the caller can edit rather than one parent's children.
    var search: String?
    /// Surface only items that still need metadata (unenriched, excluding extras
    /// that never enrich). Combinable with `search`.
    var needsAttention: Bool?
}

/// The raw (ungrouped) children for the item-correction browser.
struct AdminItemsResponse: Codable, Sendable, ResponseEncodable {
    var items: [Item]
}

// MARK: Collections (manual box sets)

/// `?library=&search=` for the collection curation endpoints.
struct CollectionsQuery: Codable, Sendable {
    var library: String?
    var search: String?
}

/// One collection tile plus its current members (full projection), for the editor.
struct AdminCollection: Codable, Sendable, ResponseEncodable {
    var id: String
    var title: String
    var libraryId: String
    var memberCount: Int
    var members: [Item]
}

struct AdminCollectionsResponse: Codable, Sendable, ResponseEncodable {
    var collections: [AdminCollection]
}

/// `POST /v1/admin/collections` body: make a collection in a library, optionally
/// seeding it with top-level items of that library.
struct CreateCollectionRequest: Codable, Sendable {
    var libraryId: String
    var title: String
    var itemIds: [String]?
}

/// `PATCH /v1/admin/collections/{id}` body: rename and/or add/remove members.
struct UpdateCollectionRequest: Codable, Sendable {
    var title: String?
    var addItems: [String]?
    var removeItems: [String]?
}

struct AdminUserResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var username: String
    var displayName: String
    var avatarURL: String?
    var isAdmin: Bool
    var permissions: [String]

    init(from user: UserRecord) {
        self.id = user.id
        self.username = user.username
        self.displayName = user.displayName
        self.avatarURL = user.avatarURL
        self.isAdmin = user.isAdmin
        // The admin holds everything implicitly; reflect that rather than its
        // (empty) stored set.
        self.permissions = user.isAdmin ? Permissions.wellKnown.sorted() : Array(user.permissions()).sorted()
    }
}

/// The admin permission editor's catalog: the capability vocabulary plus the
/// libraries a scopable capability can be granted for.
struct PermissionsCatalogResponse: Codable, Sendable, ResponseEncodable {
    var permissions: [PermissionCapability]
    var libraries: [ScopeLibrary]
}

/// A library a permission can be scoped to (id + title for the editor).
struct ScopeLibrary: Codable, Sendable {
    var id: String
    var title: String
}

struct AdminUsersResponse: Codable, Sendable, ResponseEncodable {
    var users: [AdminUserResponse]
}

/// Artwork to set on an item. Each key is optional; omitted keys clear that
/// image (the whole `images` set is locked as one unit).
struct EditImages: Codable, Sendable {
    var primary: String?
    var backdrop: String?
    var thumb: String?
}

/// `PATCH /v1/admin/items/{id}` body. Every field is optional; each one present
/// is written AND locked against auto-refresh. `unlock` removes specific locks;
/// `unlockAll` clears them all (re-enabling auto-refresh).
struct EditItemRequest: Codable, Sendable {
    var title: String?
    var overview: String?
    var year: Int?
    /// Runtime in **seconds**.
    var runtime: Double?
    var genres: [String]?
    var communityRating: Double?
    var officialRating: String?
    var images: EditImages?
    /// A custom low-res placeholder (image URL).
    var placeholder: String?
    // --- Structural re-mapping (correction). Each destination is permission-checked. ---
    /// Move the item to a different library (becomes top-level: parent/series links cleared).
    var libraryId: String?
    /// Re-parent under a series/season (becomes nested: libraryId cleared, series linkage derived).
    var parentId: String?
    /// Override the TV position.
    var seasonIndex: Int?
    var episodeIndex: Int?
    /// Override the item type (movie/series/season/episode/…).
    var type: String?
    var unlock: [String]?
    var unlockAll: Bool?
}

/// An item plus the field keys currently locked against auto-refresh (admin view).
struct AdminItemResponse: Codable, Sendable, ResponseEncodable {
    var item: Item
    var lockedFields: [String]
}

struct SetIdentityRequest: Codable, Sendable {
    var tmdbId: String
    var type: String?
}

struct EnrichSummary: Codable, Sendable, ResponseEncodable {
    var enriched: Int
}

/// `?force=true` on bulk enrich: ignore the freshness TTL and re-fetch every
/// identified item (e.g. backfill new artwork roles after an upgrade).
struct ForceQuery: Codable, Sendable {
    var force: Bool?
}
