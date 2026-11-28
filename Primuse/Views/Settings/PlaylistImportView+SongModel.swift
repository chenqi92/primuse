import Foundation
import PrimuseKit

extension PlaylistImportView {
    /// 曲库目录答不了时拿来对歌单的整库(可见的歌)。歌曲模型放掉了先装回来再取(UB);装不回来时抛取消:
    /// 页面不给预览,不把「答不了」显示成「一首都对不上」(放掉之后的数组是空的)。`taken` 是已经取好的那一份。
    @MainActor
    static func arrayMatchPool(
        _ taken: [Song]? = nil, library: MusicLibrary, timeout: Duration = SongModelArrayRead.defaultTimeout
    ) async throws -> [Song] {
        if let taken { return taken }
        // crash-pattern: allow legacy-library-api 目录答不了时的后备,同原来拿整库对;放掉了先装回来
        guard let songs = await SongModelArrayRead.read(library, timeout: timeout, { library.visibleSongs }) else {
            plog("📥 Playlist import: the library cannot answer now (song model not back); no preview")
            throw CancellationError()
        }
        return songs
    }
}
