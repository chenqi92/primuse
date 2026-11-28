import Foundation
import PrimuseKit

/// 歌曲页目录版式在歌曲模型不在内存里时修剪多选(6c 单元 4 U9a)。模型在内存里时按这一页的歌(`songs`)或列表快照修剪;
/// 放掉了就问曲库目录:选中的 id 里此刻还在这一页范围内的(同 `Scope.songs(in:sources:)` 的口径:整库是音乐,
/// 按源看是这个源的那几类)留下,删掉的、所在源停用的、改判成有声的去掉 —— 与模型在内存里时修剪的结果相同。
/// 答不了(目录读失败)时不修剪:批量操作执行时还会按 id 逐首解析,解析不到的跳过,不会作用到别的歌上。
@MainActor
enum SongSelectionCatalogPrune {
    /// 主线程外查;查的这段时间里新选上的歌不受影响(只去掉查过而不在范围里的)。
    /// 代价:选中多少首就查多少个 id(按 `song.id` 唯一索引,每段 900 个一条查询),在主线程外。
    static func prune(_ selection: SongSelectionModel, scope: LibrarySongScope, reader: LibraryCatalogReader) {
        let asked = selection.selectedIDs
        guard !asked.isEmpty else { return }
        Task { @MainActor in
            guard let present = try? await reader.read({ try $0.songIDs(asked, inScope: scope) }) else { return }
            let gone = asked.subtracting(present)
            guard selection.isActive, !gone.isEmpty else { return }
            selection.prune(to: selection.selectedIDs.subtracting(gone))
        }
    }
}

extension SongListFolderCatalogScope {
    /// 同一口径的目录查询范围(已启用的源)。
    var songScope: LibrarySongScope { LibrarySongScope(kinds: kinds, sourceID: sourceID) }
}
