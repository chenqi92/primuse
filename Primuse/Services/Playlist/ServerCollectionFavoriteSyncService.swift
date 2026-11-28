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
    /// 歌曲模型不在内存里时同一件事从曲库目录答(DL3),一次答这一轮要推的几条:喜欢的 id → 这个源上的那首歌
    /// (里层 nil:这个源上没有)。外层 nil:目录此刻答不了,不是「这个源上没有」。
    typealias CatalogSongProvider = @MainActor ([LibraryFavorite], String) async -> [String: Song?]?
    /// 镜像刷新那一轮的占用,参数是占用的原因(进日志)。
    typealias SongModelAcquirer = @MainActor (String) async -> Void

    static let baselinesDefaultsKey = "primuse.serverCollectionFavorites.baselines.v1"

    private let sourcesProvider: @MainActor () -> [MusicSource]
    private let connectorProvider: ConnectorProvider
    private let songProvider: SongProvider
    /// 曲库此刻答不答得出「这个源上有没有这张专辑 / 这位艺人的歌」(歌曲模型在内存里)。答不出时 `songProvider`
    /// 的 nil 不是「这个源上没有」。
    private let libraryCanAnswer: @MainActor () -> Bool
    private let catalogSongProvider: CatalogSongProvider?
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
        libraryCanAnswer: @escaping @MainActor () -> Bool = { true },
        catalogSongProvider: CatalogSongProvider? = nil,
        favorites: LibraryFavoritesStore = .shared,
        defaults: UserDefaults = .standard,
        localChangeDelay: Duration = .seconds(2)
    ) {
        self.sourcesProvider = sourcesProvider
        self.connectorProvider = connectorProvider
        self.songProvider = songProvider
        self.libraryCanAnswer = libraryCanAnswer
        self.catalogSongProvider = catalogSongProvider
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

    /// 扫描收尾 / 镜像刷新时调用。`acquireSongModel`:镜像刷新那一轮的占用(一轮最多一次)。对账本身(取服务端、比基线、
    /// 把服务端的改动记进本机的喜欢)不读整库;只有本机有要推上去的喜欢(要从这个源上的一首歌反查服务端 id)而
    /// 歌曲模型不在内存里时才占用。没变的一轮不占用、不装模型。
    /// DL3:要推的喜欢先问曲库目录(`catalogSongProvider`),目录也答不了时才占用。
    func refresh(source: MusicSource, applyFence: ServerMirrorApplyFence, acquireSongModel: SongModelAcquirer? = nil) async {
        guard source.type.supportsServerCollectionFavorites, applyFence() else { return }
        await reconcileSerially(source.id, acquireSongModel: acquireSongModel)
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
    private func reconcileSerially(_ sourceID: String, acquireSongModel: SongModelAcquirer? = nil) async {
        if let task = running[sourceID] {
            rerunRequested.insert(sourceID)
            await task.value
            return
        }
        repeat {
            rerunRequested.remove(sourceID)
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.reconcile(sourceID: sourceID, acquireSongModel: acquireSongModel)
            }
            running[sourceID] = task
            await task.value
            running[sourceID] = nil
        } while rerunRequested.contains(sourceID)
    }

    // MARK: - Reconciliation

    private func reconcile(sourceID: String, acquireSongModel: SongModelAcquirer?) async {
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

            // 要推上去的喜欢得从这个源上的一首歌反查服务端 id(读整库的专辑、艺人表):歌曲模型不在内存里时,
            // 镜像刷新那一轮这时才占用。
            // DL3:先问曲库目录(同一个挑法,结果与要推的条数同阶);目录也答不了时才占用。在本机、这个源上没有的
            // 专辑 / 艺人每一轮都还在「要推」里(推不了,结果是 notOnSource),以前每一轮都为它装一次模型。
            var catalogSongs: [String: Song?]?
            if !plan.starOnServer.isEmpty, !libraryCanAnswer() {
                let pending = plan.starOnServer.sorted().compactMap { favorites.entry(id: $0) }
                catalogSongs = await catalogSongProvider?(pending, source.id)
                if catalogSongs == nil, let acquireSongModel {
                    await acquireSongModel("local likes to push and the catalog cannot answer n=\(pending.count)")
                }
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
                // 歌曲模型不在内存里时查不到这个源上的歌,那不是「这个源上没有」:当作这一次没推成,下一轮再推。
                // 当成「没有」的话,对账时刻就盖过了这条喜欢,下一轮会把它当成服务端删掉的、在本机取消。
                // DL3:模型不在时用目录答的那一份;目录也没答(读不了、答不了这一条)才是「这一次没推成」。
                let song: Song?
                if libraryCanAnswer() {
                    song = songProvider(entry, source.id)
                } else if let answer = catalogSongs?[entry.id] {
                    song = answer
                } else {
                    failedEntries.append(entry)
                    continue
                }
                do {
                    guard let itemID = try await serverItemID(for: entry, song: song, source: source, connector: connector) else {
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

    /// 本机的一条喜欢在这个源上的服务端 id：从这个源上的一首歌(`song`)反查。这个源上没有就 nil。
    private func serverItemID(
        for entry: LibraryFavorite,
        song: Song?,
        source: MusicSource,
        connector: any ServerCollectionFavoriteConnector
    ) async throws -> String? {
        guard let song,
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

    /// 生产环境的 `CatalogSongProvider`。
    static func catalogSongProvider(library: MusicLibrary) -> CatalogSongProvider {
        { [weak library] entries, sourceID in
            guard let library else { return nil }
            return await catalogSongs(for: entries, sourceID: sourceID, library: library)
        }
    }

    /// `librarySong` 在歌曲模型不在内存里时的做法(DL3):同一个挑法 —— 名字对上喜欢的键的可见专辑(艺人)按专辑墙
    /// (艺人列表)的先后,取各自的歌里第一首在这个源上的。专辑(艺人)表在主线程外按页读一遍,只留对上的那几张的 id;
    /// 它们的歌经按专辑(艺人)的目录读法取(与 `songs(forAlbum:)` / `songs(forArtist:)` 放掉之后答的是同一份)。
    /// 结果与要推的条数同阶。nil:目录此刻答不了(模型在内存里、读不了、读失败,或者一组歌给满了上限还没有这个源上的,
    /// 说不清后面有没有) —— 调用方照旧占用模型,不当成「这个源上没有」。
    static func catalogSongs(
        for entries: [LibraryFavorite], sourceID: String, library: MusicLibrary
    ) async -> [String: Song?]? {
        guard !entries.isEmpty else { return [:] }
        guard !library.isReady, let reader = library.readableCatalogReader else { return nil }
        let wanted = Set(entries.map(\.id))
        let unknown = String(localized: "unknown_artist")
        let wantsAlbums = entries.contains { $0.kind == .album }
        let wantsArtists = entries.contains { $0.kind == .artist }
        let candidates: (albums: [String: [String]], artists: [String: [String]])
        do {
            candidates = try await reader.read { catalog in
                var albums: [String: [String]] = [:]
                var artists: [String: [String]] = [:]
                if wantsAlbums {
                    let keys = try catalog.albumKeys(visibleOnly: true).keys
                    for start in stride(from: 0, to: keys.count, by: LibraryScale.maxMaterializedRows) {
                        let page = keys[start..<min(keys.count, start + LibraryScale.maxMaterializedRows)]
                        for album in try catalog.albums(keys: page, visibleCounts: true) {
                            let key = LibraryFavoriteKey.id(
                                kind: .album, albumTitle: album.title, artistName: album.artistName ?? "",
                                unknownArtistName: unknown
                            )
                            if wanted.contains(key) { albums[key, default: []].append(album.id) }
                        }
                    }
                }
                if wantsArtists {
                    let keys = try catalog.artistKeys(visibleOnly: true).keys
                    for start in stride(from: 0, to: keys.count, by: LibraryScale.maxMaterializedRows) {
                        let page = keys[start..<min(keys.count, start + LibraryScale.maxMaterializedRows)]
                        for artist in try catalog.artists(keys: page, visibleCounts: true) {
                            let key = LibraryFavoriteKey.id(
                                kind: .artist, albumTitle: "", artistName: artist.name, unknownArtistName: unknown
                            )
                            if wanted.contains(key) { artists[key, default: []].append(artist.id) }
                        }
                    }
                }
                return (albums, artists)
            }
        } catch {
            plog("💗 server collection favorites: the catalog lookup failed: \(error)")
            return nil
        }
        // 读的这一会儿模型装回来了:目录那一半答不了,交给调用方(它会看到模型在内存里,走内存那条路)。
        guard !library.isReady else { return nil }
        var answers: [String: Song?] = [:]
        for entry in entries {
            let ids = (entry.kind == .album ? candidates.albums : candidates.artists)[entry.id] ?? []
            var found: Song?
            for id in ids {
                let read = entry.kind == .album
                    ? library.songsFromTheCatalog(forAlbum: id) : library.songsFromTheCatalog(forArtist: id)
                guard let songs = read else { return nil }
                if let song = songs.first(where: { $0.sourceID == sourceID }) {
                    found = song
                    break
                }
                if songs.count >= LibraryScale.maxMaterializedRows { return nil }
            }
            answers[entry.id] = .some(found)
        }
        return answers
    }
}
