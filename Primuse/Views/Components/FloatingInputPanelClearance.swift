import SwiftUI
import PrimuseKit

#if os(iOS)
import UIKit

extension View {
    /// 给未停靠的输入面板让位 —— 浮动键盘、拆分键盘,以及 iPadOS 上用
    /// Apple Pencil 唤起的手写输入浮窗。
    ///
    /// 系统只把停靠在窗口底边的键盘算进 safe area,浮动面板一律不算,SwiftUI
    /// 的自动键盘避让对它完全失效:面板就停在内容上面,输入框、底部操作条、
    /// 列表最后几行全被压住,而 app 这一侧毫不知情。这个修饰符按面板与窗口的
    /// 实际交集补上缺的那段底部空间,停靠键盘则原样交给系统,不会二次让位。
    ///
    /// 用在需要保护的滚动容器或表单的最外层(sheet 是独立的 presentation,
    /// 得各自挂一次)。
    func floatingInputPanelClearance() -> some View {
        modifier(FloatingInputPanelClearanceModifier())
    }
}

private struct FloatingInputPanelClearanceModifier: ViewModifier {
    @State private var clearance: CGFloat = 0
    @State private var window: UIWindow?

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, clearance)
            .background {
                FloatingInputPanelWindowProbe { window = $0 }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )
            ) { note in
                apply(note)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillHideNotification
                )
            ) { _ in
                clearance = 0
            }
            .animation(.easeOut(duration: 0.22), value: clearance)
    }

    private func apply(_ note: Notification) {
        // iPhone 没有未停靠键盘,系统避让已经够用;别的 app 的键盘(非 local)
        // 也不该让我们的界面跟着跳 —— 那本身就是一种「打架」。
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let info = note.userInfo
        if let isLocal = info?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool, !isLocal {
            clearance = 0
            return
        }
        guard let window,
              let screen = window.windowScene?.screen,
              let end = info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else {
            clearance = 0
            return
        }
        // 键盘通知给的是屏幕坐标。分屏 / 台前调度下窗口只占屏幕一角,不换算
        // 过来就会把面板算到完全错误的位置上。
        let panelInWindow = window.convert(end.cgRectValue, from: screen.coordinateSpace)
        clearance = FloatingInputPanelClearancePolicy.bottomClearance(
            panelFrameInWindow: panelInWindow,
            windowBounds: window.bounds
        )
    }
}

/// 零尺寸探针,只为拿到承载当前界面的那扇窗。多窗口下 `connectedScenes` 里的
/// key window 未必是自己这一扇,所以不能靠全局查询。
private struct FloatingInputPanelWindowProbe: UIViewRepresentable {
    let onChange: (UIWindow?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onChange = onChange
    }

    final class ProbeView: UIView {
        var onChange: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // 这个回调可能落在 SwiftUI 的更新过程里,当场写 @State 会触发
            // 「view update 期间修改状态」的运行时告警。推到下一拍再交出去。
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onChange?(self.window)
            }
        }
    }
}

#else

extension View {
    /// macOS / tvOS 没有未停靠的触摸输入面板,让位逻辑原样返回。
    func floatingInputPanelClearance() -> some View { self }
}

#endif
