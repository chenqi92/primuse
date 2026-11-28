import Foundation
import PrimuseKit

#if DEBUG
/// `PRIMUSE_AUTOPLAY_SONG` 找歌(6c 单元 4,设备上看放歌要不要装模型)。歌曲模型在内存里时按整库数组找,与以前相同;
/// 不在时从曲库目录按同一条规则找(整库、库内顺序第一首标题含这一段的),不装模型。
/// `PRIMUSE_AUTOPLAY_DELAY=<秒>`:曲库可用之后再等这么久才找(看放掉之后的那一刻)。只在调试版里。
@MainActor
enum DebugAutoplayLookup {
    /// 可用之后要等多久(没设时为 nil:照以前那样马上开始找)。
    static var delayAfterUsable: Duration? {
        ProcessInfo.processInfo.environment["PRIMUSE_AUTOPLAY_DELAY"].flatMap(Double.init).map { .seconds($0) }
    }

    static func song(titleContaining needle: String, library: MusicLibrary) async -> Song? {
        // crash-pattern: allow legacy-library-api 调试自动播放;模型在内存里时与以前相同
        if library.isReady { return library.songs.first { $0.title.lowercased().contains(needle) } }
        return await firstSong(in: library) { $0.title.lowercased().contains(needle) }
    }

    /// 整张专辑按曲序(`PRIMUSE_AUTOPLAY_QUEUE=album`),同以前的排法。
    static func albumQueue(albumTitle: String, library: MusicLibrary) async -> [Song] {
        let songs: [Song]
        if library.isReady {
            // crash-pattern: allow legacy-library-api 调试自动播放;模型在内存里时与以前相同
            songs = library.songs.filter { $0.albumTitle == albumTitle }
        } else {
            songs = await allSongs(in: library) { $0.albumTitle == albumTitle }
        }
        return songs.sorted { ($0.trackNumber ?? 0, $0.title) < ($1.trackNumber ?? 0, $1.title) }
    }

    private static func firstSong(in library: MusicLibrary, where matches: @escaping @Sendable (Song) -> Bool) async -> Song? {
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return nil }
        return try? await reader.read { catalog -> Song? in
            var found: Song?
            try catalog.forEachSong(.everything) { _, song in
                guard matches(song) else { return true }
                found = song
                return false
            }
            return found
        }
    }

    private static func allSongs(in library: MusicLibrary, where matches: @escaping @Sendable (Song) -> Bool) async -> [Song] {
        guard let reader = PlaybackCatalogAccess.reader(for: library) else { return [] }
        return (try? await reader.read { catalog -> [Song] in
            var songs: [Song] = []
            try catalog.forEachSong(.everything) { _, song in
                if matches(song) { songs.append(song) }
                return true
            }
            return songs
        }) ?? []
    }
}
#endif
