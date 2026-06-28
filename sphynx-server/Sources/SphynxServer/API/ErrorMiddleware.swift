import Hummingbird
import Logging
import SphynxProtocol

/// Top-level middleware that guarantees every error leaves as the protocol's
/// error envelope (§9), whatever threw it.
///
/// - `SphynxError` already renders itself.
/// - Hummingbird's `HTTPError` (e.g. a body-decode failure → 400) is mapped to
///   an equivalent envelope.
/// - Anything else becomes a generic 500 `server_error` (logged).
struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let error as SphynxError {
            return try error.response(from: request, context: context)
        } catch let error as HTTPError {
            // 429/503 are inherently retryable; other statuses retry only on 5xx.
            // No backoff hint is known here (HTTPError carries none), so retryAfter
            // stays nil and no Retry-After header is emitted for these.
            let status = error.status
            let retryable = status.code == 429 || status.code == 503 || status.code >= 500
            let mapped = SphynxError(
                status: status,
                code: Self.code(for: status),
                message: error.body ?? "Request failed",
                retryable: retryable
            )
            return try mapped.response(from: request, context: context)
        } catch {
            context.logger.error("Unhandled error: \(error)")
            return try SphynxError.serverError("Internal server error").response(from: request, context: context)
        }
    }

    private static func code(for status: HTTPResponse.Status) -> ErrorCode {
        switch status.code {
        case 401: .unauthorized
        case 403: .forbidden
        case 404: .notFound
        case 429: .rateLimited
        case 503: .unavailable
        case 400: .unknown("bad_request")
        case 500...599: .serverError
        default: .unknown("http_\(status.code)")
        }
    }
}
