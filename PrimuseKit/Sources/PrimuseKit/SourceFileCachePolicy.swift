import Foundation

/// 重新读取标签、卡拉OK 分离、离线下载遇到不认 Range 的服务器时, 会让连接器
/// 把整首原文件下到它自己的缓存目录里。这些文件只用这一次, 却既不计入音频缓存
/// 上限、也不参与淘汰, 批量重读一个源就能悄悄占掉几个 GB。这里决定用完以后
/// 哪一份可以删。纯函数, 不碰文件系统: 路径由调用方统一成同一种写法再传进来。
public enum OneOffSourceDownloadPolicy {
    /// 两条都满足才删:
    /// - 落在连接器缓存目录里。音频缓存里的完整文件、本地源的原文件都不算。
    /// - 这次调用开始以后才出现。播放等别处先下好的那份照旧留着。
    public static func isDisposable(
        filePath: String,
        creationDate: Date?,
        startedAt: Date,
        connectorCacheDirectories: [String]
    ) -> Bool {
        guard let creationDate, creationDate >= startedAt else { return false }
        return connectorCacheDirectories.contains { directory in
            guard !directory.isEmpty else { return false }
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            return filePath.count > prefix.count && filePath.hasPrefix(prefix)
        }
    }
}

/// 存储管理里「音乐源文件缓存」一行统计和清除的目录: 各连接器整首下载的原文件、
/// 媒体服务器与 Subsonic 的下载、网盘与飞牛的封面。音频缓存、SMB 缓存(一直算在
/// 音频缓存里)、音乐视频缓存各有自己的一行, 不在这里。
public enum SourceFileCacheLayout {
    public enum Location: Sendable, Equatable {
        case caches
        case temporary
    }

    public struct Root: Sendable, Equatable {
        public let location: Location
        public let name: String
        /// false: `<name>/<源 ID>/…`; true: 目录名本身就是 `<name><源 ID>`。
        public let isSourcePrefix: Bool

        public init(location: Location, name: String, isSourcePrefix: Bool = false) {
            self.location = location
            self.name = name
            self.isSourcePrefix = isSourcePrefix
        }
    }

    public static let roots: [Root] = [
        Root(location: .caches, name: "primuse_cloud_cache"),
        Root(location: .caches, name: "primuse_s3_cache"),
        Root(location: .caches, name: "fnmusic_artwork"),
        Root(location: .temporary, name: "primuse_sftp_cache"),
        Root(location: .temporary, name: "primuse_ftp_cache"),
        Root(location: .temporary, name: "primuse_webdav_cache"),
        Root(location: .temporary, name: "primuse_nfs_cache"),
        Root(location: .temporary, name: "primuse_upnp_cache"),
        Root(location: .temporary, name: "primuse_media_server_cache_", isSourcePrefix: true),
        Root(location: .temporary, name: "primuse_subsonic_cache_", isSourcePrefix: true),
        Root(location: .temporary, name: "primuse_scan_", isSourcePrefix: true),
    ]

    /// 根目录(或临时目录)下一项属于哪个源; 不属于这一类缓存时返回 nil。
    /// 隐藏项(包括删源时改名待删的 `.primuse-deleting-*`)不算。
    public static func sourceID(entryName: String, root: Root) -> String? {
        guard !entryName.isEmpty, !entryName.hasPrefix(".") else { return nil }
        guard root.isSourcePrefix else { return entryName }
        guard entryName.hasPrefix(root.name) else { return nil }
        let sourceID = String(entryName.dropFirst(root.name.count))
        return sourceID.isEmpty ? nil : sourceID
    }

    /// 删源时先把缓存目录改名成这个前缀再在后台递归删除。进程中途被杀,
    /// 改了名的目录就一直留着, 而且是隐藏的, 哪里都统计不到。
    public static let stagedDeletionPrefix = ".primuse-deleting-"

    public static func isStagedDeletion(entryName: String) -> Bool {
        entryName.hasPrefix(stagedDeletionPrefix)
    }
}
