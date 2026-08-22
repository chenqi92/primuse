#if os(tvOS)
import Intents
import SwiftUI
import UIKit

/// Apple TV 外观偏好。`.system` 不覆盖系统设置，浅色和深色则只覆盖本应用。
enum TVAppearancePreference: String, CaseIterable {
    static let storageKey = "tvAppearance"

    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
final class PrimuseTVAppDelegate: NSObject, UIApplicationDelegate {
    let store = TVStore()
    private lazy var playMediaHandler = TVPlayMediaIntentHandler(store: store)

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? playMediaHandler : nil
    }
}

/// tvOS app 入口。
///
/// 界面按 design/猿音/scenes/tvos.jsx 还原,由 TVStore 读取经 iCloud 同步下来的
/// 真实曲库快照(library-cache.json / sources.json)驱动。启动时按「自动同步」
/// 偏好决定联网拉取还是仅本地重载。
@main
struct PrimuseTVApp: App {
    @UIApplicationDelegateAdaptor(PrimuseTVAppDelegate.self) private var appDelegate
    @AppStorage(TVAppearancePreference.storageKey)
    private var appearanceRawValue = TVAppearancePreference.system.rawValue
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex

    private var store: TVStore { appDelegate.store }

    private var appearance: TVAppearancePreference {
        TVAppearancePreference(rawValue: appearanceRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .environment(store)
                .preferredColorScheme(appearance.colorScheme)
                .modifier(TVWindowAppearanceModifier(preference: appearance))
                .tint(TVColor.brand(hex: accentHex))
                .onOpenURL { store.handleDeepLink($0) }
                .task {
                    FullscreenPlayerEffectSync.shared.install()
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

/// SwiftUI 的外观偏好负责环境值，窗口覆盖则确保由 `UIColor` 动态提供的
/// 语义 token 与所有全屏 presentation 使用同一套 trait。
private struct TVWindowAppearanceModifier: ViewModifier {
    let preference: TVAppearancePreference
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear(perform: apply)
            .onChange(of: preference) { _, _ in apply() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { apply() }
            }
    }

    @MainActor
    private func apply() {
        let style: UIUserInterfaceStyle
        switch preference {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
#endif
