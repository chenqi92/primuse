import Foundation

public enum SourceSyncDirectoryPruningPolicy {
    /// `deletedKeys` 里的目录,以及它们之下(按目录条目的父目录一层层往下)的所有目录路径。
    /// 只看目录条目;删掉的键里没有目录时直接是空的,不遍历索引。
    public static func confirmedDeletedDirectoryPaths<Index: SourceSyncIndexReading>(
        index: Index,
        deletedKeys: Set<String>
    ) -> Set<String> {
        var pending = deletedKeys.compactMap { key -> String? in
            guard let item = index.item(forKey: key), item.isDirectory else { return nil }
            return item.path
        }
        guard !pending.isEmpty else { return [] }
        var children: [String: [String]] = [:]
        index.forEachDirectoryItem { item in
            if let parent = item.parentPath { children[parent, default: []].append(item.path) }
        }
        var result = Set<String>()
        while let path = pending.popLast() {
            guard result.insert(path).inserted else { continue }
            pending.append(contentsOf: children[path] ?? [])
        }
        return result
    }

    /// Follow the current parent links after all authoritative listings have
    /// been applied. Entries moved to a surviving parent are retained.
    ///
    /// 先只沿目录条目算出从消失的目录往下够得着的所有目录路径,再扫一遍找父目录落在
    /// 其中的条目——与逐层展开父子表的结果相同,但不必为整份索引建一张父目录→键的表;
    /// 没有目录消失时(绝大多数对账)直接返回空。
    public static func orphanedDescendantKeys<Baseline: SourceSyncIndexReading, Current: SourceSyncIndexReading>(
        baseline: Baseline,
        current: Current
    ) -> Set<String> {
        var survivingDirectoryPaths = Set<String>()
        current.forEachDirectoryItem { survivingDirectoryPaths.insert($0.path) }
        var vanished: [String] = []
        baseline.forEachDirectoryEntry { key, item in
            guard current.item(forKey: key) == nil,
                  !survivingDirectoryPaths.contains(item.path) else { return }
            vanished.append(item.path)
        }
        guard !vanished.isEmpty else { return [] }

        // 当前的目录条目按父目录分组,从消失的目录往下走,够得着的目录路径都算孤儿目录。
        var directoryChildren: [String: [String]] = [:]
        current.forEachDirectoryItem { item in
            if let parent = item.parentPath { directoryChildren[parent, default: []].append(item.path) }
        }
        var orphanedPaths = Set<String>()
        var pending = vanished
        while let path = pending.popLast() {
            guard orphanedPaths.insert(path).inserted else { continue }
            pending.append(contentsOf: directoryChildren[path] ?? [])
        }

        var removed = Set<String>()
        for (key, item) in current {
            if let parent = item.parentPath, orphanedPaths.contains(parent) {
                removed.insert(key)
            }
        }
        return removed
    }
}

extension SourceSyncIndexReading {
    /// 目录条目的(键, 条目)。默认整份遍历挑出目录;紧凑索引另有只看行标志的实现。
    func forEachDirectoryEntry(_ body: (String, SourceSyncIndexedItem) throws -> Void) rethrows {
        if let compact = self as? SourceSyncIndex {
            try compact.forEachDirectoryEntry(body)
            return
        }
        for (key, item) in self where item.isDirectory { try body(key, item) }
    }
}
