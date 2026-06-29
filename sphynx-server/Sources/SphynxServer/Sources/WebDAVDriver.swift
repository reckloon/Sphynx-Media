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
    /// Concurrent `PROPFIND`s during the depth-1 fallback walk. Kept modest so a
    /// big tree doesn't self-inflict `429`s; the fetcher still retries any that do
    /// occur (honoring `Retry-After`), so this is a politeness cap, not the only
    /// defense.
    private static let maxConcurrent = 5

    func list() async throws -> [SourceEntry] {
        guard let root = URL(string: baseURL) else {
            throw SphynxError.badRequest("Invalid WebDAV URL '\(baseURL)'")
        }
        let rootPath = Self.collectionPath(root.path)

        // Fast path: a single `Depth: infinity` PROPFIND returns the entire subtree
        // on servers that allow it (Nextcloud / ownCloud, Apache mod_dav, …),
        // collapsing hundreds of round-trips into one. Fall back to a
        // bounded-concurrency depth-1 walk when the server rejects or silently
        // ignores it.
        if let fast = try? await listInfinity(rootPath: rootPath) {
            return fast
        }
        return try await listDepthOne(root: root, rootPath: rootPath)
    }

    /// The collection root path, always trailing-slashed, for relative-key math.
    private static func collectionPath(_ raw: String) -> String {
        let p = decodedPath(raw)
        return p.hasSuffix("/") ? p : p + "/"
    }

    /// One `PROPFIND` member → a media `SourceEntry`, or nil if it's the root, a
    /// collection, out of tree, or a non-media / hidden file.
    private func entry(for member: (href: String, isCollection: Bool, size: Int?), rootPath: String) -> SourceEntry? {
        guard !member.isCollection else { return nil }
        let memberPath = Self.decodedPath(member.href)
        guard memberPath != rootPath, memberPath + "/" != rootPath, memberPath.hasPrefix(rootPath) else { return nil }
        let relative = String(memberPath.dropFirst(rootPath.count))
        let trimmed = relative.hasSuffix("/") ? String(relative.dropLast()) : relative
        guard !trimmed.isEmpty else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        guard let container = LocalDriver.container(for: name), !LocalDriver.isSkippable(name) else { return nil }
        return SourceEntry(key: trimmed, container: container, size: member.size)
    }

    /// Whether a member is a collection nested below the root (i.e. a real subfolder).
    private func isSubCollection(_ member: (href: String, isCollection: Bool, size: Int?), rootPath: String) -> Bool {
        guard member.isCollection else { return false }
        let mp = Self.decodedPath(member.href)
        return mp != rootPath && mp + "/" != rootPath && mp.hasPrefix(rootPath)
            && !String(mp.dropFirst(rootPath.count)).isEmpty
    }

    /// Depth:infinity fast path. Returns nil (so the caller falls back) when the
    /// server rejects it OR appears to have *ignored* it — detected by: subfolders
    /// came back but no file nested below the root did, meaning it only listed one
    /// level. A genuinely flat library (files at the root, no subfolders) is
    /// accepted. A partial/ignored result is never trusted, because the indexer
    /// deletes anything missing from a listing.
    private func listInfinity(rootPath: String) async throws -> [SourceEntry]? {
        let xml = try await fetcher.sendRequest(
            method: "PROPFIND", url: baseURL,
            headers: headers.merging(["Depth": "infinity", "Content-Type": "application/xml"]) { _, new in new },
            body: Data(Self.propfindBody.utf8))
        let members = Self.parsePropfind(xml)

        var entries: [SourceEntry] = []
        var sawSubCollection = false
        var sawNestedFile = false
        for member in members {
            if isSubCollection(member, rootPath: rootPath) { sawSubCollection = true; continue }
            guard let e = entry(for: member, rootPath: rootPath) else { continue }
            if e.key.contains("/") { sawNestedFile = true }
            entries.append(e)
        }
        guard sawNestedFile || !sawSubCollection else { return nil }  // ignored Depth:infinity → bail
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    /// Bounded-concurrency depth-1 BFS fallback: one `PROPFIND` per directory, up to
    /// `maxConcurrent` in flight per wave. Errors propagate — a partial listing would
    /// make the indexer delete the unseen items, so the scan is all-or-nothing.
    private func listDepthOne(root: URL, rootPath: String) async throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        var visited: Set<String> = [baseURL]
        var frontier = [baseURL]
        var scanned = 0

        while !frontier.isEmpty, scanned < Self.maxDirectories {
            let batch = Array(frontier.prefix(Self.maxDirectories - scanned))
            frontier.removeAll(keepingCapacity: true)
            scanned += batch.count

            let results = try await withThrowingTaskGroup(
                of: (files: [SourceEntry], dirs: [String]).self
            ) { group -> [(files: [SourceEntry], dirs: [String])] in
                var next = 0
                while next < batch.count, next < Self.maxConcurrent {
                    let url = batch[next]; next += 1
                    group.addTask { try await self.propfind(url, root: root, rootPath: rootPath) }
                }
                var out: [(files: [SourceEntry], dirs: [String])] = []
                while let r = try await group.next() {
                    out.append(r)
                    if next < batch.count {
                        let url = batch[next]; next += 1
                        group.addTask { try await self.propfind(url, root: root, rootPath: rootPath) }
                    }
                }
                return out
            }
            for r in results {
                entries.append(contentsOf: r.files)
                for d in r.dirs where visited.insert(d).inserted { frontier.append(d) }
            }
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    /// One depth-1 `PROPFIND`: this directory's media files plus its child collection
    /// URLs to recurse into.
    private func propfind(_ dirURL: String, root: URL, rootPath: String) async throws -> (files: [SourceEntry], dirs: [String]) {
        let xml = try await fetcher.sendRequest(
            method: "PROPFIND", url: dirURL,
            headers: headers.merging(["Depth": "1", "Content-Type": "application/xml"]) { _, new in new },
            body: Data(Self.propfindBody.utf8))
        var files: [SourceEntry] = []
        var dirs: [String] = []
        for member in Self.parsePropfind(xml) {
            if isSubCollection(member, rootPath: rootPath) {
                if let childURL = URL(string: member.href, relativeTo: root)?.absoluteString { dirs.append(childURL) }
            } else if let e = entry(for: member, rootPath: rootPath) {
                files.append(e)
            }
        }
        return (files, dirs)
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
