#if os(iOS)
import OSLog
import PrimuseKit
import SwiftUI
import UIKit

private let externalDisplayLog = Logger(subsystem: "com.welape.yuanyin", category: "ExternalDisplay")

/// 外接屏显示什么(设置 › 播放器 › 外接显示器)。键带点号,`@AppStorage` 只能监听整个
/// UserDefaults 的变更通知;挂在根视图上的修饰器和外接屏场景各听一份不划算,这里只听一次,
/// 值真变了才通知读过它的地方。
@MainActor
@Observable
final class ExternalDisplayPreferences {
    static let shared = ExternalDisplayPreferences()

    private(set) var mode: ExternalDisplayContentMode
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = ExternalDisplayContentMode(
            storedValue: defaults.string(forKey: ExternalDisplayContentMode.storageKey)
        )
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // 变更通知在写偏好的那条线程上同步送达。
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.refresh() }
            } else {
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    private func refresh() {
        let stored = ExternalDisplayContentMode(
            storedValue: defaults.string(forKey: ExternalDisplayContentMode.storageKey)
        )
        if mode != stored { mode = stored }
    }
}

struct ExternalDisplaySceneAccessoryModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // 在 body 里读,改了设置这里才会重新求值。选了镜像就不接管外接屏,系统照本机画面镜像。
            let drawsOwnContent = ExternalDisplayPreferences.shared.mode.drawsOwnContent
            content.sceneAccessory {
                ExternalNonInteractiveAccessory(isEnabled: .constant(drawsOwnContent)) {
                    ExternalDisplaySceneContent()
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ExternalDisplaySceneContent: View {
    @AppStorage(AppThemePreferences.iOSAppearanceKey) private var appearanceRawValue = ""

    var body: some View {
        let services = AppServices.shared
        Group {
            if ExternalDisplayPreferences.shared.mode == .immersive {
                ExternalDisplayImmersiveView()
            } else {
                ExternalDisplayNowPlayingView()
            }
        }
        .environment(services.playerService)
        .environment(services.themeService)
        .environment(services.musicLibrary)
        .environment(services.sourceManager)
        .environment(services.scraperService)
        .environment(services.visualizer)
        .environment(services.coverTintProvider)
        .tint(services.themeService.uiAccentColor)
        .preferredColorScheme((IOSAppearancePreference(rawValue: appearanceRawValue) ?? .system).colorScheme)
    }
}

/// 接外接屏(线缆接电视、显示器、投影)或隔空播放镜像到电视时,系统给我们额外配一个 UIScene。
/// 默认把那块屏渲染成「现在播放」—— 大封面 + 大字标题 + 歌词,不带控件
/// (`externalDisplayNonInteractive` 不接受触摸),播控仍在主屏;设置里也可以改成全屏效果,
/// 或者选镜像:不建外接屏窗口,系统照本机画面镜像。
///
/// 用户场景:
/// - iPad + USB-C → HDMI → 电视: 客厅播放, 大屏看歌词
/// - iPad + Sidecar / AirPlay 接 Mac: 第二屏当桌面歌词
/// - 演出 / 会议室外接屏: 投歌词
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private weak var windowScene: UIWindowScene?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        externalDisplayLog.notice("🖥 external display scene didConnect (\(windowScene.screen.bounds.size.width)x\(windowScene.screen.bounds.size.height))")
        self.windowScene = windowScene
        applyContentMode()
        observeContentMode()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        externalDisplayLog.notice("🖥 external display scene didDisconnect")
        self.window = nil
        self.windowScene = nil
    }

    /// 选了镜像就收掉外接屏窗口,系统照本机画面镜像;换回来再建一个。
    private func applyContentMode() {
        guard ExternalDisplayPreferences.shared.mode.drawsOwnContent else {
            if let window {
                window.isHidden = true
                self.window = nil
                externalDisplayLog.notice("🖥 external display handed back to system mirroring")
            }
            return
        }
        guard window == nil, let windowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        let appearance = IOSAppearancePreference(
            rawValue: UserDefaults.standard.string(forKey: AppThemePreferences.iOSAppearanceKey) ?? ""
        ) ?? .system
        let host = UIHostingController(rootView: ExternalDisplaySceneContent())
        host.view.backgroundColor = .clear
        window.rootViewController = host
        switch appearance {
        case .system: window.overrideUserInterfaceStyle = .unspecified
        case .light: window.overrideUserInterfaceStyle = .light
        case .dark: window.overrideUserInterfaceStyle = .dark
        }
        window.makeKeyAndVisible()
        self.window = window
    }

    private func observeContentMode() {
        withObservationTracking {
            _ = ExternalDisplayPreferences.shared.mode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.windowScene != nil else { return }
                self.applyContentMode()
                self.observeContentMode()
            }
        }
    }
}

#endif
