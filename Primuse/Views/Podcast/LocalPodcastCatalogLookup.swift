import Foundation
import PrimuseKit
import SwiftUI

/// 本机播客(资料库里的播客单集)按节目的几件事,歌曲模型不在内存里时从曲库目录答(6c 单元 4 U8a)。
/// 模型在内存里(或第一次装载还没完)时照旧读曲库的那几张表,与以前一字不差。
enum LocalPodcastCatalogLookup {
    /// 模型不在内存里、曲库可用:按目录答。
    @MainActor
    private static func catalog(in library: MusicLibrary) -> LibraryCatalog? {
        guard !library.isReady, library.isUsable, let host = library.catalogHost, host.revisions.isReadable else {
            return nil
        }
        // 视图读的时候跟着目录变。
        _ = host.revisions.books
        return host.mirror.readableCatalog
    }

    @MainActor
    private static func answersFromMemory(_ library: MusicLibrary) -> Bool {
        library.isReady || !library.isUsable
    }

    /// `song` 在哪档本机节目里(节目 id、节目名),同 `localPodcastShowID(forSongID:)` /
    /// `localPodcastShowTitle(forSongID:)`。模型不在内存里时按 id 问目录(一条走索引的查询);
    /// 目录读不了、或它不是本机播客单集时 nil。
    @MainActor
    static func show(of song: Song, in library: MusicLibrary?) -> (id: String, title: String?)? {
        guard let library else { return nil }
        if answersFromMemory(library) {
            guard let id = library.localPodcastShowID(forSongID: song.id) else { return nil }
            return (id, library.localPodcastShowTitle(forSongID: song.id))
        }
        // 内存里的节目表只有可见的单集:停用源里的同样不从目录认。
        guard !library.disabledPlaybackSourceIDs.contains(song.sourceID), let catalog = catalog(in: library),
              let placement = (try? catalog.podcastShowPlacements(songIDs: [song.id]))?[song.id] else { return nil }
        return (placement.showID, placement.title)
    }

    /// `bookID` 是不是一档本机播客节目,同 `localPodcastBookIDs.values.contains(bookID)`
    /// (「转到这本书」只带着 id 进来时分辨是书还是本机节目)。
    @MainActor
    static func isShow(_ bookID: String, in library: MusicLibrary) -> Bool {
        if answersFromMemory(library) { return library.localPodcastBookIDs.values.contains(bookID) }
        guard let catalog = catalog(in: library) else { return false }
        do {
            guard let first = try catalog.bookRowList(bookID: bookID).rowids.first,
                  let song = try catalog.songs(rowids: [first]).first,
                  !library.disabledPlaybackSourceIDs.contains(song.sourceID) else { return false }
            return try catalog.podcastShowPlacements(songIDs: [song.id])[song.id]?.showID == bookID
        } catch {
            plog("🎙️ local podcast show from the catalog failed: \(error)")
            return false
        }
    }

    /// 本机播客有几档节目,同 `localPodcastShowCount`。模型不在内存里时用资料库入口那份目录计数
    /// (`LibraryHubCatalogCountsModel`),还没数出来时是 0。
    @MainActor
    static func showCount(in library: MusicLibrary) -> Int {
        if answersFromMemory(library) { return library.localPodcastShowCount }
        return LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts?.podcastShows ?? 0
    }

    /// 有没有本机播客单集,同 `!localPodcastSongs.isEmpty`。
    @MainActor
    static func hasEpisodes(in library: MusicLibrary) -> Bool {
        // crash-pattern: allow legacy-library-api 模型在内存里时同原来;放掉了改问目录计数
        if answersFromMemory(library) { return !library.localPodcastSongs.isEmpty }
        return (LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts?.podcast ?? 0) > 0
    }

    /// 播客页在找节目时一集算不算命中(节目名、作者,或这一集的标题)。
    static func findMatches(_ query: LibraryFindPolicy.Query, _ song: Song) -> Bool {
        LibraryFindPolicy.matches(query, fields: [song.albumTitle, song.albumArtistName ?? song.artistName, song.title])
    }
}

/// 播客页「在本页里找」时本机节目里有没有命中的,模型不在内存里时在后台按目录找出来的那一份。
struct PodcastLocalFindAnswer: Equatable {
    let query: LibraryFindPolicy.Query
    let matches: Bool
}

extension PodcastLocalShowsSection {
    /// 在找节目时,本机节目里有没有命中的。模型不在内存里时用后台按目录找的结果(`catalogAnswer`);
    /// 这一次的还没找完时算有:本机节目那一块自己按节目名、单集名筛,筛完没有就不画,不先摆「没有结果」。
    @MainActor
    static func hasMatches(
        _ query: LibraryFindPolicy.Query, in library: MusicLibrary, catalogAnswer: PodcastLocalFindAnswer?
    ) -> Bool {
        if library.isReady || !library.isUsable {
            // crash-pattern: allow legacy-library-api 模型在内存里时同原来;放掉了改在后台按目录找
            return library.localPodcastSongs.contains { LocalPodcastCatalogLookup.findMatches(query, $0) }
        }
        if let catalogAnswer, catalogAnswer.query == query { return catalogAnswer.matches }
        return LocalPodcastCatalogLookup.hasEpisodes(in: library)
    }
}

extension View {
    /// 模型不在内存里时,在后台按曲库目录找本机播客里有没有命中 `findText` 的单集,写进 `answer`。
    func podcastLocalFind(_ findText: String, answer: Binding<PodcastLocalFindAnswer?>) -> some View {
        modifier(PodcastLocalFindModifier(findText: findText, answer: answer))
    }
}

private struct PodcastLocalFindModifier: ViewModifier {
    let findText: String
    @Binding var answer: PodcastLocalFindAnswer?
    @Environment(MusicLibrary.self) private var library

    private struct Key: Equatable {
        let query: LibraryFindPolicy.Query?
        let catalogBooks: UInt64?
    }

    func body(content: Content) -> some View {
        let key = Key(
            query: LibraryFindPolicy.query(findText),
            catalogBooks: SpokenWordCatalogShelf.catalogBooksRevision(in: library)
        )
        content.task(id: key) {
            guard let query = key.query, key.catalogBooks != nil, let reader = library.readableCatalogReader else { return }
            // 打字时停一下再找。
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let found = try await reader.reduceSongs(SpokenWordCatalogShelf.scope(.localPodcasts), into: false) {
                    hit, song in
                    guard LocalPodcastCatalogLookup.findMatches(query, song) else { return true }
                    hit = true
                    return false
                }
                guard !Task.isCancelled else { return }
                answer = PodcastLocalFindAnswer(query: query, matches: found)
            } catch {
                plog("🎙️ local podcast find from the catalog failed: \(error)")
            }
        }
    }
}
