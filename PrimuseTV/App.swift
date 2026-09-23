#if os(tvOS)
import CloudKit
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
@Observable
final class TVAppearanceState {
    private(set) var preference: TVAppearancePreference
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = TVAppearancePreference(
            rawValue: defaults.string(forKey: TVAppearancePreference.storageKey) ?? ""
        ) ?? .system
    }

    func select(_ preference: TVAppearancePreference) {
        self.preference = preference
        defaults.set(preference.rawValue, forKey: TVAppearancePreference.storageKey)
    }
}

@MainActor
final class PrimuseTVAppDelegate: NSObject, UIApplicationDelegate {
    let store = TVStore()
    private lazy var playMediaHandler = TVPlayMediaIntentHandler(store: store)
    private var radioCatalogObserver: NSObjectProtocol?
    /// 电台目录变更的通知一次播放就会连发好几条,合并成停下来约 400ms 后刷新一次词表。
    private var radioVocabularyRefreshTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // CKSyncEngine 靠 CloudKit 的静默推送才知道该去拉取。不注册就只剩启动时
        // 那一次和设置页的手动同步 —— 与 iOS / macOS 端注册的理由完全相同。
        application.registerForRemoteNotifications()
        radioCatalogObserver = NotificationCenter.default.addObserver(
            forName: .primuseTVSiriRadioCatalogDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleRadioVocabularyRefresh()
            }
        }
        playMediaHandler.refreshRadioVocabulary()
        return true
    }

    private func scheduleRadioVocabularyRefresh() {
        radioVocabularyRefreshTask?.cancel()
        radioVocabularyRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self else { return }
            self.radioVocabularyRefreshTask = nil
            self.playMediaHandler.refreshRadioVocabulary()
        }
    }

    func sceneDidBecomeActive() {
        playMediaHandler.refreshRadioVocabulary()
        store.applicationDidBecomeActive()
    }

    func sceneDidEnterBackground() {
        Task { await store.persistForLifecycle() }
    }

    /// CloudKit 的私有库变更推送。转发是必须的:引擎不会自己截获这条通知,
    /// iOS 端同一个回调(`PrimuseAppDelegate.application(_:didReceiveRemoteNotification:
    /// fetchCompletionHandler:)`)也是自己判完 `CKDatabaseNotification` 再调
    /// `syncNow()`。非 CloudKit 的推送原样放行,报 `.noData`。
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKDatabaseNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            await store.handleCloudKitPush()
            completionHandler(.newData)
        }
    }

    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent || intent is INSearchForMediaIntent
            ? playMediaHandler
            : nil
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var themeState = TVThemeState.shared
    @State private var appearanceState = TVAppearanceState()
    @State private var musicIntelligence = MusicIntelligenceService()
    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.colorModeKey)
    private var themeColorModeRawValue = AppThemePreferences.colorMode().rawValue

    private var store: TVStore { appDelegate.store }

    private var appearance: TVAppearancePreference {
        appearanceState.preference
    }

    var body: some Scene {
        WindowGroup {
            TVRoot()
                .transportTrustAlerts()
                .environment(store)
                .environment(themeState)
                .environment(appearanceState)
                .environment(musicIntelligence)
                .preferredColorScheme(appearance.colorScheme)
                .modifier(TVWindowAppearanceModifier(preference: appearance))
                .tint(themeState.accent)
                .onOpenURL { store.handleDeepLink($0) }
                .onAppear {
                    themeState.setFixedHex(accentHex)
                    themeState.setMode(
                        AppThemeColorMode(rawValue: themeColorModeRawValue)
                            ?? AppThemePreferences.defaultColorMode
                    )
                }
                .onChange(of: accentHex) { _, value in
                    themeState.setFixedHex(value)
                }
                .onChange(of: themeColorModeRawValue) { _, value in
                    themeState.setMode(
                        AppThemeColorMode(rawValue: value)
                            ?? AppThemePreferences.defaultColorMode
                    )
                }
                .task {
                    CloudKVSSync.shared.register(key: CloudKVSKey.aiRecommendationIntents) { }
                    CloudKVSSync.shared.register(
                        key: CloudKVSKey.aiRecommendationHiddenPresets
                    ) { }
                    CloudKVSSync.shared.register(key: CloudKVSKey.aiRecommendationSelectedIntent) { }
                    _ = ArtistNameSettingsStore.shared
                    musicIntelligence.start()
                    FullscreenPlayerEffectSync.shared.install()
                    #if DEBUG
                    switch ProcessInfo.processInfo.environment["TV_AUDIO_SMOKE"] {
                    case "1": store.engine.runSmokeTest()
                    case "hdr": store.engine.runSmokeTest(viaLoader: true)   // 验证 resource loader 代理路径
                    default: break
                    }
                    #endif
                    let autoSync = UserDefaults.standard.object(forKey: "tvAutoSync") as? Bool ?? true
                    if autoSync {
                        await store.bootstrap()
                    } else {
                        store.reload()
                        // 这次启动不同步,本地电台列表就是全部了。
                        store.finishPendingRadioDeepLink()
                    }
                    store.recoverReceivedMusicIfNeeded()
                }
                // 注意:不在回到前台时自动重新拉快照。否则会用手机端的权威状态覆盖
                // Apple TV 上的本地改动(如本地启用某个源)。仅在启动时拉一次 + 设置页
                // 手动刷新;手机端发送即是「主动触发」,下次启动 TV app 会拉到。
        }
        .onChange(of: scenePhase, initial: true) { previousPhase, phase in
            switch phase {
            case .active: appDelegate.sceneDidBecomeActive()
            case .background:
                if previousPhase != .background { appDelegate.sceneDidEnterBackground() }
            default: break
            }
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
            .onAppear { apply(preference) }
            .onChange(of: preference) { _, newPreference in
                apply(newPreference)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { apply(preference) }
            }
    }

    @MainActor
    private func apply(_ preference: TVAppearancePreference) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        TVWindowAppearanceApplicator.apply(preference, to: windows)
    }
}

@MainActor
enum TVWindowAppearanceApplicator {
    static func apply(_ preference: TVAppearancePreference, to windows: [UIWindow]) {
        let style: UIUserInterfaceStyle
        switch preference {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }

        for window in windows {
            window.overrideUserInterfaceStyle = style
        }
    }
}
#endif
