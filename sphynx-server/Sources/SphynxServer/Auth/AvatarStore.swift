import Foundation

/// Stores user avatar images on disk in a single contained directory.
///
/// Security posture (fail-closed, matching the rest of the server):
/// - The image **type is detected from the leading magic bytes**, never trusted
///   from the client's `Content-Type`. Only PNG / JPEG / WebP are accepted.
/// - A **size cap** (`maxBytes`) is enforced before anything is written.
/// - Files are named `<userId>.<ext>` from a **validated** user id (the
///   server-generated `u_…` form: alphanumerics + underscore only), so an upload
///   can never escape `directory` via path traversal.
///
/// A user has at most one avatar; replacing it removes any prior format variant.
struct AvatarStore: Sendable {
    /// Directory that holds `<userId>.<ext>` files. Created on first write.
    let directory: URL
    /// Maximum accepted image size, in bytes.
    let maxBytes: Int

    /// A supported avatar image format.
    enum ImageKind: String, CaseIterable, Sendable {
        case png, jpg, webp

        var ext: String { rawValue }
        var contentType: String {
            switch self {
            case .png: return "image/png"
            case .jpg: return "image/jpeg"
            case .webp: return "image/webp"
            }
        }
    }

    // MARK: Detection / validation

    /// Detect a supported image type from the leading bytes, or nil if the data is
    /// not a PNG / JPEG / WebP. The bytes are authoritative; the declared
    /// `Content-Type` is ignored.
    static func detect(_ bytes: [UInt8]) -> ImageKind? {
        if bytes.count >= 8,
           Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpg }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == [0x52, 0x49, 0x46, 0x46],   // "RIFF"
           Array(bytes[8..<12]) == [0x57, 0x45, 0x42, 0x50] { return .webp }  // "WEBP"
        return nil
    }

    /// Whether `userId` is safe to use as a filename component: the server's own
    /// id alphabet (alphanumerics + underscore). Rejects everything else so a
    /// crafted id can never traverse out of `directory`.
    static func isSafeID(_ userId: String) -> Bool {
        !userId.isEmpty && userId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    // MARK: Read / write / delete

    /// Validate and store an avatar for `userId`. Returns the detected kind.
    /// Throws `SphynxError.badRequest` on an oversize body or unsupported format.
    @discardableResult
    func write(userId: String, data: Data) throws -> ImageKind {
        guard Self.isSafeID(userId) else { throw SphynxError.badRequest("Invalid user id") }
        guard data.count <= maxBytes else {
            throw SphynxError.badRequest("Avatar exceeds the maximum size of \(maxBytes) bytes")
        }
        guard let kind = Self.detect([UInt8](data)) else {
            throw SphynxError.badRequest("Unsupported image format (use PNG, JPEG, or WebP)")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delete(userId: userId)  // drop any prior format variant first
        try data.write(to: fileURL(userId: userId, kind: kind), options: .atomic)
        return kind
    }

    /// The stored avatar bytes + content type for `userId`, or nil if none exist.
    func read(userId: String) -> (data: Data, contentType: String)? {
        guard Self.isSafeID(userId) else { return nil }
        for kind in ImageKind.allCases {
            let url = fileURL(userId: userId, kind: kind)
            if let data = try? Data(contentsOf: url) { return (data, kind.contentType) }
        }
        return nil
    }

    /// Remove every stored avatar variant for `userId` (no-op if none). Used on
    /// avatar removal and when a user account is deleted.
    func delete(userId: String) {
        guard Self.isSafeID(userId) else { return }
        for kind in ImageKind.allCases {
            try? FileManager.default.removeItem(at: fileURL(userId: userId, kind: kind))
        }
    }

    private func fileURL(userId: String, kind: ImageKind) -> URL {
        directory.appendingPathComponent("\(userId).\(kind.ext)")
    }
}
