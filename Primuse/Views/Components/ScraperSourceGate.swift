import SwiftUI
#if os(macOS)
import AppKit
#endif

extension Notification.Name {
    /// 请求跳到「刮削源」设置页。iOS 由 ContentView 切到设置 tab 并 push,
    /// macOS 由 SettingsWindowController 打开设置窗口并选中刮削分页。
    static let primuseOpenScraperSettings = Notification.Name("primuse.openScraperSettings")
}

/// 刮削源可用性判断的单一出口。UI 用 `ScraperSettingsStore` 做响应式判断,
/// 后台任务用 `hasEnabledSource` 直读持久化设置。
enum ScraperAvailability {
    /// 后台 / 非 View 上下文用。UI 请改用 store,以便开关变化时自动刷新。
    nonisolated static var hasEnabledSource: Bool {
        !ScraperSettings.load().enabledSources.isEmpty
    }

    @MainActor
    static func openScraperSettings() {
        #if os(macOS)
        SettingsWindowController.shared.show()
        #endif
        NotificationCenter.default.post(name: .primuseOpenScraperSettings, object: nil)
    }
}

extension ScraperSettingsStore {
    var hasEnabledSource: Bool { !enabledSources.isEmpty }
}

private struct ScraperSourceRequiredAlert: ViewModifier {
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content.alert("scraper_no_source_title", isPresented: $isPresented) {
            Button("scraper_no_source_open_settings") {
                ScraperAvailability.openScraperSettings()
            }
            Button("cancel", role: .cancel) {}
        } message: {
            Text("scraper_no_source_message")
        }
    }
}

extension View {
    /// 未启用任何刮削源时的统一提示 —— 说明原因并给出「前往设置」入口。
    func scraperSourceRequiredAlert(isPresented: Binding<Bool>) -> some View {
        modifier(ScraperSourceRequiredAlert(isPresented: isPresented))
    }
}
