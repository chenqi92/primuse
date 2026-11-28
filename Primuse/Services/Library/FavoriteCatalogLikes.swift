import Foundation
import Observation
import PrimuseKit

/// 收藏里的专辑与艺人,在歌曲模型不在内存里时从曲库目录对上喜欢的账本(S5e,6c 单元 4 U8b)。同内存里那两句:
/// - 专辑 = `likedAlbums(in: visibleAlbums)`:可见专辑按喜欢的键对上,按喜欢的先后(同一个先后保持专辑墙顺序);
/// - 艺人 = `likedArtists(in: favoriteArtistCandidates)`:全部艺人里对上的,再加只当过专辑艺人的(「群星」)——
///   按账本里记的名字算出艺人 id,问目录的专辑艺人(`visibleAlbumArtist(id:)`),不是可见曲目艺人、名字对得上
///   喜欢的键才算。
/// 结果与喜欢的条数同阶。读在主线程外;账本或目录变了时重读,读的时候照旧给上一份。
@MainActor
@Observable
final class FavoriteCatalogLikes {
    private(set) var answer: Answer?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var requestedKey: Key?
    @ObservationIgnored private var generation: UInt64 = 0

    init() {}
}

extension FavoriteCatalogLikes {
    struct Key: Equatable {
        let library: ObjectIdentifier
        let favoritesRevision: Int
        let albums: UInt64
        let artists: UInt64
        let everything: UInt64
    }

    struct Answer {
        let key: Key
        let albums: [Album]
        let artists: [Artist]
        /// 每读到一份新的加一(收藏顺序的缓存按它失效)。
        let generation: UInt64
    }
}

extension FavoriteCatalogLikes {
    /// 此刻该对上的那一份的键;模型在内存里、曲库还不可用、目录读不了时 nil(那时不从目录答)。
    static func key(library: MusicLibrary, favorites: LibraryFavoritesStore) -> Key? {
        guard !library.isReady, library.isUsable, let revisions = library.catalogHost?.revisions,
              revisions.isReadable else { return nil }
        return Key(
            library: ObjectIdentifier(library), favoritesRevision: favorites.revision, albums: revisions.albums,
            artists: revisions.artists, everything: revisions.everything
        )
    }

    /// 最近读到的那一份(读它的视图在新的一份到了时重画);与此刻的账本、目录对不上时排期重读。
    /// 还一份都没读到、或此刻不该从目录答时 nil。
    func current(library: MusicLibrary, favorites: LibraryFavoritesStore) -> Answer? {
        guard let key = Self.key(library: library, favorites: favorites) else { return nil }
        let answer = self.answer
        if answer?.key != key, requestedKey != key { refresh(key, library: library, favorites: favorites) }
        // 另一个曲库对出来的不算。
        return answer?.key.library == key.library ? answer : nil
    }

    /// 与此刻的账本、目录对得上的那一份,没有就读到它为止(跟着喜欢挪收藏顺序时用:要的是包含刚收藏的那一份)。
    /// 目录答不了时 nil。
    func fresh(library: MusicLibrary, favorites: LibraryFavoritesStore) async -> Answer? {
        for _ in 0..<3 {
            guard let key = Self.key(library: library, favorites: favorites) else { return nil }
            if let answer, answer.key == key { return answer }
            if requestedKey != key { refresh(key, library: library, favorites: favorites) }
            await task?.value
            if let answer, answer.key == key { return answer }
            // 读失败(这个键不再重读):不再等。
            if requestedKey == key, task == nil { return nil }
        }
        return nil
    }

    private func refresh(_ key: Key, library: MusicLibrary, favorites: LibraryFavoritesStore) {
        requestedKey = key
        let albumOrder = Self.likedOrder(favorites, .album)
        let artistOrder = Self.likedOrder(favorites, .artist)
        let artistNames = favorites.ledger.active(.artist).map(\.artistName)
        let unknown = String(localized: "unknown_artist")
        task = Task { [weak self] in
            let read = await Self.read(
                library: library, albumOrder: albumOrder, artistOrder: artistOrder, artistNames: artistNames,
                unknown: unknown
            )
            guard let self, self.requestedKey == key else { return }
            self.task = nil
            guard let read else { return }
            self.generation &+= 1
            self.answer = Answer(key: key, albums: read.albums, artists: read.artists, generation: self.generation)
        }
    }

    /// 同 `LibraryFavoritesStore.likedAlbums(in:)` 的先后:账本里生效的,最近喜欢的在前。
    static func likedOrder(_ favorites: LibraryFavoritesStore, _ kind: LibraryFavoriteKind) -> [String: Int] {
        Dictionary(
            favorites.ledger.active(kind).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func read(
        library: MusicLibrary, albumOrder: [String: Int], artistOrder: [String: Int], artistNames: [String],
        unknown: String
    ) async -> (albums: [Album], artists: [Artist])? {
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            let albums = try await reader.likedAlbums(likedOrder: albumOrder, unknownArtistName: unknown)
            let visible = try await reader.likedArtists(likedOrder: artistOrder, unknownArtistName: unknown)
            let visibleIDs = Set(visible.map(\.id))
            var albumOnly: [Artist] = []
            if !artistOrder.isEmpty {
                albumOnly = try await reader.read { catalog in
                    var found: [Artist] = []
                    var seen = visibleIDs
                    for name in artistNames {
                        let id = LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(name))
                        guard seen.insert(id).inserted, try catalog.visibleArtist(id: id) == nil,
                              let artist = try catalog.visibleAlbumArtist(id: id) else { continue }
                        found.append(artist)
                    }
                    return found
                }
            }
            return (albums, mergedArtists(visible: visible, albumOnly: albumOnly, order: artistOrder, unknown: unknown))
        } catch {
            plog("💗 favorites from the catalog failed: \(error)")
            return nil
        }
    }

    /// 同 `likedArtists(in: favoriteArtistCandidates)`:候选是全部艺人、再接只当过专辑艺人的,对上喜欢的键的
    /// 按喜欢的先后排(同一个先后保持候选的先后)。
    nonisolated static func mergedArtists(
        visible: [Artist], albumOnly: [Artist], order: [String: Int], unknown: String
    ) -> [Artist] {
        let candidates = visible + albumOnly
        return candidates.enumerated()
            .compactMap { index, artist -> (artist: Artist, offset: Int, index: Int)? in
                let key = LibraryFavoriteKey.id(kind: .artist, albumTitle: "", artistName: artist.name, unknownArtistName: unknown)
                return order[key].map { (artist, $0, index) }
            }
            .sorted { $0.offset != $1.offset ? $0.offset < $1.offset : $0.index < $1.index }
            .map(\.artist)
    }
}
