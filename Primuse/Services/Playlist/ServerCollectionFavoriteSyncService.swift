import Foundation
import PrimuseKit

/// 专辑 / 艺人的「喜欢」与服务端收藏的双向对账（规则见
/// `ServerCollectionFavoriteReconciliation`）。
///
/// - 本机改了喜欢（含 iCloud 从别的设备带来的）就对每个支持的源对一次账，把改动推上去；
/// - 扫描收尾与镜像刷新时再对一次，把别的客户端在服务端点的收藏带回本机。
///
/// 服务端带回来的改动以「server」来源记入 `LibraryFavoritesStore`：不再触发推送，
/// 但照常经 iCloud 同步到其它设备。本机的喜欢是跨源按名字认的，写到服务端前要先从这个源上
/// 的一首歌反查出服务端的专辑 / 艺人 id。
@MainActor
final class ServerCollectionFavoriteSyncService {
    struct Baseline: Codable, Equatable {
        var keys: [String]
        var syncedAt: Date
    }

    typealias ConnectorProvider = @MainActor (MusicSource) -> (any ServerCollectionFavoriteConnector)?
    /// 这个源上属于这张专辑 / 这位艺人的一首歌（没有就 nil：这个源上没有，不用推）。
    typealias SongProvider = @MainActor (LibraryFavorite, String) -> Song?

    static let baselinesDefaultsKey = "primuse.serverCollectionFavorites.baselines.v1"

    private let sourcesProvider: @MainActor () -> [MusicSource]
    private let connectorProvider: ConnectorProvider
    private let songProvider: SongProvider
    private let favorites: LibraryFavoritesStore
    private let defaults: UserDefaults
    private let localChangeDelay: Duration
    private var baselines: [String: Baseline]
    private var running: [String: Task<Void, Never>] = [:]
    private var rerunRequested: Set<String> = []
    private var localChangeTask: Task<Void, Never>?
    // deinit 不在主 actor 上，只在那里读一次。
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(
        sourcesProvider: @escaping @MainActor () -> [MusicSource],
        connectorProvider: @escaping ConnectorProvider,
        songProvider: @escaping SongProvider,
        favorites: LibraryFavoritesStore = .shared,
        defaults: UserDefaults = .standard,
        localChangeDelay: Duration = .seconds(2)
    ) {
        self.sourcesProvider = sourcesProvider
        self.connectorProvider = connectorProvider
        self.songProvider = songProvider
        self.favorites = favorites
        self.defaults = defaults
        self.localChangeDelay = localChangeDelay
        if let data = defaults.data(forKey: Self.baselinesDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: Baseline].self, from: data) {
            baselines = decoded
        } else {
            baselines = [:]
        }
        observer = NotificationCenter.default.addObserver(
            forName: .primuseLibraryFavoritesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // 服务端带回来的改动不推回服务端。
            guard (note.userInfo?["origin"] as? String) != "server" else { return }
            Task { @MainActor [weak self] in self?.scheduleLocalChangeSync() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 扫描收尾 / 镜像刷新时调用。
    func refresh(source: MusicSource, applyFence: ServerMirrorApplyFence) async {
        guard source.type.supportsServerCollectionFavorites, applyFence() else { return }
        await reconcileSerially(source.id)
    }

    /// 测试与诊断用：立即对所有支持的源对一次账。
    func syncAllNow() async {
        for source in eligibleSources() {
            await reconcileSerially(source.id)
        }
    }

    func baseline(for sourceID: String) -> Baseline? { baselines[sourceID] }

    // MARK: - Scheduling

    private func eligibleSources() -> [MusicSource] {
        sourcesProvider().filter {
            $0.isEnabled && !$0.isDeleted && $0.type.supportsServerCollectionFavorites
        }
    }

    private func scheduleLocalChangeSync() {
        localChangeTask?.cancel()
        let delay = localChangeDelay
        localChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.syncAllNow()
        }
    }

    /// 同一个源同时只对一轮账；进行中又来请求就在这一轮结束后再补一轮。
    private func reconcileSerially(_ sourceID: String) async {
        if let task = running[sourceID] {
            rerunRequested.insert(sourceID)
            await task.value
            return
        }
        repeat {
            rerunRequested.remove(sourceID)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcile(sourceID: sourceID)
            }
            running[sourceID] = task
            await task.value
            running[sourceID] = nil
        } while rerunRequested.contains(sourceID)
    }

    // MARK: - Reconciliation

    private func reconcile(sourceID: String) async {
        guard let source = eligibleSources().first(where: { $0.id == sourceID }),
              let connector = connectorProvider(source) else { return }
        let sourceTag = LogRedactionPolicy.digest(source.id)
        do {
            let startedAt = Date()
            let server = try await connector.fetchServerCollectionFavorites()
            guard eligibleSources().contains(where: { $0.id == sourceID }) else { return }
            let unknownArtist = String(localized: "unknown_artist")
            var serverByKey: [String: ServerCollectionFavorite] = [:]
            for favorite in server {
                let key = LibraryFavoriteKey.id(
                    kind: favorite.kind,
                    albumTitle: favorite.albumTitle,
                    artistName: favorite.artistName,
                    unknownArtistName: unknownArtist
                )
                serverByKey[key] = favorite
            }
            let previous = baselines[sourceID]
            let plan = ServerCollectionFavoriteReconciliation.plan(
                serverKeys: Set(serverByKey.keys),
                baseline: previous.map { Set($0.keys) },
                lastSyncedAt: previous?.syncedAt,
                local: favorites.ledger.entries
            )

            for key in plan.likeLocally {
                guard let favorite = serverByKey[key] else { continue }
                favorites.applyServerFavorite(
                    kind: favorite.kind,
                    albumTitle: favorite.albumTitle,
                    artistName: favorite.artistName,
                    liked: true
                )
            }
            for key in plan.unlikeLocally {
                guard let entry = favorites.entry(id: key) else { continue }
                favorites.applyServerFavorite(
                    kind: entry.kind,
                    albumTitle: entry.albumTitle,
                    artistName: entry.artistName,
                    liked: false
                )
            }

            var keys = Set(serverByKey.keys)
            var starred = 0, unstarred = 0, notOnSource = 0
            var failedEntries: [LibraryFavorite] = []
            for key in plan.unstarOnServer.sorted() {
                guard let favorite = serverByKey[key] else { continue }
                do {
                    try await connector.setServerCollectionFavorite(
                        kind: favorite.kind,
                        itemID: favorite.itemID,
                        isFavorite: false
                    )
                    keys.remove(key)
                    unstarred += 1
                } catch {
                    if let entry = favorites.entry(id: key) { failedEntries.append(entry) }
                }
            }
            for key in plan.starOnServer.sorted() {
                guard let entry = favorites.entry(id: key) else { continue }
                do {
                    guard let itemID = try await serverItemID(for: entry, source: source, connector: connector) else {
                        notOnSource += 1
                        continue
                    }
                    try await connector.setServerCollectionFavorite(
                        kind: entry.kind,
                        itemID: itemID,
                        isFavorite: true
                    )
                    keys.insert(key)
                    starred += 1
                } catch {
                    failedEntries.append(entry)
                }
            }

            // 推送失败的、对账期间本机又改的（不是这一轮自己带进来的）下一轮还要处理：
            // 把对账时刻压到它们修改之前，下一轮仍算「本机后来改过」。
            let ownWrites = plan.likeLocally.union(plan.unlikeLocally)
            let changedDuringPass = favorites.ledger.entries.values.filter {
                $0.modifiedAt > startedAt && !ownWrites.contains($0.id)
            }
            let syncedAt = (failedEntries + changedDuringPass).map(\.modifiedAt).min()
                .map { $0.addingTimeInterval(-0.001) } ?? Date()
            baselines[sourceID] = Baseline(keys: keys.sorted(), syncedAt: syncedAt)
            persistBaselines()
            if !plan.likeLocally.isEmpty || !plan.unlikeLocally.isEmpty
                || starred + unstarred > 0 || !failedEntries.isEmpty {
                plog("💗 server collection favorites source=\(sourceTag) first=\(previous == nil) imported=\(plan.likeLocally.count) removed=\(plan.unlikeLocally.count) starred=\(starred) unstarred=\(unstarred) notOnSource=\(notOnSource) failed=\(failedEntries.count) server=\(server.count)")
            }
        } catch is CancellationError {
            return
        } catch {
            plog("💗 server collection favorites source=\(sourceTag) failed: \(error.localizedDescription)")
        }
    }

    /// 本机的一条喜欢在这个源上的服务端 id：从这个源上的一首歌反查。这个源上没有就 nil。
    private func serverItemID(
        for entry: LibraryFavorite,
        source: MusicSource,
        connector: any ServerCollectionFavoriteConnector
    ) async throws -> String? {
        guard let song = songProvider(entry, source.id),
              let songItemID = ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: song.filePath,
                sourceType: source.type
              ) else { return nil }
        let membership = try await connector.serverCollectionMembership(songItemID: songItemID)
        switch entry.kind {
        case .album:
            return membership.albumID
        case .artist:
            let target = LibraryFavoriteKey.foldedArtist(entry.artistName)
            return membership.artists.first { LibraryFavoriteKey.foldedArtist($0.name) == target }?.id
        }
    }

    private func persistBaselines() {
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        defaults.set(data, forKey: Self.baselinesDefaultsKey)
    }

    // MARK: - Library lookup

    /// 生产环境的 `SongProvider`：按名字对上的专辑 / 艺人里，取这个源上的第一首歌。
    static func librarySong(
        for entry: LibraryFavorite,
        sourceID: String,
        library: MusicLibrary,
        favorites: LibraryFavoritesStore
    ) -> Song? {
        switch entry.kind {
        case .album:
            for album in library.visibleAlbums where favorites.favoriteID(for: album) == entry.id {
                if let song = library.songs(forAlbum: album.id).first(where: { $0.sourceID == sourceID }) {
                    return song
                }
            }
        case .artist:
            for artist in library.visibleArtists where favorites.favoriteID(for: artist) == entry.id {
                if let song = library.songs(forArtist: artist.id).first(where: { $0.sourceID == sourceID }) {
                    return song
                }
            }
        }
        return nil
    }
}
