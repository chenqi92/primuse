import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

private struct LibrarySectionRailActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 资料库的分类页签挪进了 iPhone Duo 竖栏中间(`LibrarySectionRail`)。分类页据此把自己的几颗
    /// 工具栏按钮收进一个「⋯」,竖栏里只剩返回和「⋯」,中间给分类腾出地方。
    var librarySectionRailActive: Bool {
        get { self[LibrarySectionRailActiveKey.self] }
        set { self[LibrarySectionRailActiveKey.self] = newValue }
    }
}

#if os(iOS)
/// 竖栏中间那段空当(窗口坐标的上下沿)与竖栏宽度。宽度由量的那一方给:页面上挂了
/// `ignoresSafeArea` 的几何读数里安全区是 0,读不出竖栏多宽。
struct LibrarySectionRailSpan: Equatable {
    var minY: CGFloat
    var maxY: CGFloat
    var barWidth: CGFloat
    var height: CGFloat { maxY - minY }
}

/// 一页上量到的结果:竖栏中间的空当,或者没有可用的空当(竖栏没亮出来、整条都被系统按钮占着)。
enum LibrarySectionRailReading: Equatable {
    case span(LibrarySectionRailSpan)
    case unavailable
}

/// 量的时候窗口是什么样子。开合、转屏以后各页的空当都变了,之前量的不再拿来预排。
struct LibrarySectionRailConfiguration: Equatable {
    var windowSize: CGSize
    var barWidth: CGFloat
    var barOnRight: Bool
}

/// 各页竖栏中间的空当,以及现在亮着的是哪一页的分类。
///
/// 空当按页记(资料库首页、各分类页的页面按钮不一样多):回到量过的页上,分类直接排在上次的位置,
/// 第一次进某个分类页先按最近量过的分类页排。读数要连着两次一样才算数,系统按钮排到一半时的
/// 读数不会让分类跳一下、也不会让顶上那排页签闪出来。
@MainActor
@Observable
final class LibrarySectionRailState {
    static let shared = LibrarySectionRailState()

    /// 分类胶囊和上下系统胶囊之间留的空,跟系统胶囊彼此之间的间距一样。
    static let gap: CGFloat = 12

    /// 各页量定的结果,nil 键是资料库首页。
    private var readings: [LibrarySection?: LibrarySectionRailReading] = [:]
    /// 最近量定的分类页。分类页都把页面按钮收成了「⋯」,空当大多一样。
    private var lastSectionReading: LibrarySectionRailReading?
    /// 上面这些读数是在什么样的窗口上量的。
    private var configuration: LibrarySectionRailConfiguration?
    /// 亮着的那一条分类(它所在的页停稳在导航栈最上面)。推入、返回的过渡期间为空:
    /// 两页的分类都淡出,过渡完再在新页上原地淡入,和竖栏里系统的按钮一样不跟着页面横滑。
    private(set) var activeToken: UUID?
    /// 系统竖栏里那一列胶囊的中线离竖栏外缘多远(对着前置摄像头的中心)。遮挡区偶尔一拍读不到,
    /// 记住上次的,分类不会左右跳。
    var columnCenterInset: CGFloat?
    private let probes = NSHashTable<LibrarySectionRailProbeView>.weakObjects()

    /// 这一页按什么排:量过的用这一页的,没量过的分类页先借最近量过的分类页。
    func reading(for page: LibrarySection?) -> LibrarySectionRailReading? {
        if let reading = readings[page] { return reading }
        return page == nil ? nil : lastSectionReading
    }

    func span(for page: LibrarySection?) -> LibrarySectionRailSpan? {
        if case .span(let span)? = reading(for: page) { return span }
        return nil
    }

    /// 这一页的竖栏放不下分类,资料库照旧在顶上摆一排页签。还没量过时按放得下算,免得页签先闪出来一下。
    func doesNotFit(_ page: LibrarySection?, itemCount: Int) -> Bool {
        guard let reading = reading(for: page) else { return false }
        guard case .span(let span) = reading else { return true }
        return LibrarySectionRailLayoutPolicy.layout(
            available: Double(span.height - Self.gap * 2), itemCount: itemCount
        ) == nil
    }

    fileprivate func committedReading(
        for page: LibrarySection?, configuration: LibrarySectionRailConfiguration
    ) -> LibrarySectionRailReading? {
        self.configuration == configuration ? readings[page] : nil
    }

    fileprivate func knownReading(
        for page: LibrarySection?, configuration: LibrarySectionRailConfiguration
    ) -> LibrarySectionRailReading? {
        self.configuration == configuration ? reading(for: page) : nil
    }

    fileprivate func commit(
        _ reading: LibrarySectionRailReading,
        for page: LibrarySection?,
        configuration: LibrarySectionRailConfiguration
    ) {
        if self.configuration != configuration {
            self.configuration = configuration
            readings = [:]
            lastSectionReading = nil
        }
        if readings[page] != reading { readings[page] = reading }
        if page != nil, lastSectionReading != reading { lastSectionReading = reading }
    }

    fileprivate func activate(_ token: UUID) {
        if activeToken != token { activeToken = token }
    }

    fileprivate func resign(_ token: UUID) {
        if activeToken == token { activeToken = nil }
    }

    /// 导航栈开始推入或返回:当前亮着的分类先淡出,并让别的页上的探针也去等这次过渡结束
    /// (交互式返回半路松手取消时,原来那页要靠它自己重新亮起来)。
    fileprivate func beginTransition(from probe: LibrarySectionRailProbeView) {
        guard activeToken != nil else { return }
        activeToken = nil
        for other in probes.allObjects where other !== probe {
            other.evaluateSoon()
        }
    }

    fileprivate func register(_ probe: LibrarySectionRailProbeView) {
        probes.add(probe)
    }

    fileprivate func unregister(_ probe: LibrarySectionRailProbeView) {
        probes.remove(probe)
    }
}

/// iPhone Duo 竖栏时的资料库分类:一列图标排在系统竖栏中间那段空当里(返回键与页面按钮下面、
/// 底部标签栏上面),和旁边系统标签栏一样的玻璃胶囊、一样的选中底色。
///
/// 空当在哪里每页都不一样(页面按钮有几颗)、开合转屏也会变,系统又不报竖栏里那些玻璃胶囊的位置,
/// 所以按点按命中去量:沿竖栏中线逐点问窗口「点在这里会落到谁身上」,落到本页自己的内容上就是空着的,
/// 落到别处就是系统的胶囊;竖排状态栏与摄像头那一块按遮挡区算占用。只在页面停稳时量,
/// 量定的结果按页记住(见 `LibrarySectionRailState`)。放不下全部分类时露整数格、上下按格滑,
/// 当前分类停在中间。
struct LibrarySectionRail: View {
    let sections: [LibrarySection]
    let selection: LibrarySection?
    let edge: HorizontalEdge
    /// 页面换了一套工具栏(多选)的时候先收起来,竖栏让给那些按钮。
    var isSuspended = false
    let onSelect: (LibrarySection) -> Void

    private let state = LibrarySectionRailState.shared
    @State private var token = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 和系统竖栏里返回、「⋯」、标签栏那几个玻璃胶囊一样宽。
    private static let columnWidth: CGFloat = 49

    private struct Placement: Equatable {
        var top: CGFloat
        var centerInset: CGFloat
        var layout: LibrarySectionRailLayoutPolicy.Layout
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let regions = PMReservedRegions.activeOcclusions(in: proxy)
            let occluded = regions.map {
                (CGFloat($0.minY) + frame.minY)...(CGFloat($0.maxY) + frame.minY)
            }
            // 系统把竖栏里的胶囊对着前置摄像头排:取最窄的那块遮挡区(摄像头)的中线,量它离最近一侧边缘多远。
            let cameraInset = regions
                .filter { $0.maxX - $0.minX < 60 }
                .min { $0.maxX - $0.minX < $1.maxX - $1.minX }
                .map { region -> CGFloat in
                    let mid = CGFloat(region.minX + region.maxX) / 2
                    return min(mid, proxy.size.width - mid)
                }
            let isShown = state.activeToken == token && !isSuspended
            ZStack(alignment: .topLeading) {
                LibrarySectionRailProbe(
                    token: token,
                    page: selection,
                    edge: edge,
                    occluded: occluded,
                    containerSize: proxy.size,
                    isSuspended: isSuspended
                )
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if let span = state.span(for: selection),
                   let layout = LibrarySectionRailLayoutPolicy.layout(
                       available: Double(span.height - LibrarySectionRailState.gap * 2),
                       itemCount: sections.count
                   ) {
                    let width = min(span.barWidth - 8, Self.columnWidth)
                    let side: Edge.Set = edge == .trailing ? .trailing : .leading
                    let centerInset = cameraInset ?? state.columnCenterInset ?? span.barWidth / 2
                    let top = span.minY - frame.minY + (span.height - CGFloat(layout.height)) / 2
                    // 按竖栏所在的那一侧对齐,不写死横坐标:从右往左排版时前后两侧跟着系统对调。
                    LibrarySectionRailColumn(
                        sections: sections,
                        selection: selection,
                        layout: layout,
                        width: width,
                        onSelect: onSelect
                    )
                    .padding(side, max(0, centerInset - width / 2))
                    .frame(maxWidth: .infinity, alignment: edge == .trailing ? .trailing : .leading)
                    .padding(.top, top)
                    .frame(maxHeight: .infinity, alignment: .top)
                    // 亮着时空当变了(第一次进某一页、页面按钮变了)就滑到新位置;没亮着时直接换,
                    // 淡入时已经在新位置上。
                    .animation(
                        isShown ? PMMotion.list.resolved(reduceMotion: reduceMotion) : nil,
                        value: Placement(top: top, centerInset: centerInset, layout: layout)
                    )
                    .opacity(isShown ? 1 : 0)
                    .allowsHitTesting(isShown)
                    .accessibilityHidden(!isShown)
                    .animation(PMMotion.control.animation, value: isShown)
                    .transition(.opacity.animation(PMMotion.control.animation))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onChange(of: cameraInset, initial: true) { _, inset in
                if let inset { state.columnCenterInset = inset }
            }
        }
        .ignoresSafeArea()
    }
}

/// 竖栏里那一列分类图标。选中的那格垫一块和系统标签栏选中项一样的底色,换分类时底色滑过去。
private struct LibrarySectionRailColumn: View {
    let sections: [LibrarySection]
    let selection: LibrarySection?
    let layout: LibrarySectionRailLayoutPolicy.Layout
    let width: CGFloat
    let onSelect: (LibrarySection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight
    /// 亮起的那一格。换分类时导航栈那一拍关了动画(`pageToSection`),这里下一拍再滑过去。
    @State private var shownSelection: LibrarySection?
    @State private var position = ScrollPosition()
    @State private var offset: CGFloat = 0

    private var pitch: CGFloat { CGFloat(layout.pitch) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(sections) { section in
                    item(section)
                }
            }
            .padding(.vertical, CGFloat(LibrarySectionRailLayoutPolicy.inset))
        }
        .scrollPosition($position)
        .scrollTargetBehavior(LibrarySectionRailSnap(layout: layout))
        .scrollDisabled(!layout.scrolls)
        .scrollBounceBehavior(.basedOnSize)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y
        } action: { _, newValue in
            offset = newValue
        }
        .frame(width: width, height: CGFloat(layout.height))
        .mask { edgeFade }
        .clipShape(Capsule())
        .modifier(LibrarySectionRailSurface())
        .onAppear {
            shownSelection = selection
            position.scrollTo(y: targetOffset(for: selection))
        }
        // 刚建出来时内容可能还没排好,下一拍再停一次。
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            position.scrollTo(y: targetOffset(for: shownSelection))
        }
        .onChange(of: selection) { _, next in
            slide(to: next)
        }
        // 空当变了(格数、格距跟着变):按新排法把当前分类重新停到中间。
        .onChange(of: layout) { _, _ in
            position.scrollTo(y: targetOffset(for: shownSelection))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sectionRail")
    }

    /// 还有分类藏在上面或下面时,那一头的格子渐隐一点,看得出能滑。
    private var edgeFade: some View {
        let showsTop = layout.scrolls && offset > 0.5
        let showsBottom = layout.scrolls && offset < CGFloat(layout.maximumOffset) - 0.5
        let length = pitch * 0.6
        return VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(showsTop ? 0.12 : 1), .black],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: length)
            Color.black
            LinearGradient(
                colors: [.black, .black.opacity(showsBottom ? 0.12 : 1)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: length)
        }
        .animation(PMMotion.control.animation, value: showsTop)
        .animation(PMMotion.control.animation, value: showsBottom)
    }

    private func targetOffset(for section: LibrarySection?) -> CGFloat {
        let index = section.flatMap { sections.firstIndex(of: $0) }
        return CGFloat(LibrarySectionRailLayoutPolicy.offset(selectedIndex: index, layout: layout))
    }

    private func slide(to next: LibrarySection?) {
        Task { @MainActor in
            let target = targetOffset(for: next)
            guard let animation = PMMotion.selection.resolved(reduceMotion: reduceMotion) else {
                shownSelection = next
                position.scrollTo(y: target)
                return
            }
            withAnimation(animation) {
                shownSelection = next
                position.scrollTo(y: target)
            }
        }
    }

    private func item(_ section: LibrarySection) -> some View {
        let isLit = section == shownSelection
        return Button {
            onSelect(section)
        } label: {
            Image(systemName: section.icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isLit ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .frame(width: width, height: pitch)
                .background {
                    if isLit {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                            .frame(width: max(0, width - 8), height: max(0, pitch - 4))
                            .matchedGeometryEffect(id: "selection", in: highlight)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(section.title))
        .accessibilityAddTraits(section == selection ? .isSelected : [])
        .accessibilityIdentifier("library.sectionRail." + section.rawValue)
    }
}

/// 手指松开后按整格停,露出来的格子总是完整的。
private struct LibrarySectionRailSnap: ScrollTargetBehavior {
    let layout: LibrarySectionRailLayoutPolicy.Layout

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = CGFloat(
            LibrarySectionRailLayoutPolicy.snappedOffset(Double(target.rect.origin.y), layout: layout)
        )
    }
}

/// 和系统竖栏里的胶囊同一种玻璃底;iOS 26 以前(不会有竖栏,只是让它编得过)用材质底。
private struct LibrarySectionRailSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

private struct LibrarySectionRailProbe: UIViewRepresentable {
    let token: UUID
    let page: LibrarySection?
    let edge: HorizontalEdge
    let occluded: [ClosedRange<CGFloat>]
    let containerSize: CGSize
    let isSuspended: Bool

    func makeUIView(context: Context) -> LibrarySectionRailProbeView {
        LibrarySectionRailProbeView()
    }

    func updateUIView(_ view: LibrarySectionRailProbeView, context: Context) {
        view.token = token
        view.update(
            .init(page: page, edge: edge, occluded: occluded, containerSize: containerSize, isSuspended: isSuspended)
        )
    }
}

/// 量竖栏空当的那个看不见的视图,也负责告诉分类条什么时候亮。
///
/// 页面停稳(没有在推入、返回,且在导航栈最上面)才量:挂进窗口、过渡结束、换了分类以后的一秒里多量几次
/// (系统竖栏里的按钮在页面出现后才排好),之后每秒复查一次(页面按钮会随多选、编辑进出);离开窗口就停。
/// 一次沿竖栏中线问一两百个点,读数连着两次一样才交给 `LibrarySectionRailState`。
final class LibrarySectionRailProbeView: UIView {
    struct Inputs: Equatable {
        var page: LibrarySection?
        var edge: HorizontalEdge
        var occluded: [ClosedRange<CGFloat>]
        var containerSize: CGSize
        var isSuspended: Bool
    }

    var token: UUID?
    private var inputs = Inputs(page: nil, edge: .trailing, occluded: [], containerSize: .zero, isSuspended: false)
    private var timer: Timer?
    private var settleTask: Task<Void, Never>?
    private var confirmTask: Task<Void, Never>?
    private var evaluationQueued = false
    private var waitsForTransition = false
    /// 上一次和已记下的不一样的读数,等下一次读数核对。
    private var pending: (reading: LibrarySectionRailReading, configuration: LibrarySectionRailConfiguration)?

    /// 页面出现、过渡结束、换了分类以后各量一次的时间点(毫秒)。
    private static let settleCheckpoints = [0, 120, 300, 600, 1000]
    private static let confirmDelay = Duration.milliseconds(120)

    private var state: LibrarySectionRailState { .shared }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(_ next: Inputs) {
        guard next != inputs else { return }
        if next.page != inputs.page { pending = nil }
        inputs = next
        if window != nil { settle() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else {
            settleTask?.cancel()
            settleTask = nil
            confirmTask?.cancel()
            confirmTask = nil
            pending = nil
            waitsForTransition = false
            if let token { state.resign(token) }
            state.unregister(self)
            return
        }
        state.register(self)
        settle()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
    }

    /// 接下来一秒里按 `settleCheckpoints` 多量几次。
    private func settle() {
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            var elapsed = 0
            for checkpoint in Self.settleCheckpoints {
                if checkpoint > elapsed {
                    try? await Task.sleep(for: .milliseconds(checkpoint - elapsed))
                    elapsed = checkpoint
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                self?.evaluate()
            }
        }
    }

    func evaluateSoon() {
        guard !evaluationQueued else { return }
        evaluationQueued = true
        Task { @MainActor [weak self] in
            self?.evaluationQueued = false
            self?.evaluate()
        }
    }

    private func evaluate(after delay: Duration) {
        confirmTask?.cancel()
        confirmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    private func evaluate() {
        guard let window, let token, let controller = owningController() else { return }
        let page = stackPage(of: controller)
        if let coordinator = navigationTransition(of: page) {
            pending = nil
            state.beginTransition(from: self)
            #if DEBUG
            LibrarySectionRailDebug.event("transition page=\(inputs.page?.rawValue ?? "hub")")
            #endif
            guard !waitsForTransition else { return }
            waitsForTransition = true
            let queued = coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.waitsForTransition = false
                    self?.settle()
                }
            }
            if !queued {
                waitsForTransition = false
                evaluate(after: .milliseconds(250))
            }
            return
        }
        // 过渡已经结束(结束回调有时排不上),下一次过渡照常登记。
        waitsForTransition = false
        if let navigation = page.navigationController, navigation.topViewController !== page {
            // 上面又推入了别的页(专辑、艺人详情):这一页的分类收起来。
            pending = nil
            state.resign(token)
            return
        }
        if inputs.isSuspended {
            // 多选时竖栏里是多选那一套按钮,这时量的不记;退出多选后按原来记下的位置亮出来。
            pending = nil
            state.activate(token)
            return
        }

        let (reading, configuration) = measure(in: window, pageRoot: controller.view)
        let key = inputs.page
        if reading == state.committedReading(for: key, configuration: configuration) {
            pending = nil
            state.activate(token)
            return
        }
        if let pending, pending.reading == reading, pending.configuration == configuration {
            self.pending = nil
            state.commit(reading, for: key, configuration: configuration)
            state.activate(token)
            #if DEBUG
            LibrarySectionRailDebug.event("commit page=\(key?.rawValue ?? "hub") \(reading)")
            #endif
            return
        }
        pending = (reading, configuration)
        // 先按已知的(这一页上次的,或者最近量过的分类页)亮出来,下一次读数一致再挪;
        // 一无所知(第一次量、刚开合转屏)时等核对完再亮。
        if state.knownReading(for: key, configuration: configuration) != nil {
            state.activate(token)
        } else {
            state.resign(token)
        }
        evaluate(after: Self.confirmDelay)
    }

    private func measure(
        in window: UIWindow,
        pageRoot: UIView
    ) -> (LibrarySectionRailReading, LibrarySectionRailConfiguration) {
        let insets = window.safeAreaInsets
        let isRightToLeft = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onRight = (inputs.edge == .trailing) != isRightToLeft
        let barWidth = onRight ? insets.right : insets.left
        let configuration = LibrarySectionRailConfiguration(
            windowSize: window.bounds.size, barWidth: barWidth, barOnRight: onRight
        )
        guard barWidth > 40 else { return (.unavailable, configuration) }
        let x = onRight ? window.bounds.maxX - barWidth / 2 : window.bounds.minX + barWidth / 2
        let step: CGFloat = 4
        var best: LibrarySectionRailSpan?
        var runStart: CGFloat?
        var y = window.bounds.minY
        while y <= window.bounds.maxY {
            let free = isFree(CGPoint(x: x, y: y), in: window, pageRoot: pageRoot)
            if free, runStart == nil { runStart = y }
            let runEnds = !free || y + step > window.bounds.maxY
            if runEnds, let start = runStart {
                let end = free ? y : y - step
                if end - start > (best?.height ?? 0) {
                    best = LibrarySectionRailSpan(minY: start, maxY: end, barWidth: barWidth)
                }
                runStart = nil
            }
            y += step
        }
        #if DEBUG
        LibrarySectionRailDebug.logProbe(window: window, x: x, pageRoot: pageRoot, best: best, isFree: { point in
            self.isFree(point, in: window, pageRoot: pageRoot)
        })
        #endif
        return (best.map(LibrarySectionRailReading.span) ?? .unavailable, configuration)
    }

    /// 点在这里落到本页自己的内容上(或者谁也接不住)就算空着;落到导航栏、标签栏这类系统的栏上,
    /// 或者落进竖排状态栏、摄像头的遮挡区,就算占用。
    private func isFree(_ point: CGPoint, in window: UIWindow, pageRoot: UIView) -> Bool {
        if inputs.occluded.contains(where: { $0.contains(point.y) }) { return false }
        guard let hit = window.hitTest(point, with: nil) else { return true }
        guard hit.isDescendant(of: pageRoot) else { return false }
        var view: UIView? = hit
        while let current = view, current !== pageRoot {
            if current is UINavigationBar || current is UITabBar || current is UIToolbar { return false }
            view = current.superview
        }
        return true
    }

    /// 沿响应链往上第一个视图控制器。它的视图是这一页的根视图:导航栏、标签栏不在它里面。
    private func owningController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// 这一页在导航栈里的那一格(`controller` 可能还套在别的容器里)。
    private func stackPage(of controller: UIViewController) -> UIViewController {
        var current = controller
        while let parent = current.parent, !(parent is UINavigationController) {
            current = parent
        }
        return current
    }

    /// 这一页所在的导航栈正在推入或返回(含交互式返回)时的过渡。弹出面板、菜单这类别处的过渡不算。
    private func navigationTransition(of page: UIViewController) -> UIViewControllerTransitionCoordinator? {
        guard let navigation = page.navigationController,
              let coordinator = page.transitionCoordinator ?? navigation.transitionCoordinator else { return nil }
        let stack = navigation.viewControllers
        let involved = [UITransitionContextViewControllerKey.from, .to].contains { key in
            guard let controller = coordinator.viewController(forKey: key) else { return false }
            return controller.parent === navigation || stack.contains { $0 === controller }
        }
        return involved ? coordinator : nil
    }
}

#if DEBUG
/// 取证:`PRIMUSE_DEBUG_RAIL_PROBE=1` 时把量到的空当、竖栏中线上每 20 点落到的视图,
/// 以及过渡、读数定下来这些时刻写进日志。
@MainActor
enum LibrarySectionRailDebug {
    private static let isEnabled = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_RAIL_PROBE"] == "1"
    private static var lastLine = ""

    static func event(_ message: String) {
        guard isEnabled else { return }
        plog("🧪 LibrarySectionRail " + message)
    }

    static func logProbe(
        window: UIWindow,
        x: CGFloat,
        pageRoot: UIView,
        best: LibrarySectionRailSpan?,
        isFree: (CGPoint) -> Bool
    ) {
        guard isEnabled else { return }
        var marks: [String] = []
        var y = window.bounds.minY
        while y <= window.bounds.maxY {
            let point = CGPoint(x: x, y: y)
            let hit = window.hitTest(point, with: nil).map { String(describing: type(of: $0)) } ?? "nil"
            marks.append("\(Int(y)):\(isFree(point) ? "free" : "busy"):\(hit)")
            y += 20
        }
        let line = "🧪 LibrarySectionRail x=\(Int(x)) span=\(best.map { "\(Int($0.minY))-\(Int($0.maxY))" } ?? "nil") root=\(type(of: pageRoot)) " + marks.joined(separator: " ")
        guard line != lastLine else { return }
        lastLine = line
        plog(line)
    }
}
#endif
#endif
