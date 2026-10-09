import WidgetKit
import SwiftUI

@main
struct PrimuseWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        // 大封面版的正在播放(#143), 目前只上 iPhone / iPad。
        #if os(iOS)
        CoverPlayerWidget()
        #endif
        QuickAccessWidget()
        ListeningWidgetsBundle().body
        LyricsWidget()
        // 统计/音乐源/年度报告目前只有 macOS 主 App 往 App Group 写数据。
        #if os(macOS)
        ListeningStatsWidget()
        MusicSourcesWidget()
        YearInReviewWidget()
        #endif
        // iOS 18+ 控制中心 / 锁屏 Action Button 入口 (macOS 无此 API)
        #if os(iOS)
        LyricsLiveActivityWidget()
        if #available(iOS 18.0, *) {
            PrimusePlayPauseControl()
            PrimuseShuffleControl()
            PrimuseNextControl()
            PrimusePreviousControl()
        }
        #endif
    }
}

/// 听书、播客、电台和收听台。`WidgetBundle` 的结果构建器一层最多十个，iOS 和 macOS
/// 的主包都已经满了，这几个收在一个子包里、在主包里只占一个位置。
struct ListeningWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SpokenWordShelfWidget()
        PodcastWidget()
        RecentPodcastWidget()
        RadioWidget()
        ListeningDeskWidget()
    }
}
