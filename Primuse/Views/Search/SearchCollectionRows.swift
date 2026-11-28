import Foundation
import Observation
import PrimuseKit

/// 「查看全部」那一页(搜索的文件夹与歌单结果、目录页超过 300 首的文件夹)的行(6c 单元 4 U9b)。
///
/// 模型在内存里:照原来按 id 从内存取。放掉了(或这次启动没装):id 在主线程外换成曲库目录的行号
/// (不可见的 —— 停用源里的歌单成员 —— 不给行号,同内存里查不到就不画),行按页物化(`LibraryListModel`,
/// 可见区上下各约一页),不在视图里逐行同步读目录。行号与 id 一一对应,序号照旧按 id 的位置数。
@MainActor
@Observable
final class SearchCollectionRows {
    /// 模型不在内存里时按页物化的行;模型在内存里时为 nil。
    private(set) var rows: LibraryListModel<LibrarySongListQuery>?
    @ObservationIgnored private var refreshedIDs: [String]?

    init() {}
}

/// 「查看全部」那一页的行什么时候重备:id 换了、模型在不在内存里变了。
/// (同一份 id 的比较走数组同一块存储的快路,不逐个比。)
struct SearchCollectionRowsKey: Equatable {
    let ids: [String]
    let released: Bool
}

extension SearchCollectionRows {
    /// 不存在的行号:换不到行号(不可见、目录里没有)的 id 占着这个位置,物化不出歌,这一行就不画。
    nonisolated static let missingRowid: Int32 = 0

    /// 第 `position` 行(从 0 起)那首。目录那条路上这一页还没到时是 nil(先不画,已排期取那一页,到了重画)。
    func song(at position: Int, id: String, library: MusicLibrary) -> Song? {
        if let rows {
            if let song = rows.item(at: position), song.id == id { return song }
            guard library.isReady else { return nil }
        }
        // Unobserved: a metadata write elsewhere must not make
        // the page walk every ID of a huge folder again.
        return library.unobservedVisibleSong(id: id)
    }

    /// 按这一页的 id 准备行。模型在内存里时什么都不做(行照原来取);读不了目录时也不建(行照原来按 id 取)。
    func refresh(ids: [String], library: MusicLibrary) async {
        guard !library.isReady, let host = library.catalogHost, host.revisions.isReadable else {
            replace(with: nil, ids: nil)
            return
        }
        if refreshedIDs == ids, rows != nil { return }
        let rowids: ContiguousArray<Int32>
        do {
            rowids = try await host.reader.readCancellable { catalog, cancellation in
                var result = ContiguousArray<Int32>()
                result.reserveCapacity(ids.count)
                var start = 0
                while start < ids.count {
                    try cancellation.check()
                    let end = min(ids.count, start + LibraryScale.maxMaterializedRows)
                    let chunk = try catalog.rowids(forIDs: Array(ids[start..<end]), inScope: .visible)
                    result.append(contentsOf: chunk.map { $0 ?? Self.missingRowid })
                    start = end
                }
                return result
            }
        } catch {
            // 读不了目录:行照原来按 id 取(放掉时那是逐行读,但不会是空的一页)。
            if !(error is CancellationError) { plog("⚠️ See-all rows from the catalog failed: \(error)") }
            return
        }
        guard !Task.isCancelled else { return }
        let list = LibraryListModel(
            query: LibrarySongListQuery(.rows(LibraryRowList(rowids: rowids, revision: 0))),
            reader: host.reader, revisions: host.revisions, pageSize: 100, prefetchDistance: 100
        )
        await list.reload()
        guard !Task.isCancelled else { return }
        list.activate(initialReload: false)
        replace(with: list, ids: ids)
    }

    /// 页面走开时放掉。
    func stop() {
        replace(with: nil, ids: nil)
    }

    private func replace(with list: LibraryListModel<LibrarySongListQuery>?, ids: [String]?) {
        if rows !== list { rows?.deactivate() }
        rows = list
        refreshedIDs = ids
    }
}
