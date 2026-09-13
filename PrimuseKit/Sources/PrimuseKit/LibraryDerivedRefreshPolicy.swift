import Foundation

/// 由资料库内容版本 (`searchRevision`) 驱动的整库重算的节流策略。
///
/// 首页一次重算要遍历全库若干遍 (推荐、Hero 封面、最近专辑、分组聚合), 实测
/// 万首级曲库上主线程 10~16 ms、后台 0.8~2.1 s。扫描和标签回填都会连续几小时
/// 按批发布, 只有尾部去抖是挡不住的: 去抖窗口一旦短于发布间隔, 每一次发布都
/// 会在窗口末尾换来一次完整重算, 而发布间隔本身并不由用户选的档位决定。
///
/// 所以这里是去抖 + 最小重算间隔两道闸门: 连续发布只在节流窗口末尾重算一次。
/// 用户自己的改动 (歌单、设置、场景切换) 不走这条路, 仍然立即重算。
public enum LibraryDerivedRefreshPolicy {
    /// 尾部去抖: 合并一串密集到达的版本变化。
    public static let debounce: TimeInterval = 3

    /// 两次由资料库版本驱动的重算之间的最小间隔。必须小于
    /// `MetadataBackfillExecutionPolicy.publishInterval` 的最快档位, 否则回填
    /// 的发布会排队等节流而不是被它合并。
    public static let minimumInterval: TimeInterval = 15

    /// 距离上次重算过了 `elapsed` 秒时, 这一次还要再等多久。
    /// `nil` 表示本会话还没有重算过。
    public static func delay(sinceLastRefresh elapsed: TimeInterval?) -> TimeInterval {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return debounce }
        return max(debounce, minimumInterval - elapsed)
    }
}
