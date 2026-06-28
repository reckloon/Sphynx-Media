import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SphynxProtocol
import Testing
@testable import SphynxServer

/// The backoff hint (M7 #9): a rate-limited / unavailable `SphynxError` must
/// surface its `retryAfter` both in the JSON envelope (`error.retryAfter`) and
/// in the standard HTTP `Retry-After` response header. Errors without a hint
/// must omit both.
@Suite("Retry-After backoff hint")
struct RetryAfterTests {

    /// A minimal app wrapping `ErrorMiddleware` around routes that throw the
    /// errors under test. Avoids constructing a `RequestContext` by hand.
    private func buildErrorApp() -> some ApplicationProtocol {
        let router = Router(context: SphynxRequestContext.self)
        router.middlewares.add(ErrorMiddleware())
        router.get("/rate-limited") { _, _ -> Response in
            throw SphynxError.rateLimited("Slow down.", retryAfter: 42)
        }
        router.get("/unavailable") { _, _ -> Response in
            throw SphynxError.unavailable("Down for maintenance.", retryAfter: 7.6)
        }
        router.get("/not-found") { _, _ -> Response in
            throw SphynxError.notFound("Nope.")
        }
        return Application(router: router)
    }

    @Test("rate-limited error carries error.retryAfter and the Retry-After header")
    func rateLimitedCarriesHint() async throws {
        try await buildErrorApp().test(.router) { client in
            try await client.execute(uri: "/rate-limited", method: .get) { response in
                #expect(response.status == .tooManyRequests)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .rateLimited)
                #expect(envelope.error.retryable == true)
                #expect(envelope.error.retryAfter == 42)
                #expect(response.headers[.retryAfter] == "42")
            }
        }
    }

    @Test("unavailable error rounds the Retry-After header to integer seconds")
    func unavailableRoundsHeader() async throws {
        try await buildErrorApp().test(.router) { client in
            try await client.execute(uri: "/unavailable", method: .get) { response in
                #expect(response.status == .serviceUnavailable)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.code == .unavailable)
                #expect(envelope.error.retryAfter == 7.6)
                // 7.6s rounds to 8 in the integer-seconds header.
                #expect(response.headers[.retryAfter] == "8")
            }
        }
    }

    @Test("errors with no hint omit error.retryAfter and the Retry-After header")
    func noHintOmitsBoth() async throws {
        try await buildErrorApp().test(.router) { client in
            try await client.execute(uri: "/not-found", method: .get) { response in
                #expect(response.status == .notFound)
                let envelope: ErrorEnvelope = try response.decoded()
                #expect(envelope.error.retryAfter == nil)
                #expect(response.headers[.retryAfter] == nil)
                // The raw body must not even mention the field.
                let body = String(buffer: response.body)
                #expect(!body.contains("retryAfter"))
            }
        }
    }
}
