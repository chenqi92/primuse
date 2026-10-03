#if os(macOS)
import AppKit
import PrimuseKit
import SwiftUI

/// Mac 的播客页。
///
/// 页头一行:标题、「我的节目 / 发现」、搜索框、「…」菜单。搜索与热门榜都在页里,不再弹发现页。
/// 热门榜和搜索结果排成多栏紧凑网格 —— Mac 窗口宽,一行一档会把大半屏留给空白。
/// 一档都没订时没有切换,整页就是发现。
struct MacPodcastLibraryView: View {
    enum Page: Hashable {
        case library
        case discover
    }

    @State private var navigation = PodcastNavigationModel()
    @State private var search = PodcastDirectorySearch()
    @State private var page: Page = .library
    @State private var feedPreviewURL: URL?
    @FocusState private var searchFocused: Bool

    private var store: PodcastStore { PodcastStore.shared }
    private var hasShows: Bool { !store.shows.isEmpty }
    private var isSearching: Bool { !search.trimmedQuery.isEmpty }

    init(initialPage: Page = .library, initialQuery: String = "") {
        _page = State(initialValue: initialPage)
        let search = PodcastDirectorySearch()
        search.query = initialQuery
        _search = State(initialValue: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                content
                    .padding(.horizontal, 36)
                    .padding(.top, 4)
                    .padding(.bottom, 36)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PMColor.bg)
        .navigationTitle("listening_space_podcast")
        .task {
            store.loadIfNeeded()
            store.refreshAllIfDue()
        }
        .onChange(of: store.isLoaded) { _, loaded in
            if loaded { store.refreshAllIfDue() }
        }
        .task(id: search.trimmedQuery) { await search.run() }
        .navigationDestination(item: $feedPreviewURL) { url in
            PodcastShowDetailView(source: .feed(url))
        }
        .podcastNavigationDestinations(navigation)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: PMSpace.m) {
                Text("listening_space_podcast")
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: PMSpace.m)

                if store.isRefreshingAll {
                    ProgressView().controlSize(.small)
                }
                if hasShows {
                    pagePicker
                }
                searchField
                moreMenu
            }

            Text(verbatim: summary)
                .font(.system(size: 13))
                .foregroundStyle(PMColor.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 36)
        .padding(.top, 28)
        .padding(.bottom, 18)
    }

    private var summary: String {
        guard hasShows else { return String(localized: "podcast_welcome_message") }
        var parts = ["\(store.shows.count) \(String(localized: "podcast_shows_count"))"]
        let newCount = store.shows.reduce(0) { $0 + store.newEpisodeCount(showID: $1.id) }
        if newCount > 0 {
            parts.append(String(format: String(localized: "podcast_new_episodes_count %lld"), newCount))
        }
        return parts.joined(separator: "  ·  ")
    }

    /// 两格分段:同电台页的版式开关一个样子。搜索时让位给搜索结果,所以压暗。
    private var pagePicker: some View {
        HStack(spacing: 2) {
            pageButton(.library, title: "podcast_my_shows")
            pageButton(.discover, title: "podcast_discover")
        }
        .padding(2)
        .frame(height: 32)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(PMColor.dividerStrong, lineWidth: 0.5)
        }
        .opacity(isSearching ? 0.55 : 1)
        .fixedSize()
    }

    private func pageButton(_ target: Page, title: LocalizedStringKey) -> some View {
        let selected = page == target && !isSearching
        return Button {
            pmWithAnimation(.selection) {
                page = target
                search.query = ""
            }
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? PMColor.text : PMColor.textMuted)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(selected ? PMColor.glassBtn : .clear, in: .rect(cornerRadius: PMRadius.xs))
                .contentShape(Rectangle())
                .pmAnimation(.hover, value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)

            TextField("podcast_search_prompt", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(PMColor.text)
                .focused($searchFocused)
                .onExitCommand { search.query = "" }
                .accessibilityIdentifier("podcast.mac.search")

            if search.isSearching {
                ProgressView().controlSize(.mini)
            } else if !search.query.isEmpty {
                Button {
                    search.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 260, height: 32)
        .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                .strokeBorder(
                    searchFocused ? ListeningSpace.podcast.tint.opacity(0.7) : PMColor.dividerStrong,
                    lineWidth: searchFocused ? 1 : 0.5
                )
        }
    }

    private var moreMenu: some View {
        Menu {
            PodcastActionsMenuItems(navigation: navigation)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.text)
                .frame(width: 32, height: 32)
                .background(PMColor.glassBtn, in: .rect(cornerRadius: PMRadius.m))
                .overlay {
                    RoundedRectangle(cornerRadius: PMRadius.m, style: .continuous)
                        .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
                }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("more"))
        .accessibilityIdentifier("podcast.mac.more")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearching {
            MacPodcastSearchResults(search: search, openShow: openDirectoryShow) { feedPreviewURL = $0 }
        } else if !store.isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if hasShows, page == .library {
            // 订阅内容沿用各端共用的区块;它们自带 16 点边距,这里只补到和页头对齐。
            PodcastLibraryContent(navigation: navigation)
                .padding(.horizontal, -16)
                .pmAppearFade(.contentAppear)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                MacPodcastDiscoverSection(openShow: openDirectoryShow)
                if !hasShows {
                    PodcastRegionHiddenNote()
                        .padding(.horizontal, -16)
                }
            }
            .pmAppearFade(.contentAppear)
        }
    }

    private func openDirectoryShow(_ show: PodcastDirectoryShow) {
        navigation.pushedDirectoryShow = show
    }
}

// MARK: - Discover

/// 发现:分类胶囊 + 热门榜。分类胶囊折行排,不做横滑 —— 鼠标没法顺手地横着滚。
private struct MacPodcastDiscoverSection: View {
    var openShow: (PodcastDirectoryShow) -> Void

    @State private var genreID: Int?
    @State private var shows: [PodcastDirectoryShow] = []
    @State private var failed = false
    @State private var isLoading = false

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("podcast_top_charts")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(PMColor.text)
                .accessibilityAddTraits(.isHeader)

            MacSearchFlowLayout(spacing: 6, rowSpacing: 6) {
                chip(Text("podcast_filter_all"), selected: genreID == nil) { genreID = nil }
                ForEach(PodcastDirectory.genreIDs, id: \.self) { id in
                    chip(Text(LocalizedStringKey(PodcastFormat.genreKey(id))), selected: genreID == id) { genreID = id }
                }
            }

            if isLoading && shows.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if failed && shows.isEmpty {
                Button {
                    Task { await load() }
                } label: {
                    Label("podcast_chart_failed_retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 12.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .padding(.vertical, 12)
            } else {
                MacPodcastDirectoryGrid(shows: shows, ranked: true, collapsedRows: 6, open: openShow)
                    // 换分类时整块换掉,展开状态回到收起。
                    .id(genreID ?? 0)
                    .opacity(isLoading ? 0.5 : 1)
            }
        }
        .task(id: "\(genreID ?? 0)|\(PodcastAvailabilityService.shared.policy.directoryCountry)") { await load() }
    }

    private func chip(_ title: Text, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            pmWithAnimation(.selection) { action() }
        } label: {
            title
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Color.white : PMColor.text)
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(PMColor.glassBtn), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await PodcastDirectoryService.shared.chart(genreID: genreID)
            guard !Task.isCancelled else { return }
            shows = loaded
            failed = false
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }
}

// MARK: - Search

private struct MacPodcastSearchResults: View {
    let search: PodcastDirectorySearch
    var openShow: (PodcastDirectoryShow) -> Void
    var openFeed: (URL) -> Void

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let url = search.typedFeedURL {
                Button {
                    openFeed(url)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "link")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 46, height: 46)
                            .background(tint.opacity(0.12), in: .rect(cornerRadius: PMRadius.m))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("podcast_add_this_feed")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(PMColor.text)
                            Text(verbatim: url.absoluteString)
                                .font(.system(size: 11.5))
                                .foregroundStyle(PMColor.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                    }
                    .padding(8)
                    .background(PMColor.bgElev, in: .rect(cornerRadius: PMRadius.m10))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 520, alignment: .leading)
            }

            if search.isSearching && search.results.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else if let message = search.errorMessage, search.results.isEmpty {
                ContentUnavailableView(
                    "podcast_search_failed",
                    systemImage: "wifi.exclamationmark",
                    description: Text(message)
                )
            } else if search.results.isEmpty, search.typedFeedURL == nil, !search.isSearching {
                ContentUnavailableView.search(text: search.trimmedQuery)
            } else if !search.results.isEmpty {
                MacPodcastDirectoryGrid(shows: search.results, ranked: false, collapsedRows: nil, open: openShow)
                    .opacity(search.isSearching ? 0.5 : 1)
            }
        }
    }
}

// MARK: - Directory grid

/// 目录节目排成多栏网格。榜单的排名按栏竖着数(先排满第一栏再到第二栏),和读榜单的习惯一致;
/// 搜索结果按行排,最相关的几个并排在第一行。`collapsedRows` 有值时先露这么多行,其余点「展开」。
private struct MacPodcastDirectoryGrid: View {
    let shows: [PodcastDirectoryShow]
    let ranked: Bool
    let collapsedRows: Int?
    var open: (PodcastDirectoryShow) -> Void

    @State private var width: CGFloat = 0
    @State private var expanded = false

    private static let minimumColumnWidth: Double = 300
    private static let columnSpacing: CGFloat = 16

    var body: some View {
        let columns = SearchResultPageLayout.shelfItemCount(
            width: Double(width),
            minimumItemWidth: Self.minimumColumnWidth,
            spacing: Double(Self.columnSpacing)
        )
        let collapsedCount = collapsedRows.map { $0 * columns } ?? shows.count
        let visibleCount = expanded ? shows.count : min(shows.count, collapsedCount)
        let numbered = Array(shows.prefix(visibleCount).enumerated())
        let chunks = ranked
            ? SearchResultPageLayout.columnMajorChunks(numbered, columns: columns)
            : Self.rowMajorChunks(numbered, columns: columns)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: Self.columnSpacing) {
                ForEach(chunks.indices, id: \.self) { column in
                    VStack(spacing: 2) {
                        ForEach(chunks[column], id: \.element.id) { index, show in
                            MacPodcastDirectoryCell(show: show, rank: ranked ? index + 1 : nil) { open(show) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                // 结果少于栏数时补空栏,每格宽度和满栏时一样。
                ForEach(chunks.count..<max(columns, chunks.count), id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }

            if shows.count > collapsedCount {
                Button {
                    pmWithAnimation(.list) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "podcast_show_less" : "podcast_show_more")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ListeningSpace.podcast.tint)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 第 c 栏放第 c、c+栏数、c+2×栏数… 个,读起来是一行一行往下。
    private static func rowMajorChunks<Element>(_ items: [Element], columns: Int) -> [[Element]] {
        let count = min(max(columns, 1), items.count)
        return (0..<count).map { column in
            stride(from: column, to: items.count, by: count).map { items[$0] }
        }
    }
}

/// 网格里的一档:排名、封面、名字、主播与分类,右边订阅键。整行一个高度,悬停有底色。
private struct MacPodcastDirectoryCell: View {
    let show: PodcastDirectoryShow
    var rank: Int?
    var open: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 10) {
                    if let rank {
                        Text(verbatim: "\(rank)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(rank <= 3 ? ListeningSpace.podcast.tint : PMColor.textMuted)
                            .frame(width: 22, alignment: .trailing)
                    }
                    PodcastArtwork(directoryShow: show, size: 46, cornerRadius: PMRadius.m)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: show.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PMColor.text)
                            .lineLimit(1)
                        if let detail {
                            Text(verbatim: detail)
                                .font(.system(size: 11.5))
                                .foregroundStyle(PMColor.textMuted)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            PodcastSubscribeButton(directoryShow: show, diameter: 28)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? PMColor.rowHover : .clear, in: .rect(cornerRadius: PMRadius.m10))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pmAnimation(.hover, value: hovering)
        .help(Text(verbatim: show.title))
        .accessibilityIdentifier("podcast.directory.\(show.id)")
    }

    private var detail: String? {
        var parts: [String] = []
        if let author = show.author, !author.isEmpty { parts.append(author) }
        if let genre = show.genre, !genre.isEmpty { parts.append(PodcastFormat.category(genre)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
/// `PRIMUSE_DEBUG_PODCAST_MAC_SNAPSHOT=<目录>`:把播客页放进一个屏幕外的窗口,等热门榜和封面加载完,
/// 存成 PNG。编译机常年锁屏截不到真窗口,改这一页时用它看排版。
/// `PRIMUSE_DEBUG_PODCAST_MAC_QUERY=<关键词>` 先填好搜索框;`PRIMUSE_DEBUG_PODCAST_MAC_PAGE=discover` 直接看发现。
@MainActor
enum MacPodcastDebugSnapshot {
    private static var window: NSWindow?

    static func writeIfRequested() async {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PRIMUSE_DEBUG_PODCAST_MAC_SNAPSHOT"], !path.isEmpty else { return }
        try? await Task.sleep(for: .seconds(4))
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page: MacPodcastLibraryView.Page = env["PRIMUSE_DEBUG_PODCAST_MAC_PAGE"] == "discover" ? .discover : .library
        let query = env["PRIMUSE_DEBUG_PODCAST_MAC_QUERY"] ?? ""
        for (name, appearanceName) in [("podcast-dark", NSAppearance.Name.darkAqua), ("podcast-light", NSAppearance.Name.aqua)] {
            let root = NavigationStack {
                MacPodcastLibraryView(initialPage: page, initialQuery: query)
            }
            .applyPrimuseEnvironments()
            let host = NSHostingView(rootView: root)
            let frame = NSRect(x: -4000, y: -4000, width: 1000, height: 1200)
            let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearanceName)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            Self.window = window
            try? await Task.sleep(for: .seconds(12))
            host.layoutSubtreeIfNeeded()
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent("\(name).png"))
                }
            }
            window.orderOut(nil)
            Self.window = nil
        }
        plog("🧪 podcast mac snapshots written to \(directory.path) shows=\(PodcastStore.shared.shows.count)")
    }
}
#endif
#endif
