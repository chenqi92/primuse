import SwiftUI
import PrimuseKit

/// 资料库「发行日期」:专辑按年代 → 年份分组,同一年里按艺术家排;顶上一条年代分布图,
/// 点柱子跳到那个年代,点年代标题收起或展开。
///
/// 分组要把整库专辑转写、排序一遍,放在后台算,结果按专辑数组缓存:回到这一页、
/// 别处触发重绘都直接拿缓存,曲库真的变了才重算。
struct ReleaseDateLibraryView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(AudioPlayerService.self) private var player
    @State private var layout: ReleaseDateBrowseLayout?
    @State private var collapsedDecades: Set<String> = []
    private let favorites = LibraryFavoritesStore.shared
    #if os(iOS)
    @Environment(\.pmHeightClass) private var heightClass
    #endif

    var body: some View {
        let albums = library.visibleAlbums
        let shown = layout ?? ReleaseDateLayoutCache.shared.cachedLayout(for: albums)
        Group {
            if albums.isEmpty {
                EmptyStateView(
                    titleKey: "no_albums",
                    descriptionKey: "no_albums_desc",
                    systemImage: "calendar"
                )
            } else if let shown {
                content(shown)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: ReleaseDateLayoutCache.Token(albums)) {
            let built = await ReleaseDateLayoutCache.shared.layout(for: albums)
            guard !Task.isCancelled else { return }
            layout = built
        }
    }

    // MARK: 页面

    private func content(_ layout: ReleaseDateBrowseLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    #if os(macOS)
                    Text("library_release_date_title")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(PMColor.text)
                        .padding(.horizontal, horizontalInset)
                        .padding(.top, 24)
                        .padding(.bottom, 12)
                    #endif
                    ReleaseDateDistributionChart(
                        bars: layout.chartBars,
                        albumCount: layout.albumCount,
                        title: Self.title(for:)
                    ) { era in
                        guard layout.decades.contains(where: { $0.era == era }) else { return }
                        collapsedDecades.remove(era.id)
                        pmWithAnimation(.list) {
                            proxy.scrollTo(era.id, anchor: .top)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    ForEach(layout.decades) { decade in
                        Section {
                            if !collapsedDecades.contains(decade.id) {
                                ForEach(decade.years) { year in
                                    yearBlock(year, showsHeader: decade.era != .unknown)
                                }
                            }
                        } header: {
                            decadeHeader(decade)
                                .id(decade.id)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
            #if os(iOS)
            .pmExtendsUnderVerticalBar()
            #else
            .background(PMColor.bg.ignoresSafeArea())
            #endif
        }
    }

    private func decadeHeader(_ decade: ReleaseDateBrowseLayout.Decade) -> some View {
        let collapsed = collapsedDecades.contains(decade.id)
        return Button {
            pmWithAnimation(.list) { toggleCollapsed(decade.id) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: Self.title(for: decade.era))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                Text(verbatim: Self.albumCountText(decade.albumCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
            }
            .padding(.horizontal, horizontalInset)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(pinnedHeaderBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(Text(LocalizedStringKey(
            collapsed ? "library_release_date_collapsed" : "library_release_date_expanded"
        )))
    }

    private func toggleCollapsed(_ id: String) {
        if collapsedDecades.contains(id) {
            _ = collapsedDecades.remove(id)
        } else {
            _ = collapsedDecades.insert(id)
        }
    }

    private func yearBlock(_ year: ReleaseDateBrowseLayout.Year, showsHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader, let value = year.year {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: String(value))
                        .font(.headline)
                        .monospacedDigit()
                    Text(verbatim: Self.albumCountText(year.albums.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: gridSpacing) {
                ForEach(year.albums) { album in
                    albumCell(album)
                }
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func albumCell(_ album: Album) -> some View {
        #if os(iOS)
        NavigationLink(value: album) {
            AlbumCardView(album: album)
        }
        .buttonStyle(.pmPressable)
        .contextMenu { albumMenu(album) }
        .mediaZoomSource(.album, id: album.id)
        #else
        NavigationLink(value: album) {
            AlbumCardView(album: album)
        }
        .buttonStyle(.plain)
        .contextMenu { albumMenu(album) }
        .pmHoverLift()
        #endif
    }

    private func albumMenu(_ album: Album) -> some View {
        LibraryCollectionMenuItems(
            isLiked: favorites.isLiked(album),
            toggleLike: { favorites.toggle(album) },
            songs: { library.songs(forAlbum: album.id) },
            player: player
        )
    }

    // MARK: 尺寸

    private var columns: [GridItem] {
        #if os(iOS)
        // 一年往往只有一两张,比专辑页小一档:手机竖屏一排三张,整页不至于拉得太长。
        [GridItem(.adaptive(minimum: heightClass.value(104, compact: 96)), spacing: 14, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 150), spacing: 24, alignment: .top)]
        #endif
    }

    private var gridSpacing: CGFloat {
        #if os(iOS)
        heightClass.value(18, compact: 14)
        #else
        24
        #endif
    }

    private var horizontalInset: CGFloat {
        #if os(iOS)
        16
        #else
        PMSpace.xxxl
        #endif
    }

    private var pinnedHeaderBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        PMColor.bg
        #endif
    }

    // MARK: 文案

    static func title(for era: ReleaseDateBrowseLayout.Era) -> String {
        switch era {
        case .decade(let start):
            String(format: String(localized: "library_release_date_decade_format"), start)
        case .earlier:
            String(
                format: String(localized: "library_release_date_earlier_format"),
                ReleaseDateBrowseLayoutBuilder.earliestDecade
            )
        case .unknown:
            String(localized: "library_release_date_unknown")
        }
    }

    static func albumCountText(_ count: Int) -> String {
        "\(count.formatted()) \(String(localized: "albums_count"))"
    }
}

/// 年代分布:一根柱子一个年代,柱高是专辑数。Canvas 一次画完,不做动画;柱子下面的
/// 年代标签是按钮,点了跳到那个年代。
private struct ReleaseDateDistributionChart: View {
    let bars: [ReleaseDateBrowseLayout.ChartBar]
    let albumCount: Int
    let title: (ReleaseDateBrowseLayout.Era) -> String
    let onSelect: (ReleaseDateBrowseLayout.Era) -> Void

    private static let plotHeight: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("library_release_date_chart_title")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(verbatim: ReleaseDateLibraryView.albumCountText(albumCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            let maximum = max(1, bars.map(\.albumCount).max() ?? 0)
            Canvas { context, size in
                guard !bars.isEmpty else { return }
                let slot = size.width / CGFloat(bars.count)
                let barWidth = min(slot * 0.62, 44)
                // 柱顶留出数字的高度。
                let usableHeight = size.height - 16
                for (index, bar) in bars.enumerated() {
                    let ratio = CGFloat(bar.albumCount) / CGFloat(maximum)
                    let height = bar.albumCount == 0 ? 2 : max(4, ratio * usableHeight)
                    let rect = CGRect(
                        x: slot * CGFloat(index) + (slot - barWidth) / 2,
                        y: size.height - height,
                        width: barWidth,
                        height: height
                    )
                    let shading: GraphicsContext.Shading = bar.era == .unknown
                        ? .color(.secondary.opacity(0.45))
                        : .style(.tint)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: min(4, barWidth / 4)),
                        with: bar.albumCount == 0 ? .color(.secondary.opacity(0.2)) : shading
                    )
                    if bar.albumCount > 0 {
                        context.draw(
                            Text(verbatim: bar.albumCount.formatted())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary),
                            at: CGPoint(x: rect.midX, y: rect.minY - 8)
                        )
                    }
                }
            }
            .frame(height: Self.plotHeight)
            .accessibilityHidden(true)

            HStack(spacing: 0) {
                ForEach(bars) { bar in
                    Button {
                        onSelect(bar.era)
                    } label: {
                        Text(verbatim: shortLabel(bar.era))
                            .font(.caption2.weight(.medium))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(
                                bar.albumCount == 0 ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary
                            )
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(bar.albumCount == 0)
                    .accessibilityLabel(Text(verbatim: title(bar.era)))
                    .accessibilityValue(Text(verbatim: ReleaseDateLibraryView.albumCountText(bar.albumCount)))
                }
            }
        }
    }

    /// 柱子下面一格只放得下几个字:年代写起始年,其余用短名。
    private func shortLabel(_ era: ReleaseDateBrowseLayout.Era) -> String {
        switch era {
        case .decade(let start): String(start)
        case .earlier: String(localized: "library_release_date_earlier_short")
        case .unknown: String(localized: "library_release_date_unknown_short")
        }
    }
}

/// 发行日期分组的缓存。不是 Observable:视图在 body 里读它不会因此重绘。
/// 持有输入的专辑数组本身,它的存储地址在缓存期间不会被别的数组复用,所以能拿地址
/// 判断是不是同一份(和 Mac 专辑页的排序缓存同一个做法)。
@MainActor
final class ReleaseDateLayoutCache {
    static let shared = ReleaseDateLayoutCache()

    /// 一份专辑数组的身份:存储地址 + 条数。O(1),可以放进 `.task(id:)`。
    struct Token: Equatable, Sendable {
        let address: UInt
        let count: Int

        init(_ albums: [Album]) {
            count = albums.count
            address = albums.withUnsafeBufferPointer { buffer in
                buffer.baseAddress.map { UInt(bitPattern: $0) } ?? 0
            }
        }
    }

    private var source: [Album] = []
    private var fingerprint: Int?
    private var layout: ReleaseDateBrowseLayout?

    func cachedLayout(for albums: [Album]) -> ReleaseDateBrowseLayout? {
        guard let layout, Token(source) == Token(albums) else { return nil }
        return layout
    }

    func layout(for albums: [Album]) async -> ReleaseDateBrowseLayout {
        if let cached = cachedLayout(for: albums) { return cached }
        let previousFingerprint = layout == nil ? nil : fingerprint
        let currentYear = Calendar.current.component(.year, from: Date())
        let unknownArtistName = String(localized: "unknown_artist")
        let result = await Task.detached(priority: .userInitiated) {
            // 曲库修订常因封面、播放次数这类与分组无关的变化而换一份数组;
            // 决定分组的几项没变就沿用已经建好的。
            let fingerprint = LibraryAlbumBrowseLayoutBuilder.fingerprint(albums: albums)
            guard fingerprint != previousFingerprint else {
                return (fingerprint: fingerprint, layout: ReleaseDateBrowseLayout?.none)
            }
            return (fingerprint: fingerprint, layout: ReleaseDateBrowseLayoutBuilder.layout(
                albums: albums,
                currentYear: currentYear,
                unknownArtistName: unknownArtistName
            ))
        }.value
        source = albums
        fingerprint = result.fingerprint
        if let built = result.layout {
            layout = built
        }
        return layout ?? .empty
    }
}
