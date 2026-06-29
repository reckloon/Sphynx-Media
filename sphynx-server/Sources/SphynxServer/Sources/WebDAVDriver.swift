import Foundation
#if canImport(FoundationXML)
import FoundationXML  // XMLParser lives here on Linux
#endif

/// WebDAV is HTTP under the hood: files are fetched over plain HTTPS with an
/// `Authorization` header, so `resolve()` mirrors the HTTP driver. **Listing** is
/// a depth-1 `PROPFIND` walk: enumerate each collection, recurse into child
/// collections, and emit one entry per media file — all over the existing
/// `HTTPFetching` client, so no new dependency. The server still moves no bytes.
struct WebDAVDriver: SourceDriver {
    let id: String
    /// The collection root, e.g. `https://host/remote.php/dav/files/me/Media/`.
    let baseURL: String
    /// Request headers including the `Authorization` built from credentials.
    let headers: [String: String]
    let fetcher: any HTTPFetching

    /// Safety bounds for a recursive walk of an untrusted server.
    private static let maxDirectories = 5_000

    func list() async throws -> [SourceEntry] {
        guard let root = URL(string: baseURL) else {
            throw SphynxError.badRequest("Invalid WebDAV URL '\(baseURL)'")
        }
        // The path prefix we strip to make keys relative to the collection root.
        let rootPath = Self.decodedPath(root.path).hasSuffix("/")
            ? Self.decodedPath(root.path)
            : Self.decodedPath(root.path) + "/"

        var entries: [SourceEntry] = []
        var queue = [baseURL]
        var visited = Set<String>()
        var scanned = 0

        while !queue.isEmpty {
            let dirURL = queue.removeFirst()
            guard visited.insert(dirURL).inserted else { continue }
            scanned += 1
            guard scanned <= Self.maxDirectories else { break }

            let xml = try await fetcher.sendRequest(
                method: "PROPFIND", url: dirURL,
                headers: headers.merging(["Depth": "1", "Content-Type": "application/xml"]) { _, new in new },
                body: Data(Self.propfindBody.utf8))
            let members = Self.parsePropfind(xml)

            for member in members {
                let memberPath = Self.decodedPath(member.href)
                // Skip the collection itself (PROPFIND Depth:1 echoes the parent).
                guard memberPath != rootPath, memberPath + "/" != rootPath else { continue }
                guard memberPath.hasPrefix(rootPath) else { continue }
                let relative = String(memberPath.dropFirst(rootPath.count))
                guard !relative.isEmpty else { continue }

                if member.isCollection {
                    // Resolve the child collection URL against the base and recurse.
                    if let childURL = URL(string: member.href, relativeTo: root)?.absoluteString {
                        queue.append(childURL)
                    }
                } else {
                    let name = (relative as NSString).lastPathComponent
                    guard let container = LocalDriver.container(for: name),
                          !LocalDriver.isSkippable(name) else { continue }
                    entries.append(SourceEntry(
                        key: relative.hasSuffix("/") ? String(relative.dropLast()) : relative,
                        container: container, size: member.size))
                }
            }
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        ResolvedLocation(
            url: HTTPDriver.directURL(key: request.key, baseURL: baseURL),
            headers: headers, container: request.container,
            ttl: nil, terminal: true, candidates: nil)
    }

    // MARK: PROPFIND

    private static let propfindBody =
        #"<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"#

    /// Percent-decoded path (WebDAV hrefs are URL-encoded); falls back to the raw
    /// string when decoding fails.
    static func decodedPath(_ raw: String) -> String {
        // `href` may be a full URL or an absolute path; take the path component.
        let path = URL(string: raw)?.path ?? raw
        return path.removingPercentEncoding ?? path
    }

    /// Parse a WebDAV multistatus body into (href, isCollection, size) members.
    /// Namespace-agnostic (matches element *local* names), so it tolerates the
    /// `d:` / `D:` / `lp1:` prefix variations real servers use.
    static func parsePropfind(_ data: Data) -> [(href: String, isCollection: Bool, size: Int?)] {
        let delegate = PropfindParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.parse()
        return delegate.members
    }

    static let registration = DriverRegistration(kind: "webdav", requiredConfigKeys: ["baseURL"]) { context in
        WebDAVDriver(
            id: context.id,
            baseURL: context.config["baseURL"] ?? context.baseURL ?? "",
            headers: Self.authHeaders(context),
            fetcher: context.fetcher)
    }

    /// HTTP Basic from username/password, or a bearer token. Never logged/returned.
    static func authHeaders(_ context: SourceContext) -> [String: String] {
        var headers = context.headers
        if let user = context.secrets["username"], let password = context.secrets["password"] {
            headers["Authorization"] = "Basic \(Data("\(user):\(password)".utf8).base64EncodedString())"
        } else if let bearer = context.secrets["token"], !bearer.isEmpty {
            headers["Authorization"] = "Bearer \(bearer)"
        }
        return headers
    }
}

/// XMLParser delegate that collects WebDAV `<response>` members. With namespace
/// processing on, element names arrive as local names (`response`, `href`,
/// `resourcetype`, `collection`, `getcontentlength`).
private final class PropfindParser: NSObject, XMLParserDelegate {
    var members: [(href: String, isCollection: Bool, size: Int?)] = []
    private var href = ""
    private var isCollection = false
    private var size: Int?
    private var text = ""
    private var inResponse = false

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch name {
        case "response": inResponse = true; href = ""; isCollection = false; size = nil
        case "collection": if inResponse { isCollection = true }
        default: break
        }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch name {
        case "href": if inResponse { href = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        case "getcontentlength":
            if inResponse { size = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case "response":
            if !href.isEmpty { members.append((href, isCollection, size)) }
            inResponse = false
        default: break
        }
    }
}
