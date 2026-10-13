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
