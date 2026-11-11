#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 分类页之间横滑翻页时，下一页从哪一侧进来。
///
/// 分类页是资料库导航栈里的一页，换分类就是把这一页换掉：旧页先顺着手指滑出去，滑完才换页，
/// 新页出现时读这一份，把自己从另一侧推进来。整个资料库只有一份，挂在 `LibraryView` 上。
@MainActor
final class LibrarySectionPagingMotion {
    struct Entry {
        let sectionID: String
        /// +1 从右侧进来，-1 从左侧。
        let side: CGFloat
        let distance: CGFloat
    }

    var pendingEntry: Entry?
    /// 旧页正在滑出去：这时不接新的横滑。
    var isPaging = false
    /// 每翻一次加一：兜底复位只认自己那一次。
    var generation = 0
}

/// 分类页的横滑翻页：内容跟手走，松手够远或够快就翻到相邻的分类，到两端有阻尼。
///
/// 只接「这一页没有别人要」的横滑：歌曲行自己的左右滑（入队、下一首）、列表行的系统滑动操作、
/// 系统的边缘返回都先认，认不了才轮到翻页；在横着滚的一排里、贴着左右边缘起手的不接；
/// 批量选择时整个停用。换页走导航栈换掉这一页，和点顶上的分类是同一条路，不会更慢。
struct LibrarySectionSwipeContainer<Content: View>: View {
    let sectionID: String
    let enabled: Bool
    let motion: LibrarySectionPagingMotion
    /// 往后（`true`）或往前翻到的分类；那一侧没有分类时返回 nil。
    let neighbor: (Bool) -> String?
    /// 旧页已经滑出去，换成这一个分类。
    let onCommit: (String) -> Void
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 0
    @State private var batchSelecting = false
    @State private var isVisible = false

    private var isRightToLeft: Bool { layoutDirection == .rightToLeft }

    var body: some View {
        content
            .offset(x: offset)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                width = newWidth
            }
            .onPreferenceChange(SongBatchSelectionActivePreferenceKey.self) { isActive in
                batchSelecting = isActive
            }
            .gesture(LibrarySectionSwipeGesture(
                enabled: enabled && !batchSelecting,
                isRightToLeft: isRightToLeft,
                onEvent: handle
            ))
            .onAppear {
                isVisible = true
                enterIfPending()
            }
            .onDisappear {
                isVisible = false
                offset = 0
            }
            .onChange(of: enabled && !batchSelecting) { _, isEnabled in
                if !isEnabled, !motion.isPaging { settle() }
            }
    }

    private func target(for translation: CGFloat) -> String? {
        guard translation != 0 else { return nil }
        return neighbor(LibrarySectionPagingPolicy.isForward(
            translationX: Double(translation),
            isRightToLeft: isRightToLeft
        ))
    }

    private func handle(_ event: LibrarySectionSwipeGesture.Event) {
        guard !motion.isPaging else { return }
        switch event {
        case .changed(let translation):
            // 减少动态效果时不跟手，松手照样翻页。
            guard !reduceMotion else { return }
            offset = CGFloat(LibrarySectionPagingPolicy.interactiveOffset(
                translationX: Double(translation),
                canMove: target(for: translation) != nil
            ))
        case .ended(let translation, let velocity):
            if let next = target(for: translation),
               HomeFaceSwipePolicy.exits(translationX: Double(translation), velocityX: Double(velocity)) {
                commit(to: next, translation: translation)
            } else {
                settle()
            }
        case .cancelled:
            settle()
        }
    }

    private func commit(to next: String, translation: CGFloat) {
        UISelectionFeedbackGenerator().selectionChanged()
        guard !reduceMotion else {
            offset = 0
            onCommit(next)
            return
        }
        let side = CGFloat(LibrarySectionPagingPolicy.entrySide(translationX: Double(translation)))
        let distance = max(width, 320)
        motion.isPaging = true
        motion.generation &+= 1
        let generation = motion.generation
        // 旧页顺着手指滑出去，滑完再换页；新页在 `enterIfPending` 里从另一侧进来。
        withAnimation(PMMotion.pageSwitch.animation) {
            offset = -side * distance
        } completion: {
            motion.pendingEntry = LibrarySectionPagingMotion.Entry(
                sectionID: next,
                side: side,
                distance: distance
            )
            onCommit(next)
            recoverIfStillVisible(generation: generation)
        }
    }

    /// 换页没发生（分类在这期间被藏了之类）时，旧页别停在屏幕外。
    private func recoverIfStillVisible(generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard motion.generation == generation else { return }
            motion.pendingEntry = nil
            motion.isPaging = false
            if isVisible, offset != 0 {
                withAnimation(PMMotion.selection.animation) { offset = 0 }
            }
        }
    }

    private func enterIfPending() {
        guard let entry = motion.pendingEntry, entry.sectionID == sectionID else { return }
        motion.pendingEntry = nil
        motion.isPaging = false
        guard !reduceMotion else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            offset = entry.side * entry.distance
        }
        Task { @MainActor in
            withAnimation(PMMotion.selection.animation) {
                offset = 0
            }
        }
    }

    private func settle() {
        guard offset != 0 else { return }
        withAnimation(reduceMotion ? nil : PMMotion.selection.animation) {
            offset = 0
        }
    }
}

/// UIKit 的横向拖动手势：只在横着起手时接手，和列表的上下滚动同时识别。
private struct LibrarySectionSwipeGesture: UIGestureRecognizerRepresentable {
    enum Event {
        case changed(CGFloat)
        case ended(CGFloat, velocity: CGFloat)
        case cancelled
    }

    var enabled: Bool
    var isRightToLeft: Bool
    let onEvent: (Event) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isRightToLeft: isRightToLeft)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = enabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isRightToLeft = isRightToLeft
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view).x
        switch recognizer.state {
        case .began, .changed:
            onEvent(.changed(translation))
        case .ended:
            onEvent(.ended(translation, velocity: recognizer.velocity(in: view).x))
        case .cancelled, .failed:
            onEvent(.cancelled)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isRightToLeft: Bool
        /// 这一次按下的时刻：按住一会儿才动的是长按菜单或拖动排序。
        private var touchDownTime: TimeInterval = 0

        init(isRightToLeft: Bool) {
            self.isRightToLeft = isRightToLeft
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDownTime = touch.timestamp
            // 贴着屏幕左右边缘起手的不接：左边是系统返回，右边是歌曲页的字母索引。
            if let window = touch.window,
               LibrarySectionPagingPolicy.startsInEdgeExclusion(
                   startX: Double(touch.location(in: window).x),
                   containerWidth: Double(window.bounds.width),
                   isRightToLeft: isRightToLeft
               ) {
                return false
            }
            // 在横着滚的一排里（封面轮播、横排货架）起手的交给那一排自己。
            var view = touch.view
            while let current = view {
                if let scrollView = current as? UIScrollView,
                   scrollView.contentSize.width > scrollView.bounds.width + 1 {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let recognizer = gestureRecognizer as? UIPanGestureRecognizer,
                  let view = recognizer.view else { return false }
            let translation = recognizer.translation(in: view)
            let velocity = recognizer.velocity(in: view)
            return HomeFaceSwipePolicy.shouldBegin(
                translationX: Double(translation.x),
                translationY: Double(translation.y),
                velocityX: Double(velocity.x),
                velocityY: Double(velocity.y),
                heldBeforeMove: ProcessInfo.processInfo.systemUptime - touchDownTime
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }

        /// 行内自己的横滑（歌曲行的入队、下一首，列表行的系统滑动操作、字母索引）和系统边缘返回优先：
        /// 它们认不了这一下，才轮到翻页。想入队的一划绝不会切了分类。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer { return true }
            guard otherGestureRecognizer is UIPanGestureRecognizer,
                  otherGestureRecognizer !== gestureRecognizer,
                  let ownView = gestureRecognizer.view,
                  let otherView = otherGestureRecognizer.view,
                  otherView !== ownView,
                  otherView.isDescendant(of: ownView) else { return false }
            if let scrollView = otherView as? UIScrollView,
               otherGestureRecognizer === scrollView.panGestureRecognizer {
                return false
            }
            return true
        }
    }
}
#endif
