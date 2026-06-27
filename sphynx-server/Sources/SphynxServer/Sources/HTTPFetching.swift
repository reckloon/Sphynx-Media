import Foundation

// On Linux, URLSession lives in FoundationNetworking, not Foundation.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fetches *metadata* documents (e.g. source manifests) over HTTP — never media
/// bytes. Abstracted so tests can inject a stub instead of hitting the network.
protocol HTTPFetching: Sendable {
    func getData(url: String, headers: [String: String]) async throws -> Data
}

/// Production fetcher. Reads `file://` URLs straight off disk (cross-platform,
/// no network) and everything else via URLSession. Uses a continuation around
/// `dataTask` so it works identically on macOS and Linux.
struct URLSessionFetcher: HTTPFetching {
    func getData(url: String, headers: [String: String]) async throws -> Data {
        if url.hasPrefix("file://") {
            let path = String(url.dropFirst("file://".count))
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard let parsed = URL(string: url) else {
            throw SphynxError.badRequest("Invalid URL '\(url)'")
        }
        var request = URLRequest(url: parsed)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    continuation.resume(throwing: SphynxError.noMediaSource("Manifest fetch failed (HTTP \(http.statusCode))"))
                    return
                }
                continuation.resume(returning: data ?? Data())
            }
            task.resume()
        }
    }
}
