import Foundation

/// Opaque cursor pagination. The cursor encodes a row offset; clients treat it
/// as a cookie (`cursor` in, `nextCursor` out; absent `nextCursor` = the end).
enum Cursor {
    static let defaultLimit = 50
    static let maxLimit = 200

    /// Clamp a requested limit into a sane range.
    static func clampLimit(_ requested: Int?) -> Int {
        guard let requested else { return defaultLimit }
        return max(1, min(maxLimit, requested))
    }

    /// Decode a cursor into a row offset (0 if absent/invalid).
    static func offset(from cursor: String?) -> Int {
        guard let cursor,
              let data = Data(base64Encoded: cursor),
              let string = String(data: data, encoding: .utf8),
              string.hasPrefix("offset:"),
              let value = Int(string.dropFirst("offset:".count))
        else { return 0 }
        return max(0, value)
    }

    /// Encode the next offset as a cursor.
    static func encode(offset: Int) -> String {
        Data("offset:\(offset)".utf8).base64EncodedString()
    }
}
