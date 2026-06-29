import Foundation
import Logging
import ServiceLifecycle

/// Live progress of the BlurHash backfill, for the Extensions tab's status
/// indicator (`GET /v1/admin/extensions/placeholders`). An actor so the running
/// backfill and the admin request can read/write it without races.
///
/// `total`/`done` count **images** (every role + cast face the current pass set out
/// to hash), so a client can show "1,234 / 1,500 (82%)". They hold the last pass's
/// figures while idle so the UI can show "complete"; `beginPass` resets them.
actor BlurHashProgress {
    private(set) var running = false
    private(set) var total = 0
    private(set) var done = 0
    private(set) var lastCompletedAt: Double?

    struct Snapshot: Sendable {
        var running: Bool
        var total: Int
        var done: Int
        var lastCompletedAt: Double?
    }

    func beginPass(total: Int) {
        running = true
        self.total = total
        done = 0
    }

    func advance(by n: Int = 1) { done += n }

    func endPass() {
        running = false
        lastCompletedAt = Date().timeIntervalSince1970
    }

    func snapshot() -> Snapshot {
        Snapshot(running: running, total: total, done: done, lastCompletedAt: lastCompletedAt)
    }
}

/// Lazily backfills BlurHashes for **every** image — poster, backdrop, thumb, logo,
/// banner, and each cast face — for the low-res-images extension's `blurhash` mode.
///
/// Decoupled from enrichment on purpose: a slow image fetch must never stall
/// identification/enrichment, and the work is large (up to ~5 roles + 30 faces per
/// item), so it runs here on its own cadence and **bounded concurrency** — at most
/// `maxConcurrentItems` items hash at once, and each item hashes its images
/// sequentially, so no more than `maxConcurrentItems` image fetches are ever in
/// flight against TMDB. Each pass hashes only what's still missing, so it resumes
/// across passes and quiesces once everything is hashed.
///
/// Hashes are persisted **without** bumping `updatedAt`: a backfill is a progressive
/// enhancement, not a content change, so it must not invalidate every client's cache
/// at once. Fresh fetches serve the hash immediately; existing caches pick it up on
/// their next natural refresh. Honors the per-item `placeholder` lock for the poster.
struct BlurHashBackfillService: Service {
    let interval: Double
    let catalog: Catalog
    let generator: any BlurHashGenerating
    let settings: SettingsStore
    let progress: BlurHashProgress
    let logger: Logger
    /// Max items hashed concurrently ⇒ max image fetches in flight against TMDB.
    /// Deliberately small so the backfill never hammers the image CDN.
    var maxConcurrentItems = 4

    func run() async throws {
        logger.info("BlurHash backfill scheduled every \(Int(interval))s (≤\(maxConcurrentItems) concurrent)")
        // Run once shortly after start so a fresh/just-switched server fills in
        // without waiting a whole interval, then on the regular cadence.
        await runOnce()
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                break  // cancelled on graceful shutdown
            }
            await runOnce()
        }
    }

    /// One backfill pass (also callable directly in tests). No-op unless the
    /// extension is in `blurhash` mode.
    func runOnce() async {
        guard !Task.isCancelled else { return }
        guard (try? await PlaceholderMode.current(settings)) == .blurhash else { return }

        let items: [ItemRecord]
        do {
            items = try await catalog.allItems()
        } catch {
            logger.warning("BlurHash backfill: could not list items: \(error)")
            return
        }

        // Plan only the items that still have an image without a hash.
        let work = items.compactMap { item -> ItemHashPlan? in
            let plan = ItemHashPlan(item: item)
            return plan.isEmpty ? nil : plan
        }
        guard !work.isEmpty else { return }

        let totalImages = work.reduce(0) { $0 + $1.imageCount }
        await progress.beginPass(total: totalImages)
        logger.info("BlurHash backfill: hashing \(totalImages) image(s) across \(work.count) item(s)")

        // Sliding window of at most `maxConcurrentItems` item-workers. Each worker
        // hashes its item's images sequentially, so in-flight fetches ≤ window size.
        await withTaskGroup(of: Void.self) { group in
            var iterator = work.makeIterator()
            var active = 0
            for _ in 0 ..< maxConcurrentItems where !Task.isCancelled {
                guard let next = iterator.next() else { break }
                group.addTask { await self.process(next) }
                active += 1
            }
            while active > 0 {
                _ = await group.next()
                active -= 1
                guard !Task.isCancelled, let next = iterator.next() else { continue }
                group.addTask { await self.process(next) }
                active += 1
            }
        }

        await progress.endPass()
    }

    /// Hash one item's missing images and persist them in a single write that leaves
    /// `updatedAt` untouched. Best-effort: any single image that fails to hash is
    /// simply left for a future pass.
    private func process(_ plan: ItemHashPlan) async {
        guard !Task.isCancelled else { return }
        var roleHashes = plan.item.imageBlurHashes()
        var cast = plan.cast
        var changed = false

        for (role, url) in plan.roleURLs {
            guard !Task.isCancelled else { break }
            if let hash = await generator.blurHash(forImageAt: url) {
                roleHashes[role] = hash
                changed = true
            }
            await progress.advance()
        }

        for index in plan.castIndices {
            guard !Task.isCancelled else { break }
            if let url = cast[index].placeholderURL ?? cast[index].imageURL,
               let hash = await generator.blurHash(forImageAt: url) {
                cast[index].blurHash = hash
                changed = true
            }
            await progress.advance()
        }

        guard changed else { return }
        do {
            var item = plan.item
            item.imageBlurHashesJSON = Self.encode(roleHashes)
            if plan.cast.isEmpty == false { item.castJSON = Self.encode(cast) }
            // Deliberately not touching updatedAt/enrichedAt — see the type doc.
            try await catalog.updateItem(item)
        } catch {
            logger.warning("BlurHash backfill: could not persist item \(plan.item.id): \(error)")
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The set of images on one item that still need a BlurHash. Computed up front so a
/// pass knows its total and can skip already-complete items entirely.
private struct ItemHashPlan {
    let item: ItemRecord
    /// Image roles missing a hash, mapped to the tiny source URL to hash.
    let roleURLs: [String: String]
    /// Decoded cast (empty when the item has none / it's already fully hashed).
    let cast: [StoredCast]
    /// Indices into `cast` of members that have a photo but no hash yet.
    let castIndices: [Int]

    var isEmpty: Bool { roleURLs.isEmpty && castIndices.isEmpty }
    var imageCount: Int { roleURLs.count + castIndices.count }

    init(item: ItemRecord) {
        self.item = item
        let existing = item.imageBlurHashes()
        // Skip the poster when the admin has locked the placeholder (manual override);
        // other roles aren't covered by that lock.
        let placeholderLocked = item.lockedFields().contains(LockableField.placeholder)
        var roles: [String: String] = [:]
        for (role, url) in item.placeholderSourceURLs() where existing[role] == nil {
            if role == "primary" && placeholderLocked { continue }
            roles[role] = url
        }
        self.roleURLs = roles

        // Cast lives in a JSON blob; decode only to find faces lacking a hash.
        var decoded: [StoredCast] = []
        if let castJSON = item.castJSON, let data = castJSON.data(using: .utf8),
           let stored = try? JSONDecoder().decode([StoredCast].self, from: data) {
            decoded = stored
        }
        var indices: [Int] = []
        for (i, member) in decoded.enumerated()
        where member.blurHash == nil && (member.placeholderURL ?? member.imageURL) != nil {
            indices.append(i)
        }
        self.castIndices = indices
        self.cast = indices.isEmpty ? [] : decoded
    }
}
