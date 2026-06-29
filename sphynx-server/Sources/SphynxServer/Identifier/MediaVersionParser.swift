import Foundation
import SphynxProtocol

/// One stored version/edition of a title — a single file backing the same logical
/// movie — persisted as JSON on the item and projected onto `Item.versions`. Unlike
/// the protocol `MediaVersion`, it also carries the `sourceKey` so a
/// `resolve?version=` request can map a version id back to its file.
struct StoredVersion: Codable, Hashable, Sendable {
    var id: String
    var sourceKey: String
    var container: String?
    var label: String
    var resolution: String?
    var edition: String?
    var dynamicRange: String?
    var size: Int?

    /// Projection onto the protocol type (drops the private `sourceKey`).
    var asProtocol: MediaVersion {
        MediaVersion(id: id, label: label, container: container, resolution: resolution,
                     edition: edition, dynamicRange: dynamicRange, size: size)
    }
}

/// Parses resolution / edition / dynamic-range hints out of a media filename to
/// build a selectable `StoredVersion`. Heuristic and self-contained (no network),
/// so it's exhaustively unit-testable — this is where "why is the 1080p showing as
/// the default?" bugs would live.
enum MediaVersionParser {
    /// Build a stored version for a single file. `id` is a deterministic hash of the
    /// sourceKey so it's stable across re-scans (a client can cache a chosen version).
    static func version(key: String, container: String?, size: Int?) -> StoredVersion {
        let name = (key as NSString).lastPathComponent
        let normal = normalize(name)
        let resolution = resolution(normal)
        let edition = edition(normal)
        let dynamicRange = dynamicRange(normal)
        let remux = normal.contains(" remux ")
        return StoredVersion(
            id: stableID(key), sourceKey: key, container: container,
            label: label(edition: edition, resolution: resolution, dynamicRange: dynamicRange,
                         remux: remux, container: container),
            resolution: resolution, edition: edition, dynamicRange: dynamicRange, size: size)
    }

    /// Quality rank for default-version selection (higher = better): resolution
    /// dominates, then dynamic range, then remux, then a capped size tiebreak.
    static func rank(_ v: StoredVersion) -> Int {
        var score = 0
        switch v.resolution {
        case "8K":    score += 5000
        case "4K":    score += 4000
        case "1080p": score += 3000
        case "720p":  score += 2000
        case "480p":  score += 1000
        default: break
        }
        switch v.dynamicRange {
        case "DV":     score += 300
        case "HDR10+": score += 250
        case "HDR10":  score += 200
        default: break
        }
        if v.label.lowercased().contains("remux") { score += 100 }
        score += min((v.size ?? 0) / 1_000_000_000, 50)  // GB, capped so it never outranks resolution
        return score
    }

    // MARK: - Detectors

    /// Lowercase, separators (brackets/dots/dashes/underscores/spaces/apostrophes)
    /// folded to single spaces, padded with spaces so token checks match at edges.
    private static func normalize(_ name: String) -> String {
        let mapped = name.lowercased().map { ch -> Character in
            "._-+()[]{}'’".contains(ch) ? " " : ch
        }
        let collapsed = String(mapped).split(separator: " ").joined(separator: " ")
        return " \(collapsed) "
    }

    private static func resolution(_ n: String) -> String? {
        if n.contains(" 4320p ") || n.contains(" 8k ") { return "8K" }
        if n.contains(" 2160p ") || n.contains(" 4k ") || n.contains(" uhd ") || n.contains(" 3840x2160 ") { return "4K" }
        if n.contains(" 1080p ") || n.contains(" 1080i ") || n.contains(" 1920x1080 ") { return "1080p" }
        if n.contains(" 720p ") || n.contains(" 1280x720 ") { return "720p" }
        if n.contains(" 480p ") || n.contains(" 576p ") { return "480p" }
        return nil
    }

    private static func edition(_ n: String) -> String? {
        if n.contains("director") && n.contains(" cut ") { return "Director's Cut" }
        if n.contains(" final cut ") { return "Final Cut" }
        if n.contains(" extended ") { return "Extended" }
        if n.contains(" theatrical ") { return "Theatrical" }
        if n.contains(" imax ") { return "IMAX" }
        if n.contains(" special edition ") { return "Special Edition" }
        if n.contains(" unrated ") { return "Unrated" }
        if n.contains(" uncut ") { return "Uncut" }
        if n.contains(" remastered ") { return "Remastered" }
        return nil
    }

    private static func dynamicRange(_ n: String) -> String? {
        if n.contains(" dolby vision ") || n.contains(" dovi ") || n.contains(" dv ") { return "DV" }
        if n.contains(" hdr10+ ") || n.contains(" hdr10plus ") || n.contains(" hdrplus ") { return "HDR10+" }
        if n.contains(" hdr10 ") || n.contains(" hdr ") { return "HDR10" }
        return nil
    }

    private static func label(
        edition: String?, resolution: String?, dynamicRange: String?, remux: Bool, container: String?
    ) -> String {
        var parts: [String] = []
        if let edition { parts.append(edition) }
        if let resolution { parts.append(resolution) }
        if let dynamicRange { parts.append(dynamicRange) }
        if remux { parts.append("Remux") }
        if parts.isEmpty {
            if let container, !container.isEmpty { return container.uppercased() }
            return "Version"
        }
        return parts.joined(separator: " · ")
    }

    /// FNV-1a over the sourceKey — deterministic across runs (Swift's `Hasher` is
    /// per-run randomized, so it can't be used for a stable id).
    static func stableID(_ key: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "v_" + String(hash, radix: 16)
    }
}
