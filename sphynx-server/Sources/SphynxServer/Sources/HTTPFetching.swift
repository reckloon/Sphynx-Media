import Foundation

// On Linux, URLSession lives in FoundationNetworking, not Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches *metadata* documents (e.g. source manifests, WebDAV `PROPFIND`
/// listings) over HTTP — never media bytes. Abstracted so tests can inject a stub
/// instead of hitting the network.
protocol HTTPFetching: Sendable {
    func getData(url: String, headers: [String: String]) async throws -> Data
    /// Issue an arbitrary HTTP method (e.g. `PROPFIND` for WebDAV listing) with an
    /// optional request body, returning the response body.
    func sendRequest(method: String, url: String, headers: [String: String], body: Data?) async throws -> Data
}

extension HTTPFetching {
    /// Default: only GET is supported (delegating to `getData`); a fetcher that
    /// needs other methods overrides this. Keeps simple test stubs (GET-only) valid.
    func sendRequest(method: String, url: String, headers: [String: String], body: Data?) async throws -> Data {
        guard method.uppercased() == "GET" else {
            throw SphynxError.noMediaSource("This fetcher does not support \(method) requests")
        }
        return try await getData(url: url, headers: headers)
    }
}

/// Production fetcher for metadata documents. Restricted to **http/https** —
/// `file://` (arbitrary local-file disclosure) and every other scheme
/// (`gopher://`, `ftp://`, `data:`, …, the classic SSRF amplifiers) are rejected.
/// Manifest URLs are admin-configured; a self-hosted server may legitimately point
/// at an internal/LAN origin, so private addresses are not blocked here — isolate
/// the server at the network layer if that matters. Uses a continuation around
/// `dataTask` so it works identically on macOS and Linux.
///
/// Retries on **429 (rate limited)** and **5xx**: honors a `Retry-After` header
/// when present, otherwise backs off exponentially with jitter. This keeps a
/// rate-limited TMDB scan from dropping items to the next daily maintenance pass —
/// it waits and retries within the same request instead of hammering on.
struct URLSessionFetcher: HTTPFetching {
    /// Total attempts before giving up on a retryable status (1 = no retry).
    var maxAttempts = 4
    /// Base backoff, doubled each attempt (1s, 2s, 4s, …) and capped at `maxBackoff`.
    var baseBackoff = 1.0
    var maxBackoff = 30.0

    func getData(url: String, headers: [String: String]) async throws -> Data {
        try await sendRequest(method: "GET", url: url, headers: headers, body: nil)
    }

    func sendRequest(method: String, url: String, headers: [String: String], body: Data?) async throws -> Data {
        guard let parsed = URL(string: url) else {
            throw SphynxError.badRequest("Invalid URL '\(url)'")
        }
        guard let scheme = parsed.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw SphynxError.badRequest("Only http/https URLs are allowed")
        }
        var request = URLRequest(url: parsed)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await Self.send(request)
            } catch let retry as RetryableHTTP where attempt < maxAttempts {
                // Prefer the server's own backoff hint; else exponential with jitter.
                let exponential = min(maxBackoff, baseBackoff * pow(2, Double(attempt - 1)))
                let jitter = Double.random(in: 0...(exponential / 2))
                let delay = retry.retryAfter ?? (exponential + jitter)
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// One attempt. Throws `RetryableHTTP` on 429/5xx (so the caller backs off and
    /// retries), `SphynxError` on a non-retryable status, the transport error
    /// otherwise. Static + `URLSession.shared` so it stays `Sendable`.
    private static func send(_ request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let status = http.statusCode
                    if status == 429 || (500..<600).contains(status) {
                        // Retry-After is seconds (TMDB's form); ignore HTTP-date variants.
                        let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                        continuation.resume(throwing: RetryableHTTP(status: status, retryAfter: after))
                    } else {
                        continuation.resume(throwing: SphynxError.noMediaSource("Manifest fetch failed (HTTP \(status))"))
                    }
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}

/// A retryable HTTP failure (429 / 5xx), carrying an optional server-supplied
/// `Retry-After` (seconds). Internal to the fetcher's backoff loop.
private struct RetryableHTTP: Error {
    let status: Int
    let retryAfter: Double?
}
