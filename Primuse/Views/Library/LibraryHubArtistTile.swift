import Foundation
import PrimuseKit

/// 资料库入口「艺术家」那一格在「专辑艺术家」列法、歌曲模型不在内存里时从曲库目录数人、挑头像(U3c)。「不列只有单曲、
/// EP 的人」打开时(C1):人数是 RC-b 的名单筛过的那份(`AlbumArtistCatalogCount.current(in:hidingSingleOnly:)`),头像从
/// 筛过的 `albumArtistBrowse(keeping:)` 里挑(`LibraryArtworkPreviewBuilder.catalogSelection(fullReleaseChoices:)`)——
/// 与模型在内存里时按 `browsableArtists(.albumArtists)` 数的、挑的相同,入口不再为它占用模型。目录里的发行类别还没
/// 算齐(刚升级、后台还在补)或目录读不了时答不出:入口照旧占用模型,等它回来。
@MainActor
enum LibraryHubArtistTile {
    /// 模型不在内存里时这一格要不要入口占用模型:「专辑艺术家」列法下目录读不了,或者不列只有单曲的人而发行类别还没算齐。
    static func needsTheSongModel(_ library: MusicLibrary, modeRawValue: String, hidingSingleOnly: Bool) -> Bool {
        guard ArtistBrowseMode.resolved(modeRawValue) != .allArtists else { return false }
        if library.readableCatalogReader == nil { return true }
        return hidingSingleOnly && library.catalogHost?.releaseCategoriesComplete != true
    }

    /// 封面预览里的头像从哪一份艺人列表挑:是不是「专辑艺术家」,以及(模型不在内存里、不列只有单曲的人、发行类别已
    /// 算齐时)按哪一份手动分类筛 —— 手动分类在主线程上取,交给主线程外的挑选。发行类别没算齐时 nil,调用方不挑。
    static func faces(
        _ library: MusicLibrary, modeRawValue: String, hidingSingleOnly: Bool
    ) -> (albumArtists: Bool, fullReleaseChoices: FullReleaseAlbumArtistMemo.Choices?) {
        let albumArtists = ArtistBrowseMode.resolved(modeRawValue) == .albumArtists
        guard !library.isReady, albumArtists, hidingSingleOnly,
              library.catalogHost?.releaseCategoriesComplete == true else { return (albumArtists, nil) }
        return (albumArtists, FullReleaseAlbumArtistMemo.Choices(.shared))
    }
}
