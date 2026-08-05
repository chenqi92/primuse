import SwiftUI

@main
struct PrimuseWatchApp: App {
    @State private var store = WatchPlayerStore()

    var body: some Scene {
        WindowGroup {
            // watchOS 风格的横滑分页 ── 第一页 Now Playing, 第二页最近播放。
            // 用 .verticalPage 比 NavigationStack 更适合小屏交互。
            TabView {
                NowPlayingWatchView()
                if !store.isLiveStream {
                    LibraryWatchView()
                }
            }
            .tabViewStyle(.verticalPage)
            .environment(store)
        }
    }
}
