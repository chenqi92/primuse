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

/// 竖栏里放不放得下分类。量出来放不下(外屏横握这种矮的竖栏)时,资料库照旧在顶上摆一排页签。
/// 换分类时新页上的竖排分类先用上一页量好的位置,不等重新量完才出来。
@MainActor
@Observable
final class LibrarySectionRailState {
    static let shared = LibrarySectionRailState()

    /// 最近一次量到的空当;nil 是还没量过。
    private(set) var span: LibrarySectionRailSpan?
    /// 量过而且空当不够。没量过时按放得下算,免得顶上的页签先闪出来一下。
    private(set) var doesNotFit = false
    /// 系统竖栏里那一列胶囊的中线离竖栏外缘多远(对着前置摄像头的中心)。遮挡区偶尔一拍读不到,
    /// 记住上次的,分类不会左右跳。
    var columnCenterInset: CGFloat?

    static let minimumHeight: CGFloat = 88

    func update(_ measured: LibrarySectionRailSpan?) {
        let fits = (measured?.height ?? 0) >= Self.minimumHeight
        if doesNotFit == fits { doesNotFit = !fits }
        let next = fits ? measured : nil
        if span != next { span = next }
    }
}

/// iPhone Duo 竖栏时的资料库分类:竖着排在系统竖栏中间那段空当里(返回键与页面按钮下面、底部标签栏上面)。
///
/// 空当在哪里每页都不一样(页面按钮有几颗)、开合转屏也会变,系统又不报竖栏里那些玻璃胶囊的位置,
/// 所以按点按命中去量:沿竖栏中线逐点问窗口「点在这里会落到谁身上」,落到本页自己的内容上就是空着的,
/// 落到别处就是系统的胶囊;竖排状态栏与摄像头那一块按遮挡区算占用。分类多、空当矮时就在那一段里上下滑,
/// 当前分类滚到中间。
struct LibrarySectionRail: View {
    let sections: [LibrarySection]
    let selection: LibrarySection?
    let edge: HorizontalEdge
    let onSelect: (LibrarySection) -> Void

    private let state = LibrarySectionRailState.shared
    private static let itemHeight: CGFloat = 36
    /// 和系统竖栏里返回、「⋯」、标签栏那几个玻璃胶囊一样宽。
    private static let columnWidth: CGFloat = 49
    /// 和系统胶囊之间留的空,跟系统胶囊彼此之间的间距一样。
    private static let gap: CGFloat = 12

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
            ZStack(alignment: .topLeading) {
                LibrarySectionRailProbe(edge: edge, occluded: occluded) { state.update($0) }
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let span = state.span {
                    let width = min(span.barWidth - 8, Self.columnWidth)
                    let content = CGFloat(sections.count) * Self.itemHeight + 12
                    let height = min(content, span.height - Self.gap * 2)
                    let side: Edge.Set = edge == .trailing ? .trailing : .leading
                    let centerInset = cameraInset ?? state.columnCenterInset ?? span.barWidth / 2
                    // 按竖栏所在的那一侧对齐,不写死横坐标:从右往左排版时前后两侧跟着系统对调。
                    column(width: width, height: height, scrolls: content > height)
                        .padding(side, max(0, centerInset - width / 2))
                        .frame(maxWidth: .infinity, alignment: edge == .trailing ? .trailing : .leading)
                        .padding(.top, span.minY - frame.minY + (span.height - height) / 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .onChange(of: cameraInset, initial: true) { _, inset in
                if let inset { state.columnCenterInset = inset }
            }
        }
        .ignoresSafeArea()
    }

    private func column(width: CGFloat, height: CGFloat, scrolls: Bool) -> some View {
        ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(sections) { section in
                        item(section, width: width)
                            .id(section)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(!scrolls)
            .onAppear {
                guard let selection else { return }
                reader.scrollTo(selection, anchor: .center)
            }
            .onChange(of: selection) { _, next in
                guard let next else { return }
                pmWithAnimation(.selection) { reader.scrollTo(next, anchor: .center) }
            }
            // 先按上一页量的空当排好、这一页量完变矮时,滚动位置还停在高的那一档:重新把当前分类滚到中间。
            .onChange(of: height) { _, _ in
                guard let selection else { return }
                reader.scrollTo(selection, anchor: .center)
            }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
        .modifier(LibrarySectionRailSurface())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library.sectionRail")
    }

    private func item(_ section: LibrarySection, width: CGFloat) -> some View {
        let isSelected = section == selection
        return Button {
            onSelect(section)
        } label: {
            Text(section.title)
                .font(.caption.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.72))
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 3)
                .frame(width: width, height: Self.itemHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("library.sectionRail." + section.rawValue)
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
    let edge: HorizontalEdge
    let occluded: [ClosedRange<CGFloat>]
    let onMeasure: @MainActor (LibrarySectionRailSpan?) -> Void

    func makeUIView(context: Context) -> LibrarySectionRailProbeView {
        LibrarySectionRailProbeView()
    }

    func updateUIView(_ view: LibrarySectionRailProbeView, context: Context) {
        view.edge = edge
        view.occluded = occluded
        view.onMeasure = onMeasure
        view.setNeedsMeasure()
    }
}

/// 量竖栏空当的那个看不见的视图。挂进窗口后量一次,之后每秒复查一次(页面按钮会随多选、编辑进出),
/// 离开窗口就停。一次沿竖栏中线问一两百个点,只在结果变了时才报给界面。
final class LibrarySectionRailProbeView: UIView {
    var edge: HorizontalEdge = .trailing
    var occluded: [ClosedRange<CGFloat>] = []
    var onMeasure: (@MainActor (LibrarySectionRailSpan?) -> Void)?
    private var timer: Timer?
    private var lastReported: LibrarySectionRailSpan??
    private var pendingMeasure = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        setNeedsMeasure()
        // 系统竖栏里的按钮在页面出现后才排好,稍后再补量一次。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.measure()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.measure() }
        }
    }

    func setNeedsMeasure() {
        guard !pendingMeasure else { return }
        pendingMeasure = true
        Task { @MainActor [weak self] in
            self?.pendingMeasure = false
            self?.measure()
        }
    }

    private func measure() {
        guard let window, let pageRoot = owningPageView() else { return }
        let insets = window.safeAreaInsets
        let isRightToLeft = window.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let onRight = (edge == .trailing) != isRightToLeft
        let barWidth = onRight ? insets.right : insets.left
        guard barWidth > 40 else {
            report(nil)
            return
        }
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
        report(best)
    }

    private func report(_ span: LibrarySectionRailSpan?) {
        if let lastReported, lastReported == span { return }
        lastReported = .some(span)
        onMeasure?(span)
    }

    /// 点在这里落到本页自己的内容上(或者谁也接不住)就算空着;落到导航栏、标签栏这类系统的栏上,
    /// 或者落进竖排状态栏、摄像头的遮挡区,就算占用。
    private func isFree(_ point: CGPoint, in window: UIWindow, pageRoot: UIView) -> Bool {
        if occluded.contains(where: { $0.contains(point.y) }) { return false }
        guard let hit = window.hitTest(point, with: nil) else { return true }
        guard hit.isDescendant(of: pageRoot) else { return false }
        var view: UIView? = hit
        while let current = view, current !== pageRoot {
            if current is UINavigationBar || current is UITabBar || current is UIToolbar { return false }
            view = current.superview
        }
        return true
    }

    /// 这一页的根视图:沿响应链往上第一个视图控制器的视图。导航栏、标签栏不在它里面。
    private func owningPageView() -> UIView? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller.view }
            responder = current.next
        }
        return nil
    }
}

#if DEBUG
/// 取证:`PRIMUSE_DEBUG_RAIL_PROBE=1` 时把量到的空当与竖栏中线上每 20 点落到的视图写进日志。
@MainActor
enum LibrarySectionRailDebug {
    private static let isEnabled = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_RAIL_PROBE"] == "1"
    private static var lastLine = ""

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
