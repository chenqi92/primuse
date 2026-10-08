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
    /// 「在本页里找」: 按节目名与作者筛已订阅的节目。
    @State private var findText = ""

    var body: some View {
        ScrollView {
            PodcastLibraryContent(navigation: navigation, findText: findText)
                .padding(.vertical, 12)
        }
        .pmExtendsUnderVerticalBar()
        .libraryPageFind(text: $findText, prompt: "filter_podcasts_placeholder")
        .navigationTitle("listening_space_podcast")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { PodcastLibraryToolbar(navigation: navigation) }
        .refreshable { await PodcastStore.shared.refreshAll() }
        .podcastNavigationDestinations(navigation)
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
    var showsOPMLImporter = false
    var importMessage: String?
    var pushedShowID: String?
    var pushedEpisodeID: String?
    var pushedAllEpisodes = false
    /// 本机下载的播客文件按节目分组后的那一档(`SpokenWordBook.id`)。
    var pushedLocalShowID: String?
    /// 从热门榜点进去、还没订的节目。
    var pushedDirectoryShow: PodcastDirectoryShow?

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

    private var availability: PodcastAvailabilityService { PodcastAvailabilityService.shared }
    private var store: PodcastStore { PodcastStore.shared }

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
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
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("podcast_refresh_all", systemImage: "arrow.clockwise")
                }
                .disabled(store.shows.isEmpty || store.isRefreshingAll)
                if !store.shows.isEmpty {
                    ShareLink(item: PodcastOPMLDocument(), preview: SharePreview(String(localized: "podcast_export_opml"))) {
                        Label("podcast_export_opml", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button {
                    navigation.showsSettings = true
                } label: {
                    Label("podcast_settings", systemImage: "gearshape")
                }
            } label: {
                Label("more", systemImage: "ellipsis.circle")
            }
            .accessibilityIdentifier("podcast.more")
        }
    }
}

/// 主页正文。首页「播客」那一面直接放这个,外面的滚动容器由放它的地方给。
struct PodcastLibraryContent: View {
    let navigation: PodcastNavigationModel
    /// 播客页「在本页里找」的输入; 首页那一面不传。在找节目时只摆命中的节目。
    var findText = ""

    @Environment(MusicLibrary.self) private var library
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
                    LazyVStack(alignment: .leading, spacing: 28) {
                        PodcastLocalShowsSection(navigation: navigation, findQuery: findQuery)
                        PodcastShowsGrid(navigation: navigation, findQuery: findQuery)
                    }
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 28) {
                    PodcastShowsGrid(navigation: navigation)
                    PodcastContinueListeningRow(navigation: navigation)
                    PodcastLatestEpisodesSection(navigation: navigation)
                    PodcastLocalShowsSection(navigation: navigation)
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
                        onOpen: { navigation.open(episodeID: episode.id) }
                    )
                    .podcastEpisodeContextMenu(
                        episode,
                        continuing: Array(latest.dropFirst(index + 1)),
                        openShow: navigation.open(showID:)
                    )
                    if index < latest.count - 1 {
                        Divider().padding(.leading, 72)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
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
        VStack(alignment: .leading, spacing: 12) {
            PodcastSectionHeader(titleKey: "podcast_my_shows") {
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
            .pmClearOfVerticalBar()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(sort.sorted(findQuery.map { Self.shows(matching: $0, in: store.shows) } ?? store.shows)) { show in
                    Button {
                        navigation.open(showID: show.id)
                    } label: {
                        PodcastShowTile(show: show, newCount: store.newEpisodeCount(showID: show.id),
                                        hasError: store.refreshFailures[show.id] != nil)
                    }
                    .buttonStyle(.pmPressable)
                    .contextMenu { PodcastShowMenu(show: show) }
                    .accessibilityIdentifier("podcast.show." + show.id)
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

extension PodcastShowsGrid {
    static func shows(matching query: LibraryFindPolicy.Query, in shows: [PodcastShow]) -> [PodcastShow] {
        shows.filter { LibraryFindPolicy.matches(query, fields: [$0.title, $0.author]) }
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
                            ForEach(shows) { entry in
                                Button {
                                    navigation.pushedLocalShowID = entry.id
                                } label: {
                                    PodcastLocalShowTile(entry: entry)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("podcast.localShow")
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

/// 节目的长按菜单。
struct PodcastShowMenu: View {
    let show: PodcastShow
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
        Divider()
        Button(role: .destructive) {
            store.unsubscribe(show.id)
        } label: {
            Label("podcast_unsubscribe", systemImage: "minus.circle")
        }
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
