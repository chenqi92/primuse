import SwiftUI
import PrimuseKit
#if os(macOS)
import AppKit
#endif

struct OpenScraperSettingsAction: Sendable {
    private let handler: @MainActor @Sendable () -> Void

    init(_ handler: @escaping @MainActor @Sendable () -> Void) {
        self.handler = handler
    }

    @MainActor
    func callAsFunction() {
        handler()
    }
}

private struct OpenScraperSettingsActionKey: EnvironmentKey {
    static let defaultValue = OpenScraperSettingsAction {
        #if os(macOS)
        SettingsWindowController.shared.show(tab: .scrape)
        #endif
    }
}

extension EnvironmentValues {
    var openScraperSettings: OpenScraperSettingsAction {
        get { self[OpenScraperSettingsActionKey.self] }
        set { self[OpenScraperSettingsActionKey.self] = newValue }
    }
}

/// 刮削源可用性判断的单一出口。UI 用 `ScraperSettingsStore` 做响应式判断,
/// 后台任务用 `hasEnabledSource` 直读持久化设置。
enum ScraperAvailability {
    /// 后台 / 非 View 上下文用。UI 请改用 store,以便开关变化时自动刷新。
    nonisolated static var hasEnabledSource: Bool {
        !ScraperSettings.load().enabledSources.isEmpty
    }
}

extension ScraperSettingsStore {
    var hasEnabledSource: Bool { !enabledSources.isEmpty }

    func performSingleSongScrapeAction(
        from entryPoint: SingleSongScrapeEntryPoint,
        onProceed: () -> Void,
        onRequireSource: () -> Void
    ) {
        SingleSongScrapeGatePolicy.perform(
            from: entryPoint,
            enabledSourceCount: enabledSources.count,
            onProceed: onProceed,
            onRequireSource: onRequireSource
        )
    }
}

private struct ScraperSourceRequiredAlert: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(\.openScraperSettings) private var openScraperSettings

    func body(content: Content) -> some View {
        content.alert("scraper_no_source_title", isPresented: $isPresented) {
            Button("scraper_no_source_open_settings") {
                openScraperSettings()
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
