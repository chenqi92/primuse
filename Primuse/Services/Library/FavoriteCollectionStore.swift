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
@MainActor
final class FavoriteCollectionStore {
    static let shared = FavoriteCollectionStore()

    /// 改成「收藏」那一版的一次性迁移（见 `migrateIfNeeded`）。
    static let migrationKey = "primuse.library.favoriteCollection.migrated.v1"

    /// 收藏的有声书变了（收藏、取消、在编辑页删掉）。服务端对账自己带进来的改动不发。
    static let collectedBooksDidChange = Notification.Name("primuse.favoriteCollection.collectedBooksDidChange")

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
    private var likeChangeTask: Task<Void, Never>?
    // deinit 不在主 actor 上，只在那里读一次。
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard, favorites: LibraryFavoritesStore = .shared) {
        self.defaults = defaults
        self.favorites = favorites
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// 资料库发布之后调一次：开始跟着专辑 / 艺人的收藏调整顺序，并做一次性迁移。
    func start(library: MusicLibrary) {
        self.library = library
        if observer == nil {
            likedSnapshot = activeLikedIDs()
            observer = NotificationCenter.default.addObserver(
                forName: .primuseLibraryFavoritesDidChange,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let ids = note.userInfo?["ids"] as? [String] ?? []
                Task { @MainActor [weak self] in self?.enqueueLikeChanges(ids) }
            }
        }
        migrateIfNeeded()
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
            NotificationCenter.default.post(name: Self.collectedBooksDidChange, object: nil)
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
        store(pins)
    }

    /// 目录页自己排过 / 删过置顶的目录之后：顺序只改首页目录那一份，删掉的从收藏顺序里也拿掉。
    func didEditCollectedFolders(_ rawValue: String) {
        let collected = Set(Self.collectedFolderIDs(in: rawValue).map(QuickAccessPinReference.folder))
        store(storedPins.filter { $0.kind != .folder || collected.contains($0) })
    }

    private func moveToFront(_ pins: [QuickAccessPinReference], library: MusicLibrary) {
        // 先把显示顺序写实：还没排进顺序的（别的设备收藏的）原本就排在最前，新收藏的要排到它们前面。
        store(FavoriteCollectionOrderPolicy.inserting(pins, into: references(library: library), anchor: Self.anchor))
    }

    // MARK: - Following likes

    private func activeLikedIDs() -> Set<String> {
        Set(favorites.allEntriesIncludingDeleted.lazy.filter(\.isActive).map(\.id))
    }

    private func enqueueLikeChanges(_ ids: [String]) {
        pendingLikeChanges.formUnion(ids)
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
