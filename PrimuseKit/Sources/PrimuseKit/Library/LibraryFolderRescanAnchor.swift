import Foundation

/// 文件夹页「重新扫描此文件夹」把节点交还给扫描服务的方式：挑文件夹里的一首歌当锚点，
/// 再数出从这首歌所在的文件夹往上几层是这个节点。扫描服务按这两个数在自己的索引里
/// 找到连接器认的原始目录（见 `SourceSyncSubtreePolicy`），不必反解归一化路径。
public struct LibraryFolderRescanAnchor: Hashable, Sendable {
    public let songID: String
    public let levelsAbove: Int

    public init(songID: String, levelsAbove: Int) {
        self.songID = songID
        self.levelsAbove = levelsAbove
    }

    /// 只有真实目录（扫描根和它下面的文件夹）有锚点；虚拟分组、「未分类」都没有。
    public static func make(
        for nodeID: LibraryFolderNodeID,
        in index: LibraryFolderIndex
    ) -> LibraryFolderRescanAnchor? {
        guard nodeID.kind == .folder || nodeID.kind == .scanRoot,
              index.node(withID: nodeID) != nil else { return nil }
        if let direct = index.directSongIDs(in: nodeID).first {
            return LibraryFolderRescanAnchor(songID: direct, levelsAbove: 0)
        }
        for songID in index.songIDs(in: nodeID, scope: .descendants).prefix(8) {
            guard var current = index.nodeID(containingSongID: songID) else { continue }
            var levels = 0
            while current != nodeID, levels < 256,
                  let parent = index.node(withID: current)?.parentID {
                current = parent
                levels += 1
            }
            if current == nodeID {
                return LibraryFolderRescanAnchor(songID: songID, levelsAbove: levels)
            }
        }
        return nil
    }
}
