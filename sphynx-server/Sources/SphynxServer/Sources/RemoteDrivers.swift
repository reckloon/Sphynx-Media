import Foundation

/// Scaffold drivers for networked backends. Each one's **resolve** is real — it
/// hands the client a scheme-appropriate, directly-fetchable location, honouring
/// the core contract that the server never moves bytes. Only **listing** differs
/// per backend, and that's what's left to implement (see each `list()`).
///
/// They register their kinds + required config so the framework already
/// recognises them: creating such a source and resolving an item works today;
/// scanning reports a clear "listing not implemented yet".

// MARK: - WebDAV (https + auth header)

/// WebDAV is HTTP under the hood: files are fetched over plain HTTPS with an
/// `Authorization` header, so `resolve()` mirrors the HTTP driver. Listing is a
/// `PROPFIND` request — an HTTP method the existing `HTTPFetching` client can
/// issue, so this is implementable without a new dependency.
struct WebDAVDriver: SourceDriver {
    let id: String
    let baseURL: String
    /// Request headers including the `Authorization` built from credentials.
    let headers: [String: String]
    let fetcher: any HTTPFetching

    func list() async throws -> [SourceEntry] {
        // TODO: issue a `PROPFIND` (Depth: infinity) via `fetcher` and parse the
        // multistatus XML into entries. Feasible over the current HTTP client.
        throw SphynxError.noMediaSource("WebDAV listing (PROPFIND) is not implemented yet")
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        ResolvedLocation(
            url: HTTPDriver.directURL(key: request.key, baseURL: baseURL),
            headers: headers,
            container: request.container,
            ttl: nil,
            terminal: true,
            candidates: nil
        )
    }

    static let registration = DriverRegistration(kind: "webdav", requiredConfigKeys: ["baseURL"]) { context in
        WebDAVDriver(
            id: context.id,
            baseURL: context.config["baseURL"] ?? context.baseURL ?? "",
            headers: Self.authHeaders(context),
            fetcher: context.fetcher
        )
    }

    /// Build the auth header from secret credentials: HTTP Basic from
    /// username/password, or a bearer token. Never logged or returned.
    static func authHeaders(_ context: SourceContext) -> [String: String] {
        var headers = context.headers
        if let user = context.secrets["username"], let password = context.secrets["password"] {
            let token = Data("\(user):\(password)".utf8).base64EncodedString()
            headers["Authorization"] = "Basic \(token)"
        } else if let bearer = context.secrets["token"], !bearer.isEmpty {
            headers["Authorization"] = "Bearer \(bearer)"
        }
        return headers
    }
}

// MARK: - SMB (smb:// — the client mounts/streams natively)

/// SMB/CIFS shares. `resolve()` yields an `smb://host/share/key` URL the client
/// opens itself. Listing needs an SMB client library, so it's left unbuilt.
struct SMBDriver: SourceDriver {
    let id: String
    let host: String
    let share: String

    func list() async throws -> [SourceEntry] {
        // TODO: enumerate the share via an SMB client library (no standard one
        // ships with Foundation) — that dependency is the open piece.
        throw SphynxError.noMediaSource("SMB listing requires an SMB client library; not implemented yet")
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let path = request.key.hasPrefix("/") ? String(request.key.dropFirst()) : request.key
        return ResolvedLocation(
            url: "smb://\(host)/\(share)/\(path)",
            headers: [:],
            container: request.container,
            ttl: nil,
            terminal: true,
            candidates: nil
        )
    }

    static let registration = DriverRegistration(kind: "smb", requiredConfigKeys: ["host", "share"]) { context in
        SMBDriver(
            id: context.id,
            host: context.config["host"] ?? "",
            share: context.config["share"] ?? ""
        )
    }
}

// MARK: - FTP (ftp:// — the client connects directly)

/// FTP servers. `resolve()` yields an `ftp://host[:port]/key` URL. Listing needs
/// an FTP client library, so it's left unbuilt.
struct FTPDriver: SourceDriver {
    let id: String
    let host: String
    let port: Int?

    func list() async throws -> [SourceEntry] {
        // TODO: walk directories over the FTP control connection via a client
        // library — that dependency is the open piece.
        throw SphynxError.noMediaSource("FTP listing requires an FTP client library; not implemented yet")
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let authority = port.map { "\(host):\($0)" } ?? host
        let path = request.key.hasPrefix("/") ? String(request.key.dropFirst()) : request.key
        return ResolvedLocation(
            url: "ftp://\(authority)/\(path)",
            headers: [:],
            container: request.container,
            ttl: nil,
            terminal: true,
            candidates: nil
        )
    }

    static let registration = DriverRegistration(kind: "ftp", requiredConfigKeys: ["host"]) { context in
        FTPDriver(
            id: context.id,
            host: context.config["host"] ?? "",
            port: context.config["port"].flatMap(Int.init)
        )
    }
}
