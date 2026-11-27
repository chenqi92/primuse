import Foundation

/// Apple Music 在音乐源列表里的生命周期规则。
///
/// Apple Music 以前是 `AppServices` 无条件补出来的虚拟源:永远在列表里、删不掉,
/// 用户没订阅也得看着它。改成跟其它音乐源一样由用户决定 —— 添加即授权并同步,
/// 移除即连同同步进来的歌与镜像歌单一起清掉。规则放在 PrimuseKit 里,让 iOS /
/// macOS 两套源界面和同步服务读同一份判断。
public enum AppleMusicSourcePolicy {
    public static let sourceID = AppleMusicLibraryIdentity.sourceID

    /// 只认还活着的源。软删除的墓碑仍留在 `allSources` 里等回收站过期,
    /// 但对用户来说那就是"没添加",不能据此继续同步。
    public static func isInstalled(activeSourceIDs: Set<String>) -> Bool {
        activeSourceIDs.contains(sourceID)
    }

    /// 能否继续把 Apple Music 资料库写进 Primuse 资料库。
    ///
    /// 源已被移除时必须停手:启动对账会把找不到源的歌当成孤儿删掉,一边同步
    /// 一边被删只会让用户看到歌反复闪现。
    public static func isSyncable(
        isInstalled: Bool,
        isSourceEnabled: Bool,
        isSyncPreferenceEnabled: Bool
    ) -> Bool {
        isInstalled && isSourceEnabled && isSyncPreferenceEnabled
    }

    /// 移除音乐源时要一并删掉的镜像歌单 ——「Apple Music 资料库」全集镜像,
    /// 以及每个用户歌单的镜像。它们是同步产物,源没了就不该留在资料库里
    /// 变成永远不再更新的空歌单。
    public static func mirrorPlaylistIDs(in playlistIDs: some Sequence<String>) -> Set<String> {
        Set(playlistIDs.filter(AppleMusicLibraryIdentity.isMirrorPlaylist))
    }
}
