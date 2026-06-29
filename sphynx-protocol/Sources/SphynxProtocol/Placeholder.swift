import Foundation

/// A cheap low-res image placeholder (§5.5) — a blur-up stand-in for *any* image
/// (poster, backdrop, episode still, logo, banner, or a cast face), not just the
/// poster. Attached at the item top level (`Item.placeholder`, the poster), per role
/// (`ItemImages.variants[role].placeholder`), and per `CastMember`.
///
/// **Self-describing one-of.** The object carries exactly one form. New forms
/// may be added over time, so decoding "uses the first form it understands and
/// otherwise falls back to a plain background" — an unrecognised form decodes to
/// `.unknown` rather than throwing, keeping forward compatibility.
public enum Placeholder: Codable, Hashable, Sendable {
    /// A BlurHash string, decoded client-side.
    case blurHash(String)
    /// A pre-sized low-res image URL.
    case url(String)
    /// A form this build doesn't understand; render a plain background.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case blurHash
        case url
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // First form understood wins: blurHash, then url.
        if let blurHash = try container.decodeIfPresent(String.self, forKey: .blurHash) {
            self = .blurHash(blurHash)
        } else if let url = try container.decodeIfPresent(String.self, forKey: .url) {
            self = .url(url)
        } else {
            self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blurHash(let value):
            try container.encode(value, forKey: .blurHash)
        case .url(let value):
            try container.encode(value, forKey: .url)
        case .unknown:
            break  // encodes as an empty object {}
        }
    }
}
