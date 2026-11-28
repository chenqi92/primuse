import Foundation
import PrimuseKit
import SwiftUI

/// S4(6c 单元 4 U8a):有声书架与本机播客节目在歌曲模型不在内存里时从曲库目录取。
///
/// 书架的分组(`SpokenWordBookGrouping`)看的是整类内容(书按标签、文件夹连起来),所以这里取的是与
/// `SpokenWordCollection.songs(in:)` 同一组歌 —— 可见的有声书(或本机播客)章节,库内顺序 —— 交给同一个分组,
/// 书、书的先后、章数、章节标题与模型在内存里时一模一样。只要一本书时只读它所在的连通块
/// (`spokenBookClosureSongs`,分组只看连通块,结果相同)。都在主线程外读;目录答不了时 nil(不是「没有书」)。
enum SpokenWordCatalogShelf {
    static func scope(_ collection: SpokenWordCollection) -> LibrarySongScope {
        switch collection {
        case .books: LibrarySongScope(kinds: [.spokenWord])
        case .localPodcasts: LibrarySongScope(kinds: [.podcast])
        }
    }

    static func kind(_ collection: SpokenWordCollection) -> LibraryCatalogContentKind {
        collection == .books ? .spokenWord : .podcast
    }

    /// 同 `collection.songs(in:)`:这一类的可见歌,库内顺序。
    @MainActor
    static func songs(_ collection: SpokenWordCollection, in library: MusicLibrary) async -> [Song]? {
        guard let reader = library.readableCatalogReader else { return nil }
        do {
            return try await reader.reduceSongs(scope(collection), into: [Song]()) { songs, song in
                songs.append(song)
                return true
            }
        } catch {
            plog("📚 spoken-word shelf from the catalog failed: \(error)")
            return nil
        }
    }

    /// 书架上的书,带此刻的进度,与书架页(`SpokenWordBooksModel`)分出来的相同。
    @MainActor
    static func books(
        _ collection: SpokenWordCollection = .books,
        in library: MusicLibrary,
        store: SpokenWordStore = .shared
    ) async -> [SpokenWordBook]? {
        guard let songs = await songs(collection, in: library) else { return nil }
        return await grouped(songs, store: store)
    }

    /// 一本书(或一档本机播客节目):章节、先后、书名同书架。只读它所在的连通块,不读整个书架
    /// (收藏的书、按 id 打开一本书时用)。不在(或不是这一类)时 `.some(nil)`;目录答不了时 nil。
    @MainActor
    static func book(
        id bookID: String,
        _ collection: SpokenWordCollection = .books,
        in library: MusicLibrary,
        store: SpokenWordStore = .shared
    ) async -> (book: SpokenWordBook, songs: [Song])?? {
        guard let reader = library.readableCatalogReader else { return nil }
        let kind = kind(collection)
        let closure: [Song]
        do {
            closure = try await reader.read { catalog in
                // 一本书只在一个连通块里:从它的任一章出发求连通块就够了。
                guard let first = try catalog.bookRowList(bookID: bookID).rowids.first,
                      let member = try catalog.songs(rowids: [first]).first else { return [] }
                return try catalog.spokenBookClosureSongs(containingSongIDs: [member.id], kind: kind)
            }
        } catch {
            plog("📚 spoken-word book from the catalog failed: \(error)")
            return nil
        }
        guard !closure.isEmpty else { return .some(nil) }
        let books = await grouped(closure, store: store)
        guard let book = books.first(where: { $0.id == bookID }) else { return .some(nil) }
        let byID = Dictionary(closure.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return .some((book, book.items.compactMap { byID[$0.id] }))
    }

    /// 书架的本数与章数,同 `spokenWordBookCount` / `spokenWordChapterCount`(带内嵌章节的文件按章节数算)。
    /// 资料库入口、Mac 侧栏在这次启动没装模型时用。
    @MainActor
    static func counts(in library: MusicLibrary) async -> SpokenWordShelfCounts? {
        guard let songs = await songs(.books, in: library) else { return nil }
        return await Task.detached(priority: .utility) {
            let bookIDs = SpokenWordBookGrouping.bookIDs(for: songs.map { SpokenWordBookItem(song: $0) })
            return SpokenWordShelfCounts(books: Set(bookIDs.values).count, chapters: SpokenWordChapterTally.total(songs))
        }.value
    }

    /// 同 `SpokenWordBooksModel.refresh` 的分法:按歌分组,再按存下的进度更新。
    @MainActor
    private static func grouped(_ songs: [Song], store: SpokenWordStore) async -> [SpokenWordBook] {
        let progress = SpokenWordBookProgressIndex.storedProgress(positions: store.positions, finishedAt: store.finishedAt)
        return await Task.detached(priority: .userInitiated) {
            var index = SpokenWordBookProgressIndex(items: songs.map { SpokenWordBookItem(song: $0) })
            index.update(progress)
            return index.books
        }.value
    }

    /// 曲库目录此刻的归书修订号:歌曲模型不在内存里、曲库可用、目录读得了时才有;否则 nil。
    /// 视图读它时跟着目录变(`LibraryCatalogRevisions` 是可观察的)。
    @MainActor
    static func catalogBooksRevision(in library: MusicLibrary) -> UInt64? {
        guard !library.isReady, library.isUsable, let revisions = library.catalogHost?.revisions,
              revisions.isReadable else { return nil }
        return revisions.books
    }
}

/// 书架的本数与章数。
struct SpokenWordShelfCounts: Equatable, Sendable {
    let books: Int
    let chapters: Int
}

/// 页面在的时候,曲库这一类内容或有声内容那份账(进度、听完、归档)一变,就让 `model` 在后台重分。
/// 只读分好的快照、不需要 `SpokenWordLibraryContent` 那层包装的页面(Mac 首页)直接挂这个。
///
/// 歌曲模型不在内存里时(U8a):内容没变(这一类的修订号、曲库目录都没动过)只按新进度重算,不交整份歌、
/// 不读目录;否则从曲库目录读这一类的歌重分(`SpokenWordCatalogShelf`),与模型在内存里时分出来的相同。
/// 目录也答不了时分好的书架留着,还没分好过的显示占位。
struct SpokenWordBooksRefresh: ViewModifier {
    let collection: SpokenWordCollection
    let model: SpokenWordBooksModel
    @Environment(MusicLibrary.self) private var library
    @State private var progressRevision = 0
    /// 上一次按内存里的歌曲模型分组时曲库目录的归书修订号。模型放掉后目录没再动过,内存里分好的书就是目录里的样子。
    @State private var catalogBooksAtMemoryGrouping: UInt64?

    private struct RefreshIdentity: Equatable {
        let libraryRevision: UInt64
        let progressRevision: Int
        /// 曲库装好时有声内容可能还是空的(修订号不动),也要再分一次,好让书架知道真没有书。
        let libraryIsReady: Bool
        /// 歌曲模型不在内存里时跟着曲库目录走;在内存里时是 nil,与以前相同。
        let catalogBooks: UInt64?
    }

    func body(content: Content) -> some View {
        content
            .task(id: RefreshIdentity(
                libraryRevision: collection.revision(in: library), progressRevision: progressRevision,
                libraryIsReady: library.isReady, catalogBooks: SpokenWordCatalogShelf.catalogBooksRevision(in: library)
            )) {
                await refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .primuseSpokenWordDidChange)) { _ in
                progressRevision &+= 1
            }
    }

    private func refresh() async {
        let revision = collection.revision(in: library)
        let store = SpokenWordStore.shared
        func inputs(ready: Bool, catalog: UInt64? = nil) -> SpokenWordBooksModel.Inputs {
            .init(collection: collection, libraryRevision: revision, storeRevision: store.revision,
                  libraryIsReady: ready, catalogBooksRevision: catalog)
        }
        func regroup(_ songs: [Song], _ inputs: SpokenWordBooksModel.Inputs) async {
            await model.refresh(songs: songs, positions: store.positions, finishedAt: store.finishedAt,
                                archived: store.archivedBookIDs, inputs: inputs)
        }
        if let songs = collection.songsIfLoaded(in: library) {
            let revisions = library.catalogHost?.revisions
            catalogBooksAtMemoryGrouping = revisions?.isReadable == true ? revisions?.books : nil
            await regroup(songs, inputs(ready: true))
            return
        }
        let catalogBooks = SpokenWordCatalogShelf.catalogBooksRevision(in: library)
        // 目录在模型放掉之后没动过:内容就是按内存分好的那一份(标 nil,与按内存分的输入相同)。
        let content = catalogBooks == catalogBooksAtMemoryGrouping ? nil : catalogBooks
        if let settled = model.settledInputs, settled.collection == collection,
           settled.libraryRevision == revision, settled.catalogBooksRevision == content {
            // 内容没变:分组照旧,只按新的进度重算(不交整份歌,不读目录)。
            await regroup([], inputs(ready: true, catalog: content))
            return
        }
        if catalogBooks != nil {
            // 扫描、补读这类连着改目录的时候,分好的书架不必每一下都重读:停一会儿再读。
            if model.isSettled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            if let songs = await SpokenWordCatalogShelf.songs(collection, in: library) {
                guard !Task.isCancelled else { return }
                await regroup(songs, inputs(ready: true, catalog: content))
                return
            }
        }
        // 模型不在、目录也答不了:分好的书架留着,不发一份空书架;还没分好过的照旧按未就绪分一次,显示占位。
        guard !model.isSettled else { return }
        await regroup([], inputs(ready: false))
    }
}

extension View {
    /// 这次启动还没分过书(没装过歌曲模型:有有声内容,书数却还是 0)时,书架的本数与章数从曲库目录数,
    /// 写进 `counts`;分过就写 nil,读曲库记着的那一份(`spokenWordBookCount` / `spokenWordChapterCount`)。
    func spokenWordCatalogShelfCounts(_ counts: Binding<SpokenWordShelfCounts?>) -> some View {
        modifier(SpokenWordCatalogShelfCountsModifier(counts: counts))
    }
}

private struct SpokenWordCatalogShelfCountsModifier: ViewModifier {
    @Binding var counts: SpokenWordShelfCounts?
    @Environment(MusicLibrary.self) private var library

    private struct Key: Equatable {
        let needed: Bool
        let catalogBooks: UInt64?
    }

    private var key: Key {
        let needed = !library.isReady && library.hasSpokenWordContent && library.spokenWordBookCount == 0
        return Key(needed: needed, catalogBooks: needed ? SpokenWordCatalogShelf.catalogBooksRevision(in: library) : nil)
    }

    func body(content: Content) -> some View {
        let key = key
        return content.task(id: key) {
            guard key.needed else {
                if counts != nil { counts = nil }
                return
            }
            guard key.catalogBooks != nil else { return }
            if counts != nil {
                // 目录连着在变时停一会儿再数。
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
            }
            guard let next = await SpokenWordCatalogShelf.counts(in: library), !Task.isCancelled else { return }
            if counts != next { counts = next }
        }
    }
}
