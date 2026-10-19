import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers

/// 播客这一类的主页:资料库里的「播客」、首页筛到播客、Mac 侧栏都进这里。
///
/// 从上到下:订阅的节目(我的节目,随时点进去)→ 听到一半的(继续收听)→ 订阅里新出的(最新单集)。
/// 一档都没订时整页换成发现:搜索入口和热门榜,点一下就能订。
/// Mac 另有一套页面(`MacPodcastLibraryView`):搜索和热门榜直接在页里,不弹发现页。
struct PodcastLibraryView: View {
    #if os(macOS)
    var body: some View {
        MacPodcastLibraryView()
    }
    #else
    @State private var navigation = PodcastNavigationModel()
    /// 「在本页里找」: 按节目名、作者、文件夹与标签筛已订阅的节目。
    @State private var findText = ""

    var body: some View {
        ScrollView {
            PodcastLibraryContent(navigation: navigation, findText: findText)
                .padding(.vertical, 12)
        }
        .pmExtendsUnderVerticalBar()
        .libraryPageFind(text: $findText, prompt: "filter_podcasts_placeholder")
        .navigationTitle(navigation.organizer.isSelecting ? Text(verbatim: selectingTitle) : Text("listening_space_podcast"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PodcastLibraryToolbar(navigation: navigation) }
        // 极简模式根页没有导航栏：大标题「播客」与「+」「⋯」排成页头，下面是有声书 / 播客切换。
        // 多选时换成「完成」、已选几档与批量菜单。
        .minimalPageHeader {
            if navigation.organizer.isSelecting {
                HStack(spacing: 8) {
                    Button {
                        navigation.organizer.endSelecting()
                    } label: {
                        Text("done")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ListeningSpace.podcast.tint)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Text(verbatim: selectingTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    MinimalHeaderActions {
                        PodcastShowSelectionMenu(organizer: navigation.organizer, systemImage: "ellipsis")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        MinimalPageTitle("listening_space_podcast")
                        Spacer(minLength: 8)
                        MinimalHeaderActions {
                            MinimalPageFindButton()
                            PodcastAddMenu(navigation: navigation)
                            PodcastMoreMenu(navigation: navigation, systemImage: "ellipsis")
                        }
                    }
                    MinimalSpokenSwitcher(current: .podcasts)
                        .padding(.trailing, 8)
                        .padding(.bottom, 4)
                }
            }
        }
        .refreshable { await PodcastStore.shared.refreshAll() }
        .podcastNavigationDestinations(navigation)
    }

    /// 多选时的标题:还没选就仍叫「播客」。
    private var selectingTitle: String {
        let count = navigation.organizer.selectedShows.count
        guard count > 0 else { return String(localized: "listening_space_podcast") }
        return String(format: String(localized: "podcast_manage_selected %lld"), count)
    }
    #endif
}

/// 导航与弹出的页面状态。主页里的卡片、工具栏、首页那一面共用一份。
@MainActor
@Observable
final class PodcastNavigationModel {
    var showsDiscover = false
    var showsAddFeed = false
    var showsSettings = false
    var showsSectionEditor = false
    var showsOPMLImporter = false
    var importMessage: String?
    var pushedShowID: String?
    var pushedEpisodeID: String?
    var pushedAllEpisodes = false
    var pushedLikedEpisodes = false
    /// 本机下载的播客文件按节目分组后的那一档(`SpokenWordBook.id`)。
    var pushedLocalShowID: String?
    /// 从热门榜点进去、还没订的节目。
    var pushedDirectoryShow: PodcastDirectoryShow?
    /// 「我的节目」的文件夹、标签筛选与多选。
    let organizer = PodcastShowOrganizer()

    func open(showID: String) { pushedShowID = showID }
    func open(episodeID: String) { pushedEpisodeID = episodeID }
}

extension View {
    /// 播客页面的推入与弹出。主页和首页那一面各自挂一次。
    func podcastNavigationDestinations(_ navigation: PodcastNavigationModel) -> some View {
        modifier(PodcastNavigationDestinations(navigation: navigation))
    }
}

private struct PodcastNavigationDestinations: ViewModifier {
    @Bindable var navigation: PodcastNavigationModel
    @State private var importing = false

    func body(content: Content) -> some View {
        content
            .navigationDestination(item: $navigation.pushedShowID) { showID in
                PodcastShowDetailView(source: .show(showID))
            }
            .navigationDestination(item: $navigation.pushedEpisodeID) { episodeID in
                PodcastEpisodeDetailView(episodeID: episodeID)
            }
            .navigationDestination(isPresented: $navigation.pushedAllEpisodes) {
                PodcastEpisodeFeedView()
            }
            .navigationDestination(isPresented: $navigation.pushedLikedEpisodes) {
                PodcastLikedEpisodesView(navigation: navigation)
            }
            .navigationDestination(item: $navigation.pushedLocalShowID) { showID in
                SpokenWordBookDetailView(bookID: showID, collection: .localPodcasts)
            }
            .navigationDestination(item: $navigation.pushedDirectoryShow) { show in
                PodcastShowDetailView(source: .directory(show))
            }
            .sheet(isPresented: $navigation.showsDiscover) {
                NavigationStack { PodcastDiscoverView() }
                #if os(macOS)
                    .frame(minWidth: 560, minHeight: 640)
                #endif
            }
            .sheet(isPresented: $navigation.showsAddFeed) {
                NavigationStack { PodcastAddFeedView() }
                #if os(macOS)
                    .frame(minWidth: 460, minHeight: 360)
                #endif
            }
            .sheet(isPresented: $navigation.showsSettings) {
                NavigationStack { PodcastSettingsView() }
                #if os(macOS)
                    .frame(minWidth: 460, minHeight: 520)
                #endif
            }
            .sheet(isPresented: $navigation.showsSectionEditor) {
                PodcastSectionsEditor()
            }
            .podcastShowOrganizerAlerts(navigation.organizer)
            .fileImporter(
                isPresented: $navigation.showsOPMLImporter,
                allowedContentTypes: PodcastOPMLFile.contentTypes
            ) { result in
                guard case .success(let url) = result else { return }
                importing = true
                Task { @MainActor in
                    navigation.importMessage = await PodcastOPMLFile.importFile(at: url)
                    importing = false
                }
            }
            .alert("podcast_opml_import_title", isPresented: Binding(
                get: { navigation.importMessage != nil },
                set: { if !$0 { navigation.importMessage = nil } }
            )) {
                Button("done") { navigation.importMessage = nil }
            } message: {
                Text(navigation.importMessage ?? "")
            }
            .overlay {
                if importing {
                    ProgressView("podcast_opml_importing")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
    }
}

/// 右上角:「+」(发现、按地址添加、导入 OPML)和「…」(刷新、导出、设置)。
struct PodcastLibraryToolbar: ToolbarContent {
    let navigation: PodcastNavigationModel

    var body: some ToolbarContent {
        // 导航栏按钮默认跟 App 的主题色(可能跟着封面变),这一页的按钮跟播客自己的颜色。
        if navigation.organizer.isSelecting {
            ToolbarItem(placement: .primaryAction) {
                PodcastShowSelectionMenu(organizer: navigation.organizer)
                    .tint(ListeningSpace.podcast.tint)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("done") { navigation.organizer.endSelecting() }
                    .fontWeight(.semibold)
                    .tint(ListeningSpace.podcast.tint)
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                PodcastAddMenu(navigation: navigation)
                    .tint(ListeningSpace.podcast.tint)
            }
            ToolbarItem(placement: .primaryAction) {
                PodcastMoreMenu(navigation: navigation)
                    .tint(ListeningSpace.podcast.tint)
            }
        }
    }
}

/// 「+」:发现、按地址添加、导入 OPML。工具栏与极简页头共用。
struct PodcastAddMenu: View {
    let navigation: PodcastNavigationModel

    private var availability: PodcastAvailabilityService { PodcastAvailabilityService.shared }

    var body: some View {
        Menu {
            Button {
                navigation.showsDiscover = true
            } label: {
                Label("podcast_discover", systemImage: "magnifyingglass")
            }
            if availability.allowsCustomFeeds {
                Button {
                    navigation.showsAddFeed = true
                } label: {
                    Label("podcast_add_by_url", systemImage: "link")
                }
                Button {
                    navigation.showsOPMLImporter = true
                } label: {
                    Label("podcast_import_opml", systemImage: "square.and.arrow.down")
                }
            }
        } label: {
            Label("podcast_add", systemImage: "plus")
        }
        .accessibilityIdentifier("podcast.add")
    }
}

/// 「…」:刷新、选择、导出、调整区块、设置。工具栏与极简页头共用。
struct PodcastMoreMenu: View {
    let navigation: PodcastNavigationModel
    var systemImage = "ellipsis.circle"

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        Menu {
            Button {
                Task { await store.refreshAll() }
            } label: {
                Label("podcast_refresh_all", systemImage: "arrow.clockwise")
            }
            .disabled(store.shows.isEmpty || store.isRefreshingAll)
            if !store.shows.isEmpty {
                // 选几档一起归进文件夹、贴标签或退订。
                Button {
                    navigation.organizer.beginSelecting()
                } label: {
                    Label("batch_select", systemImage: "checkmark.circle")
                }
                .accessibilityIdentifier("podcast.select")
                ShareLink(item: PodcastOPMLDocument(), preview: SharePreview(String(localized: "podcast_export_opml"))) {
                    Label("podcast_export_opml", systemImage: "square.and.arrow.up")
                }
            }
            Divider()
            PodcastSectionsEditorButton(navigation: navigation)
            Button {
                navigation.showsSettings = true
            } label: {
                Label("podcast_settings", systemImage: "gearshape")
            }
        } label: {
            Label("more", systemImage: systemImage)
        }
        .accessibilityIdentifier("podcast.more")
    }
}

/// 主页正文。首页「播客」那一面直接放这个,外面的滚动容器由放它的地方给。
struct PodcastLibraryContent: View {
    let navigation: PodcastNavigationModel
    /// 播客页「在本页里找」的输入; 首页那一面不传。在找节目时只摆命中的节目。
    var findText = ""
    /// 首页那一面给:「我的节目」右上角的「管理」进完整的播客页。
    var onManageShows: (() -> Void)?

    @Environment(MusicLibrary.self) private var library
    @AppStorage(PodcastLibrarySectionLayout.storageKey) private var sectionLayoutRawValue = ""
    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        Group {
            if !store.isLoaded {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if store.shows.isEmpty {
                VStack(spacing: 20) {
                    // 没订阅、但资料库里有自己下载的节目:先摆出来,再是发现。
                    PodcastLocalShowsSection(navigation: navigation)
                    PodcastWelcomeView(navigation: navigation)
                    PodcastRegionHiddenNote()
                }
            } else if let findQuery = LibraryFindPolicy.query(findText) {
                let localMatches = PodcastLocalShowsSection.hasMatches(findQuery, in: library)
                if PodcastShowsGrid.shows(matching: findQuery, in: store.shows).isEmpty, !localMatches {
                    ContentUnavailableView.search(text: findText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        PodcastLocalShowsSection(navigation: navigation, findQuery: findQuery)
                        PodcastShowsGrid(navigation: navigation, findQuery: findQuery, organizes: onManageShows == nil)
                    }
                }
            } else {
                // 普通 VStack:惰性栈给 ForEach 的每一项都留间距,当下没内容的区块(没有听到一半的、
                // 没有喜欢的)画不出东西也照样占一份 28,挪到中间的区块下面就空出两倍。
                // 区块只有几块,里面的节目网格自己是惰性的。
                VStack(alignment: .leading, spacing: 28) {
                    // 先后与显隐由「…›调整区块」定。
                    ForEach(PodcastLibrarySectionLayout.decode(sectionLayoutRawValue).visibleSections, id: \.self) { section in
                        sectionContent(section)
                    }
                    PodcastRegionHiddenNote()
                }
            }
        }
        .task {
            store.loadIfNeeded()
            store.refreshAllIfDue()
        }
        .onChange(of: store.isLoaded) { _, loaded in
            if loaded { store.refreshAllIfDue() }
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: PodcastLibrarySection) -> some View {
        switch section {
        // 文件夹与标签只在播客页上整理;首页那一面和电台那一面一样,只摆节目。
        case .myShows: PodcastShowsGrid(navigation: navigation, onManage: onManageShows, organizes: onManageShows == nil)
        case .continueListening: PodcastContinueListeningRow(navigation: navigation)
        case .latestEpisodes: PodcastLatestEpisodesSection(navigation: navigation)
        case .likedEpisodes: PodcastLikedEpisodesSection(navigation: navigation)
        case .localShows: PodcastLocalShowsSection(navigation: navigation)
        }
    }
}

// MARK: - Arrange sections

extension PodcastLibrarySection {
    var title: LocalizedStringKey {
        switch self {
        case .myShows: "podcast_my_shows"
        case .continueListening: "podcast_continue_listening"
        case .latestEpisodes: "podcast_latest_episodes"
        case .likedEpisodes: "podcast_liked_episodes"
        case .localShows: "podcast_local_shows"
        }
    }

    var systemImage: String {
        switch self {
        case .myShows: "square.grid.2x2"
        case .continueListening: "play.circle"
        case .latestEpisodes: "clock"
        case .likedEpisodes: "heart"
        case .localShows: "internaldrive"
        }
    }
}

/// 「…」菜单里的「调整区块」。还没订阅时页面是发现,没有区块可排,不出现。
struct PodcastSectionsEditorButton: View {
    let navigation: PodcastNavigationModel

    var body: some View {
        if !PodcastStore.shared.shows.isEmpty {
            Button {
                navigation.showsSectionEditor = true
            } label: {
                Label("podcast_sections_title", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("podcast.sections.edit")
        }
    }
}

/// 播客页各区块的先后与显隐。iOS 是常驻编辑态的列表(拖动把手、开关),
/// Mac 是勾选框加上下移,和「调整搜索结果」同一种做法。
struct PodcastSectionsEditor: View {
    @AppStorage(PodcastLibrarySectionLayout.storageKey) private var rawValue = ""
    @Environment(\.dismiss) private var dismiss

    private var layout: PodcastLibrarySectionLayout {
        PodcastLibrarySectionLayout.decode(rawValue)
    }

    private func update(_ change: (inout PodcastLibrarySectionLayout) -> Void) {
        var updated = layout
        change(&updated)
        rawValue = updated.encoded
    }

    private func visibilityBinding(for section: PodcastLibrarySection) -> Binding<Bool> {
        Binding(
            get: { layout.isVisible(section) },
            set: { visible in update { $0.setVisible(visible, for: section) } }
        )
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.order, id: \.self) { section in
                        if section.canHide {
                            Toggle(isOn: visibilityBinding(for: section)) {
                                Label(section.title, systemImage: section.systemImage)
                            }
                        } else {
                            Label(section.title, systemImage: section.systemImage)
                        }
                    }
                    .onMove { source, destination in
                        update { $0.move(fromOffsets: source, toOffset: destination) }
                    }
                } footer: {
                    Text("podcast_sections_footer")
                }

                Section {
                    Button("search_layout_restore_default") { rawValue = "" }
                        .disabled(layout.isDefault)
                }
            }
            // 常驻编辑态, 拖动把手一眼可见, 不必先长按才发现能排。
            .environment(\.editMode, .constant(.active))
            .navigationTitle(Text("podcast_sections_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
            .pmSheetSymmetricMargins()
            .pmFitsContentInSheet()
        }
    }
    #endif

    #if os(macOS)
    private var macBody: some View {
        let order = layout.order
        return VStack(alignment: .leading, spacing: 12) {
            Text("podcast_sections_title")
                .font(.headline)

            VStack(spacing: 2) {
                ForEach(Array(order.enumerated()), id: \.element) { index, section in
                    HStack(spacing: 8) {
                        Toggle(isOn: visibilityBinding(for: section)) {
                            Label(section.title, systemImage: section.systemImage)
                                .labelStyle(.titleAndIcon)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(!section.canHide)

                        Spacer(minLength: 12)

                        Button {
                            update { $0.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1) }
                        } label: {
                            Image(systemName: "chevron.up")
                                .frame(width: 18, height: 18)
                        }
                        .disabled(index == 0)
                        .accessibilityLabel(Text("home_edit_move_up"))

                        Button {
                            update { $0.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2) }
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 18, height: 18)
                        }
                        .disabled(index == order.count - 1)
                        .accessibilityLabel(Text("home_edit_move_down"))
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }

            Text("podcast_sections_footer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("search_layout_restore_default") { rawValue = "" }
                    .disabled(layout.isDefault)
                Spacer()
                Button("done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
    #endif
}

/// 当前店面不显示的订阅(别的设备同步来的手填地址、换店面前订的)。说一句,免得以为同步丢了。
struct PodcastRegionHiddenNote: View {
    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let count = store.regionHiddenShowCount
        if count > 0 {
            Label {
                Text(String(format: String(localized: "podcast_region_hidden_note %lld"), count))
            } icon: {
                Image(systemName: "globe.asia.australia")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .pmClearOfVerticalBar()
        }
    }
}

// MARK: - Continue listening

private struct PodcastContinueListeningRow: View {
    let navigation: PodcastNavigationModel

    @Environment(AudioPlayerService.self) private var player
    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let items = store.inProgressEpisodes(limit: 12)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                PodcastSectionHeader(titleKey: "podcast_continue_listening")
                    .padding(.horizontal, 16)
                    .pmClearOfVerticalBar()
                if items.count == 1, let item = items.first {
                    // 只有一集时不做横滑,卡片铺满一行,不在右边留一大块空。
                    PodcastContinueCard(episode: item.episode, show: item.show, width: nil) {
                        navigation.open(episodeID: item.episode.id)
                    }
                    .frame(maxWidth: 560, alignment: .leading)
                    .padding(.horizontal, 16)
                    .pmClearOfVerticalBar()
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(items, id: \.episode.id) { item in
                                PodcastContinueCard(episode: item.episode, show: item.show) {
                                    navigation.open(episodeID: item.episode.id)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .pmStopsAtVerticalBar()
                }
            }
        }
    }
}

/// 听到一半的一集:大封面、听到哪、一个继续键。
struct PodcastContinueCard: View {
    let episode: PodcastEpisode
    let show: PodcastShow
    /// `nil` 时撑满给它的宽度。
    var width: CGFloat? = 260
    var openDetail: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @State private var pendingInsecureHost: String?
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        let state = PodcastStore.shared.state(for: episode)
        let isCurrent = player.currentSong?.id == episode.id
        let total = episode.duration ?? 0
        let position = isCurrent ? player.currentTime : (state.position ?? 0)
        VStack(alignment: .leading, spacing: 10) {
            Button(action: openDetail) {
                HStack(alignment: .top, spacing: 12) {
                    PodcastArtwork(episode: episode, show: show, size: 72, cornerRadius: 10)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(show.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                        Text(episode.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 10) {
                Button {
                    if isCurrent {
                        player.togglePlayPause()
                    } else {
                        PodcastPlaybackLauncher.play(episode, player: player) { pendingInsecureHost = $0 }
                    }
                } label: {
                    Label(
                        isCurrent && player.isPlaying ? "pause" : "podcast_continue",
                        systemImage: isCurrent && player.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 3) {
                    if total > 0 {
                        ProgressView(value: min(1, max(0, position / total)))
                            .progressViewStyle(.linear)
                            .tint(tint)
                        Text(PodcastFormat.remaining(max(0, total - position)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu { PodcastEpisodeMenu(episode: episode, needsInsecureConsent: { pendingInsecureHost = $0 }) }
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost) {
            PodcastPlaybackLauncher.play(episode, player: player) { _ in }
        }
    }
}

// MARK: - Latest episodes

private struct PodcastLatestEpisodesSection: View {
    let navigation: PodcastNavigationModel

    private var store: PodcastStore { PodcastStore.shared }
    private static let previewCount = 6

    var body: some View {
        let latest = store.latestEpisodes(limit: Self.previewCount)
        VStack(alignment: .leading, spacing: 4) {
            PodcastSectionHeader(titleKey: "podcast_latest_episodes") {
                Button {
                    navigation.pushedAllEpisodes = true
                } label: {
                    HStack(spacing: 2) {
                        Text("podcast_see_all")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .pmClearOfVerticalBar()
            if latest.isEmpty {
                Text(store.isRefreshingAll ? "podcast_refreshing" : "podcast_all_caught_up")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ForEach(Array(latest.enumerated()), id: \.element.id) { index, episode in
                    PodcastEpisodeRow(
                        episode: episode,
                        show: store.show(id: episode.showID),
                        showsArtwork: true,
                        showsSummary: false,
                        continuing: Array(latest.dropFirst(index + 1)),
                        showsDivider: index < latest.count - 1,
                        onOpen: { navigation.open(episodeID: episode.id) }
                    )
                    .podcastEpisodeContextMenu(
                        episode,
                        continuing: Array(latest.dropFirst(index + 1)),
                        openShow: navigation.open(showID:)
                    )
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Liked episodes

private struct PodcastLikedEpisodesSection: View {
    let navigation: PodcastNavigationModel

    @Environment(MusicLibrary.self) private var library

    private var store: PodcastStore { PodcastStore.shared }
    private static let previewCount = 3

    var body: some View {
        let items = store.likedEpisodes()
        let localSongs = library.likedLocalPodcastSongs()
        if !items.isEmpty || !localSongs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                PodcastSectionHeader(titleKey: "podcast_liked_episodes") {
                    if items.count + localSongs.count > Self.previewCount {
                        Button {
                            navigation.pushedLikedEpisodes = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("podcast_see_all")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .font(.subheadline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .pmClearOfVerticalBar()
                PodcastLikedEpisodeRows(
                    items: items,
                    localSongs: localSongs,
                    limit: Self.previewCount,
                    onOpen: { navigation.open(episodeID: $0) },
                    openShow: navigation.open(showID:),
                    openLocalShow: { navigation.pushedLocalShowID = $0 }
                )
            }
            .padding(.horizontal, 16)
        }
    }
}

/// 喜欢的单集整页。
struct PodcastLikedEpisodesView: View {
    let navigation: PodcastNavigationModel

    @Environment(MusicLibrary.self) private var library

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let items = store.likedEpisodes()
        let localSongs = library.likedLocalPodcastSongs()
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                #if os(macOS)
                PodcastInlineBackButton()
                #endif
                if items.isEmpty && localSongs.isEmpty {
                    Text("podcast_no_matching_episodes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else {
                    PodcastLikedEpisodeRows(
                        items: items,
                        localSongs: localSongs,
                        onOpen: { navigation.open(episodeID: $0) },
                        openShow: navigation.open(showID:),
                        openLocalShow: { navigation.pushedLocalShowID = $0 }
                    )
                }
            }
            .padding(.horizontal, 16)
        }
        #if os(iOS)
        .navigationTitle("podcast_liked_episodes")
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Shows

enum PodcastShowSort: String, CaseIterable {
    case recentlyUpdated, title, recentlySubscribed

    var titleKey: LocalizedStringKey {
        switch self {
        case .recentlyUpdated: "podcast_sort_recently_updated"
        case .title: "podcast_sort_title"
        case .recentlySubscribed: "podcast_sort_recently_subscribed"
        }
    }

    func sorted(_ shows: [PodcastShow]) -> [PodcastShow] {
        switch self {
        case .recentlyUpdated:
            return shows.sorted { ($0.latestEpisodeAt ?? .distantPast) > ($1.latestEpisodeAt ?? .distantPast) }
        case .title:
            return shows.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlySubscribed:
            return shows.sorted { $0.subscribedAt > $1.subscribedAt }
        }
    }
}

struct PodcastShowsGrid: View {
    let navigation: PodcastNavigationModel
    var findQuery: LibraryFindPolicy.Query?
    /// 首页那一面给:标题右边多一个「管理 · N」,进完整的播客页。
    var onManage: (() -> Void)?
    /// 播客页给:节目能归进文件夹、贴标签(长按菜单与多选),没在找节目时标题下面摆文件夹与标签两排胶囊,
    /// 没筛选时按文件夹分段。首页那一面不给,和电台那一面一样。
    var organizes = false

    @AppStorage("primuse.podcast.library.sort") private var sort = PodcastShowSort.recentlyUpdated
    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]
        #endif
    }

    var body: some View {
        let organizer = navigation.organizer
        let folders = organizes ? store.folders : []
        let tags = organizes ? store.tags : []
        let ungroupedCount = organizes ? store.ungroupedShowCount : 0
        let showsBar = organizes && findQuery == nil && (!folders.isEmpty || !tags.isEmpty)
        let filter = showsBar
            ? organizer.effectiveFilter(folders: folders, tags: tags, ungroupedCount: ungroupedCount)
            : PodcastShowFilter.unfiltered
        let found = findQuery.map { Self.shows(matching: $0, in: store.shows) } ?? store.shows
        let visible = sort.sorted(filter.isNarrowed ? PodcastShowOrganization.filtered(found, with: filter) : found)
        VStack(alignment: .leading, spacing: 12) {
            PodcastSectionHeader(titleKey: "podcast_my_shows") {
                if let onManage {
                    Button(action: onManage) {
                        Text(String(
                            format: String(localized: "home_radio_wall_manage %lld"),
                            store.shows.count
                        ))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tint)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("podcast.home.manage")
                }
                Menu {
                    Picker(selection: $sort) {
                        ForEach(PodcastShowSort.allCases, id: \.self) { option in
                            Text(option.titleKey).tag(option)
                        }
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ListeningSpace.podcast.tint)
                        .frame(width: 44, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(Text("podcast_sort"))
            }
            .padding(.horizontal, 16)
            .pmClearOfVerticalBar()

            if showsBar {
                PodcastShowOrganizeBar(
                    organizer: organizer,
                    folders: folders,
                    tags: tags,
                    ungroupedCount: ungroupedCount,
                    totalCount: store.shows.count,
                    filter: filter
                )
            }

            if visible.isEmpty, filter.isNarrowed {
                // 筛空了:几个标签凑不到同一档节目上。
                VStack(alignment: .leading, spacing: 8) {
                    Text("podcast_filter_empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("radio_filter_clear") { organizer.clearFilter() }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(tint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if showsBar, !filter.isNarrowed, !folders.isEmpty {
                // 没筛选时按文件夹分段,未分组的在最后。分段只有文件夹那么几段,每段自己的网格是惰性的。
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(PodcastShowOrganization.grouped(visible)) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            folderHeader(group)
                            grid(group.shows, folders: folders, tags: tags)
                        }
                    }
                }
                .padding(.horizontal, 16)
            } else {
                grid(visible, folders: folders, tags: tags)
                    .padding(.horizontal, 16)
            }
        }
    }

    private func grid(_ shows: [PodcastShow], folders: [PodcastShowFolderSummary], tags: [PodcastShowTagSummary]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(shows) { @Sendable show in
                LazyItemCell { tile(show, folders: folders, tags: tags) }
            }
        }
    }

    @ViewBuilder
    private func tile(_ show: PodcastShow, folders: [PodcastShowFolderSummary], tags: [PodcastShowTagSummary]) -> some View {
        let organizer = navigation.organizer
        let label = PodcastShowTile(show: show, newCount: store.newEpisodeCount(showID: show.id),
                                    hasError: store.refreshFailures[show.id] != nil)
        if organizes, organizer.isSelecting {
            let isSelected = organizer.selection.contains(show.id)
            Button {
                organizer.toggleSelection(show.id)
            } label: {
                label.overlay(alignment: .topLeading) {
                    SongSelectionCheckmark(isSelected: isSelected)
                        .background(.thinMaterial, in: Circle())
                        .padding(6)
                }
            }
            .buttonStyle(.pmPressable)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("podcast.show." + show.id)
        } else {
            Button {
                navigation.open(showID: show.id)
            } label: {
                label
            }
            .buttonStyle(.pmPressable)
            .contextMenu {
                PodcastShowMenu(show: show, organizer: organizes ? organizer : nil, folders: folders, tags: tags)
            }
            .accessibilityIdentifier("podcast.show." + show.id)
        }
    }

    private func folderHeader(_ group: PodcastShowFolderGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: group.isUngrouped ? "tray" : "folder.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(group.name ?? String(localized: "radio_folder_ungrouped"))
                .font(.subheadline.weight(.semibold))
            Text(verbatim: "\(group.shows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if let name = group.name {
                PodcastFolderActions(organizer: navigation.organizer, name: name)
            }
        }
        .pmClearOfVerticalBar()
    }
}

extension PodcastShowsGrid {
    /// 「在本页里找」:节目名、主播、文件夹名与标签都算。
    static func shows(matching query: LibraryFindPolicy.Query, in shows: [PodcastShow]) -> [PodcastShow] {
        shows.filter { show in
            let fields: [String?] = [show.title, show.author, show.assignedFolderName]
            return LibraryFindPolicy.matches(query, fields: fields + show.assignedTagNames.map(Optional.some))
        }
    }
}

// MARK: - Local shows

/// 资料库里自己下载的播客文件(标成播客,或流派写着播客的),按节目(专辑)分组。
/// 点进去是这档节目的各集,播放、续听、倍速和有声书一样。
struct PodcastLocalShowsSection: View {
    let navigation: PodcastNavigationModel
    var findQuery: LibraryFindPolicy.Query?

    @Environment(MusicLibrary.self) private var library

    private var columns: [GridItem] {
        #if os(macOS)
        [GridItem(.adaptive(minimum: 130, maximum: 170), spacing: 18, alignment: .top)]
        #else
        [GridItem(.adaptive(minimum: 100, maximum: 160), spacing: 14, alignment: .top)]
        #endif
    }

    /// 在找节目时,本机节目里有没有命中的(节目名、作者,或某一集的标题)。
    @MainActor
    static func hasMatches(_ query: LibraryFindPolicy.Query, in library: MusicLibrary) -> Bool {
        library.localPodcastSongs.contains {
            LibraryFindPolicy.matches(query, fields: [$0.albumTitle, $0.albumArtistName ?? $0.artistName, $0.title])
        }
    }

    var body: some View {
        if !library.localPodcastSongs.isEmpty {
            SpokenWordLibraryContent(collection: .localPodcasts) { snapshot in
                let shows = (snapshot.allEntries + snapshot.archived).filter { entry in
                    guard let findQuery else { return true }
                    return LibraryFindPolicy.matches(findQuery, fields: [entry.book.title, entry.book.author])
                        || entry.songs.contains { LibraryFindPolicy.matches(findQuery, fields: [$0.title]) }
                }
                if !shows.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        PodcastSectionHeader(titleKey: "podcast_local_shows")
                            .padding(.horizontal, 16)
                            .pmClearOfVerticalBar()
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                            ForEach(shows) { @Sendable entry in
                                LazyItemCell {
                                    Button {
                                        navigation.pushedLocalShowID = entry.id
                                    } label: {
                                        PodcastLocalShowTile(entry: entry)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("podcast.localShow")
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }
}

/// 一档本机节目:方形封面(第一集的),名字,几集、听到哪。
private struct PodcastLocalShowTile: View {
    let entry: SpokenWordLibrarySnapshot.Entry

    var body: some View {
        let book = entry.book
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                CachedArtworkView(
                    coverRef: entry.songs.first?.coverArtFileName,
                    songID: entry.songs.first?.id,
                    size: proxy.size.width,
                    cornerRadius: 12,
                    sourceID: entry.songs.first?.sourceID,
                    filePath: entry.songs.first?.filePath,
                    fileFormat: entry.songs.first?.fileFormat,
                    placeholderIcon: "antenna.radiowaves.left.and.right",
                    fillsProposedSize: true
                )
                .frame(width: proxy.size.width, height: proxy.size.width)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .bottom) {
                if book.isInProgress {
                    ProgressView(value: book.fractionComplete)
                        .tint(ListeningSpace.podcast.tint)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
            Text(book.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(String(format: String(localized: "podcast_local_episode_count %lld"), book.items.count))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

/// 网格里的一档节目:封面 + 新单集角标 + 名字。
struct PodcastShowTile: View {
    let show: PodcastShow
    var newCount = 0
    var hasError = false

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                PodcastArtwork(show: show, size: proxy.size.width, cornerRadius: 12)
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(alignment: .topTrailing) {
                if newCount > 0 {
                    Text(verbatim: newCount > 99 ? "99+" : "\(newCount)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(tint, in: Capsule())
                        .padding(6)
                        .accessibilityLabel(Text(String(format: String(localized: "podcast_new_episodes_count %lld"), newCount)))
                } else if hasError {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                        .padding(6)
                        .accessibilityLabel(Text("podcast_refresh_failed"))
                }
            }
            Text(show.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .contentShape(Rectangle())
    }
}

/// 节目的长按菜单。播客页上多两个子菜单:移到文件夹、标签。
struct PodcastShowMenu: View {
    let show: PodcastShow
    /// 播客页给;首页那一面不给,不出归类的两项。
    var organizer: PodcastShowOrganizer?
    var folders: [PodcastShowFolderSummary] = []
    var tags: [PodcastShowTagSummary] = []
    @State private var confirmsUnsubscribe = false

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        Button {
            Task { await store.refresh(showID: show.id) }
        } label: {
            Label("refresh", systemImage: "arrow.clockwise")
        }
        Button {
            store.markAllPlayed(showID: show.id)
        } label: {
            Label("podcast_mark_all_played", systemImage: "checkmark.circle")
        }
        if let url = PodcastShare.url(for: show) {
            ShareLink(item: url) {
                Label("share", systemImage: "square.and.arrow.up")
            }
        }
        if let organizer {
            Divider()
            PodcastShowOrganizeMenus(organizer: organizer, shows: [show], folders: folders, tags: tags)
        }
        Divider()
        Button(role: .destructive) {
            store.unsubscribe(show.id)
        } label: {
            Label("podcast_unsubscribe", systemImage: "minus.circle")
        }
    }
}

// MARK: - Folders and tags

/// 「我的节目」的文件夹与标签:筛到哪个文件夹、哪几个标签,多选,还有新建、改名时弹的那个框。
/// 播客页(iPhone、iPad、Mac)各一份,挂在 `PodcastNavigationModel` 上;节目页另建一份,只用来弹框。
@MainActor
@Observable
final class PodcastShowOrganizer {
    var folderScope: PodcastShowFilter.FolderScope = .all
    var activeTags: Set<String> = []
    /// iPhone、iPad 上的多选(「…›选择」)。Mac 上右键就能归类,和电台一样不做多选。
    private(set) var isSelecting = false
    var selection: Set<String> = []
    var namePrompt: RadioNamePrompt?
    var namePromptText = ""
    var folderToDelete: String?
    var tagToDelete: String?
    var confirmsUnsubscribingSelection = false

    private var store: PodcastStore { PodcastStore.shared }

    /// 实际生效的筛选。选中的文件夹或标签被别的设备删了、改了名,就当没选,不留一页空白。
    func effectiveFilter(
        folders: [PodcastShowFolderSummary],
        tags: [PodcastShowTagSummary],
        ungroupedCount: Int
    ) -> PodcastShowFilter {
        let scope: PodcastShowFilter.FolderScope
        switch folderScope {
        case .all:
            scope = .all
        case .ungrouped:
            scope = !folders.isEmpty && ungroupedCount > 0 ? .ungrouped : .all
        case .folder(let name):
            scope = folders.contains { RadioStationOrganization.isSameName($0.name, name) } ? folderScope : .all
        }
        let liveTags = activeTags.filter { name in
            tags.contains { RadioStationOrganization.isSameName($0.name, name) }
        }
        return PodcastShowFilter(folder: scope, tagNames: liveTags)
    }

    func clearFilter() {
        folderScope = .all
        activeTags = []
    }

    func toggleTag(_ name: String) {
        if activeTags.contains(where: { RadioStationOrganization.isSameName($0, name) }) {
            activeTags = activeTags.filter { !RadioStationOrganization.isSameName($0, name) }
        } else {
            activeTags.insert(name)
        }
    }

    // MARK: 多选

    func beginSelecting() {
        selection = []
        isSelecting = true
    }

    func endSelecting() {
        isSelecting = false
        selection = []
    }

    func toggleSelection(_ showID: String) {
        if selection.remove(showID) == nil { selection.insert(showID) }
    }

    /// 选中的、眼下还订着的节目。别的设备退订掉的不算。
    var selectedShows: [PodcastShow] {
        store.shows.filter { selection.contains($0.id) }
    }

    /// 当前文件夹与标签筛选下看得到的节目:「全选」选的就是它们。
    var visibleShows: [PodcastShow] {
        let filter = effectiveFilter(folders: store.folders, tags: store.tags, ungroupedCount: store.ungroupedShowCount)
        return PodcastShowOrganization.filtered(store.shows, with: filter)
    }

    func unsubscribeSelection() {
        store.unsubscribe(showIDs: selectedShows.map(\.id))
        endSelecting()
    }

    // MARK: 命名与删除

    func begin(_ prompt: RadioNamePrompt) {
        namePromptText = prompt.initialText
        namePrompt = prompt
    }

    func commitNamePrompt() {
        defer { namePrompt = nil }
        guard let prompt = namePrompt else { return }
        let text = namePromptText
        switch prompt {
        case .createFolder(let ids):
            // 节目的文件夹没有空的:新建就是把这几档放进去。
            guard let name = RadioStationOrganization.normalizedFolderName(text) else { return }
            store.setFolder(name, forShowIDs: ids)
        case .renameFolder(let old):
            guard let name = RadioStationOrganization.normalizedFolderName(text) else { return }
            store.renameFolder(old, to: name)
            if case .folder(let current) = folderScope, RadioStationOrganization.isSameName(current, old) {
                folderScope = .folder(name)
            }
        case .createTag(let ids):
            store.addTag(text, toShowIDs: ids)
        case .renameTag(let old):
            guard let name = RadioStationOrganization.normalizedTagName(text) else { return }
            store.renameTag(old, to: name)
            if activeTags.contains(where: { RadioStationOrganization.isSameName($0, old) }) {
                activeTags = activeTags.filter { !RadioStationOrganization.isSameName($0, old) }
                activeTags.insert(name)
            }
        }
    }

    func deleteFolderConfirmed() {
        guard let name = folderToDelete else { return }
        if case .folder(let current) = folderScope, RadioStationOrganization.isSameName(current, name) {
            folderScope = .all
        }
        store.deleteFolder(name)
        folderToDelete = nil
    }

    func deleteTagConfirmed() {
        guard let name = tagToDelete else { return }
        activeTags = activeTags.filter { !RadioStationOrganization.isSameName($0, name) }
        store.deleteTag(name)
        tagToDelete = nil
    }
}

extension View {
    /// 新建、改名文件夹与标签的输入框,删除与批量退订前的确认。发起它们的菜单在哪一页,就由那一页挂一次。
    func podcastShowOrganizerAlerts(_ organizer: PodcastShowOrganizer) -> some View {
        modifier(PodcastShowOrganizerAlerts(organizer: organizer))
    }
}

/// 长按菜单、胶囊和分段标题都能发起,没有唯一的锚点,一律用居中的 alert(同电台页)。
private struct PodcastShowOrganizerAlerts: ViewModifier {
    @Bindable var organizer: PodcastShowOrganizer

    func body(content: Content) -> some View {
        content
            .alert(organizer.namePrompt?.title ?? "", isPresented: Binding(
                get: { organizer.namePrompt != nil },
                set: { if !$0 { organizer.namePrompt = nil } }
            )) {
                TextField(organizer.namePrompt?.fieldTitle ?? "", text: $organizer.namePromptText)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                Button("cancel", role: .cancel) { organizer.namePrompt = nil }
                Button("save") { organizer.commitNamePrompt() }
            }
            .alert(String(localized: "radio_folder_delete"), isPresented: Binding(
                get: { organizer.folderToDelete != nil },
                set: { if !$0 { organizer.folderToDelete = nil } }
            )) {
                Button("delete", role: .destructive) { organizer.deleteFolderConfirmed() }
                Button("cancel", role: .cancel) { organizer.folderToDelete = nil }
            } message: {
                Text("podcast_folder_delete_message")
            }
            .alert(String(localized: "radio_tag_delete"), isPresented: Binding(
                get: { organizer.tagToDelete != nil },
                set: { if !$0 { organizer.tagToDelete = nil } }
            )) {
                Button("delete", role: .destructive) { organizer.deleteTagConfirmed() }
                Button("cancel", role: .cancel) { organizer.tagToDelete = nil }
            } message: {
                Text("podcast_tag_delete_message")
            }
            .alert(
                String(format: String(localized: "podcast_unsubscribe_selected_title %lld"), organizer.selectedShows.count),
                isPresented: $organizer.confirmsUnsubscribingSelection
            ) {
                Button("podcast_unsubscribe", role: .destructive) { organizer.unsubscribeSelection() }
                Button("cancel", role: .cancel) {}
            } message: {
                Text("podcast_unsubscribe_selected_message")
            }
    }
}

/// 「移到文件夹」「标签」两个子菜单,写法同电台的归类菜单。节目的长按菜单、多选的批量菜单、
/// 节目页的对勾菜单共用。`folders` 与 `tags` 由调用方算好传进来:网格里每张封面一份菜单,
/// 不必各自把全部节目再归纳一遍。
struct PodcastShowOrganizeMenus: View {
    let organizer: PodcastShowOrganizer
    let shows: [PodcastShow]
    let folders: [PodcastShowFolderSummary]
    let tags: [PodcastShowTagSummary]

    private var store: PodcastStore { PodcastStore.shared }
    private var ids: [String] { shows.map(\.id) }

    var body: some View {
        Menu {
            Button("radio_folder_new", systemImage: "folder.badge.plus") {
                organizer.begin(.createFolder(assigning: ids))
            }
            if !folders.isEmpty {
                Divider()
                ForEach(folders) { folder in
                    // 选中的都已经在这个文件夹里时打勾。
                    let isCurrent = !shows.isEmpty && shows.allSatisfy { show in
                        show.assignedFolderName.map { RadioStationOrganization.isSameName($0, folder.name) } ?? false
                    }
                    Button {
                        store.setFolder(folder.name, forShowIDs: ids)
                    } label: {
                        Label(folder.name, systemImage: isCurrent ? "checkmark" : "folder")
                    }
                }
            }
            if shows.contains(where: { $0.assignedFolderName != nil }) {
                Divider()
                Button("radio_folder_remove_from", systemImage: "tray") {
                    store.setFolder(nil, forShowIDs: ids)
                }
            }
        } label: {
            Label("radio_folder_move", systemImage: "folder")
        }
        .disabled(shows.isEmpty)

        Menu {
            Button("radio_tag_new", systemImage: "tag.fill") {
                organizer.begin(.createTag(assigning: ids))
            }
            if !tags.isEmpty {
                Divider()
                ForEach(tags) { tag in
                    // 贴在选中的每一档上才打勾,再点一次是撕掉;否则给没贴的补上。
                    let applied = !shows.isEmpty && shows.allSatisfy { show in
                        show.assignedTagNames.contains { RadioStationOrganization.isSameName($0, tag.name) }
                    }
                    Button {
                        if applied {
                            store.removeTag(tag.name, fromShowIDs: ids)
                        } else {
                            store.addTag(tag.name, toShowIDs: ids)
                        }
                    } label: {
                        Label(tag.name, systemImage: applied ? "checkmark.circle.fill" : "tag")
                    }
                }
            }
        } label: {
            Label("radio_tags", systemImage: "tag")
        }
        .disabled(shows.isEmpty)
    }
}

/// 文件夹胶囊与分段标题的长按菜单:改名、删除。
private struct PodcastFolderActions: View {
    let organizer: PodcastShowOrganizer
    let name: String

    var body: some View {
        Button("radio_folder_rename", systemImage: "pencil") {
            organizer.begin(.renameFolder(name))
        }
        Button("radio_folder_delete", systemImage: "trash", role: .destructive) {
            organizer.folderToDelete = name
        }
    }
}

/// 「我的节目」标题下面的两排胶囊:一排文件夹、一排标签,点一下筛,再点一下取消。
/// 长按(Mac 上右键)胶囊改名或删除。
private struct PodcastShowOrganizeBar: View {
    let organizer: PodcastShowOrganizer
    let folders: [PodcastShowFolderSummary]
    let tags: [PodcastShowTagSummary]
    let ungroupedCount: Int
    let totalCount: Int
    /// 实际生效的筛选(见 `PodcastShowOrganizer.effectiveFilter`),胶囊的选中态照它画。
    let filter: PodcastShowFilter

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !folders.isEmpty {
                chipRow {
                    RadioFilterChip(
                        title: String(localized: "radio_folder_all"),
                        systemImage: "square.grid.2x2",
                        count: totalCount,
                        isSelected: isSelected(.all),
                        tint: tint
                    ) { organizer.folderScope = .all }

                    if ungroupedCount > 0 {
                        RadioFilterChip(
                            title: String(localized: "radio_folder_ungrouped"),
                            systemImage: "tray",
                            count: ungroupedCount,
                            isSelected: isSelected(.ungrouped),
                            tint: tint
                        ) { organizer.folderScope = .ungrouped }
                    }

                    ForEach(folders) { folder in
                        RadioFilterChip(
                            title: folder.name,
                            systemImage: "folder",
                            count: folder.showCount,
                            isSelected: isSelected(.folder(folder.name)),
                            tint: tint
                        ) {
                            organizer.folderScope = isSelected(.folder(folder.name)) ? .all : .folder(folder.name)
                        }
                        .contextMenu { PodcastFolderActions(organizer: organizer, name: folder.name) }
                    }
                }
            }

            if !tags.isEmpty {
                chipRow {
                    ForEach(tags) { tag in
                        RadioFilterChip(
                            title: tag.name,
                            systemImage: "tag",
                            count: tag.showCount,
                            isSelected: filter.tagNames.contains { RadioStationOrganization.isSameName($0, tag.name) },
                            tint: RadioTagPalette.color(for: tag.name)
                        ) { organizer.toggleTag(tag.name) }
                        .contextMenu {
                            Button("radio_tag_rename", systemImage: "pencil") {
                                organizer.begin(.renameTag(tag.name))
                            }
                            Button("radio_tag_delete", systemImage: "trash", role: .destructive) {
                                organizer.tagToDelete = tag.name
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func chipRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 1)
        }
        .pmStopsAtVerticalBar()
    }

    private func isSelected(_ scope: PodcastShowFilter.FolderScope) -> Bool {
        switch (filter.folder, scope) {
        case (.all, .all), (.ungrouped, .ungrouped):
            return true
        case (.folder(let lhs), .folder(let rhs)):
            return RadioStationOrganization.isSameName(lhs, rhs)
        default:
            return false
        }
    }
}

/// 多选时右上角的批量菜单:全选、移到文件夹、标签、取消订阅。
struct PodcastShowSelectionMenu: View {
    let organizer: PodcastShowOrganizer
    var systemImage = "ellipsis.circle"

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        Menu {
            let selected = organizer.selectedShows
            let visibleIDs = Set(organizer.visibleShows.map(\.id))
            let allSelected = !visibleIDs.isEmpty && visibleIDs.isSubset(of: organizer.selection)
            Button(
                LocalizedStringKey(allSelected ? "batch_deselect_all" : "batch_select_all"),
                systemImage: allSelected ? "circle" : "checkmark.circle"
            ) {
                organizer.selection = allSelected ? [] : visibleIDs
            }
            .disabled(visibleIDs.isEmpty)

            Section {
                PodcastShowOrganizeMenus(organizer: organizer, shows: selected, folders: store.folders, tags: store.tags)
            }

            Section {
                Button("podcast_unsubscribe", systemImage: "minus.circle", role: .destructive) {
                    organizer.confirmsUnsubscribingSelection = true
                }
                .disabled(selected.isEmpty)
            }
        } label: {
            Label("more", systemImage: systemImage)
        }
        .accessibilityIdentifier("podcast.selection.menu")
    }
}

enum PodcastShare {
    /// 分享出去的地址:从 Apple 目录订的给目录页(谁都能打开),其余给节目网站;都没有就不给。
    static func url(for show: PodcastShow) -> URL? {
        if let id = show.directoryID {
            return URL(string: "https://podcasts.apple.com/podcast/id\(id)")
        }
        return show.websiteURL
    }
}

// MARK: - Welcome (no subscriptions)

/// 一档都没订:说明这里会有什么,给搜索入口和热门节目,点加号就订。
struct PodcastWelcomeView: View {
    let navigation: PodcastNavigationModel

    private var availability: PodcastAvailabilityService { PodcastAvailabilityService.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: ListeningSpace.podcast.systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 60, height: 60)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                Text("podcast_welcome_title")
                    .font(.title2.weight(.bold))
                Text("podcast_welcome_message")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    navigation.showsDiscover = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("podcast_search_prompt")
                        Spacer()
                    }
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("podcast.welcome.search")
                if availability.allowsCustomFeeds {
                    HStack(spacing: 10) {
                        Button {
                            navigation.showsAddFeed = true
                        } label: {
                            Label("podcast_add_by_url", systemImage: "link")
                        }
                        Button {
                            navigation.showsOPMLImporter = true
                        } label: {
                            Label("podcast_import_opml", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(tint)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .pmClearOfVerticalBar()

            PodcastChartSection(genreID: nil, limit: 12) { show in
                navigation.pushedDirectoryShow = show
            }
            .padding(.horizontal, 16)
        }
    }
}

// MARK: - OPML files

enum PodcastOPMLFile {
    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "opml"), .xml, .plainText].compactMap { $0 }
    }

    /// 导入一份 OPML,返回给用户看的结果。
    @MainActor
    static func importFile(at url: URL) async -> String {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let entries = try? PodcastOPML.parse(data), !entries.isEmpty else {
            return String(localized: "podcast_opml_invalid")
        }
        let result = await PodcastStore.shared.importOPML(entries)
        return String(format: String(localized: "podcast_opml_import_result %lld %lld"), result.added, result.failed)
    }
}

/// 分享面板里的 OPML:真要分享时才生成。
struct PodcastOPMLDocument: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .xml) { _ in
            await MainActor.run { PodcastStore.shared.exportOPML() }
        }
        .suggestedFileName("Primuse Podcasts.opml")
    }
}

#if DEBUG
/// 取证用:`PRIMUSE_DEBUG_PRESENT=podcasts|podcastShows|podcastShow|podcastEpisode|podcastDiscover` 直接弹出对应页面。
/// `PRIMUSE_DEBUG_PODCAST_SEED=<feed 地址,逗号分隔>` 没订阅时先订上;
/// `PRIMUSE_DEBUG_PODCAST_PROGRESS=1` 给最新一集记一个听到一半的位置,看「继续收听」。
struct PodcastDebugScreen: View {
    let page: String
    @State private var isReady = false

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        NavigationStack {
            if isReady {
                destination
            } else {
                ProgressView()
            }
        }
        .task {
            await seed()
            isReady = true
        }
    }

    @ViewBuilder
    private var destination: some View {
        switch page {
        case "podcastShow":
            if let show = pickedShow {
                PodcastShowDetailView(source: .show(show.id))
            }
        case "podcastEpisode":
            if let episode = pickedShow.flatMap({ store.episodes(forShowID: $0.id).first })
                ?? store.latestEpisodes(limit: 1, includeFinished: true).first {
                PodcastEpisodeDetailView(episodeID: episode.id)
            }
        case "podcastDiscover":
            PodcastDiscoverView()
        case "podcastShows":
            ScrollView { PodcastShowsGrid(navigation: PodcastNavigationModel()) }
        default:
            PodcastLibraryView()
        }
    }

    /// `PRIMUSE_DEBUG_PODCAST_SHOW=<节目名的一段>` 选哪一档;没给就是第一档。
    private var pickedShow: PodcastShow? {
        if let needle = env["PRIMUSE_DEBUG_PODCAST_SHOW"], !needle.isEmpty,
           let show = store.shows.first(where: { $0.title.localizedCaseInsensitiveContains(needle) }) {
            return show
        }
        return store.shows.first
    }

    private func seed() async {
        store.loadIfNeeded()
        for _ in 0..<100 where !store.isLoaded {
            try? await Task.sleep(for: .milliseconds(200))
        }
        // 等店面取到再订:否则按手机地区猜的那一刻会把手填地址挡掉、按别的地区查目录。
        for _ in 0..<50 where !PodcastAvailabilityService.shared.isStorefrontResolved {
            try? await Task.sleep(for: .milliseconds(200))
        }
        let feeds = (env["PRIMUSE_DEBUG_PODCAST_SEED"] ?? "")
            .split(separator: ",")
            .compactMap { PodcastFeedURL.normalized(String($0)) }
        for url in feeds where store.isSubscribed(feedURL: url) == nil {
            do {
                let show = try await store.subscribe(feedURL: url)
                plog("🧪 Debug: subscribed podcast '\(show.title)' episodes=\(store.episodes(forShowID: show.id).count)")
            } catch {
                plog("🧪 Debug: podcast seed failed \(url.host ?? "?"): \(error.localizedDescription)")
            }
        }
        // `PRIMUSE_DEBUG_PODCAST_SEED_DIRECTORY=<目录 id,逗号分隔>`:按目录订阅(带目录 id),验店面核对用。
        let directoryIDs = (env["PRIMUSE_DEBUG_PODCAST_SEED_DIRECTORY"] ?? "").split(separator: ",").compactMap { Int($0) }
        for id in directoryIDs where store.subscribedShow(directoryID: id) == nil {
            do {
                guard let directoryShow = try await PodcastDirectoryService.shared.lookup(id) else {
                    plog("🧪 Debug: directory id \(id) not in this storefront's directory")
                    continue
                }
                let show = try await store.subscribe(directoryShow: directoryShow)
                plog("🧪 Debug: subscribed podcast '\(show.title)' from directory \(id)")
            } catch {
                plog("🧪 Debug: directory seed \(id) failed: \(error.localizedDescription)")
            }
        }
        if env["PRIMUSE_DEBUG_PODCAST_PROGRESS"] == "1",
           let episode = store.latestEpisodes(limit: 1).first {
            let duration = episode.duration ?? 3_600
            SpokenWordStore.shared.rememberPosition(duration * 0.35, duration: duration, forSongID: episode.id)
        }
        plog("🧪 Debug: podcast seed done shows=\(store.shows.count)")
    }
}
#endif
