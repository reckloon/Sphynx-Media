import Foundation
import HummingbirdBcrypt

/// bcrypt password hashing.
///
/// bcrypt is deliberately slow, so hashing/verification is offloaded to a
/// background queue to keep the cooperative thread pool — and thus the server's
/// request handling — responsive.
struct PasswordHasher: Sendable {
    /// bcrypt work factor (2^cost rounds). 12 is a sensible modern default.
    /// Injectable so tests can dial it down — bcrypt is deliberately slow, and a
    /// suite that creates/authenticates many users pays that cost on every hash
    /// and verify. Production always uses the default.
    private let cost: UInt8

    init(cost: UInt8 = 12) {
        self.cost = cost
    }

    /// Produce an encoded bcrypt hash string (salt + cost embedded).
    func hash(_ password: String) async throws -> String {
        let cost = cost
        return try await runBlocking {
            Bcrypt.hash(password, cost: cost)
        }
    }

    /// Verify a password against a stored encoded hash. Never throws on a bad
    /// password — returns false.
    func verify(password: String, encodedHash: String) async -> Bool {
        (try? await runBlocking {
            Bcrypt.verify(password, hash: encodedHash)
        }) ?? false
    }
}

/// Run blocking work off the cooperative thread pool.
private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
