import Foundation
import Observation
import PrimuseKit

/// 并发向所有已启用的媒体服务器发起标准曲库实时搜索，过滤掉本地已入库曲目。
@MainActor
@Observable
final class ServerSongSearchService {
    private(set) var hits: [ServerSearchHit] = []
    private(set) var isSearching = false
    private(set) var activeQuery = ""
    private(set) var hasCompletedQuery = false
    private(set) var failedSourceCount = 0
    private(set) var searchedSourceCount = 0

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
        failedSourceCount = 0
        searchedSourceCount = 0
    }

    func search(
        query: String,
        sources: [MusicSource],
        disabledSourceIDs: Set<String> = [],
        library: MusicLibrary,
        sourceManager: SourceManager
    ) {
        search(
            query: query,
            sources: sources,
            disabledSourceIDs: disabledSourceIDs,
            connectorProvider: { source in
                sourceManager.connector(for: source) as? any ServerSongSearchingConnector
            },
            isLocalSongIndexed: { song in
                library.song(id: song.id) != nil
            }
        )
    }

    func search(
        query: String,
        sources: [MusicSource],
        disabledSourceIDs: Set<String> = [],
        connectorProvider: @escaping @MainActor (MusicSource) -> (any ServerSongSearchingConnector)?,
        isLocalSongIndexed: @escaping @MainActor (Song) -> Bool
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
            failedSourceCount = 0
            searchedSourceCount = 0
            return
        }

        let targets = ServerSearchAvailabilityPolicy.searchableSources(
            in: sources,
            disabledSourceIDs: disabledSourceIDs
        )
        guard !targets.isEmpty else {
            hits = []
            isSearching = false
            activeQuery = trimmed
            hasCompletedQuery = true
            failedSourceCount = 0
            searchedSourceCount = 0
            return
        }

        let pairs: [(source: MusicSource, connector: any ServerSongSearchingConnector)] = targets.compactMap { source in
            guard let connector = connectorProvider(source) else { return nil }
            return (source, connector)
        }
        guard !pairs.isEmpty else {
            hits = []
            isSearching = false
            activeQuery = trimmed
            hasCompletedQuery = true
            failedSourceCount = 0
            searchedSourceCount = 0
            return
        }

        activeQuery = trimmed
        isSearching = true
        hasCompletedQuery = false
        failedSourceCount = 0
        searchedSourceCount = pairs.count

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

            let outcome = await Self.executeSearch(
                query: trimmed,
                pairs: pairs,
                limit: limit,
                timeout: timeout
            )
            guard !Task.isCancelled, self.generation == myGen else { return }

            var localIDs = Set<String>()
            var localPaths = Set<String>()
            for hit in outcome.hits where isLocalSongIndexed(hit.song) {
                localIDs.insert(hit.song.id)
                localPaths.insert(
                    ServerSearchResultDeduplicator.sourcePathKey(
                        sourceID: hit.song.sourceID,
                        filePath: hit.song.filePath
                    )
                )
            }
            self.hits = ServerSearchResultDeduplicator.filterUnindexed(
                outcome.hits,
                localSongIDs: localIDs,
                localSourceFilePaths: localPaths
            )
            self.failedSourceCount = outcome.failedCount
            self.hasCompletedQuery = true
        }
    }

    private struct BatchOutcome: Sendable {
        let hits: [ServerSearchHit]
        let failedCount: Int
    }

    private struct SourceResult: Sendable {
        let index: Int
        let hits: [ServerSearchHit]
        let failed: Bool
    }

    nonisolated private static func executeSearch(
        query: String,
        pairs: [(source: MusicSource, connector: any ServerSongSearchingConnector)],
        limit: Int,
        timeout: Duration
    ) async -> BatchOutcome {
        await withTaskGroup(of: SourceResult.self) { group in
            for (index, entry) in pairs.enumerated() {
                let source = entry.source
                let connector = entry.connector
                group.addTask {
                    do {
                        let songs = try await searchSingleSource(
                            connector: connector,
                            query: query,
                            limit: limit,
                            timeout: timeout
                        )
                        let hits = songs.map {
                            ServerSearchHit(
                                song: $0,
                                sourceName: source.name,
                                sourceType: source.type
                            )
                        }
                        return SourceResult(index: index, hits: hits, failed: false)
                    } catch is CancellationError {
                        return SourceResult(index: index, hits: [], failed: false)
                    } catch {
                        plog("🔎 Server search failed source=\(LogRedactionPolicy.digest(source.id)) type=\(source.type.rawValue): \(error.localizedDescription)")
                        return SourceResult(index: index, hits: [], failed: true)
                    }
                }
            }

            var ordered: [SourceResult] = []
            ordered.reserveCapacity(pairs.count)
            for await item in group {
                ordered.append(item)
            }
            ordered.sort { $0.index < $1.index }

            var merged: [ServerSearchHit] = []
            var failures = 0
            for item in ordered {
                if item.failed { failures += 1 }
                merged.append(contentsOf: item.hits)
            }
            return BatchOutcome(hits: merged, failedCount: failures)
        }
    }

    nonisolated private static func searchSingleSource(
        connector: any ServerSongSearchingConnector,
        query: String,
        limit: Int,
        timeout: Duration
    ) async throws -> [Song] {
        try await withThrowingTaskGroup(of: [Song].self) { group in
            group.addTask {
                try await connector.searchServerSongs(query: query, limit: limit)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw SourceError.connectionFailed("Server search timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return [] }
            return first
        }
    }
}
