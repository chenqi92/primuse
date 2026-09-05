import WidgetKit
import SwiftUI

@main
struct PrimuseWidgetBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        QuickAccessWidget()
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
