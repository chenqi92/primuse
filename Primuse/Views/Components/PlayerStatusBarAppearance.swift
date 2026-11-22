#if os(iOS)
import SwiftUI
import UIKit

/// 「播放页始终用深色」而系统是浅色时,播放页开着的那段时间状态栏换成白字(#313 那时只能整个藏起来)。
///
/// 状态栏用黑字还是白字,由「管状态栏的那个窗口」的根控制器决定;SwiftUI 的主窗口只跟着整个窗口的深浅走,
/// 只把播放页这一层换成深色时它照样给黑字。整个窗口换成深色又会让底下的 App 跟着重算一遍。
/// 所以这时在主窗口上面盖一层透明、不接触摸、不当主窗口的小窗口,由它的根控制器要白字。
/// 藏不藏状态栏、主屏指示条仍听主窗口的(播放页里的全屏效果、MV 要藏);主窗口全屏弹出的页面(卡拉OK、文稿)
/// 连样式也交回它自己。
@MainActor
final class PlayerStatusBarOverlay {
    static let shared = PlayerStatusBarOverlay()

    private var window: PassthroughWindow?
    private let controller = StatusBarStyleController()
    /// 主窗口改了藏不藏状态栏时只通知它自己那个窗口,系统不会回头来问这一层,所以这一层盖着时隔一会儿对一下。
    private var hostWatch: Timer?

    private init() {}

    func setLightContent(_ isOn: Bool, over host: UIWindow?) {
        if isOn, let host, let scene = host.windowScene, scene.session.role == .windowApplication {
            controller.host = host
            let window: PassthroughWindow
            if let existing = self.window, existing.windowScene === scene {
                window = existing
            } else {
                self.window?.isHidden = true
                window = PassthroughWindow(windowScene: scene)
                window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
                window.backgroundColor = .clear
                window.accessibilityElementsHidden = true
                window.rootViewController = controller
                self.window = window
            }
            guard window.isHidden else { return }
            window.isHidden = false
            _ = controller.appearanceChanged()
            refresh()
            startWatchingHost()
        } else {
            // 别的窗口(平板分屏)里的播放页撤掉时,不动这一个窗口上的。
            if let host, let owner = controller.host, owner !== host { return }
            guard let window, !window.isHidden else { return }
            hostWatch?.invalidate()
            hostWatch = nil
            window.isHidden = true
            let hostRoot = controller.host?.rootViewController
            hostRoot?.setNeedsStatusBarAppearanceUpdate()
            hostRoot?.setNeedsUpdateOfHomeIndicatorAutoHidden()
            hostRoot?.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
            controller.host = nil
        }
    }

    private func refresh() {
        UIView.animate(withDuration: 0.25) {
            self.controller.setNeedsStatusBarAppearanceUpdate()
        }
        controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
        controller.setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    private func startWatchingHost() {
        guard hostWatch == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.controller.appearanceChanged() else { return }
                self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hostWatch = timer
    }
}

/// 只为了管状态栏的窗口:点不中、不当主窗口。
private final class PassthroughWindow: UIWindow {
    override var canBecomeKey: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private final class StatusBarStyleController: UIViewController {
    weak var host: UIWindow?

    private struct HostAppearance: Equatable {
        var statusBarHidden: Bool
        var presentedStyle: UIStatusBarStyle?
        var homeIndicatorHidden: Bool
        var deferredEdges: UIRectEdge
    }

    private var lastAppearance: HostAppearance?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    override var prefersStatusBarHidden: Bool { hostAppearance.statusBarHidden }

    override var prefersHomeIndicatorAutoHidden: Bool { hostAppearance.homeIndicatorHidden }

    /// 屏幕边缘的系统手势让不让给 App 也照主窗口的(iPhone Duo 上播放页让开顶边,见 `PlayerBareTopEdgeReader`)。
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { hostAppearance.deferredEdges }

    /// 主窗口这一刻跟上次比有没有变(藏不藏状态栏、全屏弹出页要的字色、主屏指示条)。
    func appearanceChanged() -> Bool {
        let current = hostAppearance
        defer { lastAppearance = current }
        return current != lastAppearance
    }

    /// 主窗口这一刻要的样子:有全屏弹出的页面看它,没有就看主窗口自己(播放页里的全屏效果、MV 都在这里要藏)。
    private var hostAppearance: HostAppearance {
        let presentation = fullScreenPresentation
        let source = presentation ?? host?.rootViewController
        let hiddenSource = Self.resolved(source) { $0.childForStatusBarHidden }
        let homeIndicatorSource = Self.resolved(source) { $0.childForHomeIndicatorAutoHidden }
        let deferringSource = Self.resolved(source) { $0.childForScreenEdgesDeferringSystemGestures }
        return HostAppearance(
            statusBarHidden: hiddenSource?.prefersStatusBarHidden ?? false,
            presentedStyle: Self.resolved(presentation) { $0.childForStatusBarStyle }?.preferredStatusBarStyle,
            homeIndicatorHidden: homeIndicatorSource?.prefersHomeIndicatorAutoHidden ?? false,
            deferredEdges: deferringSource?.preferredScreenEdgesDeferringSystemGestures ?? []
        )
    }

    private static func resolved(
        _ start: UIViewController?,
        child: (UIViewController) -> UIViewController?
    ) -> UIViewController? {
        var current = start
        while let controller = current, let next = child(controller), next !== controller {
            current = next
        }
        return current
    }

    /// 主窗口里全屏弹出的那一页:它自己定样式和藏不藏。
    private var fullScreenPresentation: UIViewController? {
        var presented = host?.rootViewController?.presentedViewController
        var capturing: UIViewController?
        while let current = presented {
            if current.modalPresentationCapturesStatusBarAppearance
                || current.modalPresentationStyle == .fullScreen
                || current.modalPresentationStyle == .overFullScreen {
                capturing = current
            }
            presented = current.presentedViewController
        }
        return capturing
    }

    override var childForStatusBarStyle: UIViewController? { fullScreenPresentation }

    /// 方向仍由主窗口和播放页的方向锁决定,这一层不拦。
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }
}

/// 挂在播放页上:拿到所在的窗口,按 `isActive` 盖上或撤掉那层管状态栏的窗口。
struct PlayerLightStatusBar: UIViewRepresentable {
    let isActive: Bool

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.isActive = isActive
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.isActive = isActive
    }

    static func dismantleUIView(_ uiView: ProbeView, coordinator: Void) {
        PlayerStatusBarOverlay.shared.setLightContent(false, over: nil)
    }

    final class ProbeView: UIView {
        var isActive = false {
            didSet {
                guard isActive != oldValue else { return }
                apply()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            PlayerStatusBarOverlay.shared.setLightContent(isActive && window != nil, over: window)
        }
    }
}

/// 窗口顶上有没有状态栏。iPhone Duo 把状态栏竖排进侧边竖栏后顶部安全区是 0,播放页的把手和下拉收起
/// 那一截就贴着屏幕顶边,和系统从顶边拉通知中心的手势抢同一下。播放页据此让系统先把顶边让给自己
/// (`defersSystemGestures`):第一下拉播放页,要拉通知中心再拉一下。
struct PlayerBareTopEdgeReader: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
        uiView.publishIfNeeded()
    }

    final class ReaderView: UIView {
        var onChange: ((Bool) -> Void)?
        private var lastValue: Bool?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        func publishIfNeeded() {
            guard let window else { return }
            let isBare = window.safeAreaInsets.top < 1
            guard isBare != lastValue else { return }
            lastValue = isBare
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(isBare)
            }
        }
    }
}
#endif
