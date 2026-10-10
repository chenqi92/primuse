import Foundation
import PrimuseKit

/// 资料库与首页的「收藏」。
///
/// 收藏区是一份没有上限、可以拖动排序的列表，装专辑、艺人、歌单（含「我喜欢」）、目录和有声书。
/// 这里存的只是它们的顺序；收没收藏各有各的账：
/// - 专辑与艺人看 `LibraryFavoritesStore`（详情页那颗心，经 iCloud 与服务端同步）；
/// - 目录看首页目录的置顶列表（`HomeFolderPinStorage`，首页「目录」区块显示的也是它）；
/// - 歌单与有声书就看这里存的这一份。
/// 显示顺序由 `FavoriteCollectionOrderPolicy` 合出来：新收藏的排在最前（开头是「我喜欢」时排它后面）。
///
/// 歌单、有声书、目录收没收藏，以及收藏区与首页目录的顺序，经 iCloud 键值存储同步到同一个 Apple ID 的
/// 其他 iPhone、iPad 与 Mac（`FavoriteCollectionSyncPolicy` 合并，见「iCloud」一节）。
@MainActor
final class FavoriteCollectionStore {
    static let shared = FavoriteCollectionStore()

    /// 改成「收藏」那一版的一次性迁移（见 `migrateIfNeeded`）。
    static let migrationKey = "primuse.library.favoriteCollection.migrated.v1"

    /// 收藏的有声书变了（收藏、取消、在编辑页删掉，或者从 iCloud 带来）。服务端对账自己带进来的改动不发。
    static let collectedBooksDidChange = Notification.Name("primuse.favoriteCollection.collectedBooksDidChange")

    /// 本机这一份同步状态：每条收藏的时刻与墓碑、排定顺序的时刻。只在本机，云端那份在
    /// `CloudKVSKey.favoriteCollection`。
    static let syncStateKey = "primuse.library.favoriteCollection.syncState.v1"
    /// 拖动排序会连着写好几次，停一下再推。
    private static let cloudPushDelay: Duration = .seconds(1)

    /// 专辑、艺人、目录的成员资格，按资料库与两本账的版本记住。合一次要把整库专辑过一遍，
    /// 而资料库页、首页、收藏页在一次刷新里都会来要。
    private struct Membership {
        var albumIDs: Set<String> = []
        var artistIDs: Set<String> = []
        var folderIDs: Set<LibraryFolderNodeID> = []
        /// 收藏着的专辑、艺人（最近收藏的在前）与目录（置顶顺序），用来补上还没排进顺序的。
        var collected: [QuickAccessPinReference] = []
    }

    private struct MembershipKey: Equatable {
        let favoritesRevision: Int
        let libraryRevision: Int
        let albumCount: Int
        let artistCount: Int
        let folders: String
    }

    private let defaults: UserDefaults
    private let favorites: LibraryFavoritesStore
    private weak var library: MusicLibrary?
    private var membershipCache: (key: MembershipKey, value: Membership)?
    /// 合好的显示顺序。资料库页一次刷新会来要好几遍。
    private var referencesCache: (key: MembershipKey, stored: String, value: [QuickAccessPinReference])?
    /// 账本里生效的喜欢。改动通知只带 id，和它比一比才知道是新收藏的还是取消的。
    private var likedSnapshot: Set<String> = []
    private var pendingLikeChanges: Set<String> = []
    /// 这一批里有这台设备上点的（不是 iCloud、服务端带来的）。
    private var pendingLikeChangesIncludeLocal = false
    private var likeChangeTask: Task<Void, Never>?
    // deinit 不在主 actor 上，只在那里读一次。
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    private let injectedCloud: CloudKVSSync?
    private var cloud: CloudKVSSync { injectedCloud ?? .shared }
    /// 这台设备上的音乐源，用来认出只在本机有意义的目录与书。
    private var sourcesProvider: (@MainActor () -> [MusicSource])?
    /// `start` 接上 iCloud 之前是 `nil`。
    private var syncState: FavoriteCollectionSyncState?
    /// 正在把云端那份落回本机：这时的写入不是这台设备的编辑。
    private var isApplyingCloudCopy = false
    /// 正在做用户自己的收藏操作：做完一起记，这时的顺序也算这台设备排的。
    private var isUserEdit = false
    /// 第一次读到 iCloud 那份之前不推，免得拿本机这份先把云端那份盖掉。
    private var isAwaitingCloudRead = true
    private var cloudPushTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        favorites: LibraryFavoritesStore = .shared,
        cloud: CloudKVSSync? = nil
    ) {
        self.defaults = defaults
        self.favorites = favorites
        injectedCloud = cloud
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 资料库发布之后调一次：开始跟着专辑 / 艺人的收藏调整顺序，做一次性迁移，再接上 iCloud。
    func start(library: MusicLibrary, sources: (@MainActor () -> [MusicSource])? = nil) {
        self.library = library
        sourcesProvider = sources
        if observer == nil {
            likedSnapshot = activeLikedIDs()
            observer = NotificationCenter.default.addObserver(
                forName: .primuseLibraryFavoritesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let ids = note.userInfo?["ids"] as? [String] ?? []
                let isLocal = note.userInfo?["origin"] == nil
                Task { @MainActor [weak self] in self?.enqueueLikeChanges(ids, isLocal: isLocal) }
            }
        }
        migrateIfNeeded()
        startCloudSync()
    }

    // MARK: - Storage

    static let anchor = LibraryPinStorage.likedSongsPin

    private var storedRawValue: String {
        defaults.string(forKey: LibraryPinStorage.defaultsKey) ?? ""
    }

    private var storedPins: [QuickAccessPinReference] {
        LibraryPinStorage.decode(storedRawValue)
    }

    private func store(_ pins: [QuickAccessPinReference]) {
        let encoded = LibraryPinStorage.encode(pins)
        guard encoded != storedRawValue else { return }
        let previousBooks = collectedBookIDs
        defaults.set(encoded, forKey: LibraryPinStorage.defaultsKey)
        if !isApplyingServerBookChanges, collectedBookIDs != previousBooks {
            // 从 iCloud 带来的也发：这台设备上的服务端收藏跟着对一次账，两边本来就一致时什么都不改。
            NotificationCenter.default.post(name: Self.collectedBooksDidChange, object: nil)
        }
        if !isUserEdit {
            recordLocalChanges(orderEdited: false)
        }
    }

    private var isApplyingServerBookChanges = false

    /// 收藏着的有声书（书架上的书 id）。
    var collectedBookIDs: Set<String> {
        Set(storedPins.lazy.filter { $0.kind == .book }.map(\.itemID))
    }

    /// 服务端收藏对账带回来的改动：照常排进收藏，但不再发改动通知（免得又推回服务端）。
    func applyServerBookChanges(collect: [String], uncollect: [String], library: MusicLibrary) {
        guard !collect.isEmpty || !uncollect.isEmpty else { return }
        isApplyingServerBookChanges = true
        defer { isApplyingServerBookChanges = false }
        if !collect.isEmpty {
            moveToFront(collect.map { QuickAccessPinReference(kind: .book, itemID: $0) }, library: library)
        }
        if !uncollect.isEmpty {
            let removed = Set(uncollect)
            store(storedPins.filter { $0.kind != .book || !removed.contains($0.itemID) })
        }
    }

    private var folderRawValue: String {
        defaults.string(forKey: HomeFolderPinStorage.key) ?? ""
    }

    /// 收藏的目录，按置顶顺序。从没收藏过（存的是空串）时首页自动推荐的那几个不算。
    var collectedFolderIDs: [LibraryFolderNodeID] {
        Self.collectedFolderIDs(in: folderRawValue)
    }

    static func collectedFolderIDs(in rawValue: String) -> [LibraryFolderNodeID] {
        rawValue.isEmpty ? [] : HomeFolderPinStorage.decode(rawValue)
    }

    // MARK: - Reading

    /// 收藏区的显示顺序。指向的东西可能已经不在资料库里，由各处显示时跳过。
    func references(library: MusicLibrary) -> [QuickAccessPinReference] {
        let membership = membership(library: library)
        let stored = storedRawValue
        if let referencesCache, referencesCache.key == membershipCache?.key, referencesCache.stored == stored {
            return referencesCache.value
        }
        let value = FavoriteCollectionOrderPolicy.merged(
            stored: LibraryPinStorage.decode(stored),
            isCollected: { isCollected($0, in: membership) },
            collectedButUnordered: membership.collected,
            anchor: Self.anchor
        )
        if let key = membershipCache?.key {
            referencesCache = (key, stored, value)
        }
        return value
    }

    func isCollected(_ pin: QuickAccessPinReference, library: MusicLibrary) -> Bool {
        switch pin.kind {
        case .playlist, .book:
            return storedPins.contains(pin)
        case .folder:
            return pin.folderNodeID.map { collectedFolderIDs.contains($0) } ?? false
        case .album, .artist:
            return isCollected(pin, in: membership(library: library))
        }
    }

    private func isCollected(_ pin: QuickAccessPinReference, in membership: Membership) -> Bool {
        switch pin.kind {
        case .album: membership.albumIDs.contains(pin.itemID)
        case .artist: membership.artistIDs.contains(pin.itemID)
        case .playlist, .book: true
        case .folder: pin.folderNodeID.map { membership.folderIDs.contains($0) } ?? false
        }
    }

    private func membership(library: MusicLibrary) -> Membership {
        let folders = folderRawValue
        let key = MembershipKey(
            favoritesRevision: favorites.revision,
            libraryRevision: library.searchRevision,
            albumCount: library.visibleAlbums.count,
            artistCount: library.visibleArtists.count &+ library.visibleAlbumArtists.count,
            folders: folders
        )
        if let membershipCache, membershipCache.key == key { return membershipCache.value }

        let albums = favorites.likedAlbums(in: library.visibleAlbums)
        let artists = favorites.likedArtists(in: library.favoriteArtistCandidates)
        var dated: [(pin: QuickAccessPinReference, likedAt: Date)] = []
        dated.reserveCapacity(albums.count + artists.count)
        for album in albums {
            let likedAt = favorites.entry(id: favorites.favoriteID(for: album))?.likedAt ?? .distantPast
            dated.append((QuickAccessPinReference(kind: .album, itemID: album.id), likedAt))
        }
        for artist in artists {
            let likedAt = favorites.entry(id: favorites.favoriteID(for: artist))?.likedAt ?? .distantPast
            dated.append((QuickAccessPinReference(kind: .artist, itemID: artist.id), likedAt))
        }
        // 两组各自已按收藏时间排好，合起来再排一次（稳定排序，同一时刻保持专辑在前）。
        let liked = dated.enumerated()
            .sorted { lhs, rhs in
                lhs.element.likedAt != rhs.element.likedAt
                    ? lhs.element.likedAt > rhs.element.likedAt
                    : lhs.offset < rhs.offset
            }
            .map(\.element.pin)
        let folderIDs = Self.collectedFolderIDs(in: folders)

        let value = Membership(
            albumIDs: Set(albums.map(\.id)),
            artistIDs: Set(artists.map(\.id)),
            folderIDs: Set(folderIDs),
            collected: liked + folderIDs.map(QuickAccessPinReference.folder)
        )
        membershipCache = (key, value)
        return value
    }

    // MARK: - Editing

    /// 收藏。专辑与艺人记进喜欢的账本（顺序由账本的改动通知来排），歌单、目录与有声书直接排到最前。
    func collect(_ pin: QuickAccessPinReference, library: MusicLibrary) {
        userEdit { performCollect(pin, library: library) }
    }

    private func performCollect(_ pin: QuickAccessPinReference, library: MusicLibrary) {
        switch pin.kind {
        case .album:
            if let album = library.visibleAlbum(id: pin.itemID) { favorites.setLiked(true, album: album) }
        case .artist:
            if let artist = library.favoriteArtist(id: pin.itemID) { favorites.setLiked(true, artistNamed: artist.name) }
        case .playlist, .book:
            moveToFront([pin], library: library)
        case .folder:
            guard let id = pin.folderNodeID else { return }
            var folders = collectedFolderIDs
            folders.removeAll { $0 == id }
            folders.insert(id, at: 0)
            defaults.set(HomeFolderPinStorage.encode(folders), forKey: HomeFolderPinStorage.key)
            moveToFront([pin], library: library)
        }
    }

    func uncollect(_ pin: QuickAccessPinReference, library: MusicLibrary) {
        userEdit { performUncollect(pin, library: library) }
    }

    private func performUncollect(_ pin: QuickAccessPinReference, library: MusicLibrary) {
        switch pin.kind {
        case .album:
            if let album = library.visibleAlbum(id: pin.itemID) { favorites.setLiked(false, album: album) }
        case .artist:
            if let artist = library.favoriteArtist(id: pin.itemID) { favorites.setLiked(false, artistNamed: artist.name) }
        case .playlist, .book:
            break
        case .folder:
            guard let id = pin.folderNodeID else { return }
            let folders = collectedFolderIDs
            if folders.contains(id) {
                defaults.set(HomeFolderPinStorage.encode(folders.filter { $0 != id }), forKey: HomeFolderPinStorage.key)
            }
        }
        store(storedPins.filter { $0 != pin })
    }

    func setCollected(_ collected: Bool, _ pin: QuickAccessPinReference, library: MusicLibrary) {
        if collected {
            collect(pin, library: library)
        } else {
            uncollect(pin, library: library)
        }
    }

    /// 编辑页拖完之后的整份顺序。
    func setOrder(_ pins: [QuickAccessPinReference]) {
        userEdit { store(pins) }
    }

    /// 目录页自己排过 / 删过置顶的目录之后：顺序只改首页目录那一份，删掉的从收藏顺序里也拿掉。
    func didEditCollectedFolders(_ rawValue: String) {
        userEdit {
            let collected = Set(Self.collectedFolderIDs(in: rawValue).map(QuickAccessPinReference.folder))
            store(storedPins.filter { $0.kind != .folder || collected.contains($0) })
        }
    }

    /// 用户自己的收藏操作：做完一起记进同步状态，这时的顺序也算这台设备排的。跟着喜欢自动挪、
    /// 服务端对账带回来的改动只记收没收藏，不换顺序的时刻 —— 每台设备都会自己挪一遍，
    /// 推上去反而会盖掉另一台上用户刚排好的顺序。
    private func userEdit(_ body: () -> Void) {
        guard !isUserEdit else {
            body()
            return
        }
        isUserEdit = true
        body()
        isUserEdit = false
        recordLocalChanges(orderEdited: true)
    }

    private func moveToFront(_ pins: [QuickAccessPinReference], library: MusicLibrary) {
        // 先把显示顺序写实：还没排进顺序的（别的设备收藏的）原本就排在最前，新收藏的要排到它们前面。
        store(FavoriteCollectionOrderPolicy.inserting(pins, into: references(library: library), anchor: Self.anchor))
    }

    // MARK: - Following likes

    private func activeLikedIDs() -> Set<String> {
        Set(favorites.allEntriesIncludingDeleted.lazy.filter(\.isActive).map(\.id))
    }

    private func enqueueLikeChanges(_ ids: [String], isLocal: Bool) {
        pendingLikeChanges.formUnion(ids)
        if isLocal { pendingLikeChangesIncludeLocal = true }
        likeChangeTask?.cancel()
        // iCloud 一次会送来一批，等它们到齐了按收藏时间一起排。
        likeChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.applyLikeChanges()
        }
    }

    /// 新收藏的专辑 / 艺人排到最前，取消的从顺序里拿掉——不然再收藏一次会回到原来的位置。
    private func applyLikeChanges() {
        let isLocal = pendingLikeChangesIncludeLocal
        pendingLikeChangesIncludeLocal = false
        if isLocal {
            // 在这台设备上点的喜欢：挪完的顺序算这台设备排的，推给别的设备。从 iCloud、服务端来的
            // 每台设备各自挪，不推，免得盖掉另一台上用户刚排好的顺序。
            userEdit { followLikeChanges() }
        } else {
            followLikeChanges()
        }
    }

    private func followLikeChanges() {
        let changed = pendingLikeChanges
        pendingLikeChanges = []
        var added: Set<String> = []
        var removed: Set<String> = []
        for id in changed {
            let liked = favorites.entry(id: id)?.isActive == true
            guard liked != likedSnapshot.contains(id) else { continue }
            if liked {
                likedSnapshot.insert(id)
                added.insert(id)
            } else {
                likedSnapshot.remove(id)
                removed.insert(id)
            }
        }
        guard let library, !added.isEmpty || !removed.isEmpty else { return }

        var pins = storedPins
        if !removed.isEmpty {
            pins.removeAll { pin in
                guard let key = favoriteKey(for: pin, library: library) else { return false }
                return removed.contains(key)
            }
        }
        store(pins)
        guard !added.isEmpty else { return }

        var dated: [(pin: QuickAccessPinReference, likedAt: Date)] = []
        for album in library.visibleAlbums {
            let key = favorites.favoriteID(for: album)
            guard added.contains(key) else { continue }
            dated.append((QuickAccessPinReference(kind: .album, itemID: album.id), favorites.entry(id: key)?.likedAt ?? .distantPast))
        }
        for artist in library.favoriteArtistCandidates {
            let key = favorites.favoriteID(for: artist)
            guard added.contains(key) else { continue }
            dated.append((QuickAccessPinReference(kind: .artist, itemID: artist.id), favorites.entry(id: key)?.likedAt ?? .distantPast))
        }
        guard !dated.isEmpty else { return }
        moveToFront(dated.sorted { $0.likedAt > $1.likedAt }.map(\.pin), library: library)
    }

    private func favoriteKey(for pin: QuickAccessPinReference, library: MusicLibrary) -> String? {
        switch pin.kind {
        case .album: library.visibleAlbum(id: pin.itemID).map(favorites.favoriteID(for:))
        case .artist: library.favoriteArtist(id: pin.itemID).map(favorites.favoriteID(for:))
        case .playlist, .folder, .book: nil
        }
    }

    // MARK: - Migration

    /// 改成「收藏」之前：快捷收藏有数量上限、只在本机，专辑 / 艺人的喜欢是另一份账。
    /// 迁移把原来快捷收藏里的专辑 / 艺人点上喜欢（它们从此和详情页的心是同一件事），
    /// 再把原来就喜欢的专辑、艺人和已置顶的目录接在原有顺序后面，原来排好的位置不动。
    /// 资料库还是空的（首次安装、源都没连上）时先不做，下次启动再来。
    private func migrateIfNeeded() {
        guard !defaults.bool(forKey: Self.migrationKey),
              let library,
              !library.visibleSongs.isEmpty else { return }

        let legacy = storedPins
        var migrated = 0
        for pin in legacy {
            switch pin.kind {
            case .album:
                guard let album = library.visibleAlbum(id: pin.itemID), !favorites.isLiked(album) else { continue }
                favorites.setLiked(true, album: album)
                migrated += 1
            case .artist:
                guard let artist = library.favoriteArtist(id: pin.itemID),
                      !favorites.isLiked(artistNamed: artist.name) else { continue }
                favorites.setLiked(true, artistNamed: artist.name)
                migrated += 1
            case .playlist, .folder, .book:
                continue
            }
        }
        // 上面点的喜欢稍后会以改动通知回来；先把快照对齐，那一批就不会被当成新收藏排到最前。
        likedSnapshot = activeLikedIDs()

        let membership = membership(library: library)
        var seen = Set(legacy)
        let appended = membership.collected.filter { seen.insert($0).inserted }
        store(legacy + appended)
        defaults.set(true, forKey: Self.migrationKey)
        plog("💗 favorites migrated: legacy=\(legacy.count) liked=\(migrated) appended=\(appended.count)")
    }

    // MARK: - iCloud

    // 收藏经 iCloud 键值存储（`CloudKVSSync`，跟着 iCloud 总开关与「设置」那一类走）同步：
    // - 歌单 id 经 CloudKit 在各设备上一致，服务器歌单的镜像 id 由音乐源 id 拼成，也一致；
    // - 目录 id 是「音乐源 id + 扫描目录下的相对路径」，同一个经 iCloud 同步的音乐源上各设备一致；
    // - 有声书的书 id 是各设备按标签、目录分书算出来的，曲库内容一样就一样；
    // - 专辑、艺人只同步在收藏区里的位置，收没收藏看喜欢的账本（它自己经 CloudKit 同步）。
    // 本机音乐源（App 里导入的、文件夹书签、本机媒体库）上的目录与书在别的设备上永远对不上，
    // 留在本机不同步（`deviceBoundIDs`）。在这台设备上对不上的收藏照样留在收藏顺序里，各处显示时跳过。

    private func startCloudSync() {
        guard syncState == nil else { return }
        if let saved = FavoriteCollectionSyncPolicy.decode(defaults.data(forKey: Self.syncStateKey)) {
            syncState = saved
            // 上次接上之后、这次接上之前的改动（多半是升级前改的）补记上。
            recordLocalChanges(orderEdited: false)
        } else {
            let snapshot = localSnapshot()
            // 「我喜欢」默认在收藏里；收藏改过却没有它，就是用户拿掉的。
            let likedRemoved = !storedRawValue.isEmpty && !storedPins.contains(Self.anchor)
            syncState = FavoriteCollectionSyncPolicy.initialState(
                collected: snapshot.collected,
                removed: likedRemoved ? [Self.anchor.id] : [],
                order: snapshot.order,
                folderOrder: snapshot.folderOrder,
                localOnly: deviceBoundIDs(among: snapshot.collected)
            )
            persistSyncState()
        }
        cloud.registerMerging(key: CloudKVSKey.favoriteCollection) { [weak self] in
            self?.mergeCloudCopy()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cloud.synchronizePendingChanges()
            self.isAwaitingCloudRead = false
            self.pushToCloudNow()
        }
    }

    private struct LocalSnapshot {
        /// 收藏着的歌单、有声书、目录。
        var collected: Set<String>
        /// 收藏区的整份顺序。
        var order: [String]
        /// 首页目录的顺序；从没收藏过目录（首页在自动推荐）时为 `nil`。
        var folderOrder: [String]?
    }

    private func localSnapshot() -> LocalSnapshot {
        let pins = storedPins
        let folderIDs = collectedFolderIDs.map { QuickAccessPinReference.folder($0).id }
        var collected = Set(pins.lazy.filter { $0.kind == .playlist || $0.kind == .book }.map(\.id))
        collected.formUnion(folderIDs)
        return LocalSnapshot(
            collected: collected,
            order: pins.map(\.id),
            folderOrder: folderRawValue.isEmpty ? nil : folderIDs
        )
    }

    /// 把这台设备上的改动记进同步状态，稍后推上去。`orderEdited` 为真时这时的顺序算这台设备排的。
    private func recordLocalChanges(orderEdited: Bool) {
        guard let state = syncState, !isApplyingCloudCopy else { return }
        let snapshot = localSnapshot()
        let next = FavoriteCollectionSyncPolicy.recording(
            state,
            collected: snapshot.collected,
            localOnly: deviceBoundIDs(among: snapshot.collected.subtracting(state.members.keys)),
            order: orderEdited ? orderForRecording(snapshot.order, previous: state.order?.ids) : nil,
            folderOrder: orderEdited ? snapshot.folderOrder : nil,
            now: Date().timeIntervalSince1970
        )
        guard next != state else { return }
        syncState = next
        persistSyncState()
        scheduleCloudPush()
    }

    /// 这台设备排的顺序。别的设备收藏了、这台的曲库里没有的专辑与艺人不在显示顺序里，照它们在上一份
    /// 顺序里的位置留着，不然这边一排序，它们在别的设备上就被挤到最前。
    private func orderForRecording(_ order: [String], previous: [String]?) -> [String] {
        guard let previous, let library else { return order }
        let present = Set(order)
        let unseen = previous.filter { id in
            guard !present.contains(id), let pin = QuickAccessPinReference(id: id) else { return false }
            switch pin.kind {
            case .album: return library.visibleAlbum(id: pin.itemID) == nil
            case .artist: return library.favoriteArtist(id: pin.itemID) == nil
            case .playlist, .book, .folder: return false
            }
        }
        return FavoriteCollectionSyncPolicy.reinserting(unseen, from: previous, into: order)
    }

    /// 只在这台设备上有意义的收藏：本机音乐源上的目录、整本都在本机音乐源上的书（别的设备没有这个源，
    /// 那边永远对不上）；音乐源已经不在这台设备上的目录也算。已经在同步里的不受影响，照常同步。
    private func deviceBoundIDs(among ids: some Sequence<String>) -> Set<String> {
        guard let sourcesProvider else { return [] }
        var folders: [(id: String, sourceID: String)] = []
        var bookIDs = Set<String>()
        for id in ids {
            guard let pin = QuickAccessPinReference(id: id) else { continue }
            switch pin.kind {
            case .folder:
                if let node = pin.folderNodeID { folders.append((id: id, sourceID: node.sourceID)) }
            case .book:
                bookIDs.insert(pin.itemID)
            case .album, .artist, .playlist:
                continue
            }
        }
        guard !folders.isEmpty || !bookIDs.isEmpty else { return [] }

        let sources = sourcesProvider()
        let localSourceIDs = MusicSourceCloudSyncPolicy.deviceLocalSourceIDs(in: sources)
        let knownSourceIDs = Set(sources.map(\.id))
        var result = Set<String>()
        for folder in folders where localSourceIDs.contains(folder.sourceID) || !knownSourceIDs.contains(folder.sourceID) {
            result.insert(folder.id)
        }
        guard !bookIDs.isEmpty, !localSourceIDs.isEmpty, let library else { return result }
        var sourcesByBook: [String: Set<String>] = [:]
        for song in library.spokenWordSongs {
            guard let bookID = library.spokenWordBookIDs[song.id], bookIDs.contains(bookID) else { continue }
            sourcesByBook[bookID, default: []].insert(song.sourceID)
        }
        for (bookID, sourceIDs) in sourcesByBook where sourceIDs.isSubset(of: localSourceIDs) {
            result.insert(QuickAccessPinReference(kind: .book, itemID: bookID).id)
        }
        return result
    }

    private func persistSyncState() {
        guard let syncState, let data = FavoriteCollectionSyncPolicy.encode(syncState) else { return }
        defaults.set(data, forKey: Self.syncStateKey)
    }

    private func scheduleCloudPush() {
        cloudPushTask?.cancel()
        cloudPushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.cloudPushDelay)
            guard !Task.isCancelled else { return }
            self?.pushToCloudNow()
        }
    }

    /// 云端那份变了（别的设备推了、刚打开同步、换了账号）：合进来落回本机，本机有云端没有的再推回去。
    /// iCloud 同步关着时不碰。
    private func mergeCloudCopy() {
        guard syncState != nil, CloudSyncChannel.isEnabled(.settings, defaults: defaults) else { return }
        recordLocalChanges(orderEdited: false)
        settle()
    }

    /// 先和云端那份合一次再推，推上去的不会盖掉别的设备这台还没见过的收藏。
    func pushToCloudNow() {
        cloudPushTask?.cancel()
        cloudPushTask = nil
        settle()
    }

    /// 合上 `CloudKVSSync` 镜像在本机的云端那份，落回本机，云端缺了什么再推上去。同步关着时
    /// `markChanged` 只在本机记修订号，打开时再按修订号补推或拉取。
    private func settle() {
        guard let state = syncState else { return }
        let remote = FavoriteCollectionSyncPolicy.decode(defaults.data(forKey: CloudKVSKey.favoriteCollection))
        let now = Date().timeIntervalSince1970
        let merged = FavoriteCollectionSyncPolicy.retained(
            remote.map { FavoriteCollectionSyncPolicy.merge(state, $0) } ?? state,
            now: now
        )
        adopt(merged)
        guard !isAwaitingCloudRead,
              let upload = FavoriteCollectionSyncPolicy.upload(merged, over: remote, now: now),
              let data = FavoriteCollectionSyncPolicy.encode(upload) else { return }
        defaults.set(data, forKey: CloudKVSKey.favoriteCollection)
        cloud.markChanged(key: CloudKVSKey.favoriteCollection)
    }

    /// 合好的状态落回本机的收藏顺序与首页目录。只写真变了的；这些写入不算这台设备的编辑。
    private func adopt(_ merged: FavoriteCollectionSyncState) {
        if merged != syncState {
            syncState = merged
            persistSyncState()
        }
        let snapshot = localSnapshot()
        let order = FavoriteCollectionSyncPolicy.liveOrder(merged, current: snapshot.order, anchor: Self.anchor.id)
        let folders = FavoriteCollectionSyncPolicy.liveFolderOrder(merged, current: snapshot.folderOrder)
        guard order != snapshot.order || folders != snapshot.folderOrder else { return }

        // 从别的设备来的收藏顺序不是旧版的快捷收藏：手上本来就没有专辑、艺人的，不必再做「改成收藏」
        // 那次迁移，否则会把带过来的专辑、艺人都点上喜欢。
        if !defaults.bool(forKey: Self.migrationKey),
           !storedPins.contains(where: { $0.kind == .album || $0.kind == .artist }) {
            defaults.set(true, forKey: Self.migrationKey)
        }
        isApplyingCloudCopy = true
        defer { isApplyingCloudCopy = false }
        if let folders, folders != snapshot.folderOrder {
            let ids = folders.compactMap { QuickAccessPinReference(id: $0)?.folderNodeID }
            defaults.set(HomeFolderPinStorage.encode(ids), forKey: HomeFolderPinStorage.key)
        }
        if order != snapshot.order {
            store(order.compactMap { QuickAccessPinReference(id: $0) })
        }
        plog("💗 favorites merged: items=\(order.count) folders=\(folders?.count ?? -1)")
    }
}

extension MusicLibrary {
    /// 收藏里的艺人。只当过专辑艺人的人（「群星」）不在全部艺术家里，再去专辑艺术家里找。
    func favoriteArtist(id: String) -> Artist? {
        visibleArtist(id: id) ?? visibleAlbumArtist(id: id)
    }

    /// 收藏能对上的全部艺人：全部艺术家，加上只在专辑艺术家里的那几位。
    var favoriteArtistCandidates: [Artist] {
        let albumArtistsOnly = visibleAlbumArtists.filter { visibleArtist(id: $0.id) == nil }
        return albumArtistsOnly.isEmpty ? visibleArtists : visibleArtists + albumArtistsOnly
    }
}
