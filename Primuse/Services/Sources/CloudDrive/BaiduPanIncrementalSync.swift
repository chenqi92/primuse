import Foundation
import PrimuseKit

/// 百度网盘的增量同步。
///
/// xpan 没有 changes feed，所以这里用「快照差分」代替：`SourceSyncState.index`
/// 就是上一次提交的快照，`changes()` 重新走一遍 `list` 目录树并与它逐项比对，
/// 只把有差异的目录交回给 `ConnectorScanner.reconcileChangedDirectories`。
///
/// 差分只调用 `list`（不取 dlink、不下载文件、不读音频标签），未变更的文件不会
/// 再次进入元数据解析。
///
/// 稳定标识来自 `fs_id`（`RemoteFileItem.providerID` == `"baidu:<fs_id>"`），
/// 移动和改名后不变，因此移动文件不再表现为「旧路径删除 + 新路径新增」。
///
/// 已知限制：只有 sidecar 自身变化（封面、歌词、cue 被替换而音频文件的 md5 没
/// 变）时差分不会命中，因为 sidecar 不进 `index`，没有可比对的上一版指纹。
/// 这类变更需要一次深度扫描。
extension BaiduPanSource: IncrementalMusicSourceConnector {

    /// 快照差分没有服务端游标，这里写入一个格式标记。标记必须非空：
    /// `ScanService` 用 `cursors.isEmpty` 判断该源是否具备增量能力。
    private static let snapshotCursorKey = "baiduSnapshot"
    /// 快照比对语义的版本。比对字段变化时改这里，旧游标会退回一次全量扫描。
    private static let snapshotCursorVersion = "fsid-md5-v1"

    func initialChangeCursors(for roots: [String]) async throws -> [String: String] {
        [Self.snapshotCursorKey: Self.snapshotCursorVersion]
    }

    func changes(
        since cursors: [String: String],
        roots: [String],
        index: [String: SourceSyncIndexedItem]
    ) async throws -> IncrementalSourceChanges {
        guard cursors[Self.snapshotCursorKey] == Self.snapshotCursorVersion else {
            return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
        }

        let normalizedRoots = roots.map { $0.isEmpty ? "/" : $0 }
        // 任何一个目录列举失败都会抛出：不完整的快照会把「没列到」误判成
        // 「已删除」，宁可让本次同步失败并保留已提交的游标。
        let walk = try await buildSnapshot(roots: normalizedRoots)
        let snapshot = walk.snapshot

        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []

        for (key, current) in snapshot {
            guard let previous = index[key] else {
                // 新增项由父目录对账收录；新目录还要自己列一遍才能收录子项。
                if let parent = current.parentPath { changedParents.insert(parent) }
                if current.isDirectory { changedParents.insert(current.path) }
                continue
            }
            guard Self.entryChanged(previous: previous, current: current) else { continue }
            if let parent = current.parentPath { changedParents.insert(parent) }
            if let oldParent = previous.parentPath, oldParent != current.parentPath {
                changedParents.insert(oldParent)
            }
            // 目录改名或移动后子项路径全变，按新路径重新列一遍。
            if current.isDirectory, previous.path != current.path {
                changedParents.insert(current.path)
            }
        }

        for (key, previous) in index where snapshot[key] == nil {
            deletedKeys.insert(key)
            if let parent = previous.parentPath { changedParents.insert(parent) }
        }

        // 只保留仍然可列举的目录。已删除或已改名的旧父目录再 list 会返回错误，
        // 那会让 reconcile 抛错并中断整次同步；这些目录下的条目已经通过
        // deletedKeys 或新父目录处理掉了。
        changedParents = changedParents.filter { walk.liveDirectories.contains($0) }

        return IncrementalSourceChanges(
            cursors: cursors,
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            requiresDeepScan: false
        )
    }

    // MARK: - Snapshot

    /// 广度优先列举整棵树。用显式队列而不是递归，避免深目录树爆栈。
    private func buildSnapshot(
        roots: [String]
    ) async throws -> (snapshot: [String: SourceSyncIndexedItem], liveDirectories: Set<String>) {
        var snapshot: [String: SourceSyncIndexedItem] = [:]
        var liveDirectories = Set(roots)
        var visited: Set<String> = []
        var queue = roots

        while let directory = queue.popLast() {
            try Task.checkCancellation()
            // 选中的根目录可能互相嵌套，也可能出现符号链接式的重复路径。
            guard visited.insert(directory).inserted else { continue }
            let siblings = try await listFiles(at: directory)
            let sidecarIndex = SidecarHintResolver.DirectoryIndex(siblings)
            for item in siblings {
                if item.isDirectory {
                    liveDirectories.insert(item.path)
                    queue.append(item.path)
                    snapshot[Self.stableKey(for: item)] = Self.indexedItem(for: item)
                    continue
                }
                // 与全量扫描保持同一判定：只有可扫描项会进 index。否则封面、
                // 歌词等 sidecar 文件每次差分都会被算成新增。
                guard let scannable = SidecarHintResolver.scannableItem(
                    item,
                    index: sidecarIndex
                ) else { continue }
                snapshot[Self.stableKey(for: scannable)] = Self.indexedItem(for: scannable)
            }
        }
        return (snapshot, liveDirectories)
    }

    /// `songIDs` 与 `seenEpoch` 不参与比对：它们描述本地库状态，不是远端内容。
    private static func entryChanged(
        previous: SourceSyncIndexedItem,
        current: SourceSyncIndexedItem
    ) -> Bool {
        previous.path != current.path
            || previous.parentPath != current.parentPath
            || previous.displayName != current.displayName
            || previous.isDirectory != current.isDirectory
            || previous.size != current.size
            || previous.revision != current.revision
    }

    /// 必须与 `ConnectorScanner.recordSyncItem` 的取键方式一致，否则同一文件在
    /// 快照与 index 里会落在两个不同的键上。
    private static func stableKey(for item: RemoteFileItem) -> String {
        item.providerID ?? "path:\(item.path.lowercased())"
    }

    private static func indexedItem(for item: RemoteFileItem) -> SourceSyncIndexedItem {
        let parent = item.parentPath ?? {
            let value = (item.path as NSString).deletingLastPathComponent
            return value.isEmpty || value == "." ? "/" : value
        }()
        return SourceSyncIndexedItem(
            stableKey: stableKey(for: item),
            path: item.path,
            displayName: item.name,
            parentPath: parent,
            isDirectory: item.isDirectory,
            songIDs: [],
            size: item.size,
            modifiedDate: item.modifiedDate,
            revision: item.revision
        )
    }
}
