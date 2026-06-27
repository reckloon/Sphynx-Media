import SphynxProtocol

/// The late-bound handoff (§6 / server §8). Given an item, ask its source's
/// driver for a direct, fetchable URL and assemble the playback descriptor.
///
/// Called at play time, never during browse, so any time-bounded locations stay
/// fresh — and the descriptor is never cached from a browse response.
struct Resolver: Sendable {
    let catalog: Catalog
    let drivers: DriverFactory

    func resolve(itemId: String) async throws -> ResolveDescriptor {
        guard let item = try await catalog.item(id: itemId) else {
            throw SphynxError.notFound("No item '\(itemId)'")
        }

        let driver: any SourceDriver
        if let sourceId = item.sourceId {
            guard let source = try await catalog.source(id: sourceId) else {
                throw SphynxError.noMediaSource("Item's source is unavailable")
            }
            driver = try drivers.makeDriver(for: source)
        } else {
            // Self-contained item: the key is an absolute URL.
            driver = drivers.inlineHTTPDriver()
        }

        let location = try await driver.resolve(
            ResolveRequest(key: item.sourceKey, container: item.container)
        )

        return ResolveDescriptor(
            url: location.url,
            headers: location.headers,
            container: location.container,
            ttl: location.ttl,
            preResolved: location.preResolved,
            // Convenience: fold in any stored intro/credit markers (§6).
            markers: item.storedMarkers(),
            candidates: location.candidates
        )
    }
}
