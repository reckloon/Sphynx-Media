import Foundation
import SphynxProtocol

/// Builds the **unified Continue Watching** list: in-progress items (movies and
/// episodes you're partway through) **plus** the next unwatched episode of each
/// show you've started — merged into one recency-ordered list.
///
/// There is deliberately **no separate "Next Up"**: next-up episodes live in the
/// same list as resume items, which is what `ShelfKind.continueWatching`
/// guarantees on the wire. A show with an in-progress episode is represented by
/// that episode (resume wins); a show whose latest watched episode is finished is
/// represented by its next episode at position 0.
///
/// Returns ordered entries (record + resume position); the controller owns
/// read-permission filtering, projection, and pagination.
struct HomeService: Sendable {
    let catalog: Catalog
    let playstate: PlaystateService
    let userState: UserStateService

    /// One row of the unified Continue Watching list.
    struct Entry: Sendable {
        /// The item to show (an in-progress item, or a next-up episode).
        let record: ItemRecord
        /// Resume position in seconds; `0` for a next-up episode (start from the top).
        let position: Double
        /// Recency key the list is sorted by, descending.
        let sortTime: Double
    }

    /// A generous cap on how many in-progress rows to consider before merging in
    /// next-up; far beyond any real home row, so paging happens after the merge.
    private static let scanLimit = 500

    func continueWatching(userId: String) async throws -> [Entry] {
        // 1. In-progress items (resume position > 0), most-recently-updated first.
        let resume = try await playstate.recentlyPlayed(userId: userId, limit: Self.scanLimit, offset: 0)
        let resumeRecords = try await catalog.items(ids: resume.map(\.itemId))

        var entries: [Entry] = []
        var includedIds: Set<String> = []
        var seriesInProgress: Set<String> = []   // shows already represented by a resume episode
        for state in resume {
            guard let record = resumeRecords[state.itemId] else { continue }
            entries.append(Entry(record: record, position: state.position, sortTime: state.updatedAt))
            includedIds.insert(record.id)
            if record.type == "episode", let seriesId = record.seriesId {
                seriesInProgress.insert(seriesId)
            }
        }

        // 2. Next-up: for each show with watched episodes but no in-progress
        //    episode, the next unwatched regular-season episode after the latest
        //    watched one. Ordered by when that latest episode was played.
        let watched = try await userState.watchedStates(userId: userId)
        let watchedRecords = try await catalog.items(ids: watched.map(\.itemId))
        let lastPlayedById = Dictionary(
            watched.map { ($0.itemId, $0.lastPlayedAt ?? 0) }, uniquingKeysWith: { a, _ in a })
        let watchedIds = Set(watched.map(\.itemId))

        var watchedEpisodesBySeries: [String: [ItemRecord]] = [:]
        for state in watched {
            guard let record = watchedRecords[state.itemId],
                  record.type == "episode", let seriesId = record.seriesId else { continue }
            watchedEpisodesBySeries[seriesId, default: []].append(record)
        }

        for (seriesId, episodes) in watchedEpisodesBySeries where !seriesInProgress.contains(seriesId) {
            guard let latestWatched = episodes.max(by: { Self.order($0) < Self.order($1) }) else { continue }
            let all = try await catalog.episodes(seriesId: seriesId)
            // First regular-season (≥1; specials don't generate next-up) episode
            // strictly after the latest watched one, not itself watched/included.
            guard let next = all.first(where: { ep in
                (ep.seasonIndex ?? 0) >= 1
                    && Self.order(ep) > Self.order(latestWatched)
                    && !watchedIds.contains(ep.id)
                    && !includedIds.contains(ep.id)
            }) else { continue }
            entries.append(Entry(record: next, position: 0, sortTime: lastPlayedById[latestWatched.id] ?? 0))
            includedIds.insert(next.id)
        }

        // 3. Merge into one list, most-recent first.
        entries.sort { $0.sortTime > $1.sortTime }
        return entries
    }

    /// (season, episode) ordering key; missing indices sort first.
    private static func order(_ record: ItemRecord) -> (Int, Int) {
        (record.seasonIndex ?? 0, record.episodeIndex ?? 0)
    }
}
