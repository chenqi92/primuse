import Foundation

/// Accepts a server-catalog title as the completed title inspection only when
/// it contains a real value. Placeholder titles must retain the bounded file
/// header fallback so incomplete server metadata can still be repaired.
public enum ServerCatalogMetadataInspectionPolicy {
    public static func hasUsableTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        guard !MediaMetadataTextRepair.isSuspicious(title) else { return false }
        guard !TextEncodingRepair.requiresRawByteVerification(title) else { return false }
        return !isPlaceholderTitle(title)
    }

    /// 空着,或只写着「Unknown」「未知」之类的占位词:标签等于没写歌名。和 `hasUsableTitle` 不同,
    /// 这里不管编码像不像读错了。
    public static func isPlaceholderTitle(_ title: String?) -> Bool {
        let normalized = (title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        return [
            "unknown",
            "[unknown]",
            "unknown title",
            "[unknown title]",
            "unknown track",
            "[unknown track]",
            "untitled",
            "[untitled]",
            "未知",
            "[未知]",
            "未知标题",
            "[未知标题]",
            "未知標題",
            "[未知標題]",
            "未知歌曲",
            "[未知歌曲]",
            "无标题",
            "無標題"
        ].contains(normalized)
    }
}
