import Foundation

/// Gives an opaque provider item ID a media extension for decoder sniffing.
/// The returned path is only a type hint; connectors continue to fetch bytes
/// with the original provider path.
public enum MediaDecodingPathPolicy {
    public static func make(path: String, preferredExtension: String?) -> String {
        if let remotePath = remoteURLPath(path) {
            // 播客单集、DLNA/UPnP 条目的 filePath 是完整的 http(s) 地址。查询串
            // (`default.mp3?aid=…`)会被算进扩展名,解码器只好按内容去猜,
            // MP3 因此落到被拒用的 MPEG 解码器上。只留主机和路径;路径的扩展名
            // 不是音频格式(`/redirect`、`/play.php`)就补上条目自己的格式。
            let pathExtension = (remotePath as NSString).pathExtension
            guard AudioFormat.from(fileExtension: pathExtension) == nil,
                  let normalized = normalizedExtension(preferredExtension) else { return remotePath }
            return "\(remotePath).\(normalized)"
        }
        guard (path as NSString).pathExtension.isEmpty,
              let normalized = normalizedExtension(preferredExtension) else { return path }
        return "\(path).\(normalized)"
    }

    private static func normalizedExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
        else { return nil }
        return normalized
    }

    /// `https://host/a/b.mp3?x=1#t` → `/host/a/b.mp3`。不经 URLComponents:
    /// feed 里的地址常有没转义的空格和中文,那样解析会失败。
    private static func remoteURLPath(_ path: String) -> String? {
        guard let separator = path.range(of: "://") else { return nil }
        let scheme = path[..<separator.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        let rest = path[separator.upperBound...]
        let end = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let hostAndPath = rest[..<end]
        guard !hostAndPath.isEmpty else { return nil }
        return "/" + hostAndPath
    }
}
