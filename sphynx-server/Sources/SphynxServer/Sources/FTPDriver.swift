import Foundation

/// FTP servers. `resolve()` yields an `ftp://host[:port]/key` URL the client
/// connects to directly. **Listing** walks directories with `curl` (its FTP
/// support is ubiquitous and cross-platform) — one control request per directory,
/// parsing the `LIST` output. The server moves no bytes; it only enumerates names.
///
/// `curl` must be on the server's `PATH`; if it isn't, listing fails with a clear
/// message (resolve/playback still work without it).
struct FTPDriver: SourceDriver {
    let id: String
    let host: String
    let port: Int?
    /// Root directory to scan from (default `/`).
    let rootPath: String
    /// `user:password` for `--user`, or empty for anonymous.
    let credential: String
    var run: CommandRunner = ProcessRunner.shell

    private static let maxDirectories = 5_000

    private var authority: String { port.map { "\(host):\($0)" } ?? host }

    func list() async throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        var queue = [normalize(rootPath)]
        var visited = Set<String>()
        var scanned = 0
        let base = normalize(rootPath)

        while !queue.isEmpty {
            let dir = queue.removeFirst()
            guard visited.insert(dir).inserted else { continue }
            scanned += 1
            guard scanned <= Self.maxDirectories else { break }

            let urlPath = dir == "/" ? "/" : dir + "/"
            var args = ["-s", "--connect-timeout", "20", "ftp://\(authority)\(urlPath)"]
            if !credential.isEmpty { args = ["--user", credential] + args }
            let out = try await run("curl", args)
            guard out.exitCode == 0 else {
                if scanned == 1 {   // first request failed → surface the real reason
                    let err = String(data: out.stderr, encoding: .utf8) ?? ""
                    throw SphynxError.noMediaSource(
                        "FTP listing failed (curl exit \(out.exitCode)). \(err.isEmpty ? "Is `curl` installed and the server reachable?" : err)")
                }
                continue   // a single unreadable subdir shouldn't abort the whole scan
            }

            for line in Self.parseList(String(data: out.stdout, encoding: .utf8) ?? "") {
                let childPath = dir == "/" ? "/\(line.name)" : "\(dir)/\(line.name)"
                if line.isDirectory {
                    queue.append(childPath)
                } else {
                    guard let container = LocalDriver.container(for: line.name),
                          !LocalDriver.isSkippable(line.name) else { continue }
                    // Key is relative to the scan root, matching `resolve(key:)`.
                    let relative = childPath.hasPrefix(base + "/")
                        ? String(childPath.dropFirst(base.count + 1))
                        : String(childPath.drop(while: { $0 == "/" }))
                    entries.append(SourceEntry(key: relative, container: container, size: line.size))
                }
            }
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let path = request.key.hasPrefix("/") ? String(request.key.dropFirst()) : request.key
        return ResolvedLocation(
            url: "ftp://\(authority)/\(path)", headers: [:], container: request.container,
            ttl: nil, terminal: true, candidates: nil)
    }

    private func normalize(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return "/" }
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s = String(s.dropLast()) }
        return s
    }

    /// Parse a directory `LIST` (the common Unix `ls -l` layout; also a basic
    /// Windows/IIS `MS-DOS` layout). Best-effort — entries it can't classify are
    /// dropped. Returns `(name, isDirectory, size)` rows, excluding `.`/`..`.
    struct Row: Equatable { var name: String; var isDirectory: Bool; var size: Int? }
    static func parseList(_ text: String) -> [Row] {
        var rows: [Row] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

            // Unix: "drwxr-xr-x 2 owner group 4096 Jan 1 12:00 name"
            if let first = line.first, "dl-".contains(first), fields.count >= 9 {
                let name = fields[8...].joined(separator: " ")
                if name == "." || name == ".." { continue }
                if first == "l" { continue }   // skip symlinks (loop risk)
                rows.append(Row(name: name, isDirectory: first == "d", size: Int(fields[4])))
                continue
            }
            // MS-DOS: "01-01-21  12:00PM  <DIR>  name"  /  "01-01-21 12:00PM 12345 name"
            if fields.count >= 4, fields[0].contains("-"), fields[1].contains(":") {
                let isDir = line.contains("<DIR>")
                let name = isDir
                    ? line.components(separatedBy: "<DIR>").last?.trimmingCharacters(in: .whitespaces) ?? ""
                    : fields[3...].joined(separator: " ")
                if name.isEmpty || name == "." || name == ".." { continue }
                rows.append(Row(name: name, isDirectory: isDir, size: isDir ? nil : Int(fields[2])))
            }
        }
        return rows
    }

    static let registration = DriverRegistration(kind: "ftp", requiredConfigKeys: ["host"]) { context in
        let user = context.secrets["username"] ?? ""
        let pass = context.secrets["password"] ?? ""
        return FTPDriver(
            id: context.id,
            host: context.config["host"] ?? "",
            port: context.config["port"].flatMap(Int.init),
            rootPath: context.config["path"] ?? "/",
            credential: user.isEmpty ? "" : "\(user):\(pass)")
    }
}
