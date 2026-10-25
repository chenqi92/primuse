#if os(iOS)
import SwiftUI
import UIKit

/// 播放页的横竖屏。
///
/// - 播放页顶上那颗切换键手动转：不用等手机转过去，手机放着不动也换得了方向。手动转过去以后先按住这个方向，
///   手机也转到这个方向了再交还给手机（「跟随手机方向转屏」开着时）；收起播放页一律交还。
/// - 「跟随手机方向转屏」关掉时，播放页开着就停在当时的方向，只按那颗键转。
/// - 转屏本身是系统的整页旋转：在应用之外转整个窗口，`UIView.setAnimationsEnabled` 关不掉；实测把窗口底色
///   换掉，转的途中四周露出来的仍是黑的，那块黑不在应用的窗口里。
///
/// 只在手机上起作用：平板与展开的折叠屏内屏不接受方向请求，也没有手机那副横屏播放页。
@MainActor
enum PlayerOrientationControl {
    /// 播放页开着时只许这些方向；nil 时不管，按 Info.plist 里的方向走。
    private static var lockedMask: UIInterfaceOrientationMask?
    /// 手动转过去的这一次：手机也转到同一个方向时交还给手机。
    private static var releasesWhenDeviceAgrees = false
    private static var deviceObserver: NSObjectProtocol?

    /// App 代理回给系统的方向：播放页按住方向时主窗口只有那一组，其它时候（以及 CarPlay、外接屏的窗口）
    /// 和 Info.plist 一致。
    static func supportedMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        guard let lockedMask, window?.windowScene?.session.role == .windowApplication else { return defaultMask }
        return lockedMask
    }

    private static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    /// 这块画布上播放页能不能手动转：手机，并且不是宽高都常规的画布（展开的折叠屏内屏）。
    static func isAvailable(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .phone && !(horizontal == .regular && vertical == .regular)
    }

    /// 播放页醒来：不跟随手机方向时停在当前方向。
    static func playerBecameActive(followsDevice: Bool, isLandscape: Bool) {
        guard !followsDevice else { return }
        lock(isLandscape ? .landscape : .portrait, releasesWhenDeviceAgrees: false)
    }

    /// 设置在播放页开着时被改了（多半是从别的设备同步过来的）。
    static func followsDeviceChanged(_ followsDevice: Bool, isLandscape: Bool) {
        if followsDevice {
            release()
        } else {
            lock(isLandscape ? .landscape : .portrait, releasesWhenDeviceAgrees: false)
        }
    }

    /// 播放页收起、切到后台、进了平板那样的画布：交还给手机，系统会按手机此刻的方向转回来。
    static func playerBecameInactive() {
        guard lockedMask != nil else { return }
        release()
    }

    /// 播放页上的切换键：竖屏转横屏、横屏转竖屏。
    static func toggle(fromLandscape isLandscape: Bool, followsDevice: Bool) {
        guard let scene = foregroundWindowScene else { return }
        let toLandscape = !isLandscape
        lock(toLandscape ? .landscape : .portrait, releasesWhenDeviceAgrees: followsDevice)
        let target: UIInterfaceOrientationMask = toLandscape ? preferredLandscape : .portrait
        // 系统拒绝请求时在后台队列回调：闭包不能沿用外面的主线程隔离，否则运行时的隔离检查当场崩溃。
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: target)) { @Sendable error in
            plog("⚠️ Player orientation request failed: \(error.localizedDescription)")
        }
    }

    /// 横过来往哪边：手机已经侧着拿就顺着它，竖着拿时按大多数视频 App 的习惯（顶端朝左）。
    private static var preferredLandscape: UIInterfaceOrientationMask {
        switch UIDevice.current.orientation {
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: .landscapeRight
        }
    }

    private static func lock(_ mask: UIInterfaceOrientationMask, releasesWhenDeviceAgrees releases: Bool) {
        lockedMask = mask
        releasesWhenDeviceAgrees = releases
        if releases {
            observeDevice()
        } else {
            stopObservingDevice()
        }
        refreshSupportedOrientations()
    }

    private static func release() {
        lockedMask = nil
        releasesWhenDeviceAgrees = false
        stopObservingDevice()
        refreshSupportedOrientations()
    }

    private static func observeDevice() {
        guard deviceObserver == nil else { return }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        deviceObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { deviceOrientationChanged() }
        }
    }

    private static func stopObservingDevice() {
        guard let deviceObserver else { return }
        NotificationCenter.default.removeObserver(deviceObserver)
        self.deviceObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// 手机转到了手动选的那个方向：从这儿起又跟着手机走（界面已经在这个方向上，不会再转一次）。
    private static func deviceOrientationChanged() {
        guard releasesWhenDeviceAgrees, let lockedMask else { return }
        let agrees: Bool = switch UIDevice.current.orientation {
        case .portrait: lockedMask.contains(.portrait)
        case .landscapeLeft, .landscapeRight: lockedMask.contains(.landscapeLeft) || lockedMask.contains(.landscapeRight)
        default: false
        }
        if agrees { release() }
    }

    private static func refreshSupportedOrientations() {
        guard let scene = foregroundWindowScene else { return }
        for window in scene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }

    private static var foregroundWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive && $0.session.role == .windowApplication }
        // CarPlay 与外接屏的场景可能同时在前台，只有主应用场景接受手机的方向请求。
        return scenes.first { $0.keyWindow != nil } ?? scenes.first
    }
}

/// 挂在播放页里的零尺寸视图：播放页醒来、收起时按住或交还方向（见 `PlayerOrientationControl`）。
struct PlayerOrientationHost: View {
    let isActive: Bool
    let followsDevice: Bool
    let isLandscape: Bool

    var body: some View {
        Color.clear
            // `initial: true` 第一次回调时新旧值相同：一出现就醒着的那一次也要按住方向。
            .onChange(of: isActive, initial: true) { wasActive, active in
                if active {
                    PlayerOrientationControl.playerBecameActive(followsDevice: followsDevice, isLandscape: isLandscape)
                } else if wasActive {
                    PlayerOrientationControl.playerBecameInactive()
                }
            }
            .onChange(of: followsDevice) { _, follows in
                guard isActive else { return }
                PlayerOrientationControl.followsDeviceChanged(follows, isLandscape: isLandscape)
            }
            .onDisappear {
                if isActive { PlayerOrientationControl.playerBecameInactive() }
            }
    }
}
#endif
