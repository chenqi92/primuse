#if os(iOS)
import PrimuseKit
import SwiftUI
import UIKit

/// 分类页横滑时跟手的那段位移。单独放在一个可观察对象里、只由 `LibrarySectionPagingOffset` 读：
/// 拖动、落位的每一帧只重算那一层，两页里面一行都不用重算。
@MainActor
@Observable
final class LibrarySectionPagingDrag {
    /// 位移是相对哪一页算的：换了页（点顶上的分类、导航栈换过来）以后，旧的位移不再算数。
    var anchor: LibrarySection?
    var offset: CGFloat = 0
    /// 手指正按着拖。
    @ObservationIgnored var isDragging = false
    /// 松手后相邻那一页正滑向原位：这时不接新的横滑。
    @ObservationIgnored var isSettling = false
    /// 每翻一次、每次从外面换页加一：落位动画的收尾、兜底复位只认自己那一次。
    @ObservationIgnored var generation = 0
}

#if DEBUG
/// 取证：极简导航换分类要多久才有内容。点分类（或滑过去）那一刻起表，新页出现、歌曲页的转圈、
/// 目录索引（复用上一页的还是重新分的）、列表出来各记一笔：`🧪 section <分类> <事件> +<毫秒>ms`。
/// 横滑时相邻那一页在拖动起手时挂上，从那一刻起表（`beside`）。
@MainActor
enum LibrarySectionSwitchTrace {
    private static var start: ContinuousClock.Instant?
    private static var label = ""

    static func begin(_ section: String, event: String = "selected") {
        start = .now
        label = section
        mark(event)
    }

    static func mark(_ event: String) {
        guard let start else { return }
        let elapsed = ContinuousClock.now - start
        // 换完很久以后才出现的（回到这一页、改了排序）不算这一次。
        guard elapsed < .seconds(5) else { return }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        plog("🧪 section \(label) \(event) +\(Int(ms.rounded()))ms")
    }
}
#endif

/// 分类页的横滑翻页：内容跟手走，相邻的分类紧贴着当前页一起出来，松手够远或够快就滑到位，
/// 不够就一起退回去；到两端有阻尼。
///
/// 每个分类是资料库导航栈里的一页，换分类是把栈里这一格换掉。导航栈原地换页时沿用这一格的视图，
/// 所以这一层跟着留下来，里面每个分类各是一页、按分类区分：
/// - 拖动起手时才把手指方向上的相邻分类挂在旁边。不预先挂：分类页可能是几万首的歌曲列表，提前建会在
///   看当前页、滚列表时卡一下；智能推荐页一出现就去要推荐；两张列表同时在屏上时点状态栏回顶也不灵；
/// - 松手滑到位以后才换导航栈，换过来的那一页就是拖动时挂上的那一个，不再重建，也没有第二段进场；
///   换下来的那一页这时已在屏幕外，随即拆掉；
/// - 没拖够就两页一起退回去，退完把相邻那一页拆掉。停着的时候始终只有一页。
///
/// 页里横着划归翻页：起手落在卡片、歌曲行上也翻。歌曲行因此不再左右滑出入队（见
/// `songRowSwipeYieldsToSectionPaging`，两项留在长按菜单里）；列表行的系统滑动操作（歌单左滑删除）
/// 和系统的边缘返回先认，认不了才轮到翻页；在横着滚的一排里、贴着左右边缘起手的不接；
/// 批量选择时整个停用，挂在旁边的那一页也拆掉。减少动态效果时不跟手，松手直接换页。
struct LibrarySectionSwipeContainer<Content: View>: View {
    let section: LibrarySection
    let enabled: Bool
    /// 这一页右缘有字母索引（歌曲、专辑、艺人页）：贴着后沿起手的留给索引。
    var excludesTrailingEdge = false
    /// 某一页往后（`true`）或往前翻到的分类；那一侧没有分类时返回 nil。
    let neighbor: (LibrarySection, Bool) -> LibrarySection?
    /// 相邻那一页已经滑到原位，导航栈换成这一个分类。
    let onCommit: (LibrarySection) -> Void
    @ViewBuilder let page: (LibrarySection) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var drag = LibrarySectionPagingDrag()
    @State private var width: CGFloat = 0
    @State private var batchSelecting = false
    /// 挂在当前页旁边的相邻分类。
    @State private var attached: Attachment?
    /// 刚翻过去、导航栈还没换过来的那一次。
    @State private var committed: Commit?

    private struct Attachment: Equatable {
        let section: LibrarySection
        /// 在当前页哪一侧（容器自己的坐标）：+1 右、-1 左。
        let slot: CGFloat
    }

    private struct Commit: Equatable {
        let from: LibrarySection
        let to: LibrarySection
    }

    private struct MountedPage: Identifiable {
        let section: LibrarySection
        let slot: CGFloat
        var id: LibrarySection { section }
    }

    private var isRightToLeft: Bool { layoutDirection == .rightToLeft }
    private var pagingEnabled: Bool { enabled && !batchSelecting }

    /// 摆在原位的那一页：通常就是导航栈里的这一页，刚翻过去、栈还没换过来时先摆翻到的那一页。
    private var shownSection: LibrarySection {
        LibrarySectionPagingPolicy.shownPage(
            current: section,
            committedFrom: committed?.from,
            committedTo: committed?.to
        )
    }

    var body: some View {
        let shown = shownSection
        ZStack {
            ForEach(mountedPages(shown: shown)) { mounted in
                page(mounted.section)
                    .modifier(LibrarySectionPageSlot(slot: mounted.slot, width: width))
            }
        }
        .environment(\.songRowSwipeYieldsToSectionPaging, enabled)
        .modifier(LibrarySectionPagingOffset(drag: drag, anchor: shown))
        // 手势挂在不跟着位移走的这一层：本地坐标里的位移才不会被内容自己的移动带偏。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .onPreferenceChange(SongBatchSelectionActivePreferenceKey.self) { isActive in
            batchSelecting = isActive
        }
        .gesture(LibrarySectionSwipeGesture(
            enabled: pagingEnabled,
            isRightToLeft: isRightToLeft,
            excludesTrailingEdge: excludesTrailingEdge,
            onEvent: handle
        ))
        .onChange(of: section) { _, newSection in
            sectionDidChange(to: newSection)
        }
        .onChange(of: pagingEnabled) { _, isEnabled in
            if !isEnabled, !drag.isSettling {
                drag.isDragging = false
                settle()
            }
        }
        .onDisappear(perform: reset)
    }

    /// 原位的那一页在前，挂在旁边的在后。按分类区分：翻过去时，挂在旁边的那一页原样留下来当这一页。
    private func mountedPages(shown: LibrarySection) -> [MountedPage] {
        var pages = [MountedPage(section: shown, slot: 0)]
        if let attached, attached.section != shown {
            pages.append(MountedPage(section: attached.section, slot: attached.slot))
        }
        return pages
    }

    private func target(from shown: LibrarySection, for translation: CGFloat) -> LibrarySection? {
        guard translation != 0 else { return nil }
        return neighbor(shown, LibrarySectionPagingPolicy.isForward(
            translationX: Double(translation),
            isRightToLeft: isRightToLeft
        ))
    }

    private func handle(_ event: LibrarySectionSwipeGesture.Event) {
        guard !drag.isSettling else { return }
        switch event {
        case .changed(let movement):
            // 减少动态效果时不跟手，松手照样翻页。
            guard !reduceMotion else { return }
            drag.isDragging = true
            follow(movement)
        case .ended(let movement):
            drag.isDragging = false
            let shown = shownSection
            if let next = target(from: shown, for: movement.translation),
               HomeFaceSwipePolicy.exits(
                   translationX: Double(movement.translation),
                   velocityX: Double(movement.velocity)
               ) {
                commit(from: shown, to: next, movement: movement)
            } else {
                settle()
            }
        case .cancelled:
            drag.isDragging = false
            settle()
        }
    }

    /// 跟手：往哪边翻由屏幕上手指的方向定（`isForward`），相邻页挂在哪一侧、内容挪多少按容器自己坐标里的
    /// 位移算，从右到左的语言里也是紧贴着露出来的那一边。
    private func follow(_ movement: LibrarySectionSwipeGesture.Movement) {
        let shown = shownSection
        let next = target(from: shown, for: movement.translation)
        if let next, width > 0,
           let slot = LibrarySectionPagingPolicy.neighborSlot(contentOffset: Double(movement.localTranslation)) {
            attach(next, slot: CGFloat(slot))
        }
        drag.anchor = shown
        drag.offset = CGFloat(LibrarySectionPagingPolicy.interactiveOffset(
            translationX: Double(movement.localTranslation),
            canMove: next != nil
        ))
    }

    /// 把相邻分类挂上。换了方向就换成那一侧的分类，原来挂着的拆掉。
    private func attach(_ next: LibrarySection, slot: CGFloat) {
        let attachment = Attachment(section: next, slot: slot)
        guard attached != attachment else { return }
        #if DEBUG
        LibrarySectionSwitchTrace.begin(next.rawValue, event: "beside")
        #endif
        withoutAnimation { attached = attachment }
    }

    /// 松手翻页：挂在旁边的那一页接着手指的速度滑到原位，停稳了才换导航栈。
    private func commit(
        from shown: LibrarySection,
        to next: LibrarySection,
        movement: LibrarySectionSwipeGesture.Movement
    ) {
        UISelectionFeedbackGenerator().selectionChanged()
        guard !reduceMotion, width > 0, let attached, attached.section == next, drag.anchor == shown else {
            // 减少动态效果（不跟手），或者相邻那一页没挂上：直接换页。
            withoutAnimation { drag.offset = 0 }
            onCommit(next)
            return
        }
        let destination = -attached.slot * width
        let remaining = destination - drag.offset
        drag.generation &+= 1
        let generation = drag.generation
        guard abs(remaining) >= 0.5 else {
            // 已经拖到头了，不用再滑。
            finishCommit(from: shown, to: next, generation: generation)
            return
        }
        drag.isSettling = true
        let duration = LibrarySectionPagingPolicy.settleDuration(remainingFraction: Double(remaining / width))
        let curve = LibrarySectionPagingPolicy.settleCurve(
            velocity: Double(movement.localVelocity),
            remaining: Double(remaining),
            duration: duration
        )
        // 用定时长的曲线而不是弹簧：它在算完的那一刻正好停在终点，收尾换算位置时画面一点不跳。
        withAnimation(.timingCurve(curve.x1, curve.y1, curve.x2, curve.y2, duration: duration)) {
            drag.offset = destination
        } completion: {
            finishCommit(from: shown, to: next, generation: generation)
        }
    }

    /// 滑到位了：改成以新的一页为原位（位置一样，画面不动），换下来的那一页已在屏幕外、拆掉，再换导航栈。
    private func finishCommit(from previous: LibrarySection, to next: LibrarySection, generation: Int) {
        guard drag.generation == generation else { return }
        let commit = Commit(from: previous, to: next)
        withoutAnimation {
            committed = commit
            attached = nil
            drag.anchor = next
            drag.offset = 0
        }
        drag.isSettling = false
        onCommit(next)
        confirmCommit(commit, generation: generation)
    }

    /// 导航栈一直没换过来（这期间分类被藏了之类）时，回到栈里的那一页，别一直摆着翻到的那一页。
    private func confirmCommit(_ commit: Commit, generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard drag.generation == generation, committed == commit else { return }
            withoutAnimation { committed = nil }
        }
    }

    /// 导航栈里的这一页换了。是横滑翻过去的那一次就只是对上了；别的换页（点顶上的分类、深链）从头来，
    /// 挂在旁边的拆掉。
    private func sectionDidChange(to newSection: LibrarySection) {
        if let committed, committed.to == newSection {
            withoutAnimation { self.committed = nil }
            return
        }
        drag.generation &+= 1
        drag.isDragging = false
        drag.isSettling = false
        withoutAnimation {
            committed = nil
            attached = nil
            drag.anchor = newSection
            drag.offset = 0
        }
    }

    /// 没翻页：两页一起退回去，退完把挂在旁边的那一页拆掉。退的途中又按住拖了就留着它。
    private func settle() {
        let generation = drag.generation
        let detach = {
            guard drag.generation == generation, !drag.isDragging, !drag.isSettling,
                  drag.offset == 0, attached != nil else { return }
            withoutAnimation { attached = nil }
        }
        guard drag.offset != 0 else {
            detach()
            return
        }
        withAnimation(reduceMotion ? nil : PMMotion.selection.animation) {
            drag.offset = 0
        } completion: {
            detach()
        }
    }

    /// 页面收起（推进详情、切到别的顶栏去处）：位移归零，挂在旁边的拆掉。
    private func reset() {
        drag.generation &+= 1
        drag.isDragging = false
        drag.isSettling = false
        withoutAnimation {
            committed = nil
            attached = nil
            drag.offset = 0
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

/// 横滑跟手的位移。只有这一层读 `drag.offset`，拖动时两页本身不重算。
private struct LibrarySectionPagingOffset: ViewModifier {
    let drag: LibrarySectionPagingDrag
    let anchor: LibrarySection

    func body(content: Content) -> some View {
        content.offset(x: drag.anchor == anchor ? drag.offset : 0)
    }
}

/// 一页在哪一格：原位（0）或者挂在左右整一页宽外。挂在旁边的不接触摸，读屏也跳过它。
private struct LibrarySectionPageSlot: ViewModifier {
    let slot: CGFloat
    let width: CGFloat

    func body(content: Content) -> some View {
        let isShown = slot == 0
        content
            .offset(x: slot * width)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
    }
}

/// UIKit 的横向拖动手势：只在横着起手时接手，和列表的上下滚动同时识别。
private struct LibrarySectionSwipeGesture: UIGestureRecognizerRepresentable {
    /// 同一段拖动的两种量法。
    struct Movement {
        /// 屏幕方向（UIKit 坐标）：往前还是往后翻、够不够翻页都按它判断。
        let translation: CGFloat
        let velocity: CGFloat
        /// 同一段位移在容器自己坐标里的值：内容跟手挪多少、相邻页挂在哪一侧按它，和 `offset` 同一个坐标。
        let localTranslation: CGFloat
        let localVelocity: CGFloat
    }

    enum Event {
        case changed(Movement)
        case ended(Movement)
        case cancelled
    }

    var enabled: Bool
    var isRightToLeft: Bool
    var excludesTrailingEdge: Bool
    let onEvent: (Event) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isRightToLeft: isRightToLeft, excludesTrailingEdge: excludesTrailingEdge)
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
        context.coordinator.excludesTrailingEdge = excludesTrailingEdge
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        guard let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view).x
        let velocity = recognizer.velocity(in: view).x
        let movement = Movement(
            translation: translation,
            velocity: velocity,
            localTranslation: context.converter.localTranslation?.x ?? translation,
            localVelocity: context.converter.localVelocity?.x ?? velocity
        )
        switch recognizer.state {
        case .began, .changed:
            onEvent(.changed(movement))
        case .ended:
            onEvent(.ended(movement))
        case .cancelled, .failed:
            onEvent(.cancelled)
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isRightToLeft: Bool
        var excludesTrailingEdge: Bool
        /// 这一次按下的时刻：按住一会儿才动的是长按菜单或拖动排序。
        private var touchDownTime: TimeInterval = 0

        init(isRightToLeft: Bool, excludesTrailingEdge: Bool) {
            self.isRightToLeft = isRightToLeft
            self.excludesTrailingEdge = excludesTrailingEdge
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDownTime = touch.timestamp
            // 贴着屏幕左右边缘起手的不接：左边是系统返回，右边是字母索引。
            if let window = touch.window,
               LibrarySectionPagingPolicy.startsInEdgeExclusion(
                   startX: Double(touch.location(in: window).x),
                   containerWidth: Double(window.bounds.width),
                   isRightToLeft: isRightToLeft,
                   excludesTrailingEdge: excludesTrailingEdge
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

        /// 只等这几样先认：系统边缘返回、列表行的系统滑动操作（歌单左滑删除）、还开着横滑的歌曲行。
        ///
        /// 原先页里所有拖动类的手势都要先失败才轮到翻页，按住卡片、歌曲行时总有一个一直等到松手才算失败，
        /// 结果只有空白处能翻。字母索引、横着滚的一排在 `shouldReceive` 里按起手位置让开了。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer { return true }
            if otherGestureRecognizer is SongRowPanRecognizer { return true }
            guard otherGestureRecognizer !== gestureRecognizer,
                  let ownView = gestureRecognizer.view,
                  let otherView = otherGestureRecognizer.view,
                  otherView.isDescendant(of: ownView) else { return false }
            return Self.isListSwipeAction(otherGestureRecognizer)
        }

        /// 系统 26 起导航栈在内容上也能右划返回：分类页上的横划先归翻页，到头了也不会把这一页拉回总览。
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard #available(iOS 26, *) else { return false }
            var responder: UIResponder? = gestureRecognizer.view
            while let current = responder {
                if let controller = current as? UIViewController,
                   let navigation = (controller as? UINavigationController) ?? controller.navigationController {
                    return otherGestureRecognizer === navigation.interactiveContentPopGestureRecognizer
                }
                responder = current.next
            }
            return false
        }

        /// 列表（表格、集合视图）行的系统滑动操作用的拖动手势，挂在列表本身上，不是它滚动用的那一个。
        private static func isListSwipeAction(_ recognizer: UIGestureRecognizer) -> Bool {
            guard recognizer is UIPanGestureRecognizer,
                  let list = recognizer.view as? UIScrollView,
                  list is UICollectionView || list is UITableView,
                  recognizer !== list.panGestureRecognizer else { return false }
            return NSStringFromClass(type(of: recognizer)).contains("SwipeAction")
        }
    }
}
#endif
