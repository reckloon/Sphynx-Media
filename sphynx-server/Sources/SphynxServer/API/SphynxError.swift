import Foundation
import Hummingbird
import NIOCore
import SphynxProtocol

/// A server error that renders as the protocol's consistent error envelope (§9).
///
/// Conforms to `HTTPResponseError`, so simply `throw`ing one produces a non-2xx
/// response whose body is `{ "error": { code, message, retryable } }`.
struct SphynxError: HTTPResponseError {
    let status: HTTPResponse.Status
    let code: ErrorCode
    let message: String
    let retryable: Bool

    init(status: HTTPResponse.Status, code: ErrorCode, message: String, retryable: Bool = false) {
        self.status = status
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    func response(from request: Request, context: some RequestContext) throws -> Response {
        let envelope = ErrorEnvelope(code: code, message: message, retryable: retryable)
        let data = try JSONEncoder().encode(envelope)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        return Response(
            status: status,
            headers: headers,
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }

    // Convenience constructors keyed to the protocol's suggested codes.
    static func unauthorized(_ message: String) -> SphynxError {
        .init(status: .unauthorized, code: .unauthorized, message: message)
    }
    static func forbidden(_ message: String) -> SphynxError {
        .init(status: .forbidden, code: .forbidden, message: message)
    }
    static func notFound(_ message: String) -> SphynxError {
        .init(status: .notFound, code: .notFound, message: message)
    }
    static func noMediaSource(_ message: String) -> SphynxError {
        .init(status: .notFound, code: .noMediaSource, message: message)
    }
    static func conflict(_ message: String) -> SphynxError {
        // Open code: a contribution would clobber authoritative data.
        .init(status: .conflict, code: .unknown("conflict"), message: message)
    }
    static func badRequest(_ message: String) -> SphynxError {
        // The protocol's suggested codes have no generic "bad request"; ErrorCode
        // is an open enum, so an unknown code is legitimate and forward-compatible.
        .init(status: .badRequest, code: .unknown("bad_request"), message: message)
    }
    static func serverError(_ message: String) -> SphynxError {
        .init(status: .internalServerError, code: .serverError, message: message, retryable: true)
    }
}
