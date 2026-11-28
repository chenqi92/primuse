import Foundation
import PrimuseKit

/// 资料库入口「收藏」货架上摆哪几个(6c 单元 4 U3c):收藏顺序(`FavoriteCollectionStore.references`)里此刻在资料库里的,
/// 先后不变,卡片照旧(`LibraryView.pinnedItemCard`)。
/// - 模型在内存里:与以前相同(专辑、艺人按 id 查内存,书看整份有声条目归到的书,目录看目录索引)。
/// - 不在内存里:收藏的专辑、艺人从曲库目录对喜欢(U8b);在不在按 id 问目录(卡片也这样读,结果按目录修订号记着);
///   书从目录问(`FavoriteBookCatalog`,与卡片同一份);目录看按目录建的目录索引(U6b);歌单是小状态。
///   有一项此刻答不了(喜欢还没对出来、按 id 的读答不了、书还在第一次问、目录索引还没建好)时整份答不了(nil):
///   调用方照旧摆上一份,不把答不了的当成不在。
/// 只在收藏的条数上走一遍,不读整库数组;按 id 的读每项至多一次(之后按修订号取记下的)。
@MainActor
enum LibraryHubPins {
    static func visible(
        library: MusicLibrary,
        playlists: [Playlist],
        folderIndex: LibraryFolderIndex?,
        store: FavoriteCollectionStore = .shared
    ) -> [LibraryPinReference]? {
        let references = store.references(library: library)
        if library.isReady {
            return references.filter { exists($0, library: library, playlists: playlists, folderIndex: folderIndex) == true }
        }
        guard library.isUsable, store.answersAlbumsAndArtists(library: library) else { return nil }
        var shown: [LibraryPinReference] = []
        for pin in references {
            guard let present = exists(pin, library: library, playlists: playlists, folderIndex: folderIndex) else { return nil }
            if present { shown.append(pin) }
        }
        return shown
    }

    /// 这一项此刻在不在资料库里;nil:模型不在内存里而此刻答不了。
    static func exists(
        _ pin: LibraryPinReference, library: MusicLibrary, playlists: [Playlist], folderIndex: LibraryFolderIndex?
    ) -> Bool? {
        switch pin.kind {
        case .album, .artist:
            // 模型不在内存里时按 id 的读由目录答;目录此刻答不了(落后、正在整份替换)时按 id 读到的 nil 不是「不在」。
            guard library.isReady || library.catalogHost?.songLookup() != nil else { return nil }
            return pin.kind == .album
                ? library.visibleAlbum(id: pin.itemID) != nil
                : library.favoriteArtist(id: pin.itemID) != nil
        case .playlist:
            return pin.itemID == MusicLibrary.likedSongsPlaylistID || playlists.contains { $0.id == pin.itemID }
        case .folder:
            guard let folderIndex else { return library.isReady ? false : nil }
            return pin.folderNodeID.flatMap { folderIndex.node(withID: $0) } != nil
        case .book:
            if library.isReady { return library.spokenWordBookIDs.values.contains(pin.itemID) }
            return FavoriteBookCatalog.shared.contains(id: pin.itemID, library: library)
        }
    }
}

extension FavoriteBookCatalog {
    /// 收藏的书在不在书架上(模型不在内存里时):问到了这本书为真;问过了、不是书架上的书为假;
    /// 还在第一次问、读失败为 nil(答不了)。再问的时候照旧给上一次的答案,同卡片。
    func contains(id: String, library: MusicLibrary) -> Bool? {
        if book(id: id, library: library) != nil { return true }
        if case .some(.none) = books[id] { return false }
        return nil
    }
}

/// 资料库导航栈里按值压进来的详情页怎么等曲库(U3c):专辑页、艺人页从曲库目录答(详情页单元),歌单页的歌按 id 取、
/// 计数与摘要不读整库数组(19a,Mac 的 `.playlistDetail` 同),都随「曲库可用」就画,不占用模型。
enum LibraryStackDetail: CaseIterable {
    case album, artist, playlist

    var readiness: LibraryPageReadiness { .catalog }
}
