import WidgetKit
import SwiftUI

@main
struct PrimuseWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        // 大封面版的正在播放(#143)。macOS 的小组件包已经 10 个, 到了构建器上限, 先只上 iPhone / iPad。
        #if os(iOS)
        CoverPlayerWidget()
        #endif
        QuickAccessWidget()
        SpokenWordShelfWidget()
        PodcastWidget()
        RadioWidget()
        ListeningDeskWidget()
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
