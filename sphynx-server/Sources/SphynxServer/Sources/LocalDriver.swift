import Foundation
import SphynxProtocol

/// A driver over a local filesystem tree — the "periodically updated source": a
/// re-scan re-walks the configured root and re-reconciles. It is metadata-only,
/// like every driver: it never moves media bytes.
///
/// - `list()` walks `root` and emits one entry per media file, keyed by its path
///   **relative to the root** so the (folder-aware) parser sees the directory
///   structure that carries the clean title/series. The container is the real
///   media extension, unwrapping the common `.strm` double extension
///   (`Name.mkv.strm` → `mkv`).
/// - `resolve()` reads the file on demand (never storing a resolved URL): a
///   `.strm` file's contents are the source URL; any other media file resolves to
///   a `file://` path.
struct LocalDriver: SourceDriver {
    let id: String
    /// Absolute path to the directory this source indexes.
    let root: String

    /// Media file extensions worth indexing (besides `.strm`).
    private static let mediaExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "wmv", "flv",
        "ts", "m2ts", "mpg", "mpeg", "3gp", "ogv",
    ]

    func list() async throws -> [SourceEntry] {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]  // also skips .DS_Store and dotfiles
        ) else {
            throw SphynxError.noMediaSource("Local root is not readable: \(root)")
        }

        let rootPath = rootURL.standardizedFileURL.path
        var entries: [SourceEntry] = []
        while let next = enumerator.nextObject() {
            guard let fileURL = next as? URL else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let name = fileURL.lastPathComponent
            guard let container = Self.container(for: name) else { continue }  // not media
            guard !Self.isSkippable(name) else { continue }

            // Key = path relative to the root (folders preserved for the parser).
            let path = fileURL.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath + "/")
                ? String(path.dropFirst(rootPath.count + 1))
                : name

            entries.append(SourceEntry(
                key: relative,
                container: container,
                size: values?.fileSize
            ))
        }
        // Stable order keeps scans deterministic and episodes naturally grouped.
        entries.sort { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return entries
    }

    func resolve(_ request: ResolveRequest) async throws -> ResolvedLocation {
        let fileURL = URL(fileURLWithPath: root).appendingPathComponent(request.key)

        // A `.strm` file is a pointer: its contents are the real source URL,
        // read fresh at play time (we never persist the resolved URL).
        if fileURL.pathExtension.lowercased() == "strm" {
            let raw = try String(contentsOf: fileURL, encoding: .utf8)
            let url = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            guard !url.isEmpty else {
                throw SphynxError.noMediaSource("Empty .strm file: \(request.key)")
            }
            return ResolvedLocation(
                url: url, headers: [:], container: request.container,
                ttl: nil, preResolved: true, candidates: nil
            )
        }

        // A plain local media file resolves to a file:// URL.
        return ResolvedLocation(
            url: fileURL.standardizedFileURL.absoluteString, headers: [:],
            container: request.container, ttl: nil, preResolved: true, candidates: nil
        )
    }

    /// The media container for a filename, unwrapping the `.strm` double
    /// extension. Returns nil for non-media files (sidecars, junk).
    static func container(for name: String) -> String? {
        var base = name
        if base.lowercased().hasSuffix(".strm") {
            base = String(base.dropLast(5))  // drop ".strm" → expose ".mkv"/".mp4"
            // A bare "name.strm" (no inner media extension) still resolves.
            guard let ext = fileExtension(base) else { return "strm" }
            return mediaExtensions.contains(ext) ? ext : "strm"
        }
        guard let ext = fileExtension(base), mediaExtensions.contains(ext) else { return nil }
        return ext
    }

    /// Lowercased trailing extension, or nil when there isn't a plausible one.
    private static func fileExtension(_ name: String) -> String? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return ext.isEmpty ? nil : ext
    }

    /// Junk to skip even when it carries a media extension: sample clips and any
    /// stray hidden files the enumerator didn't already drop.
    static func isSkippable(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let lower = name.lowercased()
        if lower == ".ds_store" { return true }
        if lower.hasPrefix("sample.") || lower.hasPrefix("sample-") { return true }
        if lower == "sample.mkv" || lower == "sample.mp4" { return true }
        return false
    }
}
