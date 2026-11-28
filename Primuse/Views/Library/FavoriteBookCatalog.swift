import Foundation
import Observation
import PrimuseKit

/// 收藏的有声书在歌曲模型不在内存里时从曲库目录取(6c 单元 4 U8b),同 `FavoriteCollectionResolver.book(id:library:)`:
/// 这本书的可见章节(库内顺序)只拿它们自己分组、排章节。按 id 问一次记着,目录的归书或有声内容那份账(进度、听完)
/// 变了再问,问的时候照旧给上一份;一本书至多物化 `LibraryScale.maxMaterializedRows` 章,更多时答不了。
@MainActor
@Observable
final class FavoriteBookCatalog {
    /// 书 id → 这本书;`.some(nil)`:问过了,不是书架上的书(或答不了)。
    private(set) var books: [String: FavoriteBook?] = [:]
    @ObservationIgnored private var answeredKeys: [String: Key] = [:]
    @ObservationIgnored private var reading: [String: Key] = [:]

    init() {}
}

extension FavoriteBookCatalog {
    static let shared = FavoriteBookCatalog()

    struct Key: Equatable {
        let library: ObjectIdentifier
        let books: UInt64
        let store: Int
    }

    /// 这本书(读的视图在问到时重画);还在问时 nil。
    func book(id: String, library: MusicLibrary) -> FavoriteBook? {
        guard let revisions = library.catalogHost?.revisions, revisions.isReadable else {
            return answeredKeys[id]?.library == ObjectIdentifier(library) ? books[id] ?? nil : nil
        }
        let key = Key(library: ObjectIdentifier(library), books: revisions.books, store: SpokenWordStore.shared.revision)
        // 另一个曲库问来的不算(测试里一个进程有几个曲库)。
        let known = answeredKeys[id]?.library == key.library ? books[id] ?? nil : nil
        if answeredKeys[id] != key, reading[id] != key { read(id: id, key: key, library: library) }
        return known
    }

    /// 有收藏的书还在第一次问(收藏页据此先不说「还没有收藏」)。
    func isReading(_ ids: some Sequence<String>) -> Bool {
        _ = books
        return ids.contains { books[$0] == nil && reading[$0] != nil }
    }

    private func read(id: String, key: Key, library: MusicLibrary) {
        reading[id] = key
        Task { @MainActor [weak self] in
            let chapters = await Self.chapters(ofBook: id, library: library)
            guard let self, self.reading[id] == key else { return }
            self.reading[id] = nil
            self.answeredKeys[id] = key
            // 读失败不记成「不是书」:照旧给上一份,目录再变时再问。
            guard let chapters else { return }
            self.books[id] = .some(FavoriteCollectionResolver.favoriteBook(id: id, songs: chapters))
        }
    }

    /// 同 `spokenWordSongs.filter { spokenWordBookIDs[$0.id] == id }`:归到这本书的可见有声书条目,库内顺序。
    private static func chapters(ofBook id: String, library: MusicLibrary) async -> [Song]? {
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            return try await reader.read { catalog in
                let rows = try catalog.bookRowList(bookID: id)
                guard rows.count <= LibraryScale.maxMaterializedRows else { return nil }
                let members = try catalog.songs(rowids: rows.rowids).map(\.id)
                return try catalog.songs(ids: members, scope: LibrarySongScope(kinds: [.spokenWord]))
            }
        } catch {
            plog("📚 favorite book from the catalog failed: \(error)")
            return nil
        }
    }
}

extension FavoriteCollectionResolver {
    /// 歌曲模型不在内存里时,收藏的专辑、艺人还没从曲库目录对出来,或者收藏的书还在第一次问:
    /// 收藏页先显示加载,不说「还没有收藏」。
    static func isWaitingForTheCatalog(_ pins: [QuickAccessPinReference], library: MusicLibrary) -> Bool {
        guard !library.isReady, library.isUsable else { return false }
        return !FavoriteCollectionStore.shared.answersAlbumsAndArtists(library: library)
            || FavoriteBookCatalog.shared.isReading(pins.lazy.filter { $0.kind == .book }.map(\.itemID))
    }
}
