import Crypto
import Foundation

/// Opaque token + identifier helpers.
///
/// Tokens are 256 bits of CSPRNG output, base64url-encoded. The server stores
/// only their SHA-256 hashes, so a database leak doesn't expose live tokens.
enum Tokens {
    /// A fresh, unguessable bearer/refresh token.
    static func newToken() -> String {
        var rng = SystemRandomNumberGenerator()  // cryptographically secure
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        return Data(bytes).base64URLEncodedString()
    }

    /// Lowercase hex SHA-256 of a token, for storage and lookup.
    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// A prefixed opaque id, e.g. "u_3f2a…". Opaque to clients.
    static func newID(_ prefix: String) -> String {
        prefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

extension Data {
    /// URL-safe base64 without padding.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
