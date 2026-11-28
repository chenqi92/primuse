#if os(iOS)
import Foundation
import Observation
import PrimuseKit

/// 车机上那几份按内容列的表 —— 专辑 A–Z、歌曲 A–Z、喜欢的专辑、环境音、有声书架与本机播客节目的歌、打开的文件夹
/// 这一层的歌 —— 在歌曲模型不在内存里时从曲库目录取(C2;两份艺人列表见 `CarPlayArtistLists`,写法相同)。
///
/// 模型在内存里时照旧在内存里取,一字不差。不在时用与内存里同一组、同一先后的目录查询,在主线程外跑;每份列表记住最近
/// 一份答案(按目录与它的修订号认)。答不出(目录读不了、读失败)时给同一份列表的上一份,一份都没有时 nil:车机摆一行
/// 「正在准备」,不拿「答不出」当「没有」。答案到了、或答案依据的目录动了,`revision` 跟着变,车机的观察者据此重建;
/// 只在问过之后跟一次,车机不再问就不再跟。同一份列表同时只读一次:读的途中目录又动了,读完再按最新的读一次,
/// 扫描期间目录一秒动几回也不会排起一串整表查询。
@MainActor
@Observable
final class CarPlayCatalogLists {
    /// 车机据此重建列表。
    private(set) var revision = 0
    @ObservationIgnored private var answers: [CarPlayCatalogList: Answer] = [:]
    /// 正在读的那一份按什么读的、读完要不要按更新的再读一次。
    @ObservationIgnored private var running: [CarPlayCatalogList: Pending] = [:]
    /// 答案是哪个目录的:换了目录(换了曲库)先清掉旧的,不拿别的曲库的列表顶。
    @ObservationIgnored private weak var answeredHost: LibraryCatalogHost?
    /// 正在跟的是哪个目录(一次性的观察,报过信就清掉);换了目录要在新的上面再跟。
    @ObservationIgnored private weak var watchedHost: LibraryCatalogHost?
    @ObservationIgnored private var watchGeneration = 0
    /// 记着的文件夹层,最近打开的在后:只留最近几层,一层层点下去不会一直攒着。
    @ObservationIgnored private var folderLists: [CarPlayCatalogList] = []
    /// 车机断开、内存吃紧时放掉记着的答案(它们只是缓存,再问时重读)。
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.primuseCarPlaySceneDidDisconnect, .primuseMemoryPressure] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.forgetAnswers() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// 车机的哪一份列表。
enum CarPlayCatalogList: Hashable, Sendable {
    case albumsByTitle
    case songsByTitle
    case likedAlbums(favorites: ObjectIdentifier)
    case ambient(limit: Int)
    case spokenWord(SpokenWordCollection)
    case folderSongs(LibraryFolderNodeID)
}

extension CarPlayCatalogLists {
    static let shared = CarPlayCatalogLists()

    /// 车机 A–Z 列表与「喜欢」列表的上限(同以前)。
    nonisolated static let limit = 500

    /// 记着的文件夹层至多几层。
    static let rememberedFolderLevels = 6

    /// 放掉记着的答案;正在读的照旧读完、记下。
    func forgetAnswers() {
        answers = [:]
        folderLists = []
    }

    enum Value: Sendable {
        case albums([Album])
        case songs([Song])
    }

    struct Answer {
        let key: [UInt64]
        let value: Value
    }

    struct Pending {
        var key: [UInt64]
        var newer: (key: [UInt64], compute: @Sendable (LibraryCatalogReader) async throws -> Value)?
    }

    // MARK: Lists

    /// 专辑 A–Z:按标题(`localizedCaseInsensitiveCompare`)的前 500 张。模型在内存里时与以前相同(目录读得了先问目录,
    /// 否则在内存里挑);不在时只问目录。nil:此刻答不出。
    func albumsByTitle(in library: MusicLibrary) -> [Album]? {
        guard !library.isReady else {
            return Self.fromCatalog("albums", library) { try $0.firstAlbumsByTitle(limit: Self.limit) }
                // crash-pattern: allow legacy-library-api 模型在内存里、目录读不了时同原来,只挑前 500 张
                ?? CarPlayListSelection.firstSorted(library.visibleAlbums, limit: Self.limit) {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
        }
        return albums(.albumsByTitle, in: library, revisions: { [$0.albums, $0.everything] }) { reader in
            .albums(try await reader.read { try $0.firstAlbumsByTitle(limit: Self.limit) })
        }
    }

    /// 歌曲 A–Z:可见音乐按标题的前 500 首。规则同 `albumsByTitle(in:)`。
    func songsByTitle(in library: MusicLibrary) -> [Song]? {
        guard !library.isReady else {
            return Self.fromCatalog("songs", library) { try $0.firstSongsByTitle(limit: Self.limit) }
                // crash-pattern: allow legacy-library-api 模型在内存里、目录读不了时同原来,只挑前 500 首
                ?? CarPlayListSelection.firstSorted(library.musicSongs, limit: Self.limit) {
                    $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
        }
        return songs(.songsByTitle, in: library, revisions: { [$0.songs, $0.membership, $0.everything] }) { reader in
            .songs(try await reader.read { try $0.firstSongsByTitle(limit: Self.limit) })
        }
    }

    /// 喜欢的专辑:最近喜欢的在前(同 `likedAlbums(in:)`)的前 500 张;不在内存里时用收藏页同一个目录查询
    /// (`likedAlbums(likedOrder:unknownArtistName:)`,同一个键、同一个先后)。
    func likedAlbums(in library: MusicLibrary, favorites: LibraryFavoritesStore = .shared) -> [Album]? {
        // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时从目录取
        guard !library.isReady else { return Array(favorites.likedAlbums(in: library.visibleAlbums).prefix(Self.limit)) }
        let order = FavoriteCatalogLikes.likedOrder(favorites, .album)
        let unknown = String(localized: "unknown_artist")
        let liked = UInt64(truncatingIfNeeded: favorites.revision)
        return albums(.likedAlbums(favorites: ObjectIdentifier(favorites)), in: library,
                      revisions: { [$0.albums, $0.everything, liked] }) { reader in
            .albums(Array(try await reader.likedAlbums(likedOrder: order, unknownArtistName: unknown).prefix(Self.limit)))
        }
    }

    /// 环境音:可见的环境音按库内顺序(同 `ambientSongs`)的前 `limit` 段。
    func ambient(limit: Int, in library: MusicLibrary) -> [Song]? {
        // crash-pattern: allow legacy-library-api 模型在内存里时同原来;不在时从目录取前 limit 段
        guard !library.isReady else { return Array(library.ambientSongs.prefix(max(0, limit))) }
        return songs(.ambient(limit: limit), in: library, revisions: { [$0.songs, $0.membership, $0.everything] }) { reader in
            .songs(try await reader.read { catalog in
                try Self.firstSongs(LibrarySongScope(kinds: [.ambient]), limit: limit, in: catalog)
            })
        }
    }

    /// 有声书架(或本机播客)的歌:这一类的可见歌,库内顺序,同 `spokenWordSongs` / `localPodcastSongs`
    /// (`SpokenWordCatalogShelf.scope`)。分书、进度照旧由车机在主线程上按这份歌算,与内存里时同一段代码。
    func shelfSongs(_ collection: SpokenWordCollection, in library: MusicLibrary) -> [Song]? {
        guard !library.isReady else { return collection.songs(in: library) }
        let scope = SpokenWordCatalogShelf.scope(collection)
        return songs(.spokenWord(collection), in: library,
                     revisions: { [$0.books, $0.songs, $0.membership, $0.everything] }) { reader in
            .songs(try await reader.reduceSongs(scope, into: [Song]()) { songs, song in
                songs.append(song)
                return true
            })
        }
    }

    /// 打开的文件夹这一层的歌(`CarPlayFolderLibrary.songs(in:scope: .direct)`,碟号、曲号、标题排好)。
    /// 不在内存里时 id 从索引(目录版的分区读目录)取、歌按 id 分段从目录取,在主线程外排。
    func folderSongs(_ nodeID: LibraryFolderNodeID, in library: MusicLibrary,
                     folders: CarPlayFolderLibrary = .shared) -> [Song]? {
        guard !library.isReady else { return folders.songs(in: nodeID, scope: .direct) }
        guard let index = folders.index else { return nil }
        let indexRevision = UInt64(truncatingIfNeeded: folders.revision)
        return songs(.folderSongs(nodeID), in: library,
                     revisions: { [indexRevision, $0.songs, $0.membership, $0.everything] }) { reader in
            .songs(try await CarPlayFolderLibrary.catalogSongs(in: nodeID, scope: .direct, index: index, reader: reader))
        }
    }

    // MARK: Engine

    private func albums(
        _ list: CarPlayCatalogList, in library: MusicLibrary, revisions: (LibraryCatalogRevisions) -> [UInt64],
        compute: @escaping @Sendable (LibraryCatalogReader) async throws -> Value
    ) -> [Album]? {
        guard case .albums(let albums)? = answer(list, in: library, revisions: revisions, compute: compute) else { return nil }
        return albums
    }

    private func songs(
        _ list: CarPlayCatalogList, in library: MusicLibrary, revisions: (LibraryCatalogRevisions) -> [UInt64],
        compute: @escaping @Sendable (LibraryCatalogReader) async throws -> Value
    ) -> [Song]? {
        guard case .songs(let songs)? = answer(list, in: library, revisions: revisions, compute: compute) else { return nil }
        return songs
    }

    private func answer(
        _ list: CarPlayCatalogList, in library: MusicLibrary, revisions: (LibraryCatalogRevisions) -> [UInt64],
        compute: @escaping @Sendable (LibraryCatalogReader) async throws -> Value
    ) -> Value? {
        guard let host = library.catalogHost else { return nil }
        if answeredHost !== host {
            running = [:]
            answers = [:]
            answeredHost = host
        }
        watch(host, library: library)
        let previous = answers[list]
        // 目录此刻读得了才查:读不了时先给上一份(没有就是 nil),等 `watch` 报信再问。
        guard host.revisions.isReadable else { return previous?.value }
        let key = revisions(host.revisions)
        if previous?.key == key { return previous?.value }
        if var pending = running[list] {
            if pending.key != key {
                pending.newer = (key, compute)
                running[list] = pending
            }
        } else {
            start(list, key: key, compute: compute, host: host)
        }
        return previous?.value
    }

    private func start(
        _ list: CarPlayCatalogList, key: [UInt64], compute: @escaping @Sendable (LibraryCatalogReader) async throws -> Value,
        host: LibraryCatalogHost
    ) {
        running[list] = Pending(key: key)
        let reader = host.reader
        Task { [weak self, weak host] in
            let value: Value?
            do {
                value = try await compute(reader)
            } catch {
                plog("🚗 CarPlay \(list) catalog read failed (\(error)); keeping the last answer")
                value = nil
            }
            guard let self, let host, self.answeredHost === host, let pending = self.running[list] else { return }
            self.running[list] = nil
            // 答不出(读失败)不记、不报信:车机照旧摆上一份或「正在准备」,目录再动时重问。
            if let value {
                self.answers[list] = Answer(key: key, value: value)
                self.rememberFolderLevel(list)
                self.revision &+= 1
            }
            if let newer = pending.newer { self.start(list, key: newer.key, compute: newer.compute, host: host) }
        }
    }

    private func rememberFolderLevel(_ list: CarPlayCatalogList) {
        guard case .folderSongs = list else { return }
        folderLists.removeAll { $0 == list }
        folderLists.append(list)
        while folderLists.count > Self.rememberedFolderLevels { answers[folderLists.removeFirst()] = nil }
    }

    /// 问过之后跟一次答案依据的东西:目录能不能读、几个修订号、喜欢的账本。变了就让车机重建(重建时再问,问的时候
    /// 再跟);模型已经装回来时不必。
    private func watch(_ host: LibraryCatalogHost, library: MusicLibrary) {
        guard watchedHost !== host else { return }
        watchedHost = host
        watchGeneration &+= 1
        let generation = watchGeneration
        withObservationTracking {
            _ = host.revisions.isReadable
            _ = host.revisions.songs
            _ = host.revisions.membership
            _ = host.revisions.albums
            _ = host.revisions.books
            _ = host.revisions.everything
            _ = LibraryFavoritesStore.shared.revision
        } onChange: { [weak self, weak library] in
            Task { @MainActor [weak self, weak library] in
                guard let self else { return }
                if self.watchGeneration == generation { self.watchedHost = nil }
                guard let library, !library.isReady else { return }
                self.revision &+= 1
            }
        }
    }

    // MARK: Reads

    /// 模型在内存里时车机原来那条路:目录可读时直接在目录上取(一次有界的查询,结果与在内存数组上挑一样);
    /// 目录不能读或读失败返回 nil,调用方照旧在内存里的整库上挑。
    static func fromCatalog<T>(_ list: String, _ library: MusicLibrary, _ body: (LibraryCatalog) throws -> T) -> T? {
        guard let host = library.catalogHost, host.revisions.isReadable,
              let catalog = host.mirror.readableCatalog else { return nil }
        do {
            return try body(catalog)
        } catch {
            plog("🚗 CarPlay \(list) catalog read failed (\(error)); using the in-memory library")
            return nil
        }
    }

    /// 范围里按库内顺序的前 `limit` 首,读够就停。
    nonisolated static func firstSongs(_ scope: LibrarySongScope, limit: Int, in catalog: LibraryCatalog) throws -> [Song] {
        guard limit > 0 else { return [] }
        var songs: [Song] = []
        try catalog.forEachSong(scope) { _, song in
            songs.append(song)
            return songs.count < limit
        }
        return songs
    }
}
#endif
