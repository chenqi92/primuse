import Foundation

// 不按平台包起来:iOS 的测试目标也编这个文件,在那里测「放掉之后先占用、装回来再读」。

/// 曲库目录那条路答不了(目录没开、读失败)之后才走的整库数组兜底(6c 单元 4 U2a)。
/// 歌曲模型在内存里时直接读,与改之前相同;放掉了时先替这一下占用模型(`.legacyPage`)、等它装回来再读,
/// 读完放手。放掉之后的数组是空的,直接读会把「答不了」当成「没有歌」。
@MainActor
enum MacLibraryArrayFallback {
    static func read<T>(_ library: MusicLibrary, _ body: @MainActor () -> T) async -> T {
        if library.isReady { return body() }
        return await library.withSongModel(.legacyPage) { body() }
    }

    /// Spotlight 点开一首歌、目录拼不了队列时:这首在前,整个可见曲库跟在后面(同原来);这首不在可见曲库里时 nil。
    static func visibleQueueIDs(startingWith id: String, in library: MusicLibrary) async -> [String]? {
        await read(library) {
            guard library.visibleSong(id: id) != nil else { return nil }
            var ids = [id]
            // crash-pattern: allow legacy-library-api 目录拼不了队列时的后备,同原来交整库;放掉了先装回来
            ids.reserveCapacity(library.visibleSongs.count)
            // crash-pattern: allow legacy-library-api 同上
            for song in library.visibleSongs where song.id != id { ids.append(song.id) }
            return ids
        }
    }
}
