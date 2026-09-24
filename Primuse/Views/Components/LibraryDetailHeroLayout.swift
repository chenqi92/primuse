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

/// 详情页头部「封面 + 标题块」那一段的排法。
///
/// 封面边长要等标题块排完才知道：先按宽度量出标题块多高，再用剩下的预算定封面
/// （`LibraryDetailArtworkStack.resolvedExtent`），一次排版就定下来，不经过状态、不会来回跳。
/// 第一个子视图是封面槽（`LibraryDetailArtworkSlot`），第二个是标题块。
struct LibraryDetailArtworkStackLayout: Layout {
    var stack: LibraryDetailArtworkStack
    /// 封面宽 / 高。专辑封面是 1，风格页马赛克是 1.9 / 1.3。
    var aspectRatio: CGFloat = 1

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
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + metrics.extent + CGFloat(stack.spacing)),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: metrics.width, height: metrics.identityHeight)
        )
    }

    private struct Metrics {
        var width: CGFloat
        var height: CGFloat
        var extent: CGFloat
        var artworkWidth: CGFloat
        var identityHeight: CGFloat
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
        return Metrics(
            width: width,
            height: extent + spacing + identityHeight,
            extent: extent,
            artworkWidth: extent * aspectRatio,
            identityHeight: identityHeight
        )
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
/// 切换只换排法，按钮还是那几个视图。
struct LibraryDetailActionRow<Content: View>: View {
    let arrangement: LibraryDetailActionRowArrangement
    @ViewBuilder let content: Content

    var body: some View {
        let layout = arrangement == .singleRow
            ? AnyLayout(HStackLayout(spacing: CGFloat(LibraryDetailHeroLayoutPolicy.actionRowSpacing)))
            : AnyLayout(LibraryDetailTwoRowActionLayout())
        layout { content }
            .frame(maxWidth: .infinity)
    }
}

extension LibraryDetailActionRowArrangement {
    /// 播放胶囊的最大宽度：一行时 220，两行时通栏。
    var primaryMaxWidth: CGFloat {
        self == .singleRow ? 220 : .infinity
    }
}
#endif
