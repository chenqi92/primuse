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

    /// 扫描进行中时的最小间隔。首页上随扫描变化的只是封面、最近添加这些展示,
    /// 不需要实时跟; 扫描结束会立刻按正常档位补一次, 最终结果不会晚到。
    public static let scanningMinimumInterval: TimeInterval = 45

    public static func delay(
        sinceLastRefresh elapsed: TimeInterval?,
        libraryIsScanning: Bool
    ) -> TimeInterval {
        guard libraryIsScanning else { return delay(sinceLastRefresh: elapsed) }
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return debounce }
        return max(debounce, scanningMinimumInterval - elapsed)
    }

    /// 资料库入口上的封面预览: 第一次与用户改动后只等这么一下(合并连续的改动)。
    public static let artworkPreviewDebounce: TimeInterval = 0.28

    /// 只是资料库内容在变时, 两次重挑封面预览之间的最小间隔。预览只是入口上的
    /// 装饰, 扫描时每次入库都重挑一遍, 整排封面就跟着重新加载一遍。
    public static let artworkPreviewMinimumInterval: TimeInterval = 30

    public static func artworkPreviewDelay(sinceLastRefresh elapsed: TimeInterval?) -> TimeInterval {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return artworkPreviewDebounce }
        return max(artworkPreviewDebounce, artworkPreviewMinimumInterval - elapsed)
    }

    /// 歌单变化的合并窗口。用户自己建/改歌单要很快在首页看到, 但扫描收尾会把
    /// 服务端歌单一个一个落地 —— 一个歌单一次整页重算, 几秒里就是几十次。
    public static let playlistDebounce: TimeInterval = 1

    /// 两次由歌单变化驱动的重算之间的最小间隔。
    public static let playlistMinimumInterval: TimeInterval = 5

    public static func playlistDelay(sinceLastRefresh elapsed: TimeInterval?) -> TimeInterval {
        guard let elapsed, elapsed.isFinite, elapsed >= 0 else { return playlistDebounce }
        return max(playlistDebounce, playlistMinimumInterval - elapsed)
    }
}
