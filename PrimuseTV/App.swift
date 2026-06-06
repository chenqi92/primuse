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
    @Environment(\.scenePhase) private var scenePhase
    @State private var didInitialBootstrap = false

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(TVColor.brand)
                .onOpenURL { store.handleDeepLink($0) }
                .task {
                    store.engine.configureAudioSession()
                    #if DEBUG
                    switch ProcessInfo.processInfo.environment["TV_AUDIO_SMOKE"] {
                    case "1": store.engine.runSmokeTest()
                    case "hdr": store.engine.runSmokeTest(viaLoader: true)   // 验证 resource loader 代理路径
                    default: break
                    }
                    #endif
                    let autoSync = UserDefaults.standard.object(forKey: "tvAutoSync") as? Bool ?? true
                    if autoSync { await store.bootstrap() } else { store.reload() }
                    didInitialBootstrap = true
                }
                // 每次回到前台都重新拉一次快照:手机推送后只要切回 tvOS app(无需彻底退出)
                // 就能看到新数据,也消除「TV 比手机早拉一步」的时序竞态。
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active, didInitialBootstrap else { return }
                    let autoSync = UserDefaults.standard.object(forKey: "tvAutoSync") as? Bool ?? true
                    guard autoSync else { return }
                    Task { await store.bootstrap() }
                }
        }
    }
}
#endif
