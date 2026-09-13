import Foundation

/// CarPlay 行内封面的缓存键。
///
/// CarPlay 的列表模板没有「复用单元格」这一说：每次重建都是一批全新的
/// CPListItem，先挂占位图，再异步把真封面塞回去。只要重建得勤一点，用户看到的
/// 就是占位图和真封面在来回闪。把已经取到的图按这个键缓存住，重建时同步命中，
/// 中间那一帧占位图就不存在了。
///
/// 键里必须带上封面覆盖版本号:专辑/歌单的封面可以被用户手动换掉，只按 ID 缓存
/// 会一直返回旧图 —— 那是把闪烁换成了不刷新，更糟。
public enum CarPlayArtworkCacheKey {
    public static func make(identity: String, pixelSize: Int, overrideRevision: Int) -> String {
        "\(identity)|\(pixelSize)|\(overrideRevision)"
    }
}
