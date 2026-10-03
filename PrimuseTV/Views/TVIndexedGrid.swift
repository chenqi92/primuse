#if os(tvOS)
import SwiftUI
import PrimuseKit

/// 从索引栏跳到某个首字母分段的请求;`serial` 让同一个字母可以连按两次。
struct TVGridJumpRequest: Equatable {
    let bucket: String
    let serial: Int
}

/// 带分段的分页网格(专辑墙 / 艺人墙;分段是首字母,年份墙是年份)。
///
/// 大曲库里整墙卡片都参与布局和焦点搜索会卡,所以只渲染一页左右、焦点靠近末尾时续页;
/// 而且渲染的是一个窗口 `[起点, 起点 + 已渲染数)`,不总是从第一张开始:从索引栏跳到 M 时
/// 窗口直接从 M 那一段开始,不用把前面几千张都建出来。没有分段时窗口总从头开始。窗口起点只落在分段起点或段内的整行上,往前补卡片时
/// 已有的行不会重新换行;焦点从窗口第一行往上走,先落到顶上的「更早」一行,它立刻把
/// 前面一页补出来,再把焦点交给上一行同一列的那张卡片。
struct TVIndexedGrid<Items: RandomAccessCollection, Cell: View>: View
where Items.Element: Identifiable, Items.Index == Int {
    typealias Item = Items.Element

    private struct Entry: Identifiable {
        var id: Item.ID { item.id }
        let index: Int
        let item: Item
    }

    private struct Segment: Identifiable {
        let id: String
        let showsHeader: Bool
        let entries: [Entry]
    }

    /// 最近一次聚焦的是第几项。普通引用:焦点每挪一格都写,不能因此重算网格。
    private final class FocusTrail {
        var index: Int?
    }

    let items: Items
    let sections: [LibraryBrowseSection]
    let columns: [GridItem]
    var spacing: CGFloat
    let jumpRequest: TVGridJumpRequest?
    let scrollProxy: ScrollViewProxy
    /// 把焦点放到某张卡片上(持有 `@FocusState` 的父视图来做)。
    let focusItem: (Item.ID) -> Void
    /// 焦点进入了哪一个分段;父视图拿它点亮索引栏。
    let onSectionFocused: (String) -> Void
    /// 分段标题怎么显示(按年份分段时「没有年份」那一段要换成文字)。
    let sectionTitle: (String) -> String
    private let cell: (Int, Item, @escaping (Bool) -> Void) -> Cell

    /// 窗口起点 = 所在分段的字母 + 段内偏移。曲库变化后各段整体挪动,按字母找回起点,
    /// 窗口仍落在同一段里;那一段没了就回到开头。
    @State private var startBucket: String?
    @State private var startOffset = 0
    @State private var renderedCount: Int
    @State private var focusTrail = FocusTrail()

    /// `revealingIndex`:网格重建时要能直接落到的那一项(回到资料库时上次聚焦的卡片)。
    init(
        items: Items,
        sections: [LibraryBrowseSection],
        columns: [GridItem],
        spacing: CGFloat = 28,
        revealingIndex: Int? = nil,
        jumpRequest: TVGridJumpRequest?,
        scrollProxy: ScrollViewProxy,
        focusItem: @escaping (Item.ID) -> Void,
        onSectionFocused: @escaping (String) -> Void = { _ in },
        sectionTitle: @escaping (String) -> String = { $0 },
        @ViewBuilder cell: @escaping (Int, Item, @escaping (Bool) -> Void) -> Cell
    ) {
        self.items = items
        self.sections = sections
        self.columns = columns
        self.spacing = spacing
        self.jumpRequest = jumpRequest
        self.scrollProxy = scrollProxy
        self.focusItem = focusItem
        self.onSectionFocused = onSectionFocused
        self.sectionTitle = sectionTitle
        self.cell = cell

        let pageSize = TVLongListPagingPolicy.pageSize
        let columnCount = max(1, columns.count)
        guard let anchor = revealingIndex, items.indices.contains(anchor) else {
            _renderedCount = State(initialValue: pageSize)
            return
        }
        if let (section, start) = LibraryBrowseWindow.start(
            revealing: anchor, sections: sections, columns: columnCount, pageSize: pageSize
        ) {
            // 首次渲染就覆盖到锚点。
            _startBucket = State(initialValue: section.bucket)
            _startOffset = State(initialValue: start - section.range.lowerBound)
            _renderedCount = State(initialValue: TVLongListPagingPolicy.limit(
                after: pageSize, focusedRow: anchor - start, totalCount: items.count - start
            ))
        } else {
            _renderedCount = State(initialValue: TVLongListPagingPolicy.limit(
                after: pageSize, focusedRow: anchor, totalCount: items.count
            ))
        }
    }

    private var columnCount: Int { max(1, columns.count) }

    /// 网格顶部(「更早」一行之上)。跳转后滚到这里:按卡片自身比例对齐的锚点会把
    /// 分段标题和「更早」一行切掉一半。
    private static var topID: String { "tv.indexedGrid.top" }

    private var windowStart: Int {
        guard let startBucket,
              let section = sections.first(where: { $0.bucket == startBucket }) else { return 0 }
        let offset = min(startOffset, max(0, section.range.count - 1))
        return LibraryBrowseWindow.rowAligned(section.range.lowerBound + offset, in: section, columns: columnCount)
    }

    var body: some View {
        let start = windowStart
        let available = items.count - start
        let shown = TVLongListPagingPolicy.clamped(limit: renderedCount, totalCount: available)
        // 跳转后 tvOS 的焦点滚动只给首行卡片上方留约 130pt:「更早」一行和字母标题
        // 都要压进这段空间,否则顶上那行会被可视区切掉一半。
        VStack(alignment: .leading, spacing: 12) {
            if start > 0 {
                earlierRow(windowStart: start)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                ForEach(segments(start: start, end: start + shown)) { segment in
                    if segment.showsHeader {
                        Section {
                            cells(segment, start: start, shown: shown)
                        } header: {
                            sectionHeader(segment.id)
                        }
                    } else {
                        Section {
                            cells(segment, start: start, shown: shown)
                        }
                    }
                }
            }
        }
        .id(Self.topID)
        .onChange(of: jumpRequest) { _, request in
            guard let request else { return }
            jump(to: request.bucket)
        }
    }

    @ViewBuilder
    private func cells(_ segment: Segment, start: Int, shown: Int) -> some View {
        ForEach(segment.entries) { entry in
            cell(entry.index, entry.item) { focused in
                guard focused else { return }
                focusTrail.index = entry.index
                if let bucket = LibraryBrowseSection.section(containing: entry.index, in: sections)?.bucket {
                    onSectionFocused(bucket)
                }
                renderedCount = TVLongListPagingPolicy.limit(
                    after: shown, focusedRow: entry.index - start, totalCount: items.count - start
                )
            }
        }
    }

    private func sectionHeader(_ bucket: String) -> some View {
        Text(verbatim: sectionTitle(bucket))
            .tvFont(.sectionTitle)
            .foregroundStyle(TVColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// 窗口里的条目按分段切开;没有分段(按年份、最近添加)时整窗一段、不带标题。
    /// 窗口从某段中间开始时,那一段不显示标题(标题在窗口外)。
    private func segments(start: Int, end: Int) -> [Segment] {
        guard start < end else { return [] }
        func entries(_ range: Range<Int>) -> [Entry] {
            range.map { Entry(index: $0, item: items[$0]) }
        }
        guard !sections.isEmpty else {
            return [Segment(id: "", showsHeader: false, entries: entries(start..<end))]
        }
        return sections.compactMap { section in
            let lower = max(section.range.lowerBound, start)
            let upper = min(section.range.upperBound, end)
            guard lower < upper else { return nil }
            return Segment(
                id: section.bucket,
                showsHeader: lower == section.range.lowerBound,
                entries: entries(lower..<upper)
            )
        }
    }

    /// 窗口上方的一行:焦点一落上来就把前面一页补出来,再把焦点交给紧挨着的上一行。
    /// 交接没成功时它就是一颗普通按钮,按下效果相同。
    private func earlierRow(windowStart start: Int) -> some View {
        let previousBucket = LibraryBrowseSection.section(containing: start - 1, in: sections)
            .map { sectionTitle($0.bucket) }
        return TVFocusButton(
            radius: 14,
            scale: 1.0,
            lift: 0,
            action: { revealEarlier() },
            onFocusChanged: { focused in
                if focused { revealEarlier() }
            }
        ) { focused in
            HStack(spacing: 12) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 22, weight: .semibold))
                if let previousBucket {
                    Text(verbatim: previousBucket)
                        .tvFont(.caption, weight: .semibold)
                }
            }
            .foregroundStyle(focused ? TVColor.onBrand : TVColor.textMuted)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(focused ? TVColor.brand : TVColor.surfaceSubtle, in: .rect(cornerRadius: 14))
        }
        .accessibilityLabel(Text(verbatim: previousBucket ?? "↑"))
    }

    private func revealEarlier() {
        let start = windowStart
        guard start > 0 else { return }
        let reveal = LibraryBrowseWindow.earlierWindow(
            before: start,
            sections: sections,
            columns: columnCount,
            pageSize: TVLongListPagingPolicy.pageSize,
            focusedIndex: focusTrail.index
        )
        guard let section = LibraryBrowseSection.section(containing: reveal.start, in: sections) else {
            startBucket = nil
            startOffset = 0
            renderedCount += start
            return
        }
        startBucket = section.bucket
        startOffset = reveal.start - section.range.lowerBound
        renderedCount += start - reveal.start
        let targetID = items[reveal.target].id
        plog("TV grid reveal earlier start=\(start)→\(reveal.start) target=\(reveal.target) focused=\(focusTrail.index ?? -1)")
        Task { @MainActor in
            // 等补出来的卡片排好版再滚动和交焦点:懒网格没建出来的卡片接不住焦点。
            try? await Task.sleep(nanoseconds: 50_000_000)
            scrollProxy.scrollTo(targetID, anchor: .center)
            try? await Task.sleep(nanoseconds: 50_000_000)
            focusItem(targetID)
        }
    }

    private func jump(to bucket: String) {
        guard let section = sections.first(where: { $0.bucket == bucket }),
              items.indices.contains(section.range.lowerBound) else { return }
        startBucket = section.bucket
        startOffset = 0
        renderedCount = TVLongListPagingPolicy.pageSize
        focusTrail.index = section.range.lowerBound
        let targetID = items[section.range.lowerBound].id
        plog("TV grid jump bucket=\(bucket) start=\(section.range.lowerBound) count=\(section.range.count)")
        Task { @MainActor in
            await Task.yield()
            // 网格顶部贴住可视区顶部:完整露出「更早」一行和这一段的字母标题。
            scrollProxy.scrollTo(Self.topID, anchor: .top)
            try? await Task.sleep(nanoseconds: 50_000_000)
            focusItem(targetID)
            #if DEBUG
            // 截图用:TV_INDEX_REVEAL=1 模拟跳转后在第一行按上键。
            if ProcessInfo.processInfo.environment["TV_INDEX_REVEAL"] == "1" {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                revealEarlier()
            }
            #endif
        }
    }
}

/// 网格右侧的竖排首字母栏。没有内容的字母变灰、焦点直接跳过。
struct TVLetterIndexBar: View {
    static let width: CGFloat = 52

    let availableBuckets: Set<String>
    let currentBucket: String?
    var focusedBucket: FocusState<String?>.Binding
    let onSelect: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            // 27 个字母均分可用高度:顶栏、筛选条和安全区占掉多少随设置而变。
            let rowHeight = min(32, max(22, geo.size.height / CGFloat(LibraryCollationPolicy.buckets.count)))
            VStack(spacing: 0) {
                ForEach(LibraryCollationPolicy.buckets, id: \.self) { bucket in
                    letter(bucket, rowHeight: rowHeight)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(width: Self.width)
        // 从网格按右键进来时落在当前所在的字母上,而不是几何上最近的那个:
        // 上下几下就到相邻字母,不用先找自己在哪。
        .defaultFocus(focusedBucket, entryBucket, priority: .userInitiated)
        .focusSection()
    }

    private var entryBucket: String? {
        if let currentBucket, availableBuckets.contains(currentBucket) { return currentBucket }
        return LibraryCollationPolicy.buckets.first(where: availableBuckets.contains)
    }

    private func letter(_ bucket: String, rowHeight: CGFloat) -> some View {
        let enabled = availableBuckets.contains(bucket)
        let focused = focusedBucket.wrappedValue == bucket
        return Button { onSelect(bucket) } label: {
            Text(verbatim: bucket)
                .tvFont(.meta, weight: .semibold)
                .foregroundStyle(
                    focused ? TVColor.onBrand
                        : (enabled ? (currentBucket == bucket ? TVColor.text : TVColor.textMuted)
                           : TVColor.textGhost.opacity(0.5))
                )
                .frame(width: 40, height: rowHeight)
                .background {
                    if focused {
                        Capsule().fill(TVColor.brand)
                    } else if currentBucket == bucket {
                        Capsule().fill(TVColor.surface)
                    }
                }
                .scaleEffect(focused ? 1.25 : 1)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused(focusedBucket, equals: bucket)
        .focusEffectDisabled()
        .disabled(!enabled)
        .accessibilityIdentifier("tv.library.index." + bucket)
    }
}

/// 焦点在字母栏上时网格中央浮出的大号字母。
struct TVLetterIndexWatermark: View {
    let bucket: String?

    var body: some View {
        ZStack {
            if let bucket {
                Text(verbatim: bucket)
                    .tvFont(size: 160, weight: .bold, design: .rounded, relativeTo: .largeTitle)
                    .foregroundStyle(TVColor.text)
                    .frame(width: 260, height: 260)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 40))
                    .transition(.opacity)
                    .id(bucket)
            }
        }
        .animation(.easeOut(duration: 0.3), value: bucket)
        .allowsHitTesting(false)
    }
}
#endif
