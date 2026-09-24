#if os(iOS)
import PrimuseKit
import SwiftUI

extension LibraryDetailTypeSize {
    init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .xSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .xLarge
        case .xxLarge: self = .xxLarge
        case .xxxLarge: self = .xxxLarge
        case .accessibility1: self = .accessibility1
        case .accessibility2: self = .accessibility2
        case .accessibility3: self = .accessibility3
        case .accessibility4: self = .accessibility4
        case .accessibility5: self = .accessibility5
        @unknown default: self = .large
        }
    }
}

/// 详情页头部「封面 + 标题块（+ 操作行）」那一段的竖屏排法。
///
/// 封面边长要等标题块排完才知道：先按宽度量出标题块多高，再用剩下的预算定封面
/// （`LibraryDetailArtworkStack.resolvedExtent`），一次排版就定下来，不经过状态、不会来回跳。
/// 第一个子视图是封面槽（`LibraryDetailArtworkSlot`），第二个是标题块，第三个（可选）是操作行，
/// 排在标题块下面 `actionsSpacing` 处、占满整宽 —— 手机横屏换成 `LibraryDetailCompactHeroLayout`，
/// 经 `AnyLayout` 互换时三件视图的身份不变。
struct LibraryDetailArtworkStackLayout: Layout {
    var stack: LibraryDetailArtworkStack
    /// 封面宽 / 高。专辑封面是 1，风格页马赛克是 1.9 / 1.3。
    var aspectRatio: CGFloat = 1
    /// 操作行（第三个子视图）与标题块之间的间距。
    var actionsSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let metrics = measure(proposal: proposal, subviews: subviews)
        return CGSize(width: metrics.width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measure(proposal: ProposedViewSize(width: bounds.width, height: bounds.height), subviews: subviews)
        guard let artwork = subviews.first else { return }
        artwork.place(
            at: CGPoint(x: bounds.midX, y: bounds.minY),
            anchor: .top,
            proposal: ProposedViewSize(width: metrics.artworkWidth, height: metrics.extent)
        )
        guard subviews.count > 1 else { return }
        let identityTop = bounds.minY + metrics.extent + CGFloat(stack.spacing)
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: identityTop),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: metrics.width, height: metrics.identityHeight)
        )
        guard subviews.count > 2 else { return }
        subviews[2].place(
            at: CGPoint(x: bounds.minX, y: identityTop + metrics.identityHeight + actionsSpacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: metrics.width, height: metrics.actionsHeight)
        )
    }

    private struct Metrics {
        var width: CGFloat
        var height: CGFloat
        var extent: CGFloat
        var artworkWidth: CGFloat
        var identityHeight: CGFloat
        var actionsHeight: CGFloat
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews) -> Metrics {
        let identity = subviews.count > 1 ? subviews[1] : nil
        let width = proposal.width
            ?? max(CGFloat(stack.ideal) * aspectRatio, identity?.sizeThatFits(.unspecified).width ?? 0)
        let identityHeight = identity?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        var extent = CGFloat(stack.resolvedExtent(identityHeight: Double(identityHeight)))
        // 宽度也卡得住封面：马赛克这种横长的，窄屏上以宽度为准。
        if extent * aspectRatio > width, aspectRatio > 0 {
            extent = (width / aspectRatio).rounded(.down)
        }
        let spacing = identity == nil ? 0 : CGFloat(stack.spacing)
        let actionsHeight = subviews.count > 2
            ? subviews[2].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            : 0
        let actionsBlock = subviews.count > 2 ? actionsSpacing + actionsHeight : 0
        return Metrics(
            width: width,
            height: extent + spacing + identityHeight + actionsBlock,
            extent: extent,
            artworkWidth: extent * aspectRatio,
            identityHeight: identityHeight,
            actionsHeight: actionsHeight
        )
    }
}

/// 手机横屏（紧凑高度）头部的排法：封面在前，标题块与操作行在右栏（`.besideArtwork`，
/// 操作行在标题块下面、靠前对齐），或者三件排成一行（`.inline`，操作行靠后）。
///
/// 子视图与竖屏的 `LibraryDetailArtworkStackLayout` 一致：封面槽、标题块、操作行（可选）。
/// 封面尺寸由 `LibraryDetailHeroLayoutPolicy` 按首屏定，右栏按封面竖向居中。
struct LibraryDetailCompactHeroLayout: Layout {
    var style: LibraryDetailCompactHeaderStyle
    /// 封面高度（风格马赛克是高度，宽度按比例）。
    var artworkHeight: CGFloat
    var aspectRatio: CGFloat = 1
    /// 封面与右栏之间的横向间距。
    var spacing: CGFloat = CGFloat(LibraryDetailHeroLayoutPolicy.Compact.artworkToColumn)
    /// 右栏里标题块与操作行之间。
    var identityToActions: CGFloat = CGFloat(LibraryDetailHeroLayoutPolicy.Compact.identityToActions)
    /// 排成一行时操作行最多占多宽。
    var inlineActionsMaxWidth: CGFloat = 320

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (artworkHeight * aspectRatio + spacing + 420)
        let metrics = measure(width: width, subviews: subviews)
        return CGSize(width: width, height: metrics.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let metrics = measure(width: bounds.width, subviews: subviews)
        let artworkWidth = artworkHeight * aspectRatio
        subviews.first?.place(
            at: CGPoint(x: bounds.minX, y: bounds.midY),
            anchor: .leading,
            proposal: ProposedViewSize(width: artworkWidth, height: artworkHeight)
        )
        guard subviews.count > 1 else { return }
        let columnX = bounds.minX + artworkWidth + spacing
        switch style {
        case .besideArtwork:
            var y = bounds.midY - metrics.columnHeight / 2
            subviews[1].place(
                at: CGPoint(x: columnX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.columnWidth, height: metrics.identityHeight)
            )
            guard subviews.count > 2 else { return }
            y += metrics.identityHeight + identityToActions
            subviews[2].place(
                at: CGPoint(x: columnX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: metrics.columnWidth, height: metrics.actionsHeight)
            )
        case .inline:
            subviews[1].place(
                at: CGPoint(x: columnX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: metrics.identityWidth, height: metrics.identityHeight)
            )
            guard subviews.count > 2 else { return }
            subviews[2].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: metrics.actionsWidth, height: metrics.actionsHeight)
            )
        }
    }

    private struct Metrics {
        var height: CGFloat
        var columnWidth: CGFloat
        var columnHeight: CGFloat
        var identityWidth: CGFloat
        var identityHeight: CGFloat
        var actionsWidth: CGFloat
        var actionsHeight: CGFloat
    }

    private func measure(width: CGFloat, subviews: Subviews) -> Metrics {
        let columnWidth = max(0, width - artworkHeight * aspectRatio - spacing)
        let identity = subviews.count > 1 ? subviews[1] : nil
        let actions = subviews.count > 2 ? subviews[2] : nil
        switch style {
        case .besideArtwork:
            let identityHeight = identity?.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height ?? 0
            let actionsHeight = actions?.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height ?? 0
            let columnHeight = identityHeight + (actions == nil ? 0 : identityToActions + actionsHeight)
            return Metrics(
                height: max(artworkHeight, columnHeight),
                columnWidth: columnWidth,
                columnHeight: columnHeight,
                identityWidth: columnWidth,
                identityHeight: identityHeight,
                actionsWidth: columnWidth,
                actionsHeight: actionsHeight
            )
        case .inline:
            let actionsWidth = actions == nil ? 0 : min(columnWidth * 0.46, inlineActionsMaxWidth)
            let identityWidth = max(0, columnWidth - (actions == nil ? 0 : actionsWidth + spacing))
            let identityHeight = identity?.sizeThatFits(ProposedViewSize(width: identityWidth, height: nil)).height ?? 0
            let actionsHeight = actions?.sizeThatFits(ProposedViewSize(width: actionsWidth, height: nil)).height ?? 0
            return Metrics(
                height: max(artworkHeight, identityHeight, actionsHeight),
                columnWidth: columnWidth,
                columnHeight: max(identityHeight, actionsHeight),
                identityWidth: identityWidth,
                identityHeight: identityHeight,
                actionsWidth: actionsWidth,
                actionsHeight: actionsHeight
            )
        }
    }
}

extension LibraryDetailHeroLayout {
    /// 头部「封面 + 标题块 + 操作行」这一段的排法：竖屏（以及横屏的无障碍字号）叠成一列，手机横屏换成右栏或一行。
    /// 两种排法经 `AnyLayout` 互换，横竖切换不换视图。
    func artworkHeaderLayout(
        _ stack: LibraryDetailArtworkStack,
        aspectRatio: CGFloat = 1,
        actionsSpacing: CGFloat,
        stacksVertically: Bool
    ) -> AnyLayout {
        if stacksVertically || !isCompactHeight {
            return AnyLayout(LibraryDetailArtworkStackLayout(
                stack: stack,
                aspectRatio: aspectRatio,
                actionsSpacing: actionsSpacing
            ))
        }
        return AnyLayout(LibraryDetailCompactHeroLayout(
            style: compactStyle ?? .besideArtwork,
            artworkHeight: CGFloat(stack.ideal),
            aspectRatio: aspectRatio
        ))
    }

    /// 标题块与操作行靠前对齐（手机横屏右栏 / 一行）还是居中（竖屏一列）。
    func stacksArtworkHeader(accessibilityType: Bool) -> Bool {
        !isCompactHeight || accessibilityType
    }
}

/// 封面槽：尺寸由外面的排法给，里面的封面拿到最终边长再画 —— 封面视图按边长取缩略图。
struct LibraryDetailArtworkSlot<Artwork: View>: View {
    private let artwork: (CGSize) -> Artwork

    init(@ViewBuilder artwork: @escaping (CGSize) -> Artwork) {
        self.artwork = artwork
    }

    var body: some View {
        Color.clear
            .overlay(alignment: .topLeading) {
                GeometryReader { proxy in
                    artwork(proxy.size)
                }
            }
    }
}

/// 两行排的操作行：播放胶囊独占第一行，其余圆钮在第二行居中。
///
/// 一行排时用系统的 `HStackLayout`，经 `AnyLayout` 与这里互换，子视图身份不变。
struct LibraryDetailTwoRowActionLayout: Layout {
    var lineSpacing: CGFloat = CGFloat(LibraryDetailHeroLayoutPolicy.actionRowLineSpacing)
    var spacing: CGFloat = 24

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let parts = split(subviews)
        let secondarySizes = parts.secondary.map { $0.sizeThatFits(.unspecified) }
        let secondaryWidth = secondarySizes.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(0, secondarySizes.count - 1))
        let width = proposal.width ?? max(secondaryWidth, 220)
        let primaryHeight = parts.primary?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        let secondaryHeight = secondarySizes.map(\.height).max() ?? 0
        let gap = parts.primary != nil && !secondarySizes.isEmpty ? lineSpacing : 0
        return CGSize(width: width, height: primaryHeight + gap + secondaryHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let parts = split(subviews)
        var y = bounds.minY
        if let primary = parts.primary {
            let height = primary.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            primary.place(
                at: CGPoint(x: bounds.minX, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
            y += height + lineSpacing
        }
        let sizes = parts.secondary.map { $0.sizeThatFits(.unspecified) }
        let total = sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
        let rowHeight = sizes.map(\.height).max() ?? 0
        var x = bounds.midX - total / 2
        for (subview, size) in zip(parts.secondary, sizes) {
            subview.place(
                at: CGPoint(x: x, y: y + rowHeight / 2),
                anchor: .leading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
        }
    }

    private func split(_ subviews: Subviews) -> (primary: LayoutSubview?, secondary: [LayoutSubview]) {
        let primary = subviews.first { $0[LibraryDetailPrimaryActionKey.self] }
        return (primary, subviews.filter { !$0[LibraryDetailPrimaryActionKey.self] })
    }
}

private struct LibraryDetailPrimaryActionKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// 标记操作行里的播放胶囊：两行排时它独占第一行。
    func libraryDetailPrimaryAction() -> some View {
        layoutValue(key: LibraryDetailPrimaryActionKey.self, value: true)
    }
}

/// 「随机 · 播放 · 下载」这一排。一行时两颗圆钮夹着宽度至多 220 的胶囊；两行时胶囊通栏、圆钮在下一行。
/// 切换只换排法，按钮还是那几个视图。手机横屏排在封面右栏时靠前对齐。
struct LibraryDetailActionRow<Content: View>: View {
    let arrangement: LibraryDetailActionRowArrangement
    var alignment: Alignment = .center
    @ViewBuilder let content: Content

    var body: some View {
        let layout = arrangement == .singleRow
            ? AnyLayout(HStackLayout(spacing: CGFloat(LibraryDetailHeroLayoutPolicy.actionRowSpacing)))
            : AnyLayout(LibraryDetailTwoRowActionLayout())
        layout { content }
            .frame(maxWidth: .infinity, alignment: alignment)
    }
}

// MARK: - 跟着滚动的头图

/// 详情页头部的坐标空间。头部根视图挂上它，里面的封面、海报据此算出头部被拉开或滚走了多少，
/// 大标题据此报告自己的位置。
enum LibraryDetailHeroSpace {
    static let name = "primuse.libraryDetailHero"
}

/// 头图跟着滚动的两种动法。
enum LibraryDetailHeroMotionStyle: Sendable, Equatable {
    /// 铺满整幅的海报与封面墙：下拉时上沿钉住、往下拉长，上滚时半速跟随。
    case poster
    /// 浮在底色上的封面：只在下拉时从下沿往上放大。
    case artwork
}

extension View {
    /// 头图的拉伸与视差。只动变换，不改布局尺寸；开了「减弱动态效果」就不动。
    func libraryDetailHeroMotion(_ style: LibraryDetailHeroMotionStyle) -> some View {
        modifier(LibraryDetailHeroMotionModifier(style: style))
    }

    /// 只裁掉下沿以外的部分：海报下拉时要能长出上沿，上滚跟随时不能漏到正文里。
    func libraryDetailClipBottomEdge() -> some View {
        mask(alignment: .bottom) {
            Rectangle().padding(.top, -4000)
        }
    }

    /// 头图里那行大标题。它滚到导航栏下面之后，导航栏里淡入同名的小标题。
    func libraryDetailHeroTitle() -> some View {
        modifier(LibraryDetailHeroTitleMarker())
    }
}

private struct LibraryDetailHeroMotionModifier: ViewModifier {
    let style: LibraryDetailHeroMotionStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let enabled = !reduceMotion
        let style = style
        content.visualEffect { effect, proxy in
            // 头部在滚动视图里的位置减去自己在头部里的位置，就是头部离静止处被拉开（正）或滚走（负）了多少。
            let pull = enabled
                ? proxy.frame(in: .scrollView(axis: .vertical)).minY
                    - proxy.frame(in: .named(LibraryDetailHeroSpace.name)).minY
                : 0
            let height = Double(proxy.size.height)
            let transform = style == .poster
                ? LibraryDetailHeroMotionPolicy.poster(pull: Double(pull), height: height)
                : LibraryDetailHeroMotionPolicy.artwork(pull: Double(pull), extent: height)
            return effect
                .scaleEffect(CGFloat(transform.scale), anchor: style == .poster ? .top : .bottom)
                .offset(y: CGFloat(transform.offsetY))
        }
    }
}

private struct LibraryDetailHeroTitleReporterKey: EnvironmentKey {
    static let defaultValue: (@MainActor (CGFloat) -> Void)? = nil
}

private struct LibraryDetailHeroTopInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 大标题在头部里的下沿位置交给谁。详情页的滚动容器挂上，别处为空。
    var libraryDetailHeroTitleReporter: (@MainActor (CGFloat) -> Void)? {
        get { self[LibraryDetailHeroTitleReporterKey.self] }
        set { self[LibraryDetailHeroTitleReporterKey.self] = newValue }
    }

    /// 导航栏下沿在滚动视图里的位置（顶部安全区）。大标题滑到这里之前淡出。
    var libraryDetailHeroTopInset: CGFloat {
        get { self[LibraryDetailHeroTopInsetKey.self] }
        set { self[LibraryDetailHeroTopInsetKey.self] = newValue }
    }
}

/// 大标题离导航栏下沿还剩多少点时开始淡出。导航栏里的小标题在它淡到两成时出现（见滚动容器里的阈值）。
let libraryDetailHeroTitleFadeDistance: CGFloat = 20

private struct LibraryDetailHeroTitleMarker: ViewModifier {
    @Environment(\.libraryDetailHeroTitleReporter) private var report
    @Environment(\.libraryDetailHeroTopInset) private var topInset

    func body(content: Content) -> some View {
        let fadeLine = topInset
        let fadeDistance = libraryDetailHeroTitleFadeDistance
        content
            // 滑到导航栏下面的最后一段里淡出，与导航栏里淡入的小标题交接，两行字不叠在一起。
            .visualEffect { effect, proxy in
                let bottom = proxy.frame(in: .scrollView(axis: .vertical)).maxY
                return effect.opacity(Double(min(1, max(0, (bottom - fadeLine) / fadeDistance))))
            }
            // 量的是它在头部坐标里的位置，滚动时不变，只在排版变了（换字号、转屏）时才回报。
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.frame(in: .named(LibraryDetailHeroSpace.name)).maxY
            } action: { maxY in
                report?(maxY)
            }
    }
}

/// 导航栏中间那行小标题。放在导航栏条目里，只收值，不读模型类环境。
struct LibraryDetailInlineTitle: View {
    let title: String
    let isVisible: Bool
    let onArtwork: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.headline)
            .foregroundStyle(onArtwork ? Color.white : Color.primary)
            .lineLimit(1)
            .opacity(isVisible ? 1 : 0)
            .pmAnimation(.contentAppear, value: isVisible)
            .accessibilityHidden(!isVisible)
    }
}

// MARK: - iOS 26 的玻璃导航区

extension View {
    /// 海报延伸到玻璃导航区与屏幕两侧(iOS 26 起)。更早的系统原样返回。
    @ViewBuilder
    func libraryDetailBackgroundExtension() -> some View {
        if #available(iOS 26.0, *) {
            backgroundExtensionEffect()
        } else {
            self
        }
    }

    /// 正文滚到顶部玻璃圆钮下面时柔化(iOS 26 起)。更早的系统原样返回。
    @ViewBuilder
    func libraryDetailSoftTopEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

extension LibraryDetailActionRowArrangement {
    /// 播放胶囊的最大宽度：一行时 220，两行时通栏。
    var primaryMaxWidth: CGFloat {
        self == .singleRow ? 220 : .infinity
    }
}
#endif
