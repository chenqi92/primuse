import Foundation

/// 一整个范围的结果:排好序的行号 + 分节索引 + 修订号。唯一允许与曲库同阶的内存结构
/// (每行 4 字节),由目录在主线程外用 SQL 建好,界面按需取页物化。
public struct LibraryRowList: Sendable, Equatable {
    public struct Aggregates: Sendable, Equatable {
        public let count: Int
        public let playableCount: Int
        public let totalDuration: TimeInterval

        public init(count: Int, playableCount: Int, totalDuration: TimeInterval) {
            self.count = count
            self.playableCount = playableCount
            self.totalDuration = totalDuration
        }
    }

    public let rowids: ContiguousArray<Int32>
    /// 与 `SongListSnapshot.sectionIndexEntries` 同一套规则。不分节的排序为空。
    public let sections: [SongListSectionIndexEntry]
    /// 建表时目录的修订号。
    public let revision: Int64
    public let aggregates: Aggregates?

    public init(
        rowids: ContiguousArray<Int32>,
        sections: [SongListSectionIndexEntry] = [],
        revision: Int64,
        aggregates: Aggregates? = nil
    ) {
        self.rowids = rowids
        self.sections = sections
        self.revision = revision
        self.aggregates = aggregates
    }

    public static let empty = LibraryRowList(rowids: [], revision: 0)

    public var count: Int { rowids.count }
    public var isEmpty: Bool { rowids.isEmpty }

    public subscript(position: Int) -> Int32 { rowids[position] }

    /// 第 `range` 页的行号(越界部分截掉)。
    public func page(_ range: Range<Int>) -> ArraySlice<Int32> {
        let lower = min(max(0, range.lowerBound), rowids.count)
        let upper = min(max(lower, range.upperBound), rowids.count)
        return rowids[lower..<upper]
    }

    /// 占用的字节数(全局行号预算记账用)。
    public var byteCount: Int { rowids.count * MemoryLayout<Int32>.stride }
}
