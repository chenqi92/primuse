#if os(tvOS)
import Foundation
import Observation
import PrimuseKit

/// Apple TV 上的媒体服务器实时搜索。并发请求所有已启用的自托管音乐服务器，
/// 过滤掉本地曲库中已有的曲目，点击结果即可直接流式播放。
@MainActor
@Observable
final class TVServerSearchCatalog {
    private(set) var hits: [ServerSearchHit] = []
    private(set) var isSearching = false
    private(set) var activeQuery = ""
    private(set) var hasCompletedQuery = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private let perSourceLimit: Int
    @ObservationIgnored private let perSourceTimeout: Duration

    init(
        debounce: Duration = ServerSearchAvailabilityPolicy.debounce,
        perSourceLimit: Int = ServerSearchAvailabilityPolicy.perSourceLimit,
        perSourceTimeout: Duration = ServerSearchAvailabilityPolicy.perSourceTimeout
    ) {
        self.debounce = debounce
        self.perSourceLimit = perSourceLimit
        self.perSourceTimeout = perSourceTimeout
    }

    func clear() {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        hits = []
        isSearching = false
        activeQuery = ""
        hasCompletedQuery = false
    }

    func search(_ query: String, store: TVStore) {
        search(
            query: query,
            sources: store.sourcesStore.sources,
            fetcher: { source, trimmed, limit in
                try await store.searchServerSongs(source: source, query: trimmed, limit: limit)
            },
            isLocalSongIndexed: { song in
                store.library.song(id: song.id) != nil
            },
            onHitsUpdated: { hits in
                store.registerServerSearchPreviewSongs(hits)
            }
        )
    }

    func search(
        query: String,
        sources: [MusicSource],
        fetcher: @escaping @Sendable (MusicSource, String, Int) async throws -> [Song],
        isLocalSongIndexed: @escaping @MainActor (Song) -> Bool,
        onHitsUpdated: (@MainActor ([ServerSearchHit]) -> Void)? = nil
    ) {
        searchTask?.cancel()
        searchTask = nil
        generation &+= 1
        let myGen = generation

        guard let trimmed = ServerSearchAvailabilityPolicy.normalizedQuery(query) else {
            hits = []
            isSearching = false
            activeQuery = ""
            hasCompletedQuery = false
            return
        }

        let targets = ServerSearchAvailabilityPolicy.searchableSources(in: sources)
        guard !targets.isEmpty else {
            hits = []
            isSearching = false
            activeQuery = trimmed
            hasCompletedQuery = true
            return
        }

        activeQuery = trimmed
        isSearching = true
        hasCompletedQuery = false

        let debounce = self.debounce
        let limit = self.perSourceLimit
        let timeout = self.perSourceTimeout

        searchTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.generation == myGen {
                    self.isSearching = false
                }
            }
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled, let self, self.generation == myGen else { return }

            let merged = await Self.executeSearch(
                query: trimmed,
                sources: targets,
                limit: limit,
                timeout: timeout,
                fetcher: fetcher
            )
            guard !Task.isCancelled, self.generation == myGen else { return }

            var localIDs = Set<String>()
            var localPaths = Set<String>()
            for hit in merged where isLocalSongIndexed(hit.song) {
                localIDs.insert(hit.song.id)
                localPaths.insert(
                    ServerSearchResultDeduplicator.sourcePathKey(
                        sourceID: hit.song.sourceID,
                        filePath: hit.song.filePath
                    )
                )
            }
            self.hits = ServerSearchResultDeduplicator.filterUnindexed(
                merged,
                localSongIDs: localIDs,
                localSourceFilePaths: localPaths
            )
            onHitsUpdated?(self.hits)
            self.hasCompletedQuery = true
        }
    }

    private struct SourceResult: Sendable {
        let index: Int
        let hits: [ServerSearchHit]
    }

    nonisolated private static func executeSearch(
        query: String,
        sources: [MusicSource],
        limit: Int,
        timeout: Duration,
        fetcher: @escaping @Sendable (MusicSource, String, Int) async throws -> [Song]
    ) async -> [ServerSearchHit] {
        await withTaskGroup(of: SourceResult.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let songs = try await withThrowingTaskGroup(of: [Song].self) { timeoutGroup in
                            timeoutGroup.addTask {
                                try await fetcher(source, query, limit)
                            }
                            timeoutGroup.addTask {
                                try await Task.sleep(for: timeout)
                                throw TVScanError.connectFailed
                            }
                            defer { timeoutGroup.cancelAll() }
                            return try await timeoutGroup.next() ?? []
                        }
                        let hits = songs.map {
                            ServerSearchHit(
                                song: $0,
                                sourceName: source.name,
                                sourceType: source.type
                            )
                        }
                        return SourceResult(index: index, hits: hits)
                    } catch is CancellationError {
                        return SourceResult(index: index, hits: [])
                    } catch {
                        plog("🔎 TV server search failed source=\(LogRedactionPolicy.digest(source.id)) type=\(source.type.rawValue): \(error.localizedDescription)")
                        return SourceResult(index: index, hits: [])
                    }
                }
            }

            var ordered: [SourceResult] = []
            ordered.reserveCapacity(sources.count)
            for await entry in group {
                ordered.append(entry)
            }
            ordered.sort { $0.index < $1.index }
            return ordered.flatMap(\.hits)
        }
    }
}
#endif
