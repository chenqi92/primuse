/// 搜索页要不要去查 Apple Music 曲库。
///
/// Apple Music 是用户自己添加的音乐源:没添加就不该在搜索里出现它的结果,
/// 跟"没添加的源不显示"是同一件事。停用这个源、或关掉曲库搜索开关同样生效。
public enum AppleMusicCatalogSearchAvailabilityPolicy {
    public static func isEnabled(
        catalogSearchEnabled: Bool,
        sourceInstalled: Bool,
        disabledSourceIDs: Set<String>
    ) -> Bool {
        catalogSearchEnabled
            && sourceInstalled
            && !disabledSourceIDs.contains(AppleMusicLibraryIdentity.sourceID)
    }
}
