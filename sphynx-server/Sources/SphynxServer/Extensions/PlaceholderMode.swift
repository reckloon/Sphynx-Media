import Foundation
import SphynxProtocol

/// How the server emits the low-res image `placeholder` on every served item — the
/// only knob of the **low-res-images** extension. The mode is read live from
/// settings, so changing it in the Extensions tab applies to subsequent responses
/// without a restart.
///
/// `blurhash` only changes the *form* served; the hashes themselves are generated
/// and cached during enrichment (see `EnrichmentService`). An item enriched before
/// the mode was switched has no hash yet and transparently falls back to `url`
/// until it's re-enriched (the periodic poster refresh, or a manual one).
enum PlaceholderMode: String, Sendable, CaseIterable {
    /// A pre-sized tiny image URL — the always-available form. Default.
    case url
    /// A BlurHash string, decoded client-side. Falls back to `url` for any item
    /// (or image role) without a generated hash.
    case blurhash
    /// No placeholder at all — clients render a plain background.
    case off

    /// Settings key, stored alongside the other free-form `ext.*` extension keys.
    static let settingKey = "ext.placeholders.mode"

    /// The live mode from settings (defaults to `.url` when unset or unrecognised).
    static func current(_ settings: SettingsStore) async throws -> PlaceholderMode {
        let all = try await settings.all()
        return PlaceholderMode(rawValue: all[settingKey] ?? "") ?? .url
    }

    /// Resolve the `Placeholder` to serve for one image role under this mode:
    /// - `off` → none
    /// - `url` → the URL form (when a URL is known)
    /// - `blurhash` → the BlurHash (when one was generated), else the URL form
    func placeholder(url: String?, blurHash: String? = nil) -> Placeholder? {
        switch self {
        case .off:
            return nil
        case .url:
            return url.map { .url($0) }
        case .blurhash:
            if let blurHash, !blurHash.isEmpty { return .blurHash(blurHash) }
            return url.map { .url($0) }
        }
    }
}
