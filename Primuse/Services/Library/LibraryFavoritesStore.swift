import Foundation
import Observation
import PrimuseKit

extension Notification.Name {
    /// 本机切换了专辑 / 艺人的喜欢。userInfo["ids"] 是改动的 `LibraryFavorite.id`；
    /// iCloud 套用远端时同样发，但带 userInfo["origin"] = "remote"，同步服务据此不回推。
    static let primuseLibraryFavoritesDidChange = Notification.Name("primuseLibraryFavoritesDidChange")
    /// 到期的取消记录清掉了，userInfo["ids"]；同步服务删掉云端那几条。
    static let primuseLibraryFavoritesDidPurge = Notification.Name("primuseLibraryFavoritesDidPurge")
}

/// 专辑 / 艺人的「喜欢」（见 `LibraryFavorite`）。三端各存一份 JSON，经 CloudKit 的
/// `LibraryFavorite` 记录逐条同步；Apple TV 也跑同一个同步服务，所以电视上点的喜欢会回到手机。
@MainActor
@Observable
final class LibraryFavoritesStore {
    static let shared = LibraryFavoritesStore()

    /// 每次本机或远端改动 +1；界面按它重算「喜欢的专辑 / 艺人」列表。
    private(set) var revision = 0
    private(set) var ledger: LibraryFavoriteLedger
    @ObservationIgnored private let fileURL: URL?
    /// 专辑 / 艺人 id → 喜欢的键。整库筛选时每张专辑都要算一次折叠 + 哈希，记住它；
    /// 两个 id 本来就由同样的名字算出来，同一个 id 的键不会变。
    @ObservationIgnored private var albumKeyCache: [String: String] = [:]
    @ObservationIgnored private var artistKeyCache: [String: String] = [:]

    init(fileURL: URL? = LibraryFavoritesStore.defaultFileURL()) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(LibraryFavoriteLedger.self, from: data) {
            ledger = decoded
        } else {
            ledger = LibraryFavoriteLedger()
        }
    }

    nonisolated static func defaultFileURL() -> URL {
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        let directory = base.appendingPathComponent("Primuse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("library-favorites.json")
    }

    // MARK: - Keys

    /// 本机语言的「未知艺术家」：没有专辑艺术家的专辑在 `Album.artistName` 里是这个词。
    private static var unknownArtistName: String { String(localized: "unknown_artist") }

    nonisolated static func albumArtistName(_ album: Album) -> String {
        album.artistName ?? ""
    }

    func favoriteID(for album: Album) -> String {
        if let cached = albumKeyCache[album.id] { return cached }
        let key = LibraryFavoriteKey.id(
            kind: .album,
            albumTitle: album.title,
            artistName: Self.albumArtistName(album),
            unknownArtistName: Self.unknownArtistName
        )
        albumKeyCache[album.id] = key
        return key
    }

    func favoriteID(for artist: Artist) -> String {
        if let cached = artistKeyCache[artist.id] { return cached }
        let key = favoriteID(forArtistNamed: artist.name)
        artistKeyCache[artist.id] = key
        return key
    }

    func favoriteID(forArtistNamed name: String) -> String {
        LibraryFavoriteKey.id(
            kind: .artist,
            albumTitle: "",
            artistName: name,
            unknownArtistName: Self.unknownArtistName
        )
    }

    // MARK: - Queries

    func isLiked(_ album: Album) -> Bool {
        _ = revision
        return ledger.isLiked(favoriteID(for: album))
    }

    func isLiked(artistNamed name: String) -> Bool {
        _ = revision
        return ledger.isLiked(favoriteID(forArtistNamed: name))
    }

    var hasLikedAlbums: Bool {
        _ = revision
        return ledger.entries.values.contains { $0.kind == .album && $0.isActive }
    }

    var hasLikedArtists: Bool {
        _ = revision
        return ledger.entries.values.contains { $0.kind == .artist && $0.isActive }
    }

    /// 资料库里能对上的喜欢的专辑，最近喜欢的在前。对不上的（歌被删了、换了名字）不显示，
    /// 记录照留，歌回来了就又出现。
    func likedAlbums(in albums: [Album]) -> [Album] {
        _ = revision
        let order = Dictionary(
            ledger.active(.album).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !order.isEmpty else { return [] }
        return albums
            .compactMap { album in order[favoriteID(for: album)].map { (album, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    func likedArtists(in artists: [Artist]) -> [Artist] {
        _ = revision
        let order = Dictionary(
            ledger.active(.artist).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !order.isEmpty else { return [] }
        return artists
            .compactMap { artist in order[favoriteID(for: artist)].map { (artist, $0) } }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    // MARK: - Local edits

    func toggle(_ album: Album) {
        setLiked(!isLiked(album), album: album)
    }

    func setLiked(_ liked: Bool, album: Album) {
        let artist = Self.albumArtistName(album)
        let artistName = artist == Self.unknownArtistName ? "" : artist
        commitLocal(ledger.set(kind: .album, albumTitle: album.title, artistName: artistName, liked: liked, at: Date()))
    }

    func toggle(artistNamed name: String) {
        setLiked(!isLiked(artistNamed: name), artistNamed: name)
    }

    func setLiked(_ liked: Bool, artistNamed name: String) {
        commitLocal(ledger.set(kind: .artist, albumTitle: "", artistName: name, liked: liked, at: Date()))
    }

    private func commitLocal(_ change: LibraryFavorite?) {
        guard let change else { return }
        didChange(ids: [change.id], origin: nil)
    }

    // MARK: - Sync

    var allEntriesIncludingDeleted: [LibraryFavorite] { Array(ledger.entries.values) }

    func entry(id: String) -> LibraryFavorite? { ledger.entries[id] }

    /// iCloud 拉回来的一条；本机更新就不动。
    func applyRemote(_ entry: LibraryFavorite) {
        guard ledger.applyRemote(entry) else { return }
        didChange(ids: [entry.id], origin: "remote")
    }

    func removeRemote(id: String) {
        guard ledger.entries[id] != nil else { return }
        ledger.removeRemote(id: id)
        didChange(ids: [id], origin: "remote")
    }

    /// 清掉早于 `threshold` 的取消记录，返回 id 给同步服务删云端那条。
    @discardableResult
    func pruneTombstones(before threshold: Date) -> [String] {
        let pruned = ledger.pruneTombstones(before: threshold)
        if !pruned.isEmpty {
            revision &+= 1
            persist()
            NotificationCenter.default.post(
                name: .primuseLibraryFavoritesDidPurge,
                object: nil,
                userInfo: ["ids": pruned]
            )
        }
        return pruned
    }

    private func didChange(ids: [String], origin: String?) {
        revision &+= 1
        persist()
        var userInfo: [String: Any] = ["ids": ids]
        if let origin { userInfo["origin"] = origin }
        NotificationCenter.default.post(name: .primuseLibraryFavoritesDidChange, object: nil, userInfo: userInfo)
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            plog("💗 library favorites not saved: \(error.localizedDescription)")
        }
    }
}
