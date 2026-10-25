import SwiftUI

@main
struct PrimuseWatchApp: App {
    @State private var store = WatchPlayerStore()

    var body: some Scene {
        WindowGroup {
            // 正在播放是根页面, 一屏放下封面和播放键: 播放列表从左上角推进去, 更多选项从
            // 右上角弹出。不再横滑分页: 分页圆点压在播放键上, 表冠也要留给 iPhone 音量。
            NavigationStack {
                NowPlayingWatchView()
            }
            .environment(store)
        }
    }
}
