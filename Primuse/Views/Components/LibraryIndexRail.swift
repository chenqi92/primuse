#if os(iOS) || os(macOS)
import SwiftUI
import PrimuseKit

/// 列表当前滚到哪个字母。只有字母条读它：滚动时只重画字母条，不重建列表。
@MainActor
@Observable
final class LibraryIndexRailTracker {
    private(set) var currentLabel: String?
    /// 最近一次露在最上面的那一项（歌曲页是第几行，专辑、艺人页是那一行的第一项）。列表换了一份时
    /// 拿它重新认当前字母：露出的行没变时系统不会再报一次。
    @ObservationIgnored var lastTopPosition: Int?

    func update(_ label: String?) {
        guard label != currentLabel else { return }
        currentLabel = label
    }
}

/// 资料库页右缘的字母条，歌曲、专辑、艺人三页共用。
///
/// 静止时字母用次要色，当前所在的字母点亮、垫一个淡色圆点，没有内容的字母更淡。按下或拖动时
/// 字母条垫上一层材质，手指附近的字母放大，左边浮出一张卡片：大字母、这一段的前几张封面
/// （或头像，由 `preview` 给）和数量。滑到有内容的字母轻震一下，并立即跳过去。
struct LibraryIndexRail<Preview: View>: View {
    let entries: [LibraryIndexRailEntry]
    let tracker: LibraryIndexRailTracker
    /// 字母条可按的宽度（从容器右缘算起）。列表行尾、网格右侧要让出这么宽。
    var hitWidth: CGFloat = LibraryIndexRailMetrics.gridHitWidth
    /// 卡片上的数量文字，如「42 张专辑」。
    let countText: (Int) -> String
    @ViewBuilder let preview: (LibraryIndexRailEntry) -> Preview
    let onSelect: (LibraryIndexRailEntry) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var focusedIndex: Int?
    /// 手指在字母条坐标里的高度（0 是第一个字母的上沿）。
    @State private var touchY: CGFloat?
    @State private var lastTarget: Int?
    @State private var hapticTrigger = 0

    private struct Metrics {
        let itemHeight: CGFloat
        let railHeight: CGFloat
        let top: CGFloat
        let fontSize: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = metrics(for: geometry.size)
            ZStack(alignment: .topTrailing) {
                railLayer(metrics: metrics)
                touchArea(metrics: metrics)
                if let focusedIndex, entries.indices.contains(focusedIndex) {
                    let cardWidth = max(0, geometry.size.width - hitWidth - 6)
                    LibraryIndexRailCard(
                        entry: entries[focusedIndex],
                        countText: countText,
                        preview: preview
                    )
                    .frame(width: cardWidth, alignment: .trailing)
                    .position(
                        x: cardWidth / 2,
                        y: cardCenterY(metrics: metrics, containerHeight: geometry.size.height)
                    )
                    .transition(.scale(scale: 0.86, anchor: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            #if DEBUG
            .task(id: geometry.size.height) {
                await focusForScreenshotIfRequested(itemHeight: metrics.itemHeight)
            }
            #endif
        }
        .sensoryFeedback(.selection, trigger: hapticTrigger)
        .accessibilityRepresentation {
            VStack(spacing: 0) {
                ForEach(entries.filter(\.hasItems)) { entry in
                    Button {
                        onSelect(entry)
                    } label: {
                        Text(verbatim: entry.label)
                    }
                }
            }
        }
        .onChange(of: entries) { _, _ in
            clearFocus()
        }
    }

    /// 字母、当前字母的圆点和拖动时的底，只画不接触摸。
    private func railLayer(metrics: Metrics) -> some View {
        let highlighted = highlightedIndex
        let isDragging = focusedIndex != nil
        let dotSize = isDragging ? min(metrics.itemHeight + 5, 21) : min(metrics.itemHeight + 3, 19)
        return ZStack(alignment: .top) {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5)
                }
                .frame(width: LibraryIndexRailMetrics.railWidth + 2, height: metrics.railHeight + 10)
                .offset(y: -5)
                .opacity(isDragging ? 1 : 0)

            if let highlighted {
                Circle()
                    .fill(isDragging ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.accentColor.opacity(0.16)))
                    .frame(width: dotSize, height: dotSize)
                    .offset(y: (CGFloat(highlighted) + 0.5) * metrics.itemHeight - dotSize / 2)
            }

            VStack(spacing: 0) {
                ForEach(entries.indices, id: \.self) { index in
                    Text(verbatim: entries[index].label)
                        .font(.system(size: metrics.fontSize, weight: index == highlighted ? .heavy : .semibold, design: .rounded))
                        .foregroundStyle(letterStyle(index: index, highlighted: highlighted, isDragging: isDragging))
                        .frame(maxWidth: .infinity)
                        .frame(height: metrics.itemHeight)
                        .scaleEffect(scale(for: index, itemHeight: metrics.itemHeight))
                }
            }
        }
        .frame(width: LibraryIndexRailMetrics.railWidth, height: metrics.railHeight, alignment: .top)
        .padding(.trailing, LibraryIndexRailMetrics.railTrailing)
        .offset(y: metrics.top)
        .animation(isDragging || reduceMotion ? nil : .snappy(duration: 0.24), value: highlighted)
        .animation(focusAnimation, value: isDragging)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func touchArea(metrics: Metrics) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .frame(width: hitWidth, height: metrics.railHeight + LibraryIndexRailMetrics.touchSlop * 2)
            // 被系统接走（拉通知中心、来电）时没有结束回调，卡片和放大的字母会一直挂着。
            .pmGesture(dragGesture(metrics: metrics), onCancel: clearFocus)
            .offset(y: metrics.top - LibraryIndexRailMetrics.touchSlop)
    }

    private var highlightedIndex: Int? {
        if let focusedIndex { return focusedIndex }
        guard let label = tracker.currentLabel else { return nil }
        return entries.firstIndex { $0.label == label }
    }

    private func letterStyle(index: Int, highlighted: Int?, isDragging: Bool) -> AnyShapeStyle {
        if index == highlighted {
            return isDragging ? AnyShapeStyle(.textOnAccent) : AnyShapeStyle(Color.accentColor)
        }
        return entries[index].hasItems ? AnyShapeStyle(.secondary) : AnyShapeStyle(.quaternary)
    }

    private func dragGesture(metrics: Metrics) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let railY = value.location.y - LibraryIndexRailMetrics.touchSlop
                guard let index = SongListSectionIndexHitTesting.index(
                    at: Double(railY),
                    railOriginY: 0,
                    railHeight: Double(metrics.railHeight),
                    entryCount: entries.count
                ) else { return }
                touchY = min(max(railY, 0), metrics.railHeight)
                focus(on: index)
            }
            .onEnded { _ in
                clearFocus()
            }
    }

    private func focus(on index: Int) {
        guard entries.indices.contains(index), focusedIndex != index else { return }
        // 卡片出现的这一次走和收起同一条曲线；拖动中换字母要跟手，那些帧裸赋值。
        if focusedIndex == nil {
            withAnimation(focusAnimation) { focusedIndex = index }
        } else {
            focusedIndex = index
        }
        let entry = entries[index]
        // 只在有内容的字母上震：手指滑过一串空字母时不会一路震下去。
        if entry.hasItems { hapticTrigger &+= 1 }
        // 连着几个空字母都跳到同一段，不重复发同一个跳转。
        guard lastTarget != entry.target else { return }
        lastTarget = entry.target
        onSelect(entry)
    }

    private func clearFocus() {
        lastTarget = nil
        withAnimation(focusAnimation) {
            focusedIndex = nil
            touchY = nil
        }
    }

    private var focusAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.2, extraBounce: 0.06)
    }

    #if DEBUG
    /// 截图钩子：`PRIMUSE_DEBUG_INDEX_RAIL_FOCUS=<字母>` 页面出来两秒后按住字母条上的这个字母不放，
    /// 看浮出的卡片、放大的字母和跳转落点。
    private func focusForScreenshotIfRequested(itemHeight: CGFloat) async {
        guard let label = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_INDEX_RAIL_FOCUS"]?.uppercased(),
              let index = entries.firstIndex(where: { $0.label == label }) else { return }
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        touchY = (CGFloat(index) + 0.5) * itemHeight
        focus(on: index)
    }
    #endif

    /// 手指附近的字母放大，往外两格半渐弱。
    private func scale(for index: Int, itemHeight: CGFloat) -> CGFloat {
        guard let touchY, itemHeight > 0 else { return 1 }
        let center = (CGFloat(index) + 0.5) * itemHeight
        let distance = abs(center - touchY) / itemHeight
        let proximity = max(0, 1 - distance / 2.5)
        return 1 + 0.4 * proximity * proximity
    }

    private func cardCenterY(metrics: Metrics, containerHeight: CGFloat) -> CGFloat {
        let fingerY = metrics.top + (touchY ?? 0)
        let half = LibraryIndexRailMetrics.cardHalfHeight
        return min(max(fingerY, half + 4), max(half + 4, containerHeight - half - 4))
    }

    /// 字母之间的间距有上限，整条在可视区里竖直居中；矮的时候（横屏）压到填满。
    private func metrics(for size: CGSize) -> Metrics {
        let margin: CGFloat = size.height >= 480 ? 14 : 6
        let available = max(0, size.height - margin * 2)
        let count = CGFloat(max(entries.count, 1))
        let itemHeight = min(LibraryIndexRailMetrics.maxItemHeight, available / count)
        let railHeight = itemHeight * count
        return Metrics(
            itemHeight: itemHeight,
            railHeight: railHeight,
            top: max(0, (size.height - railHeight) / 2),
            fontSize: min(11, max(7.5, itemHeight * 0.66))
        )
    }
}

enum LibraryIndexRailMetrics {
    /// 字母那一列的宽度，和它离容器右缘的距离。
    static let railWidth: CGFloat = 20
    static let railTrailing: CGFloat = 4
    /// 网格、带头像的列表让给字母条的宽度：字母左边还留一道缝，按最右一列封面的边不会误跳。
    static let gridHitWidth: CGFloat = 28
    static let maxItemHeight: CGFloat = 17
    /// 字母条上下多给的可按范围，按在第一个、最后一个字母边上也算。
    static let touchSlop: CGFloat = 8
    static let cardHalfHeight: CGFloat = 40

    /// 系统竖栏在尾侧（iPhone Duo）时字母条往里让一段，拖动时手指不会滑到竖栏的按钮上。
    static func trailingInset(verticalBarEdge: HorizontalEdge?) -> CGFloat {
        verticalBarEdge == .trailing ? 10 : 2
    }
}

extension LibraryIndexRailEntry {
    /// 这一段开头的几项，给卡片里的封面、头像用。
    func previewItems<Item>(in items: [Item], limit: Int = 3) -> [Item] {
        let start = min(max(target, 0), items.count)
        return Array(items[start..<min(items.count, start + min(count, limit))])
    }
}

/// 拖动字母条时浮出的卡片：大字母，右边是这一段的前几张封面和数量。空字母只有一个淡的字母。
private struct LibraryIndexRailCard<Preview: View>: View {
    let entry: LibraryIndexRailEntry
    let countText: (Int) -> String
    let preview: (LibraryIndexRailEntry) -> Preview

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(spacing: 12) {
            Text(verbatim: entry.label)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(entry.hasItems ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(minWidth: 30)
            if entry.hasItems {
                VStack(alignment: .leading, spacing: 5) {
                    preview(entry)
                    Text(verbatim: countText(entry.count))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background { background(shape) }
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func background(_ shape: RoundedRectangle) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            // 压在彩色封面上：玻璃带一层底色，字母和数量才看得清。
            shape.fill(.clear).glassEffect(.regular.tint(libraryIndexCardTint), in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay { shape.strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }
}

/// 卡片里一段的前几张专辑封面，错开叠成一摞。
struct LibraryIndexAlbumStack: View {
    let albums: [Album]

    var body: some View {
        LibraryIndexStack(count: albums.count, side: 34) { index in
            AlbumArtworkView(album: albums[index], size: 34, cornerRadius: 7)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(libraryIndexStackSeparator, lineWidth: 1.5)
                }
        }
    }
}

/// 卡片里一段的前几位艺人头像，叠成一排圆。
struct LibraryIndexArtistStack: View {
    let artists: [Artist]

    var body: some View {
        LibraryIndexStack(count: artists.count, side: 34) { index in
            ArtistArtworkView(artist: artists[index], size: 34, cornerRadius: 17)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(libraryIndexStackSeparator, lineWidth: 1.5)
                }
        }
    }
}

/// 卡片玻璃的底色。
private var libraryIndexCardTint: Color {
    #if os(macOS)
    return Color(nsColor: .windowBackgroundColor).opacity(0.72)
    #else
    return Color(uiColor: .systemBackground).opacity(0.72)
    #endif
}

/// 叠在一起的封面之间的那道缝，和页面底色一样。
private var libraryIndexStackSeparator: Color {
    #if os(macOS)
    return Color(nsColor: .windowBackgroundColor).opacity(0.9)
    #else
    return Color(uiColor: .systemBackground).opacity(0.9)
    #endif
}

/// 从左往右错开叠放，左边的压在上面。
private struct LibraryIndexStack<Item: View>: View {
    let count: Int
    let side: CGFloat
    @ViewBuilder let item: (Int) -> Item

    private let step: CGFloat = 22

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(0..<count, id: \.self) { index in
                item(index)
                    .frame(width: side, height: side)
                    .offset(x: CGFloat(index) * step)
                    .zIndex(Double(count - index))
            }
        }
        .frame(width: side + CGFloat(max(count - 1, 0)) * step, height: side, alignment: .leading)
    }
}

/// 按名字排好的一页（专辑网格、艺人网格与列表）的版式：尾侧给字母条让多宽、一行多宽、摆几项。
struct LibraryIndexedLayout {
    /// 尾侧让给字母条的宽度；没有字母条时为 0。
    let railReserve: CGFloat
    let leadingPadding: CGFloat
    /// 行的尾侧留白：有字母条时就是让给它的宽度。
    let trailingPadding: CGFloat
    /// 去掉左右留白后一行的宽度。
    let rowWidth: CGFloat
    let columns: Int
    let columnSpacing: CGFloat

    /// 每格的宽度（列表是整行）。
    var cellWidth: CGFloat {
        max(0, (rowWidth - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    func rowCount(itemCount: Int) -> Int {
        (itemCount + columns - 1) / columns
    }

    func items(inRow row: Int, itemCount: Int) -> Range<Int> {
        let start = min(row * columns, itemCount)
        return start..<min(start + columns, itemCount)
    }
}

/// 和 `GridItem(.adaptive(minimum:), spacing:)` 一样的列数：一行尽量多放，每格不窄于下限。
enum LibraryIndexedGridColumns {
    static func count(rowWidth: CGFloat, minimumWidth: CGFloat, spacing: CGFloat) -> Int {
        guard minimumWidth > 0, rowWidth > 0 else { return 1 }
        return max(1, Int((rowWidth + spacing) / (minimumWidth + spacing)))
    }
}

/// 按名字排好的一页（专辑网格、艺人网格与列表）：滚动容器加右缘的字母条。
///
/// 网格也按行摆成懒加载栈（`content` 收到版式自己排）：`ForEach` 按行号（0、1、2…）认身份、一行一个
/// 子视图，挂 `.scrollTargetLayout()`，每行包一层 `LazyItemCell`。这样字母条按行号跳过去落点是准的
/// （`LazyVGrid` 远距离跳转按估算的行高落点，会差出一两行），露出的行号也能直接换算成当前字母。
struct LibraryIndexedScrollView<Content: View, Preview: View>: View {
    /// nil 或不到两个有内容的字母时不出字母条，滚动容器照旧。
    let model: LibraryIndexRailModel?
    /// 一行的宽度能摆几项；列表是 1。
    var columns: (CGFloat) -> Int = { _ in 1 }
    var leadingPadding: CGFloat = 16
    var trailingPadding: CGFloat = 16
    var columnSpacing: CGFloat = 16
    /// 没有字母条时最右一列伸进 iPhone Duo 的竖栏（`pmCoversExtendUnderVerticalBar()` 那样）。
    var extendsUnderVerticalBar = false
    let countText: (Int) -> String
    @ViewBuilder let preview: (LibraryIndexRailEntry) -> Preview
    @ViewBuilder let content: (LibraryIndexedLayout) -> Content

    @State private var tracker = LibraryIndexRailTracker()
    @State private var position = ScrollPosition(idType: Int.self)
    @State private var jump: LibraryIndexJump?
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.pmVerticalBarOverlap) private var verticalBarOverlap

    private var usefulModel: LibraryIndexRailModel? {
        guard let model, model.isUseful else { return nil }
        return model
    }

    private var trailingInset: CGFloat {
        LibraryIndexRailMetrics.trailingInset(verticalBarEdge: verticalBarEdge)
    }

    private func makeLayout(width: CGFloat, hasRail: Bool) -> LibraryIndexedLayout {
        let reserve = hasRail ? LibraryIndexRailMetrics.gridHitWidth + trailingInset : 0
        let trailing = hasRail ? reserve : trailingPadding
        // 没有字母条时最右一列伸进竖栏：行宽多出竖栏那么宽，尾侧留白照旧算在屏幕边上。
        let extra = !hasRail && extendsUnderVerticalBar ? verticalBarOverlap : 0
        let rowWidth = max(0, width - leadingPadding - trailing + extra)
        return LibraryIndexedLayout(
            railReserve: reserve,
            leadingPadding: leadingPadding,
            trailingPadding: trailing - extra,
            rowWidth: rowWidth,
            columns: max(1, columns(rowWidth)),
            columnSpacing: columnSpacing
        )
    }

    var body: some View {
        let railModel = usefulModel
        GeometryReader { geometry in
            let layout = makeLayout(width: geometry.size.width, hasRail: railModel != nil)
            ZStack(alignment: .trailing) {
                ScrollView {
                    content(layout)
                }
                // 锚点要挂在修饰符上：只给 `scrollTo(id:anchor:)` 时系统按「滚到刚好露出」处理，
                // 目标停在可视区底部，本来就露着的根本不动。
                .scrollPosition($position, anchor: .top)
                .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.5) { rows in
                    guard let top = rows.min() else { return }
                    tracker.lastTopPosition = top * layout.columns
                    tracker.update(railModel?.label(containing: top * layout.columns))
                }

                if let railModel {
                    LibraryIndexRail(
                        entries: railModel.entries,
                        tracker: tracker,
                        countText: countText,
                        preview: preview
                    ) { entry in
                        jump = LibraryIndexJump(row: entry.target / layout.columns)
                    }
                    .padding(.trailing, trailingInset)
                    .transition(.opacity)
                }
            }
            .onChange(of: layout.columns) { _, columns in
                // 转屏、分屏改了每行几项：行号对应的内容变了，回到刚才最上面那一项所在的行。
                guard let top = tracker.lastTopPosition else { return }
                position.scrollTo(id: top / columns, anchor: .top)
            }
        }
        .pmAnimation(.control, value: railModel == nil)
        .onChange(of: model.map(ObjectIdentifier.init)) { _, _ in
            // 换了一份列表（筛选、排序变了）：按刚才露在最上面的位置重新认。
            tracker.update(tracker.lastTopPosition.flatMap { usefulModel?.label(containing: $0) })
        }
        .task(id: jump) {
            guard let jump else { return }
            await Task.yield()
            guard !Task.isCancelled else { return }
            position.scrollTo(id: jump.row, anchor: .top)
        }
    }
}

/// 字母条发出的一次跳转；同一行连着跳两次也各算一次。
private struct LibraryIndexJump: Equatable {
    let row: Int
    let token = UUID()
}

#endif
