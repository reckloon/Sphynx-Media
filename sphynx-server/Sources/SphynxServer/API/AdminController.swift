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

    func addRoutes(to group: RouterGroup<SphynxRequestContext>) {
        let admin = group.group("admin")
        admin.post("libraries", use: createLibrary)
        admin.post("sources", use: createSource)
        admin.post("sources/:sourceId/scan", use: scanSource)
        admin.post("scan", use: scanAll)
        admin.post("items", use: createItem)
        admin.post("items/:itemId/identity", use: setIdentity)
        admin.post("items/:itemId/enrich", use: enrichItem)
        admin.post("enrich", use: enrichAll)
        admin.post("users", use: createUser)
        admin.post("users/:userId/grants", use: setGrants)
    }

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
            isAdmin: body.isAdmin ?? false,
            writeGrants: body.writeGrants ?? []
        )
        return AdminUserResponse(from: user)
    }

    @Sendable
    func setGrants(_ request: Request, context: SphynxRequestContext) async throws -> AdminUserResponse {
        try requireAdmin(context)
        guard let userId = context.parameters.get("userId") else {
            throw SphynxError.badRequest("Missing user id")
        }
        let body = try await request.decode(as: SetGrantsRequest.self, context: context)
        let user = try await auth.setWriteGrants(userId: userId, grants: body.writeGrants)
        return AdminUserResponse(from: user)
    }

    @Sendable
    func createLibrary(_ request: Request, context: SphynxRequestContext) async throws -> LibraryResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateLibraryRequest.self, context: context)
        guard !body.title.isEmpty else { throw SphynxError.badRequest("title is required") }
        let record = try await catalog.createLibrary(title: body.title, kind: body.kind ?? "other")
        return LibraryResponse(id: record.id, title: record.title, kind: record.kind)
    }

    @Sendable
    func createSource(_ request: Request, context: SphynxRequestContext) async throws -> SourceResponse {
        try requireAdmin(context)
        let body = try await request.decode(as: CreateSourceRequest.self, context: context)
        if let libraryId = body.libraryId, try await catalog.library(id: libraryId) == nil {
            throw SphynxError.badRequest("No library '\(libraryId)'")
        }
        let record = try await catalog.createSource(
            label: body.label,
            driver: body.driver ?? "http",
            baseURL: body.baseURL,
            headers: body.headers,
            libraryId: body.libraryId,
            manifestURL: body.manifestURL,
            config: body.config,
            secrets: body.secrets
        )
        return SourceResponse(from: record)
    }

    @Sendable
    func scanSource(_ request: Request, context: SphynxRequestContext) async throws -> IndexSummary {
        try requireAdmin(context)
        guard let sourceId = context.parameters.get("sourceId") else {
            throw SphynxError.badRequest("Missing source id")
        }
        return try await indexer.scan(sourceId: sourceId)
    }

    @Sendable
    func scanAll(_ request: Request, context: SphynxRequestContext) async throws -> IndexAllSummary {
        try requireAdmin(context)
        return IndexAllSummary(sources: try await indexer.scanAll())
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

    /// Pin an item to a specific TMDB id (admin override) and re-enrich.
    @Sendable
    func setIdentity(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        try requireAdmin(context)
        let enrichment = try requireEnrichment()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        let body = try await request.decode(as: SetIdentityRequest.self, context: context)
        guard var item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        item.tmdbId = body.tmdbId
        item.identityPinned = true
        if let type = body.type { item.type = type }
        try await catalog.updateItem(item)

        await enrichment.process(item, force: true)
        guard let refreshed = try await catalog.item(id: itemId) else {
            throw SphynxError.serverError("Item vanished after enrichment")
        }
        return refreshed.toProtocol(full: true)
    }

    /// Force re-identification + enrichment of one item.
    @Sendable
    func enrichItem(_ request: Request, context: SphynxRequestContext) async throws -> Item {
        try requireAdmin(context)
        let enrichment = try requireEnrichment()
        guard let itemId = context.parameters.get("itemId") else {
            throw SphynxError.badRequest("Missing item id")
        }
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }
        await enrichment.process(item, force: true)
        guard let refreshed = try await catalog.item(id: itemId) else {
            throw SphynxError.serverError("Item vanished after enrichment")
        }
        return refreshed.toProtocol(full: true)
    }

    /// Enrich every item that needs it.
    @Sendable
    func enrichAll(_ request: Request, context: SphynxRequestContext) async throws -> EnrichSummary {
        try requireAdmin(context)
        let enrichment = try requireEnrichment()
        let count = try await enrichment.enrichAll(force: false)
        return EnrichSummary(enriched: count)
    }

    private func requireEnrichment() throws -> EnrichmentService {
        guard let enrichment else {
            throw SphynxError.badRequest("TMDB is not configured (set SPHYNX_TMDB_API_KEY)")
        }
        return enrichment
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
    var title: String
    var kind: String?
}

struct LibraryResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var title: String
    var kind: String
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
}

/// A source as exposed by the API — non-secret fields only. Credentials
/// (`secrets`, and the HTTP driver's request headers) are deliberately omitted.
struct SourceResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var label: String
    var driver: String
    var config: [String: String]?

    init(from record: SourceRecord) {
        self.id = record.id
        self.label = record.label
        self.driver = record.driver
        let config = record.config()
        self.config = config.isEmpty ? nil : config
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
    var isAdmin: Bool?
    var writeGrants: [String]?
}

struct SetGrantsRequest: Codable, Sendable {
    var writeGrants: [String]
}

struct AdminUserResponse: Codable, Sendable, ResponseEncodable {
    var id: String
    var username: String
    var displayName: String
    var isAdmin: Bool
    var writeGrants: [String]

    init(from user: UserRecord) {
        self.id = user.id
        self.username = user.username
        self.displayName = user.displayName
        self.isAdmin = user.isAdmin
        self.writeGrants = Array(user.writeGrants()).sorted()
    }
}

struct SetIdentityRequest: Codable, Sendable {
    var tmdbId: String
    var type: String?
}

struct EnrichSummary: Codable, Sendable, ResponseEncodable {
    var enriched: Int
}
