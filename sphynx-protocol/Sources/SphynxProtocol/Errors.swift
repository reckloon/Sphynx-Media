import Foundation

/// A stable, machine-readable error code (`error.code`).
///
/// Open enum: clients key behaviour off `code`, and unknown codes must not break
/// decoding. The suggested codes from the protocol doc are modelled as known
/// cases; anything else becomes `.unknown`.
public enum ErrorCode: OpenEnum {
    case unauthorized
    case forbidden
    case notFound
    case noMediaSource
    case rateLimited
    case serverError
    case unavailable
    case unknown(String)

    public init?(rawValue: String) {
        switch rawValue {
        case "unauthorized": self = .unauthorized
        case "forbidden": self = .forbidden
        case "not_found": self = .notFound
        case "no_media_source": self = .noMediaSource
        case "rate_limited": self = .rateLimited
        case "server_error": self = .serverError
        case "unavailable": self = .unavailable
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .unauthorized: "unauthorized"
        case .forbidden: "forbidden"
        case .notFound: "not_found"
        case .noMediaSource: "no_media_source"
        case .rateLimited: "rate_limited"
        case .serverError: "server_error"
        case .unavailable: "unavailable"
        case .unknown(let value): value
        }
    }
}

/// The body of a non-2xx response (`error.*`).
public struct APIError: Codable, Hashable, Sendable {
    /// Stable, machine-readable error code.
    public var code: ErrorCode
    /// Human-readable message; may change, not for branching on.
    public var message: String
    /// Whether the client may retry the same request.
    public var retryable: Bool
    /// Seconds the client SHOULD wait before retrying. Set only when the server
    /// knows a hint (e.g. rate-limited or temporarily unavailable); omitted
    /// (and absent from the wire) otherwise.
    public var retryAfter: Double?

    public init(code: ErrorCode, message: String, retryable: Bool = false, retryAfter: Double? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.retryAfter = retryAfter
    }
}

/// The consistent error envelope wrapping every non-2xx body: `{ "error": {…} }`.
public struct ErrorEnvelope: Codable, Hashable, Sendable {
    public var error: APIError

    public init(error: APIError) {
        self.error = error
    }

    /// Convenience for constructing an envelope from its parts.
    public init(code: ErrorCode, message: String, retryable: Bool = false, retryAfter: Double? = nil) {
        self.error = APIError(code: code, message: message, retryable: retryable, retryAfter: retryAfter)
    }
}
