#if os(tvOS)
import SwiftUI

/// tvOS app 入口。
///
/// 界面按 design/猿音/scenes/tvos.jsx 还原,由 TVStore 读取经 iCloud 同步下来的
/// 真实曲库快照(library-cache.json / sources.json)驱动。启动时按「自动同步」
/// 偏好决定联网拉取还是仅本地重载。
@main
struct PrimuseTVApp: App {
    @State private var store = TVStore()

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(TVColor.brand)
                .onOpenURL { store.handleDeepLink($0) }
                .task {
                    #if DEBUG
                    switch ProcessInfo.processInfo.environment["TV_AUDIO_SMOKE"] {
                    case "1": store.engine.runSmokeTest()
                    case "hdr": store.engine.runSmokeTest(viaLoader: true)   // 验证 resource loader 代理路径
                    default: break
                    }
                    #endif
                    let autoSync = UserDefaults.standard.object(forKey: "tvAutoSync") as? Bool ?? true
                    if autoSync { await store.bootstrap() } else { store.reload() }
                }
                // 注意:不在回到前台时自动重新拉快照。否则会用手机端的权威状态覆盖
                // Apple TV 上的本地改动(如本地启用某个源)。仅在启动时拉一次 + 设置页
                // 手动刷新;手机端发送即是「主动触发」,下次启动 TV app 会拉到。
        }
    }
}
#endif
