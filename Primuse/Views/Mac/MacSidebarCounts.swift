import Foundation
import PrimuseKit

// 不按平台包起来:iOS 的测试目标也编这个文件,在那里测歌曲模型放掉前后侧栏的数。

/// Mac 侧栏「资料库」各行与音乐源行右边的数(6c 单元 4 U2a)。nil 是「此刻答不出」,不是 0:
/// 侧栏沿用上一次显示的数(`filling(from:)`),一次都没答出过时显示「—」,不当成没有内容。
struct MacSidebarCounts: Equatable, Sendable {
    /// 「歌曲」只数音乐(`musicSongs`)。
    var music: Int?
    var ambient: Int?
    var musicVideos: Int?
    var albums: Int?
    /// 「艺术家」跟着艺术家页的列法:全部艺术家或专辑艺术家(`browsableArtists`)。
    var artists: Int?
    /// `artists` 是按哪种列法(和「专辑艺术家」去不去掉只有单曲、EP 的人)数的:换了列法,上一次的数不能沿用。
    var artistListKey = ""
    var genres: Int?
    /// 音乐源行:各源的可见歌曲数(`visibleSongCount(forSourceID:)`)。只放问到且答得出的源。
    var bySource: [String: Int] = [:]

    /// 一项没答出来时用 `last` 里那一项(上一次显示的数)。
    func filling(from last: MacSidebarCounts) -> MacSidebarCounts {
        var filled = self
        filled.music = music ?? last.music
        filled.ambient = ambient ?? last.ambient
        filled.musicVideos = musicVideos ?? last.musicVideos
        filled.albums = albums ?? last.albums
        if artists == nil, last.artistListKey == artistListKey { filled.artists = last.artists }
        filled.genres = genres ?? last.genres
        for (sourceID, count) in last.bySource where filled.bySource[sourceID] == nil {
            filled.bySource[sourceID] = count
        }
        return filled
    }
}

extension MacSidebarCounts {
    /// 此刻答得出的数:曲库目录可读且计数读到了时读目录(`LibraryHubCatalogCountsModel`,与资料库入口同一份);
    /// 否则歌曲模型在内存里时数内存模型(与改之前相同);都答不了(模型放掉了、目录这会儿不可读)时是 nil。
    /// 「专辑艺术家」列法模型不在内存里时数目录(`AlbumArtistCatalogCount`,去掉只有单曲的人时答不出)。
    /// 在视图里读会登记对这些值的观察。
    @MainActor
    static func current(
        library: MusicLibrary,
        artistMode: ArtistBrowseMode,
        hidesSingleOnlyAlbumArtists: Bool,
        sourceIDs: [String]
    ) -> MacSidebarCounts {
        let catalog = LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts
        let arraysAnswer = library.isReady
        var counts = MacSidebarCounts()
        // crash-pattern: allow legacy-library-api 目录还没答时、模型在内存里才数数组,同原来侧栏的后备
        counts.music = catalog?.music ?? (arraysAnswer ? library.musicSongs.count : nil)
        // crash-pattern: allow legacy-library-api 同上
        counts.ambient = catalog?.ambient ?? (arraysAnswer ? library.ambientSongs.count : nil)
        // crash-pattern: allow legacy-library-api 同上
        counts.musicVideos = catalog?.musicVideos ?? (arraysAnswer ? library.musicVideoSongs.count : nil)
        // crash-pattern: allow legacy-library-api 同上
        counts.albums = catalog?.albums ?? (arraysAnswer ? library.visibleAlbums.count : nil)
        // crash-pattern: allow legacy-library-api 同上
        counts.genres = catalog?.genres ?? (arraysAnswer ? library.visibleGenres.count : nil)
        counts.artistListKey = artistMode == .allArtists
            ? artistMode.rawValue
            : "\(artistMode.rawValue)-\(hidesSingleOnlyAlbumArtists)"
        if artistMode == .allArtists, let catalog {
            counts.artists = catalog.artists
        } else if artistMode == .albumArtists, !hidesSingleOnlyAlbumArtists, !arraysAnswer {
            // U4b:模型不在内存里时「专辑艺术家」的人数从目录数;去掉只有单曲的人要专辑分类,目录没有,那时答不出。
            counts.artists = AlbumArtistCatalogCount.current(in: library)
        } else {
            counts.artists = arraysAnswer ? library.browsableArtists(artistMode).count : nil
        }
        for sourceID in sourceIDs {
            if let catalog {
                counts.bySource[sourceID] = catalog.visibleBySource[sourceID] ?? 0
            } else if arraysAnswer {
                counts.bySource[sourceID] = library.visibleSongCount(forSourceID: sourceID)
            }
        }
        return counts
    }
}
