import Foundation

/// A forward-compatible, string-backed enum.
///
/// The Sphynx protocol promises that "new enum-like string values may appear at
/// any time" and that clients "must not break on values they don't recognize".
/// Any type conforming to `OpenEnum` therefore decodes an unrecognized string
/// into an `.unknown(value)` case instead of throwing — preserving the original
/// string so it can be round-tripped back onto the wire untouched.
///
/// Conformers are plain enums (so they can carry the `.unknown(String)` case)
/// that map their known cases to/from `String` via `RawRepresentable`. The
/// `Codable` behaviour is provided here once, for all of them.
public protocol OpenEnum: RawRepresentable, Codable, Hashable, Sendable
where RawValue == String {
    /// Wraps a string the conformer doesn't recognise. Satisfied automatically
    /// by the conformer's `case unknown(String)`.
    static func unknown(_ value: String) -> Self
}

extension OpenEnum {
    /// Decodes from a single JSON string, never throwing on an unknown value.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.unknown(raw)
    }

    /// Encodes back to the original wire string (including unknown values).
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
