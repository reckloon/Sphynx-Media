import Foundation

/// SMB/CIFS shares. `resolve()` yields an `smb://host/share/key` URL the client
/// opens itself. **Listing** walks the share with `smbclient` (Samba's CLI) — one
/// `ls` per directory, recursing into subdirectories — and parses its output. The
/// server moves no bytes; it only enumerates names.
///
/// `smbclient` must be on the server's `PATH`; if it isn't, listing fails with a
/// clear message (resolve/playback still work without it).
struct SMBDriver: SourceDriver {
    let id: String
    let host: String
    let share: String
    /// `username%password` for `-U`, or empty for an anonymous (`-N`) connection.
    let credential: String
    var run: CommandRunner = ProcessRunner.shell

    private static let maxDirectories = 5_000

    func list() async throws -> [SourceEntry] {
        var entries: [SourceEntry] = []
        var queue = [""]   // "" = share root; subdirs are share-relative paths
        var visited = Set<String>()
        var scanned = 0

        while !queue.isEmpty {
            let dir = queue.removeFirst()
            guard visited.insert(dir).inserted else { continue }
            scanned += 1
            guard scanned <= Self.maxDirectories else { break }

            var args = ["//\(host)/\(share)"]
            args += credential.isEmpty ? ["-N"] : ["-U", credential]
            if !dir.isEmpty { args += ["-D", dir] }
            args += ["-c", "ls"]
            let out = try await run("smbclient", args)
            guard out.exitCode == 0 else {
                if scanned == 1 {
                    let err = String(data: out.stderr, encoding: .utf8) ?? ""
                    throw SphynxError.noMediaSource(
                        "SMB listing failed (smbclient exit \(out.exitCode)). \(err.isEmpty ? "Is `smbclient` installed and the share reachable?" : err)")
                }
                continue
            }

            for row in Self.parseLS(String(data: out.stdout, encoding: .utf8) ?? "") {
                let childPath = dir.isEmpty ? row.name : "\(dir)/\(row.name)"
                if row.isDirectory {
                    queue.append(childPath)
                } else {
                    guard let container = LocalDriver.container(for: row.name),
                          !LocalDriver.isSkippable(row.name) else { continue }
                    entries.append(SourceEntry(key: childPath, container: container, size: row.size))
                }
            }
        }
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let path = request.key.hasPrefix("/") ? String(request.key.dropFirst()) : request.key
        return ResolvedLocation(
            url: "smb://\(host)/\(share)/\(path)", headers: [:], container: request.container,
            ttl: nil, terminal: true, candidates: nil)
    }

    /// Parse `smbclient`'s `ls` output: each entry line is
    /// `  <name>   <attrs>   <size>  <Day> <Mon> <d> <time> <year>`, where `name`
    /// may contain spaces and `attrs` is a run of `DAHSRN` flags (`D` = directory).
    /// Skips `.`/`..` and the trailing "blocks of size" summary.
    struct Row: Equatable { var name: String; var isDirectory: Bool; var size: Int? }
    static func parseLS(_ text: String) -> [Row] {
        var rows: [Row] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.contains("blocks of size") { continue }
            // Anchor on the tail: <attrs> <size> <weekday Mon …>. Work right-to-left.
            // tokens: …, attrs, size, "Mon", "Jan", "1", "12:00:00", "2024"
            let toks = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard toks.count >= 7 else { continue }
            // Find the size token: the last all-digit token that is followed by a
            // 3-letter weekday — i.e. tokens[count-6] is size, tokens[count-7] attrs.
            let sizeIdx = toks.count - 6
            let attrIdx = toks.count - 7
            guard sizeIdx >= 1, attrIdx >= 0,
                  let size = Int(toks[sizeIdx]),
                  toks[attrIdx].allSatisfy({ "DAHSRNn".contains($0) })
            else { continue }
            let name = toks[0..<attrIdx].joined(separator: " ")
            if name.isEmpty || name == "." || name == ".." { continue }
            let isDir = toks[attrIdx].contains("D")
            rows.append(Row(name: name, isDirectory: isDir, size: isDir ? nil : size))
        }
        return rows
    }

    static let registration = DriverRegistration(kind: "smb", requiredConfigKeys: ["host", "share"]) { context in
        let user = context.secrets["username"] ?? ""
        let pass = context.secrets["password"] ?? ""
        return SMBDriver(
            id: context.id,
            host: context.config["host"] ?? "",
            share: context.config["share"] ?? "",
            credential: user.isEmpty ? "" : "\(user)%\(pass)")
    }
}
