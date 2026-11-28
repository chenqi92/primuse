import SwiftUI
import PrimuseKit

/// 从一首歌的行上打开的标签编辑器:翻页队列是同源同目录的歌,按文件名排(6c 单元 4 U9b)。
/// 队列在打开时、每翻一页时取一次,不在行上每次重画时把整库过一遍(原来写在 `SongRowView` 的弹出内容里,
/// 编辑器开着时宿主每重画一次就在主线程上把可见歌整个筛一遍)。
struct TagEditorQueueSheet: View {
    @Environment(MusicLibrary.self) private var library

    /// 编辑器眼前这首(翻页翻到的那首)。
    let song: Song
    /// 行上那首:队列按它的源与目录,同原来。
    let anchor: Song
    let onNavigate: (Song) -> Void

    // crash-pattern: allow library-array-property 同一个目录里的歌;歌曲模型不在内存里时至多物化上限那么多(更多时占用模型照内存取)
    @State private var queue: [Song] = []

    var body: some View {
        TagEditorView(song: song, queue: queue, onNavigate: onNavigate)
            .task(id: [anchor.id, anchor.filePath, song.id]) {
                // 答不了(目录读失败又等不到模型):不翻页,也不把手里的那份清掉。
                guard let answer = await SongTagEditorQueue.queue(for: anchor, library: library), !Task.isCancelled else { return }
                if queue != answer { queue = answer }
            }
    }
}

/// 标签编辑器翻页队列的取法。
@MainActor
enum SongTagEditorQueue {
    /// 放掉时从目录一次至多取多少首同目录的歌;更多时占用模型照内存取(测试里改小)。
    static var catalogSongLimit = LibraryScale.maxMaterializedRows

    /// 模型在内存里:照原来在可见歌里挑(同一条规则、同一种排法)。放掉了(或这次启动没装):曲库目录里这个目录的
    /// 可见歌(主线程外一条按文件夹键的查询,`LibraryCatalog.directorySongs`),交给同一条规则筛、同样排 ——
    /// 目录给的是库内顺序,与可见歌的先后相同,文件名相同的(CUE 分轨共用一个文件)也排得一样。
    /// 目录答不了、或这个目录的歌多于物化上限:占用模型照内存挑(至多等 `SongModelArrayRead.defaultTimeout`)。
    /// nil = 答不了。
    static func queue(for song: Song, library: MusicLibrary) async -> [Song]? {
        guard let prefix = directoryPrefix(of: song) else { return [] }
        if library.isReady { return memoryQueue(for: song, prefix: prefix, library: library) }
        if let reader = library.readableCatalogReader {
            let sourceID = song.sourceID
            let directory = AlbumArtistInferencePolicy.directory(ofPath: song.filePath)
            let limit = catalogSongLimit
            do {
                let rows = try await reader.read { catalog in
                    try catalog.directorySongs(sourceID: sourceID, directory: directory, scope: .visible, limit: limit)
                }
                if let rows { return ordered(siblings(of: song, prefix: prefix, in: rows)) }
            } catch {
                plog("⚠️ Tag editor queue from the catalog failed, using the song model: \(error)")
            }
        }
        return await SongModelArrayRead.read(library) { memoryQueue(for: song, prefix: prefix, library: library) }
    }

    /// 歌所在目录加一个斜杠;没有目录(路径里没有斜杠)时 nil,同原来的「没有队列」。
    nonisolated static func directoryPrefix(of song: Song) -> String? {
        let directory = (song.filePath as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return nil }
        return directory.hasSuffix("/") ? directory : directory + "/"
    }

    private static func memoryQueue(for song: Song, prefix: String, library: MusicLibrary) -> [Song] {
        // crash-pattern: allow legacy-library-api 模型在内存里(原路径,或刚为这一下占用、装回来)时才读;每打开、翻页一次过一遍
        ordered(siblings(of: song, prefix: prefix, in: library.visibleSongs))
    }

    /// 同源、路径以这个目录开头、再往下没有斜杠的歌。A prefix test per song; parsing every path in a large
    /// library took about a second on the main thread.
    nonisolated static func siblings(of song: Song, prefix: String, in candidates: [Song]) -> [Song] {
        candidates.filter { candidate in
            guard candidate.sourceID == song.sourceID,
                  candidate.filePath.hasPrefix(prefix) else { return false }
            return !candidate.filePath.dropFirst(prefix.count).contains("/")
        }
    }

    /// 只有一首时没有队列;否则按文件名排(文件名相同的保持给进来的先后)。
    nonisolated static func ordered(_ siblings: [Song]) -> [Song] {
        guard siblings.count > 1 else { return [] }
        return siblings.sorted {
            ($0.filePath as NSString).lastPathComponent
                .localizedStandardCompare(($1.filePath as NSString).lastPathComponent)
                == .orderedAscending
        }
    }
}
