import SwiftUI

@main
struct PrimuseWatchApp: App {
    @State private var store = WatchPlayerStore()

    var body: some Scene {
        WindowGroup {
            // 左右横滑分页 ── 第一页 Now Playing, 第二页播放队列。竖向分页要先把
            // 队列滚回顶部才能翻回正在播放; 横滑在队列任意位置都能一下回去,
            // 表冠和上下滑动也都留给页内的滚动与进度调节。
            TabView {
                NowPlayingWatchView()
                if !store.isLiveStream {
                    LibraryWatchView()
                }
            }
            .tabViewStyle(.page)
            .environment(store)
        }
    }
}
