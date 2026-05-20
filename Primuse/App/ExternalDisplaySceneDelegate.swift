#if os(iOS)
import OSLog
import PrimuseKit
import SwiftUI
import UIKit

private let externalDisplayLog = Logger(subsystem: "com.welape.yuanyin", category: "ExternalDisplay")

/// 接外接屏 / AirPlay 镜像扩展 / DisplayPort over USB-C 时,iPad 给我们额外
/// 配一个 UIScene。这里把那块屏渲染成"全屏现在播放" —— 大封面 + 大字标题 +
/// 歌词,不带控件 (`externalDisplayNonInteractive` 不接受触摸)。播控仍在主屏。
///
/// 用户场景:
/// - iPad + USB-C → HDMI → 电视: 客厅播放, 大屏看歌词
/// - iPad + Sidecar / AirPlay 接 Mac: 第二屏当桌面歌词
/// - 演出 / 会议室外接屏: 投歌词
///
/// iPad 必须开 Stage Manager + 外接屏扩展模式才会触发这个 scene; 镜像模式
/// 不会(那种情况下系统直接复制主屏画面)。
@MainActor
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        externalDisplayLog.notice("🖥 external display scene didConnect (\(windowScene.screen.bounds.size.width)x\(windowScene.screen.bounds.size.height))")

        let window = UIWindow(windowScene: windowScene)
        let services = AppServices.shared
        let rootView = ExternalDisplayNowPlayingView()
            .environment(services.playerService)
            .environment(services.themeService)
            .environment(services.musicLibrary)
            .environment(services.sourceManager)
            .environment(services.scraperService)
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        externalDisplayLog.notice("🖥 external display scene didDisconnect")
        self.window = nil
    }
}

#endif
