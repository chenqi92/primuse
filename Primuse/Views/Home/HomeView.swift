import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Task handles are operational state, not rendering state. Keeping them in
/// `@State` made every debounce cancellation/replacement invalidate HomeView,
/// defeating the debounce while background metadata batches were arriving.
@MainActor
private final class HomeRefreshCoordinator {
    var debounceTask: Task<Void, Never>?
    var recommendationTask: Task<Void, Never>?
    var libraryHighlightsTask: Task<Void, Never>?
    var pendingSignature: HomeView.HomeSnapshotSignature?
    /// 上一次真正做完整库重算的时刻, 给资料库版本驱动的刷新做节流。
    var lastRefreshAt: Date?

    func cancelAll() {
        debounceTask?.cancel()
        recommendationTask?.cancel()
        libraryHighlightsTask?.cancel()
        debounceTask = nil
        recommendationTask = nil
        libraryHighlightsTask = nil
        pendingSignature = nil
    }
}

struct PersistedHomeAlbumTile: Codable, Sendable {
    let albumID: String
    let artworkSongID: String?
}

private struct RecentlyAddedAlbumsView: View {
    @Environment(MusicLibrary.self) private var library
    @Environment(\.pmHeightClass) private var heightClass
    @State private var albums: [Album] = []
    @State private var isPrepared = false
    @State private var query = ""

    private var filteredAlbums: [Album] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return albums }
        return albums.filter {
            $0.title.localizedCaseInsensitiveContains(text)
                || ($0.artistName?.localizedCaseInsensitiveContains(text) ?? false)
        }
    }

    var body: some View {
        ScrollView {
            if !isPrepared {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if albums.isEmpty {
                EmptyStateView(titleKey: "no_albums", descriptionKey: "no_albums_desc", systemImage: "square.stack")
            } else if filteredAlbums.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                // 手机横屏与资料库的专辑网格用同一档列宽，一屏能看到一行半以上。
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: heightClass.value(150, compact: 100)),
                        spacing: 16,
                        alignment: .top
                    )],
                    spacing: heightClass.value(20, compact: 14)
                ) {
                    ForEach(filteredAlbums) { album in
                        NavigationLink {
                            AlbumDetailView(album: album)
                                .navigationTitle(album.title)
                                .mediaZoomDestination(.album, id: album.id)
                        } label: {
                            AlbumCardView(album: album, showsSongCount: true)
                        }
                        .buttonStyle(.pmPressable)
                        .mediaZoomSource(.album, id: album.id)
                    }
                }
                .padding(20)
            }
        }
        .navigationTitle(HomeDiscoveryText.string("recent_albums"))
        .searchable(text: $query, prompt: Text("filter_albums_placeholder"))
        .task(id: library.searchRevision) {
            let visibleSongs = library.visibleSongs
            let visibleAlbums = library.visibleAlbums
            let sorted = await Task.detached(priority: .utility) {
                RecentlyAddedAlbumPolicy.sorted(albums: visibleAlbums, songs: visibleSongs)
            }.value
            guard !Task.isCancelled else { return }
            albums = sorted
            isPrepared = true
        }
    }
}

struct PersistedHomeRecommendation: Codable, Sendable {
    let songID: String
    let score: Double
    let reasons: [String]
}

/// Small, disposable projection of the last complete home page. The library
/// remains the source of truth: cached IDs are rehydrated from current models,
/// then the expensive highlights and recommendations refresh in the background.
struct PersistedHomeSnapshot: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let dayStamp: Int
    let visibleSongCount: Int
    let visibleAlbumCount: Int
    let visibleArtistCount: Int
    let recentSongIDs: [String]
    let heroSongIDs: [String]
    let recentlyAddedAlbums: [PersistedHomeAlbumTile]
    let recommendations: [PersistedHomeRecommendation]
}

private actor HomeInitialSnapshotCacheStore {
    static let shared = HomeInitialSnapshotCacheStore()

    private let url: URL

    init(fileManager: FileManager = .default) {
        let directory = fileManager
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("Primuse", isDirectory: true)
        url = directory.appendingPathComponent("home-initial-snapshot.plist")
    }

    func load() -> PersistedHomeSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListDecoder().decode(PersistedHomeSnapshot.self, from: data)
    }

    func save(_ snapshot: PersistedHomeSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(snapshot).write(to: url, options: .atomic)
        } catch {
            plog("⚠️ Home snapshot cache write failed: \(error.localizedDescription)")
        }
    }
}

/// Tracks the rapidly changing revision in its own observation scope so scan
/// batches do not invalidate the much larger home-page view tree.
private struct HomeLibraryRevisionObserver: View {
    @Environment(MusicLibrary.self) private var library
    let onLibraryRevisionChange: () -> Void
    let onPlaylistRevisionChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: library.searchRevision) { _, _ in
                onLibraryRevisionChange()
            }
            .onChange(of: library.playlistCollectionRevision) { _, _ in
                onPlaylistRevisionChange()
            }
    }
}

/// 把一个首页分区的构造推迟到这一层自己的 `body` 里，由 SwiftUI 单独求值。
///
/// Debug（-Onone）构建不复用栈槽：`homeSectionContent` 的 10 路 switch 会给每个分区、
/// 每层条件包装都预留一份栈，没走到的分支也照样留。播放页同样形状的 switch 已经在
/// iPhone 主线程 1MB 的栈上撞过保护页（见 `NowPlayingDeferredContent`）。
private struct HomeDeferredSection<Content: View>: View {
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        content()
    }
}

/// 首页排版拖动时显示的提示胶囊。
///
/// 预览在自己的视图图里渲染,这里只用文字和字形,不读任何环境对象。
private struct HomeSectionDragPreview: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.footnote.weight(.semibold))
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
    }
}

/// 首页翻面的转场：横向压成一条再展开，看起来像绕竖轴翻过去。
///
/// 挂在滚动内容上，不能挂到 ScrollView 本身：它背后是 UIScrollView，导航栏与滚动边缘
/// 效果要换算它的几何，挂过一版整页透视变换，切到电台时在布局提交里抛异常闪退。
/// 也不用 rotation3DEffect：透视按被变换内容的尺寸算，电台上千个时内容有十几万点高，
/// 早已压成平面，看起来与横向压扁无异，却要系统对整块内容做 3D 合成、再反推可见区。
/// 纵向不缩放，可见区才不会被推出内容。
private struct HomeFaceFlipModifier: ViewModifier {
    /// 横向宽度比例，1 是正面。
    let widthScale: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(x: widthScale, y: 1, anchor: .center)
    }
}

private struct HomeModeFlipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.58 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(PMMotion.press.animation, value: configuration.isPressed)
    }
}

private struct HomeRadioStationsPage: View {
    var body: some View {
        RadioStationsView()
            #if os(iOS)
            .minimalNavigationDetail()
            #endif
    }
}

/// 首页电台态的「我的电台」墙，全部电台都在这里。
///
/// 照歌曲列表的做法拆成单独的视图并按电台清单判等：清单不变，首页因为播放
/// 状态、资料库刷新而重算时，这面墙不跟着重新描述；播放状态由每张卡片自己
/// 观察。音乐源镜像进来的台可能上千个，懒加载网格只建可见区里的卡片。
private struct HomeRadioWall: View, @MainActor Equatable {
    let stations: [RadioStation]
    let cardSurface: Color
    let onSelect: (RadioStation) -> Void
    let onAdd: () -> Void

    @Environment(\.pmHeightClass) private var heightClass

    /// 电台清单来自电台存储的排序缓存，没变化时是同一块数组存储，这里的比较
    /// 不会逐个比电台。
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.stations == rhs.stations && lhs.cardSurface == rhs.cardSurface
    }

    private static let regularLayout = RadioStationArtworkGridLayout()

    /// 手机横屏下同样的列宽会让一排封面吃掉大半个视口。放低最小列宽让一排多放
    /// 两张，再给列宽封顶，一屏就能看全一整排还露出下一排的开头。
    private static let compactHeightLayout = RadioStationArtworkGridLayout(
        minimumItemWidth: 116,
        maximumItemWidth: 150
    )

    /// 标题始终预留两行，副标题再占一行。这样长台名可以自然换行，
    /// 短台名也不会把下一排封面提高。手机横屏留不下两行标题，收成一行。
    private var captionHeight: CGFloat {
        heightClass.value(59, compact: 42)
    }

    private var titleLineLimit: Int {
        heightClass.pick(2, compact: 1)
    }

    var body: some View {
        let layout = heightClass.pick(Self.regularLayout, compact: Self.compactHeightLayout)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("home_radio_wall_title")
                    .font(.title3.weight(.bold))
                Spacer()
                NavigationLink {
                    HomeRadioStationsPage()
                } label: {
                    Text(String(
                        format: String(localized: "home_radio_wall_manage %lld"),
                        stations.count
                    ))
                    .font(.subheadline.weight(.medium))
                }
            }
            .padding(.horizontal, 20)

            // 竖屏手机纵向有的是空间，横向反而最窄。原来做成横滑一排，
            // 结果是下面大片留白、电台却挤在一条窄带里还看不全名字。
            // 改成网格：手机通常排 2 列，宽屏自动扩展更多列并向下自然延伸。
            LazyVGrid(
                columns: [GridItem(
                    .adaptive(
                        minimum: CGFloat(layout.minimumItemWidth),
                        maximum: CGFloat(layout.maximumItemWidth)
                    ),
                    spacing: CGFloat(layout.spacing)
                )],
                alignment: .leading,
                spacing: 16
            ) {
                ForEach(stations) { station in
                    HomeRadioWallCard(
                        station: station,
                        captionHeight: captionHeight,
                        titleLineLimit: titleLineLimit,
                        onSelect: onSelect
                    )
                }
                addCard
            }
            .padding(.horizontal, CGFloat(layout.horizontalPadding))
        }
    }

    private var addCard: some View {
        Button {
            onAdd()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(cardSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(
                                    .primary.opacity(0.12),
                                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                                )
                        }

                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                        Text("radio_batch_add_title")
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                Color.clear
                    .frame(height: captionHeight)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pmPressable)
    }
}

/// 电台墙上的一张卡。播放状态在卡片自己的 body 里读：换台只重画新旧两张，
/// 节目标题更新只重画正在播的那张，而不是整面墙。
private struct HomeRadioWallCard: View {
    let station: RadioStation
    let captionHeight: CGFloat
    let titleLineLimit: Int
    let onSelect: (RadioStation) -> Void

    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)

        Button {
            onSelect(station)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // 用空白容器决定几何尺寸，避免长图的原始宽高比反过来撑大网格列。
                // 台标是 logo 而不是照片，完整显示比填满后裁掉文字更重要。
                Color.clear
                    .frame(maxWidth: .infinity)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        RadioStationArtworkContent(
                            station: station,
                            decodeSize: 320,
                            contentMode: .fit
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text(isPlaying ? String(localized: "live_badge") : String(localized: "radio_title"))
                            .font(.system(size: 9.5, weight: .bold))
                            .tracking(0.8)
                            .contentTransition(.opacity)
                            .foregroundStyle(isPlaying ? .white : .white.opacity(0.85))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                (isPlaying ? Color.red.opacity(0.9) : Color.black.opacity(0.35)),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                            .padding(9)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 2)
                    }
                    // 选中描边看 isCurrent, 徽标看 isPlaying —— 暂停当前台时只有
                    // 后者会变, 两个值各挂一次才不会有一边硬切。
                    .pmAnimation(.hover, value: isCurrent)
                    .pmAnimation(.hover, value: isPlaying)

                // 名字长短不一，固定文字区高度让同一行的卡底边齐平。
                VStack(alignment: .leading, spacing: 3) {
                    Text(station.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(titleLineLimit, reservesSpace: true)
                        .multilineTextAlignment(.leading)

                    Text(isCurrent
                         ? (player.radioMetadataTitle ?? station.playbackSubtitle)
                         : station.playbackSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: captionHeight,
                    maxHeight: captionHeight,
                    alignment: .topLeading
                )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pmPressable)
    }
}

/// 首页的两种展示模式。翻面只切换首页内容，不改变当前音乐或电台的播放状态。
enum HomeMode: String, CaseIterable, Hashable {
    case music
    case radio

    var titleKey: String.LocalizationValue {
        self == .music ? "home_mode_music" : "home_mode_radio"
    }

    var icon: String {
        self == .music ? "music.note" : "radio.fill"
    }

    var faceTitleKey: String.LocalizationValue {
        self == .music ? "home_mode_face_music" : "home_mode_face_radio"
    }

    var opposite: HomeMode {
        self == .music ? .radio : .music
    }

    /// The toolbar describes the destination, not the current state: while the
    /// user is on Side A it should read “Flip to Side B · Radio”.
    var flipTitleKey: String.LocalizationValue {
        opposite == .music ? "home_mode_flip_to_music" : "home_mode_flip_to_radio"
    }
}

struct HomeView: View {
    var switchToSettingsTab: (() -> Void)?
    let model: Model
    let openLibrarySongs: () -> Void
    /// 由「设置 › 外观 › 界面编辑」嵌入时为 true：去掉自己的导航栈与工具栏，
    /// 每个区块套上编辑操作条，内容本身不可点 —— 编辑的是版面，不是内容。
    var editorMode = false
    /// Home cards and "see all" links that lead into radio or spoken word.
    var openListeningSpace: ((ListeningSpace) -> Void)? = nil
    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(CoverTintProvider.self) private var tintProvider
    @Environment(RadioStationsStore.self) private var radioStationsStore
    @Environment(ThemeService.self) private var theme
    @Environment(\.skin) private var skin
    #if os(iOS)
    @Environment(\.legacyBottomChromeOverlayActive)
    private var legacyBottomChromeOverlayActive
    #endif

    /// 只有 iOS 的叠加式 mini player 需要列表自己让位；macOS 不走这条路径，沿用原值。
    private var bottomChromeClearance: CGFloat {
        #if os(iOS)
        let overlayActive = legacyBottomChromeOverlayActive
        #else
        let overlayActive = true
        #endif
        return BottomChromeClearancePolicy.clearance(
            legacyOverlayActive: overlayActive,
            legacy: 100,
            baseline: 16
        )
    }

    /// 音乐态是否有内容可展示。电台不再计入 —— 它有独立模式，光有电台
    /// 不该让音乐态藏起"去添加音乐源"的引导。
    private var hasContent: Bool {
        model.snapshot.hasContent
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return String(localized: "greeting_morning")
        case 12..<18: return String(localized: "greeting_afternoon")
        case 18..<22: return String(localized: "greeting_evening")
        default: return String(localized: "greeting_night")
        }
    }

    @Environment(AppUpdateChecker.self) private var updateChecker
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.pmHeightClass) private var heightClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// iPhone 才在宽画布(Duo 内屏横握)上把区块排成两栏,iPad 保持原样。
    @Environment(\.pmIsPhoneIdiom) private var isPhoneIdiom
    /// 首页滚动区的尺寸,决定要不要排成两栏。
    @State private var homeCanvasSize: CGSize = .zero
    @State private var showUpdateSheet: Bool = false
    @State private var selectedHomeRadioID: String?
    @State private var pendingInsecureHomeStation: RadioStation?
    @State private var homeModeSwitchTurn = 0
    /// 首页当前处在音乐态还是电台态。持久化 —— 常听电台的人不该每次回首页
    /// 都手动切一次。
    @AppStorage("primuse.home.mode") private var homeModeRawValue = HomeMode.music.rawValue
    @AppStorage("primuse.home.showRadio") private var showRadioOnHome = true
    #if os(iOS)
    @Environment(\.usesTopTabsShell) private var usesTopTabsShell
    #endif
    @State private var showRadioBatchAdd = false
    @State private var isHomeVisible = false
    /// 文件夹的钉选管理原本挂在设置那张列表上，那张列表已被界面编辑取代，
    /// 入口跟着搬到文件夹这一块的操作条里，免得整个功能没了去处。
    @State private var showsFolderManager = false

    /// 顶部 tab 外壳里首页上面没有大标题,头图直接顶着 tab 条,留一点空。编辑态不在那个外壳里。
    private var topTabsContentInset: CGFloat {
        #if os(iOS)
        usesTopTabsShell && !editorMode ? 12 : 0
        #else
        0
        #endif
    }

    /// 首页有没有「翻到电台」这一面。顶部 tab 外壳里电台是一个 tab,首页只剩音乐面。
    private var showsRadioFace: Bool {
        #if os(iOS)
        showRadioOnHome && !usesTopTabsShell
        #else
        showRadioOnHome
        #endif
    }

    /// 首页不再翻面到电台:电台有了自己的标签页,首页只放一块电台区。
    private var homeMode: HomeMode { .music }

    @AppStorage(ListeningSpacesIntroductionPolicy.seenKey) private var hasSeenListeningSpacesIntro = false

    /// 老用户第一次看到新布局时的一张说明卡。新装的人一开始就是新布局(首启引导
    /// 那一刻已记为看过),顶部 tab 外壳是另一套布局,两者都不出。
    private var showsListeningSpacesIntro: Bool {
        #if os(iOS)
        guard !usesTopTabsShell else { return false }
        #endif
        return ListeningSpacesIntroductionPolicy.shouldShow(
            hasSeen: hasSeenListeningSpacesIntro,
            isExistingUser: model.snapshot.hasContent
        )
    }

    private func openSpace(_ space: ListeningSpace) {
        openListeningSpace?(space)
    }

    /// 是不是该按 iPad 那档取尺寸与条目数。
    ///
    /// 大屏手机横屏也是常规宽度,只看宽度会把 iPad 的大卡片、成倍的条目数
    /// 搬进一个只有四百来点高的视口 —— 同一个 App 在两台手机上长成两副样子。
    /// 常规宽度还得配上常规高度才算 iPad。
    private var usesPadMetrics: Bool {
        sizeClass == .regular && !heightClass.isCompact && !usesTwoColumnHome
    }

    /// 宽画布(Duo 内屏横握)上区块排成两栏,每栏按手机的尺寸取值 —— 像「音乐」那样,
    /// 外屏的竖向单栏在内屏变宽时重排,内容与顺序不变。编辑态始终单栏。
    private var usesTwoColumnHome: Bool {
        !editorMode && WideCanvasColumnsPolicy.usesTwoColumns(
            isPhone: isPhoneIdiom,
            isRegularWidth: sizeClass == .regular,
            isCompactHeight: heightClass.isCompact,
            width: Double(homeCanvasSize.width),
            height: Double(homeCanvasSize.height)
        )
    }

    private var observedHomeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if homeMode == .radio, !editorMode {
                    radioModeContent
                        .transition(homeFaceTransition)
                } else if !model.isPrepared {
                    initialLoadingView
                        .transition(homeFaceTransition)
                } else if hasContent {
                    contentView
                        .transition(homeFaceTransition)
                } else {
                    emptyView
                        .transition(homeFaceTransition)
                }
            }
            .padding(.top, topTabsContentInset)
            .padding(.bottom, bottomChromeClearance)
            .pmAnimation(.contentAppear, value: model.isPrepared)
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            homeCanvasSize = size
        }
        .task {
            await refreshHomeSnapshotAfterPresentationIfNeeded()
        }
        .background {
            HomeLibraryRevisionObserver(
                onLibraryRevisionChange: scheduleDebouncedHomeRefresh,
                onPlaylistRevisionChange: refreshHomeSnapshotForPlaylistChange
            )
            if homeMode == .music, showFolders || showListeningRanking {
                HomeDiscoveryObserver(model: model.discovery)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .primusePlaybackHistoryDidChange)) { _ in
            refreshHomeSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseListeningStatsDidChange)) { _ in
            refreshHomeSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            refreshHomeSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            refreshHomeSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidCache)) { note in
            tintProvider.invalidateArtwork(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: .primuseArtworkDidInvalidate)) { note in
            tintProvider.invalidateArtwork(from: note)
        }
        .onChange(of: quickAccessRawValue) { _, _ in
            // Quick access is part of the cached home snapshot. Without an
            // explicit refresh, edits made in Library remained invisible
            // until another library revision happened to arrive.
            refreshHomeSnapshot()
        }
        .onChange(of: configuredQuickAccessLimit) { _, _ in
            refreshHomeSnapshot()
        }
        .onChange(of: showForYou) { _, _ in
            refreshHomeSnapshot()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard isHomeVisible, needsHomeRefreshWhenActive else { return }
                needsHomeRefreshWhenActive = false
                if model.isPrepared {
                    scheduleDebouncedHomeRefresh()
                } else {
                    Task { await refreshHomeSnapshotAfterPresentationIfNeeded() }
                }
            } else {
                needsHomeRefreshWhenActive = true
                refreshCoordinator.cancelAll()
            }
        }
        .onDisappear {
            isHomeVisible = false
            refreshCoordinator.cancelAll()
        }
    }

    var body: some View {
        Group {
            if editorMode {
                observedHomeContent
                    .sheet(isPresented: $showsFolderManager) {
                        NavigationStack { HomeFolderManagementView() }
                    }
            } else {
                navigationRoot
            }
        }
        .environment(model.discovery)
    }

    private var navigationRoot: some View {
        NavigationStack {
            observedHomeContent
            .navigationTitle("home_title")
            .toolbarTitleDisplayMode(.inlineLarge)
            #if os(iOS)
            .minimalNavigationRoot()
            #endif
            .toolbar {
                // 设置从标签栏挪到这里。极简导航的顶栏自带设置入口,不重复。
                #if os(iOS)
                if !usesTopTabsShell, let switchToSettingsTab {
                    ToolbarItem(placement: .topBarTrailing) {
                        HomeSettingsButton(action: switchToSettingsTab)
                    }
                }
                #else
                if let switchToSettingsTab {
                    ToolbarItem(placement: .primaryAction) {
                        HomeSettingsButton(action: switchToSettingsTab)
                    }
                }
                #endif
            }
            .sheet(isPresented: $showRadioBatchAdd) {
                RadioBatchAddView()
            }
            .navigationDestination(for: Album.self) {
                AlbumDetailView(album: $0)
                    .mediaZoomDestination(.album, id: $0.id)
            }
            .navigationDestination(for: Artist.self) {
                ArtistDetailView(artist: $0)
                    .mediaZoomDestination(.artist, id: $0.id)
            }
            .navigationDestination(for: Playlist.self) {
                PlaylistDetailView(playlist: $0)
                    .mediaZoomDestination(.playlist, id: $0.id)
            }
            // 更新提示改成 sheet 弹框 ── 之前内嵌在首页顶部当 banner 用,
            // 用户更想要"弹框"的 modal 体感, 也避免占用首页空间。
            // checker.availableUpdate 从 nil 变非 nil 时自动弹出。
            // 首页不在屏幕上时不弹 —— 设置里手动检查到新版会自己弹同一张卡片,
            // 这里再弹就成了从隐藏的标签页里叠出第二个。
            .onChange(of: updateChecker.availableUpdate) { _, newValue in
                guard newValue != nil else { return }
                guard isHomeVisible, !showUpdateSheet else { return }
                UpdateBannerSheet.presentWithoutSystemTransition { showUpdateSheet = true }
            }
            .onAppear {
                isHomeVisible = true
                if !showRadioOnHome {
                    homeModeRawValue = HomeMode.music.rawValue
                }
                if updateChecker.availableUpdate != nil {
                    UpdateBannerSheet.presentWithoutSystemTransition { showUpdateSheet = true }
                }
            }
            .onChange(of: showRadioOnHome) { _, isVisible in
                guard !isVisible else { return }
                homeModeRawValue = HomeMode.music.rawValue
            }
            .alert("insecure_http_warning_title", isPresented: Binding(
                get: { pendingInsecureHomeStation != nil },
                set: { if !$0 { pendingInsecureHomeStation = nil } }
            )) {
                Button("cancel", role: .cancel) {
                    pendingInsecureHomeStation = nil
                }
                Button("insecure_http_continue", role: .destructive) {
                    guard let station = pendingInsecureHomeStation,
                          let url = station.url,
                          let trustTarget = TrustedHTTPTransport.trustTarget(for: url) else { return }
                    SSLTrustStore.shared.allowInsecureHTTP(domain: trustTarget)
                    pendingInsecureHomeStation = nil
                    performHomeRadioToggle(station)
                }
            } message: {
                Text(String(
                    format: String(localized: "insecure_http_warning_message %@"),
                    pendingInsecureHomeStation?.url.flatMap(TrustedHTTPTransport.trustTarget(for:)) ?? ""
                ))
            }
            // fullScreenCover + 透明背景实现居中 modal 弹框, 替代之前
            // 的底部 sheet (sheet 视觉上像"双层弹框", 用户反馈丑)。
            // macOS 没有 fullScreenCover, 退化成普通 sheet。
            #if os(iOS)
            .fullScreenCover(isPresented: $showUpdateSheet) {
                UpdateBannerSheet()
            }
            #else
            .sheet(isPresented: $showUpdateSheet) {
                UpdateBannerSheet()
            }
            #endif
        }
        .mediaZoomNamespace(homeZoomNamespace)
    }

    // MARK: - Content

    // Section toggles. Hero is mandatory (always shown).
    @AppStorage("primuse.home.showStatsGlimpse") private var showStatsGlimpse: Bool = true
    @AppStorage("primuse.home.showForYou") private var showForYou: Bool = true
    @AppStorage("primuse.home.showTopArtists") private var showTopArtists: Bool = true
    @AppStorage("primuse.home.showRecentlyAdded") private var showRecentlyAdded: Bool = true
    @AppStorage("primuse.home.showContinueListening") private var showContinueListening: Bool = true
    @AppStorage("primuse.home.showQuickAccess") private var showQuickAccess: Bool = true
    @AppStorage("primuse.home.showPlaylists") private var showPlaylists: Bool = true
    @AppStorage("primuse.home.showFolders") private var showFolders = true
    @AppStorage("primuse.home.showListeningRanking") private var showListeningRanking = true
    @AppStorage(HomeSectionConfiguration.orderKey) private var homeSectionOrderRawValue = ""
    @AppStorage(HomeSectionLayoutConfiguration.storageKey) private var homeSectionLayoutRawValue = ""
    @AppStorage(LibraryPinStorage.defaultsKey) private var quickAccessRawValue = ""
    @AppStorage(LibraryDisplayConfiguration.quickAccessLimitKey)
    private var configuredQuickAccessLimit = LibraryDisplayConfiguration.defaultQuickAccessLimit
    /// 首页这一层导航栈的 zoom 命名空间:卡片放大成详情页,返回时缩回卡片。
    @Namespace private var homeZoomNamespace
    @State private var needsHomeRefreshWhenActive = false
    // Debounce for `searchRevision`-driven refreshes. MusicLibrary bumps
    // `searchRevision` on *every* upsert batch during a scan, so a large
    // library scan would otherwise fire refreshHomeSnapshot() dozens
    // of times — each one a full main-thread resort/regroup/recommend.
    // Coalesce the storm and only recompute once it settles.
    @State private var refreshCoordinator = HomeRefreshCoordinator()

    // Owned by ContentView so navigation can discard the page without losing
    // its last complete projection or treating cancelled work as a cache hit.
    @MainActor
    @Observable
    final class Model {
        fileprivate var snapshot = HomeSnapshot()
        var isPrepared = false
        let discovery = HomeDiscoveryModel()
        @ObservationIgnored var signature: HomeSnapshotSignature?
        @ObservationIgnored var highlightsSignature: HomeSnapshotSignature?
        @ObservationIgnored var recommendationSignature: HomeSnapshotSignature?

        func needsRefresh(for signature: HomeSnapshotSignature) -> Bool {
            !isPrepared || self.signature != signature
                || highlightsSignature != signature
                || (signature.showsRecommendations && recommendationSignature != signature)
        }
    }

    struct HomeSnapshotSignature: Equatable {
        let libraryRevision: Int
        let playlistRevision: Int
        let historyRevision: Int
        let visibleSongCount: Int
        let visibleAlbumCount: Int
        let visibleArtistCount: Int
        let recentSongIDs: [String]
        let dayStamp: Int
        let localeIdentifier: String
        let timeZoneIdentifier: String
        let quickAccess: String
        let quickAccessLimit: Int
        let showsRecommendations: Bool
    }

    struct HomeAlbumTile: Identifiable, Sendable {
        let album: Album
        let artworkSong: Song?

        var id: String { album.id }
    }

    private struct HomeAlbumAccumulator: Sendable {
        var latestDate: Date
        var firstSong: Song
        var firstCoveredSong: Song?
    }

    fileprivate struct HomePlaylistTile: Identifiable {
        let playlist: Playlist
        let songCount: Int

        var id: String { playlist.id }
    }

    fileprivate enum HomeQuickItem: Identifiable {
        case liked(Playlist)
        case album(Album)
        case artist(Artist)
        case playlist(HomePlaylistTile)

        var id: String {
            switch self {
            case .liked: "playlist:\(MusicLibrary.likedSongsPlaylistID)"
            case .album(let album): "album:\(album.id)"
            case .artist(let artist): "artist:\(artist.id)"
            case .playlist(let tile): "playlist:\(tile.id)"
            }
        }
    }

    fileprivate struct HomeSnapshot {
        var hasContent = false
        var statsGlimpse: PlayHistoryStore.Summary?
        var forYouResults: [MusicDiscoveryResult] = []
        var recentSongs: [Song] = []
        var heroCoverSongs: [Song] = []
        var recentlyAddedAlbums: [HomeAlbumTile] = []
        var topArtists: [Artist] = []
        var topArtistsHasHistory = false
        var playlists: [HomePlaylistTile] = []
        var quickItems: [HomeQuickItem] = []
        var likedPlaylist: Playlist?
    }

    struct InitialHomeSnapshotPayload: Sendable {
        let heroCoverSongs: [Song]
        let recentlyAddedAlbums: [HomeAlbumTile]
        let forYouResults: [MusicDiscoveryResult]
    }

    private var homeSectionOrder: [HomeSectionKind] {
        HomeSectionConfiguration.decode(homeSectionOrderRawValue)
    }

    private var likedPlaylist: Playlist {
        model.snapshot.likedPlaylist
            ?? Playlist(
                id: MusicLibrary.likedSongsPlaylistID,
                name: String(localized: "playlist_liked_name")
            )
    }

    private var contentView: some View {
        // Section contents are bounded. Stable vertical sizes avoid lazy
        // placement loops when a ranking card changes height near the viewport.
        VStack(alignment: .leading, spacing: editorMode ? 12 : 24) {
            if editorMode {
                Text("home_editor_hint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                homeEditorRadioToggle
            } else if model.snapshot.hasContent {
                libraryHeroSection
            }
            if !editorMode {
                if showsListeningSpacesIntro {
                    HomeListeningSpacesIntroCard()
                }
                HomeContinueSpacesRow(openSpace: openSpace)
                HomeBooksInProgressStrip(minimumCount: 2, openSpace: openSpace)
            }

            if usesTwoColumnHome {
                homeTwoColumnSections
            } else {
                ForEach(editorMode ? editableHomeSections : homeSectionOrder) { section in
                    homeSectionRow(section)
                }
            }
        }
    }

    /// 两栏:可见的区块按顺序交替放进左右两栏,各栏按紧凑宽度(手机)排版。
    private var homeTwoColumnSections: some View {
        let visible = homeSectionOrder.filter(homeSectionHasContent)
        let columns = WideCanvasColumnsPolicy.homeColumns(sectionCount: visible.count)
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(columns.leading.map { visible[$0] }) { section in
                    homeSectionRow(section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 24) {
                ForEach(columns.trailing.map { visible[$0] }) { section in
                    homeSectionRow(section)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .environment(\.horizontalSizeClass, .compact)
    }

    /// 这个区块此刻有没有东西可显示(与 `homeSectionContent` 的显示条件一致),两栏分配只数有内容的。
    private func homeSectionHasContent(_ section: HomeSectionKind) -> Bool {
        switch section {
        case .continueListening: showContinueListening && !model.snapshot.recentSongs.isEmpty
        case .radio: false
        case .quickAccess: showQuickAccess && !model.snapshot.quickItems.isEmpty
        case .forYou: showForYou && !model.snapshot.forYouResults.isEmpty
        case .playlists: showPlaylists && !model.snapshot.playlists.isEmpty
        case .folders: showFolders
        case .listeningRanking: showListeningRanking
        case .topArtists: showTopArtists && !model.snapshot.topArtists.isEmpty
        case .recentlyAdded: showRecentlyAdded && !model.snapshot.recentlyAddedAlbums.isEmpty
        case .stats: showStatsGlimpse && model.snapshot.statsGlimpse != nil
        }
    }

    /// 分区本身经 `HomeDeferredSection` 推迟构造，别直接内联回来（见那个类型的说明）；
    /// 显示条件留在这里判断，失效范围与原来一致。
    @ViewBuilder
    private func homeSectionContent(_ section: HomeSectionKind) -> some View {
        let style = homeLayout.style(for: section)
        switch section {
        case .continueListening:
            if showContinueListening, !model.snapshot.recentSongs.isEmpty {
                HomeDeferredSection { continueListeningSection(style) }
            }
        case .radio:
            // 电台有了自己的标签页;首页留一条横排,没有电台时是一张添加卡片。
            if showRadioOnHome {
                HomeRadioSpaceSection(openSpace: openSpace)
            }
        case .quickAccess:
            if showQuickAccess, !model.snapshot.quickItems.isEmpty {
                HomeDeferredSection { quickAccessSection(style) }
            }
        case .forYou:
            if showForYou, !model.snapshot.forYouResults.isEmpty {
                HomeDeferredSection { forYouSection(style) }
            }
        case .playlists:
            if showPlaylists, !model.snapshot.playlists.isEmpty {
                HomeDeferredSection { playlistsSection(style) }
            }
        case .folders:
            if showFolders { HomeFoldersSection() }
        case .listeningRanking:
            if showListeningRanking { HomeListeningRankingSection() }
        case .topArtists:
            if showTopArtists, !model.snapshot.topArtists.isEmpty {
                HomeDeferredSection { artistsSection(style) }
            }
        case .recentlyAdded:
            if showRecentlyAdded, !model.snapshot.recentlyAddedAlbums.isEmpty {
                HomeDeferredSection { recentlyAddedAlbumsSection(style) }
            }
        case .stats:
            if showStatsGlimpse, let summary = model.snapshot.statsGlimpse {
                HomeDeferredSection { statsGlimpseSection(summary) }
            }
        }
    }

    /// 每块区域选定的排布。编辑入口在「设置 › 外观 › 界面编辑」—— 调整是低频
    /// 操作，而首页是高频界面，把按钮常驻在这里只会挡路；但编辑时看到的必须是
    /// 真实首页，所以那个入口把这张页面原样嵌进去，只多套一层操作条。
    private var homeLayout: HomeSectionLayoutConfiguration {
        HomeSectionLayoutConfiguration.decode(homeSectionLayoutRawValue)
    }

    /// 快照的取数上限。必须不小于设置里能调到的最大值,否则用户调大了也不会
    /// 多出内容,看起来就像设置没生效。
    nonisolated static let recentlyAddedAlbumPoolLimit = 24
    nonisolated static let playlistPoolLimit = 20
    nonisolated static let topArtistPoolLimit = 20

    /// 用户没设过条目数时,沿用各排布原本按尺寸类给的默认值。
    private func sectionItemCount(_ section: HomeSectionKind, _ fallback: Int) -> Int {
        homeLayout.itemCount(for: section) ?? fallback
    }

    // MARK: - 编辑态

    /// 编辑态列出全部可配置区块,包括已隐藏和当前没内容的 —— 否则关掉一块之后
    /// 它就从界面上消失了,用户没有任何入口把它开回来。
    private var editableHomeSections: [HomeSectionKind] {
        homeSectionOrder.filter(\.isUserConfigurable)
    }

    private func isSectionVisible(_ section: HomeSectionKind) -> Bool {
        switch section {
        case .continueListening: showContinueListening
        case .quickAccess: showQuickAccess
        case .forYou: showForYou
        case .playlists: showPlaylists
        case .folders: showFolders
        case .listeningRanking: showListeningRanking
        case .topArtists: showTopArtists
        case .recentlyAdded: showRecentlyAdded
        case .stats: showStatsGlimpse
        case .radio: true
        }
    }

    private func setSectionVisible(_ section: HomeSectionKind, _ visible: Bool) {
        switch section {
        case .continueListening: showContinueListening = visible
        case .quickAccess: showQuickAccess = visible
        case .forYou: showForYou = visible
        case .playlists: showPlaylists = visible
        case .folders: showFolders = visible
        case .listeningRanking: showListeningRanking = visible
        case .topArtists: showTopArtists = visible
        case .recentlyAdded: showRecentlyAdded = visible
        case .stats: showStatsGlimpse = visible
        case .radio: break
        }
    }

    /// 行数在 1–3 之间轮换 —— 三档而已,一个按钮点过去比塞一对加减号省地方。
    private func advanceSectionRows(_ section: HomeSectionKind) {
        let style = homeLayout.style(for: section)
        guard let range = HomeSectionLayoutPolicy.rowsRange(for: section, style: style) else { return }
        var configuration = homeLayout
        let next = homeLayout.rowCount(for: section) >= range.upperBound
            ? range.lowerBound
            : homeLayout.rowCount(for: section) + 1
        configuration.setRowCount(next, for: section)
        homeSectionLayoutRawValue = configuration.encoded()
    }

    /// 电台是首页的另一面（右上角切换），不参与区块排序，但用户在这里就想
    /// 一并决定它显不显示，所以放在编辑态的最前面。
    private var homeEditorRadioToggle: some View {
        Toggle(isOn: $showRadioOnHome) {
            Label("radio_home_visibility", systemImage: "radio")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(homeCardSurface.opacity(0.55))
        }
        .padding(.horizontal, 12)
        .accessibilityIdentifier("home.edit.radio")
    }

    private func advanceSectionLayout(_ section: HomeSectionKind) {
        var configuration = homeLayout
        configuration.advanceStyle(for: section)
        homeSectionLayoutRawValue = configuration.encoded()
    }

    private func adjustSectionCount(_ section: HomeSectionKind, by delta: Int) {
        guard let range = HomeSectionLayoutPolicy.itemCountRange(for: section) else { return }
        let current = homeLayout.itemCount(for: section)
            ?? HomeSectionLayoutPolicy.defaultItemCount(for: section)
        var configuration = homeLayout
        configuration.setItemCount(min(max(current + delta, range.lowerBound), range.upperBound), for: section)
        homeSectionLayoutRawValue = configuration.encoded()
    }

    private func moveSection(_ section: HomeSectionKind, by offset: Int) {
        var order = homeSectionOrder
        guard let from = order.firstIndex(of: section) else { return }
        let to = from + offset
        guard order.indices.contains(to) else { return }
        order.swapAt(from, to)
        homeSectionOrderRawValue = HomeSectionConfiguration.encode(order)
    }

    /// 把 `moved` 放到 `target` 原来的位置上。拖放只给得到「落在谁身上」,具体是
    /// 插到前面还是后面由两者当前的先后决定,这样上拖下拖都落在手指所指那一块。
    private func moveSection(_ moved: HomeSectionKind, onto target: HomeSectionKind) {
        guard moved != target else { return }
        var order = homeSectionOrder
        guard let from = order.firstIndex(of: moved),
              let to = order.firstIndex(of: target) else { return }
        order.remove(at: from)
        order.insert(moved, at: to)
        homeSectionOrderRawValue = HomeSectionConfiguration.encode(order)
    }

    @ViewBuilder
    private func homeSectionRow(_ section: HomeSectionKind) -> some View {
        if editorMode {
            VStack(alignment: .leading, spacing: 10) {
                homeSectionEditBar(section)
                if isSectionVisible(section) {
                    // 编辑的是版面，不是内容：区块里的封面和按钮一律不响应，
                    // 免得一边排版一边误触播放或跳转。
                    homeSectionContent(section)
                        .allowsHitTesting(false)
                }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(homeCardSurface.opacity(isSectionVisible(section) ? 0.55 : 0.28))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        .tint.opacity(isSectionVisible(section) ? 0.45 : 0.18),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
            }
            .opacity(isSectionVisible(section) ? 1 : 0.55)
            .padding(.horizontal, 12)
            // 拖动会把内容搬进独立的预览宿主,那里拿不到本页注入的环境对象,
            // 区块里读 MusicLibrary / HomeDiscoveryModel 之类的子视图会当场闪退。
            // 给一个只有区块名字的轻量预览,整块内容就不会在那个宿主里重新渲染。
            .draggable(section.rawValue) {
                HomeSectionDragPreview(title: section.title)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let moved = HomeSectionKind(rawValue: raw) else { return false }
                pmWithAnimation(.list) { moveSection(moved, onto: section) }
                return true
            }
            .contextMenu {
                Button {
                    pmWithAnimation(.list) { moveSection(section, by: -1) }
                } label: { Label("home_edit_move_up", systemImage: "arrow.up") }
                Button {
                    pmWithAnimation(.list) { moveSection(section, by: 1) }
                } label: { Label("home_edit_move_down", systemImage: "arrow.down") }
            }
        } else {
            homeSectionContent(section)
        }
    }

    private func homeSectionEditBar(_ section: HomeSectionKind) -> some View {
        let visible = isSectionVisible(section)
        let style = homeLayout.style(for: section)
        let range = HomeSectionLayoutPolicy.itemCountRange(for: section)
        let count = homeLayout.itemCount(for: section)
            ?? HomeSectionLayoutPolicy.defaultItemCount(for: section)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                Text(section.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if section == .folders {
                    Button { showsFolderManager = true } label: {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel(Text(HomeDiscoveryText.string("manage_folders")))
                    .accessibilityIdentifier("home.edit.manageFolders")
                }

                Button {
                    pmWithAnimation(.list) { setSectionVisible(section, !visible) }
                } label: {
                    Image(systemName: visible ? "eye" : "eye.slash")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityLabel(section.title)
                .accessibilityIdentifier("home.edit.visibility." + section.rawValue)
            }

            if visible, HomeSectionLayoutPolicy.isConfigurable(section) || range != nil {
                HStack(spacing: 10) {
                    if HomeSectionLayoutPolicy.isConfigurable(section) {
                        Button {
                            pmWithAnimation(.list) { advanceSectionLayout(section) }
                        } label: {
                            Label(LocalizedStringKey(style.titleKey), systemImage: style.icon)
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("home.edit.layout." + section.rawValue)
                    }

                    if HomeSectionLayoutPolicy.rowsRange(for: section, style: style) != nil {
                        Button {
                            pmWithAnimation(.list) { advanceSectionRows(section) }
                        } label: {
                            Text(
                                String(
                                    format: String(localized: "home_rows_format"),
                                    homeLayout.rowCount(for: section)
                                )
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .accessibilityIdentifier("home.edit.rows." + section.rawValue)
                    }

                    if let range {
                        Spacer(minLength: 4)
                        Text("home_count_label")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Text(count.formatted())
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                        Button {
                            pmWithAnimation(.list) { adjustSectionCount(section, by: -1) }
                        } label: {
                            Image(systemName: "minus").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.mini)
                        .disabled(count <= range.lowerBound)
                        .accessibilityIdentifier("home.edit.count.decrement." + section.rawValue)
                        Button {
                            pmWithAnimation(.list) { adjustSectionCount(section, by: 1) }
                        } label: {
                            Image(systemName: "plus").font(.caption2.weight(.bold))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.mini)
                        .disabled(count >= range.upperBound)
                        .accessibilityIdentifier("home.edit.count.increment." + section.rawValue)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var selectedHomeRadio: RadioStation? {
        let stations = radioStationsStore.stations
        if let selectedHomeRadioID,
           let selected = stations.first(where: { $0.id == selectedHomeRadioID }) {
            return selected
        }
        if let current = player.currentRadioStation,
           stations.contains(where: { $0.id == current.id }) {
            return current
        }
        return stations.first
    }

    private func radioSpotlightCard(_ station: RadioStation) -> some View {
        let stations = radioStationsStore.stations
        let currentIndex = stations.firstIndex(where: { $0.id == station.id }) ?? 0
        let isCurrent = player.currentRadioStation?.id == station.id
        let isPlaying = isCurrent && (player.isPlaying || player.isLoading)

        return VStack(alignment: .leading, spacing: heightClass.value(14, compact: 10)) {
            homeFaceHeader(.radio, onDarkSurface: true)

            HStack(spacing: 16) {
                RadioStationArtworkView(
                    station: station,
                    size: usesPadMetrics ? 126 : heightClass.value(106, compact: 76),
                    cornerRadius: 20
                )
                .shadow(color: .black.opacity(0.2), radius: 10, y: 5)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        // 只有真在播才亮红点 LIVE。无条件亮着的话，没播放时
                        // 卡片也在说"正在直播"，跟底部播放条自相矛盾。
                        if isPlaying {
                            Circle()
                                .fill(.red)
                                .frame(width: 7, height: 7)
                            Text("live_badge")
                                .font(.caption2.weight(.bold))
                                .tracking(0.8)
                        } else {
                            Image(systemName: "radio")
                                .font(.system(size: 10, weight: .semibold))
                            Text("radio_title")
                                .font(.caption2.weight(.bold))
                                .tracking(0.8)
                        }
                        Spacer()
                        Text("\(currentIndex + 1) / \(stations.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Text(station.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(heightClass.pick(2, compact: 1))

                    Text(isCurrent ? (player.radioMetadataTitle ?? station.playbackSubtitle) : station.playbackSubtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(heightClass.pick(2, compact: 1))

                    Spacer(minLength: 2)

                    HStack(spacing: 10) {
                        Button {
                            selectHomeRadio(relativeTo: station, offset: -1)
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.14), in: Circle())
                        .disabled(stations.count < 2)
                        .accessibilityLabel("radio_previous_station")

                        Button {
                            toggleHomeRadio(station)
                        } label: {
                            Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: skin.usesPosterHome ? 17 : 15, weight: .bold))
                                .frame(
                                    width: skin.usesPosterHome ? 46 : 38,
                                    height: skin.usesPosterHome ? 46 : 38
                                )
                                .contentTransition(.symbolEffect(.replace))
                                .pmAnimation(.control, value: isPlaying)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.uiDarkAccent)
                        .background(.white, in: Circle())
                        .accessibilityLabel(isPlaying ? "radio_stop" : "play")

                        Button {
                            selectHomeRadio(relativeTo: station, offset: 1)
                        } label: {
                            Image(systemName: "chevron.right")
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .background(.white.opacity(0.14), in: Circle())
                        .disabled(stations.count < 2)
                        .accessibilityLabel("radio_next_station")
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(heightClass.value(18, compact: 14))
        .frame(
            maxWidth: .infinity,
            minHeight: heightClass.value(142, compact: 110),
            alignment: .leading
        )
        .background {
            radioSpotlightBackdrop
                .clipShape(RoundedRectangle(cornerRadius: radioSpotlightRadius, style: .continuous))
        }
        .contentShape(RoundedRectangle(cornerRadius: radioSpotlightRadius))
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.25 else { return }
                selectHomeRadio(relativeTo: station, offset: value.translation.width < 0 ? 1 : -1)
            }
        )
        .pmAnimation(.contentAppear, value: station.id)
    }

    private var radioSpotlightRadius: CGFloat { skin.usesPosterHome ? 26 : 22 }

    private var radioSpotlightBackdrop: some View {
        ZStack {
            theme.uiDarkAccent
            LinearGradient(
                colors: [theme.uiAccentColor.opacity(0.76), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Color.black.opacity(0.08)
        }
    }

    // MARK: - 模式切换

    /// 固定在导航栏里的“翻面”入口。文案始终描述目的地，让用户不用先猜当前
    /// 图标代表状态还是动作；无底色的轻按钮也不会和页面主操作争夺视觉层级。
    private var modeToggleButton: some View {
        Button {
            switchHomeMode()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(Double(homeModeSwitchTurn) * 180))

                Text(String(localized: homeMode.flipTitleKey))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .contentTransition(.opacity)
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .contentShape(.rect)
        }
        .buttonStyle(HomeModeFlipButtonStyle())
        .accessibilityLabel(String(localized: homeMode.flipTitleKey))
        .accessibilityHint(String(localized: "home_mode_switch_a11y"))
    }

    private var homeFaceTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .modifier(
            active: HomeFaceFlipModifier(widthScale: 0.2, opacity: 0),
            identity: HomeFaceFlipModifier(widthScale: 1, opacity: 1)
        )
    }

    private func switchHomeMode(to destination: HomeMode? = nil) {
        let nextMode = destination ?? homeMode.opposite
        guard nextMode != homeMode else { return }

        if reduceMotion {
            homeModeRawValue = nextMode.rawValue
        } else {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
                homeModeSwitchTurn += 1
                homeModeRawValue = nextMode.rawValue
            }
        }

        #if os(iOS)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        #endif
    }

    @ViewBuilder
    private func homeFaceHeader(_ mode: HomeMode, onDarkSurface: Bool = false) -> some View {
        if showsRadioFace {
            HStack(spacing: 12) {
                Text(String(localized: mode.faceTitleKey))
                    .font(.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(onDarkSurface ? Color.white.opacity(0.72) : Color.secondary)

                Spacer()

                Button {
                    switchHomeMode(to: mode.opposite)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .rotationEffect(.degrees(Double(homeModeSwitchTurn) * 180))
                        .frame(width: 32, height: 32)
                        .contentShape(.circle)
                        .background(
                            onDarkSurface ? Color.white.opacity(0.12) : Color.primary.opacity(0.06),
                            in: Circle()
                        )
                }
                .buttonStyle(HomeModeFlipButtonStyle())
                .accessibilityLabel(String(localized: mode.flipTitleKey))
            }
        }
    }

    // MARK: - 电台态

    /// 电台态整页：正在直播的大卡 + 我的电台墙。跟音乐态互斥，切过来时
    /// 用户面对的只有电台这一件事。
    ///
    /// 外层是普通 VStack：电台墙自己就是懒加载网格，外面再套一层懒加载容器，
    /// 内层网格能不能只建可见区里的卡片就取决于系统怎么量外层了。
    @ViewBuilder
    private var radioModeContent: some View {
        let stations = radioStationsStore.stations

        VStack(alignment: .leading, spacing: 24) {
            if stations.isEmpty {
                radioModeEmptyState
            } else {
                if let station = selectedHomeRadio {
                    radioSpotlightCard(station)
                        .padding(.horizontal, 16)
                }

                HomeRadioWall(
                    stations: stations,
                    cardSurface: homeCardSurface,
                    onSelect: { station in
                        selectedHomeRadioID = station.id
                        toggleHomeRadio(station)
                    },
                    onAdd: { showRadioBatchAdd = true }
                )
                .equatable()
            }
        }
        .onChange(of: player.currentRadioStation?.id) { _, stationID in
            guard let stationID,
                  radioStationsStore.stations.contains(where: { $0.id == stationID }) else { return }
            selectedHomeRadioID = stationID
        }
    }

    private var radioModeEmptyState: some View {
        VStack(spacing: 16) {
            homeFaceHeader(.radio)
                .padding(.horizontal, 20)

            Spacer(minLength: 40)

            Image(systemName: "radio")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(width: 96, height: 96)
                .background(homeCardSurface, in: RoundedRectangle(cornerRadius: 26, style: .continuous))

            Text("radio_empty_title")
                .font(.title3.weight(.semibold))

            Text("radio_empty_description")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            NavigationLink {
                HomeRadioStationsPage()
            } label: {
                Text("radio_manage")
                    .fontWeight(.medium)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func selectHomeRadio(relativeTo station: RadioStation, offset: Int) {
        let stations = radioStationsStore.stations
        guard stations.count > 1,
              let index = stations.firstIndex(where: { $0.id == station.id }) else { return }
        selectedHomeRadioID = stations[(index + offset + stations.count) % stations.count].id
    }

    private func toggleHomeRadio(_ station: RadioStation) {
        if let url = station.url,
           TrustedHTTPTransport.requiresPlainSocket(for: url),
           let trustTarget = TrustedHTTPTransport.trustTarget(for: url),
           !SSLTrustStore.allowsInsecureHTTPHostSync(domain: trustTarget) {
            pendingInsecureHomeStation = station
            return
        }
        performHomeRadioToggle(station)
    }

    private func performHomeRadioToggle(_ station: RadioStation) {
        if player.currentRadioStation?.id == station.id,
           player.isPlaying || player.isLoading {
            player.pause()
        } else {
            SiriMediaInteractionDonor.donate(station: station)
            Task { await player.play(station: station, within: radioStationsStore.stations) }
        }
    }

    /// Coalesce `searchRevision` storms (scan batches) into a single
    /// recompute. Each call cancels the pending one and restarts the
    /// timer, so only the last revision in a burst actually rebuilds the
    /// snapshot. Recheck the signature after the delay so a foreground event
    /// or returning to this page does not repeat an already completed refresh.
    private func scheduleDebouncedHomeRefresh() {
        guard scenePhase == .active, isHomeVisible else {
            needsHomeRefreshWhenActive = true
            refreshCoordinator.cancelAll()
            return
        }
        // 尾部去抖只能合并"密集到达"的版本变化。回填的发布间隔本身就比去抖
        // 窗口长, 所以单靠去抖, 每一次发布都会在窗口末尾换来一次完整重算 ——
        // 实测主线程 10~16 ms 加后台 0.8~2.1 s, 而发布间隔并不由用户选的档位
        // 决定。去抖之外再加一道最小重算间隔, 让连续发布只重算一次。用户自己
        // 的改动 (歌单/设置/场景切换) 走 refreshHomeSnapshot(), 不受这道闸门约束。
        let elapsed = refreshCoordinator.lastRefreshAt.map { Date().timeIntervalSince($0) }
        let delay = LibraryDerivedRefreshPolicy.delay(sinceLastRefresh: elapsed)
        refreshCoordinator.debounceTask?.cancel()
        refreshCoordinator.debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            refreshHomeSnapshot()
        }
    }

    /// Playlist mutations are comparatively rare and already coalesced by
    /// `MusicLibrary`. Refresh them immediately instead of routing them through
    /// the scan debounce, otherwise a batch add leaves the home card stale.
    private func refreshHomeSnapshotForPlaylistChange() {
        guard model.isPrepared else { return }
        refreshHomeSnapshot()
    }

    private var homeSnapshotSignature: HomeSnapshotSignature {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayStamp = (components.year ?? 0) * 10_000
            + (components.month ?? 0) * 100
            + (components.day ?? 0)
        return HomeSnapshotSignature(
            libraryRevision: library.searchRevision,
            playlistRevision: library.playlistCollectionRevision,
            historyRevision: PlayHistoryStore.shared.revision,
            visibleSongCount: library.visibleSongs.count,
            visibleAlbumCount: library.visibleAlbums.count,
            visibleArtistCount: library.visibleArtists.count,
            recentSongIDs: Array(library.recentPlaybackSongIDsForSync.prefix(30)),
            dayStamp: dayStamp,
            localeIdentifier: Locale.current.identifier,
            timeZoneIdentifier: TimeZone.current.identifier,
            quickAccess: quickAccessRawValue,
            quickAccessLimit: configuredQuickAccessLimit,
            showsRecommendations: showForYou
        )
    }

    /// 先把已有快照交给 SwiftUI 画出首帧，再检查资料库是否需要刷新。
    /// `.task` 在 tab 切入时会先同步执行到第一个 suspension point；旧实现
    /// 直接在这里做全库计算，导致导航动画必须等计算结束才显示首页。
    private func refreshHomeSnapshotAfterPresentationIfNeeded() async {
        isHomeVisible = true
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard scenePhase == .active else {
            needsHomeRefreshWhenActive = true
            return
        }

        if !model.isPrepared {
            await prepareInitialHomeSnapshot()
            return
        }

        try? await Task.sleep(for: .milliseconds(180))
        guard !Task.isCancelled else { return }
        refreshHomeSnapshot()
    }

    /// The first frame should never claim the library is empty while the home
    /// snapshot is still being assembled. Rehydrate the last complete page
    /// from current library models when possible, then refresh the expensive
    /// highlights and recommendations off the main actor.
    private func prepareInitialHomeSnapshot() async {
        let persistedSnapshot = await HomeInitialSnapshotCacheStore.shared.load()
        guard !Task.isCancelled else { return }
        let signature = homeSnapshotSignature
        let visibleSongs = library.visibleSongs
        let visibleAlbums = library.visibleAlbums
        let payload = Self.rehydrateInitialHomePayload(
            persistedSnapshot,
            visibleAlbums: visibleAlbums,
            songForID: { library.unobservedVisibleSong(id: $0) }
        )
        let snapshot = makeHomeSnapshot(
            forYouResults: showForYou ? (payload?.forYouResults ?? []) : [],
            heroCoverSongs: payload?.heroCoverSongs ?? Array(visibleSongs.prefix(6)),
            recentlyAddedAlbums: payload?.recentlyAddedAlbums ?? []
        )
        publishInitialHomeSnapshot(snapshot, signature: signature)

        await Task.yield()
        guard !Task.isCancelled else { return }
        scheduleLibraryHighlightsRefresh(
            songs: visibleSongs,
            albums: visibleAlbums,
            recentSongs: library.recentlyPlayedSongs(limit: 30),
            signature: signature
        )
        if showForYou {
            scheduleRecommendationRefresh(
                input: MusicDiscoveryEngine.recommendationSnapshot(in: library),
                signature: signature
            )
        }
        if homeSnapshotSignature != signature {
            scheduleDebouncedHomeRefresh()
        }
    }

    private func publishInitialHomeSnapshot(
        _ snapshot: HomeSnapshot,
        signature: HomeSnapshotSignature
    ) {
        model.snapshot = snapshot
        model.signature = signature
        refreshCoordinator.pendingSignature = signature
        tintProvider.prepare(snapshot.forYouResults.map(\.song))
        tintProvider.prepare(Array(snapshot.recentSongs.prefix(15)))
        model.isPrepared = true
    }

    static func rehydrateInitialHomePayload(
        _ persisted: PersistedHomeSnapshot?,
        visibleAlbums: [Album],
        songForID: (String) -> Song?
    ) -> InitialHomeSnapshotPayload? {
        guard let persisted,
              persisted.version == PersistedHomeSnapshot.currentVersion else { return nil }

        // A stale projection can still fill the first frame. Resolve every ID
        // against the current visible library so removed sources stay hidden.
        let heroCoverSongs = persisted.heroSongIDs.compactMap {
            songForID($0)
        }

        let albumsByID = Dictionary(
            visibleAlbums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let recentlyAddedAlbums = persisted.recentlyAddedAlbums.compactMap { tile in
            albumsByID[tile.albumID].map { album in
                HomeAlbumTile(
                    album: album,
                    artworkSong: tile.artworkSongID.flatMap {
                        songForID($0)
                    }
                )
            }
        }

        let recommendations = persisted.recommendations.compactMap { recommendation in
            songForID(recommendation.songID).map { song in
                MusicDiscoveryResult(
                    song: song,
                    score: recommendation.score,
                    reasons: recommendation.reasons.compactMap(MusicDiscoveryReason.init(rawValue:))
                )
            }
        }

        return InitialHomeSnapshotPayload(
            heroCoverSongs: heroCoverSongs,
            recentlyAddedAlbums: recentlyAddedAlbums,
            forYouResults: recommendations
        )
    }

    private func persistInitialHomeSnapshotCache(signature: HomeSnapshotSignature) {
        guard model.highlightsSignature == signature,
              !signature.showsRecommendations || model.recommendationSignature == signature else { return }
        let persisted = PersistedHomeSnapshot(
            version: PersistedHomeSnapshot.currentVersion,
            dayStamp: signature.dayStamp,
            visibleSongCount: signature.visibleSongCount,
            visibleAlbumCount: signature.visibleAlbumCount,
            visibleArtistCount: signature.visibleArtistCount,
            recentSongIDs: signature.recentSongIDs,
            heroSongIDs: model.snapshot.heroCoverSongs.map(\.id),
            recentlyAddedAlbums: model.snapshot.recentlyAddedAlbums.map {
                PersistedHomeAlbumTile(
                    albumID: $0.album.id,
                    artworkSongID: $0.artworkSong?.id
                )
            },
            recommendations: model.snapshot.forYouResults.map {
                PersistedHomeRecommendation(
                    songID: $0.song.id,
                    score: $0.score,
                    reasons: $0.reasons.map(\.rawValue)
                )
            }
        )
        Task(priority: .utility) {
            await HomeInitialSnapshotCacheStore.shared.save(persisted)
        }
    }

    private var initialLoadingView: some View {
        LoadingSkeletonGroup {
            VStack(alignment: .leading, spacing: 24) {
                // 与头图同尺寸,数据到位时版面不跳。
                RoundedRectangle(cornerRadius: skin.usesPosterHome ? 26 : 20, style: .continuous)
                    .fill(homeCardSurface)
                    .frame(height: skin.usesPosterHome
                        ? heightClass.value(318, compact: 196)
                        : heightClass.value(154, compact: 96))
                    .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                        .frame(width: 116, height: 20)

                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(homeCardSurface)
                                .frame(maxWidth: .infinity)
                                // 横屏一张卡有两百多点宽，竖着的比例会让骨架整块
                                // 超出视口 —— 冷启动第一眼就是溢出。
                                .aspectRatio(heightClass.value(0.9, compact: 1.6), contentMode: .fit)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func refreshHomeSnapshot() {
        guard scenePhase == .active, isHomeVisible else {
            needsHomeRefreshWhenActive = true
            refreshCoordinator.cancelAll()
            return
        }
        guard model.isPrepared else { return }
        let signature = homeSnapshotSignature
        guard model.needsRefresh(for: signature) else { return }
        guard refreshCoordinator.pendingSignature != signature else { return }
        refreshCoordinator.pendingSignature = signature
        refreshCoordinator.lastRefreshAt = Date()

        let visibleAlbumIDs = Set(library.visibleAlbums.map(\.id))
        let retainedRecommendations = model.snapshot.forYouResults.filter {
            library.unobservedVisibleSong(id: $0.song.id) != nil
        }
        let retainedHeroCovers = model.snapshot.heroCoverSongs.filter {
            library.unobservedVisibleSong(id: $0.id) != nil
        }
        let retainedRecentlyAddedAlbums = model.snapshot.recentlyAddedAlbums.filter {
            visibleAlbumIDs.contains($0.id)
        }
        let recommendationInput = showForYou
            ? MusicDiscoveryEngine.recommendationSnapshot(in: library)
            : nil
        // Array copies are copy-on-write and therefore cheap on the main actor.
        // The detached worker below is the only place that traverses them.
        let visibleSongs = library.visibleSongs
        let visibleAlbums = library.visibleAlbums

        let startedAt = Date()
        let snapshot = makeHomeSnapshot(
            forYouResults: retainedRecommendations,
            heroCoverSongs: retainedHeroCovers,
            recentlyAddedAlbums: retainedRecentlyAddedAlbums
        )
        model.snapshot = snapshot
        model.signature = signature

        // Kick off background tint extraction for the visible cards.
        // Idempotent — cached songs are skipped.
        tintProvider.prepare(snapshot.forYouResults.map(\.song))
        tintProvider.prepare(Array(snapshot.recentSongs.prefix(15)))

        scheduleLibraryHighlightsRefresh(
            songs: visibleSongs,
            albums: visibleAlbums,
            recentSongs: library.recentlyPlayedSongs(limit: 30),
            signature: signature
        )

        if let recommendationInput {
            scheduleRecommendationRefresh(
                input: recommendationInput,
                signature: signature
            )
        } else {
            refreshCoordinator.recommendationTask?.cancel()
            refreshCoordinator.recommendationTask = nil
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        #if DEBUG
        plog(String(format: "🏠 home snapshot main %.0fms songs=%d albums=%d artists=%d",
                    elapsed * 1000,
                    signature.visibleSongCount,
                    signature.visibleAlbumCount,
                    signature.visibleArtistCount))
        #else
        if elapsed > 0.08 {
            plog(String(format: "🏠 home snapshot refresh %.0fms songs=%d albums=%d artists=%d",
                        elapsed * 1000,
                        signature.visibleSongCount,
                        signature.visibleAlbumCount,
                        signature.visibleArtistCount))
        }
        #endif
    }

    /// Hero 封面和最近专辑都需要遍历整库；它们与推荐一样不应该参与
    /// Tab 切换首帧。保留旧快照，后台算完后再一次性发布。
    private func scheduleLibraryHighlightsRefresh(
        songs: [Song],
        albums: [Album],
        recentSongs: [Song],
        signature: HomeSnapshotSignature
    ) {
        refreshCoordinator.libraryHighlightsTask?.cancel()
        refreshCoordinator.libraryHighlightsTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                let startedAt = Date()
                let heroCoverSongs = Self.makeHeroCoverSongs(
                    songs: songs,
                    recentSongs: recentSongs
                )
                let albumTiles = Self.makeRecentlyAddedAlbumTiles(
                    songs: songs,
                    albums: albums,
                    limit: Self.recentlyAddedAlbumPoolLimit
                )
                let resolvedRecentSongs = recentSongs.isEmpty
                    ? Array(songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(30))
                    : recentSongs
                return (
                    heroCoverSongs,
                    albumTiles,
                    Date().timeIntervalSince(startedAt),
                    resolvedRecentSongs
                )
            }
            let payload = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, homeSnapshotSignature == signature else { return }
            model.snapshot.heroCoverSongs = payload.0
            model.snapshot.recentlyAddedAlbums = payload.1
            model.snapshot.recentSongs = payload.3
            model.highlightsSignature = signature
            persistInitialHomeSnapshotCache(signature: signature)

            #if DEBUG
            if payload.2 > 0.02 {
                plog(String(
                    format: "🏠 library highlights background %.0fms songs=%d",
                    payload.2 * 1000,
                    songs.count
                ))
            }
            #endif
        }
    }

    /// Capture array references on the main actor; prepare and score the
    /// recommendation input in the worker while the current page stays visible.
    private func scheduleRecommendationRefresh(
        input: MusicDiscoveryEngine.RecommendationSnapshot,
        signature: HomeSnapshotSignature
    ) {
        refreshCoordinator.recommendationTask?.cancel()
        refreshCoordinator.recommendationTask = Task { @MainActor in
            let worker = Task.detached(priority: .utility) {
                let startedAt = Date()
                let results = MusicDiscoveryEngine.dailyRecommendations(from: input.makeInput(), limit: 12, isCancelled: { Task.isCancelled })
                return (results, Date().timeIntervalSince(startedAt))
            }
            let payload = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }

            guard !Task.isCancelled, homeSnapshotSignature == signature else { return }
            model.snapshot.forYouResults = payload.0
            model.recommendationSignature = signature
            tintProvider.prepare(payload.0.map(\.song))
            persistInitialHomeSnapshotCache(signature: signature)

            #if DEBUG
            if payload.1 > 0.05 {
                plog(String(
                    format: "🏠 recommendations background %.0fms songs=%d",
                    payload.1 * 1000,
                    input.songs.count
                ))
            }
            #endif
        }
    }

    private func makeHomeSnapshot(
        forYouResults: [MusicDiscoveryResult],
        heroCoverSongs: [Song],
        recentlyAddedAlbums: [HomeAlbumTile]
    ) -> HomeSnapshot {
        let snapshotStartedAt = Date()
        let recentSongs = makeRecentSongs()
        let summary = PlayHistoryStore.shared.statisticsSummary(in: .week)
        let topArtistHistory = PlayHistoryStore.shared.topArtists(in: .month, limit: Self.topArtistPoolLimit)
        let allPlaylists = library.playlists
        let likedPlaylist = allPlaylists.first {
            $0.id == MusicLibrary.likedSongsPlaylistID
        }
        let regularPlaylists = allPlaylists
            .filter { $0.id != MusicLibrary.likedSongsPlaylistID }
            .sorted { $0.updatedAt > $1.updatedAt }
        let playlistTiles = regularPlaylists.prefix(Self.playlistPoolLimit).map(makeHomePlaylistTile)
        let baseFinishedAt = Date()

        let heroFinishedAt = Date()
        let albumsFinishedAt = Date()
        let topArtists = topArtistsForHome(history: topArtistHistory)
        let artistsFinishedAt = Date()
        let quickItems = makeHomeQuickItems(allPlaylists: allPlaylists)
        let quickFinishedAt = Date()

        let snapshot = HomeSnapshot(
            hasContent: !library.visibleSongs.isEmpty,
            statsGlimpse: summary.totalPlays > 0 ? summary : nil,
            forYouResults: forYouResults,
            recentSongs: recentSongs,
            heroCoverSongs: heroCoverSongs,
            recentlyAddedAlbums: recentlyAddedAlbums,
            topArtists: topArtists,
            topArtistsHasHistory: !topArtistHistory.isEmpty,
            playlists: playlistTiles,
            quickItems: quickItems,
            likedPlaylist: likedPlaylist
        )

        #if DEBUG
        let total = quickFinishedAt.timeIntervalSince(snapshotStartedAt)
        plog(String(
            format: "🏠 snapshot parts total=%.0fms base=%.0f hero=%.0f albums=%.0f artists=%.0f quick=%.0f",
            total * 1000,
            baseFinishedAt.timeIntervalSince(snapshotStartedAt) * 1000,
            heroFinishedAt.timeIntervalSince(baseFinishedAt) * 1000,
            albumsFinishedAt.timeIntervalSince(heroFinishedAt) * 1000,
            artistsFinishedAt.timeIntervalSince(albumsFinishedAt) * 1000,
            quickFinishedAt.timeIntervalSince(artistsFinishedAt) * 1000
        ))
        #endif

        return snapshot
    }

    private func makeHomePlaylistTile(_ playlist: Playlist) -> HomePlaylistTile {
        HomePlaylistTile(
            playlist: playlist,
            songCount: library.songCount(forPlaylist: playlist.id)
        )
    }

    private func makeHomeQuickItems(
        allPlaylists: [Playlist]
    ) -> [HomeQuickItem] {
        let albumsByID = Dictionary(
            library.visibleAlbums.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let artistsByID = Dictionary(
            library.visibleArtists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let playlistsByID = Dictionary(
            allPlaylists.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let quickAccessLimit = LibraryDisplayConfiguration.normalizedQuickAccessLimit(
            configuredQuickAccessLimit
        )
        return LibraryPinStorage.decode(
            quickAccessRawValue,
            maximumCount: quickAccessLimit
        ).compactMap { pin in
            switch pin.kind {
            case .album:
                return albumsByID[pin.itemID].map(HomeQuickItem.album)
            case .artist:
                return artistsByID[pin.itemID].map(HomeQuickItem.artist)
            case .playlist:
                if pin.itemID == MusicLibrary.likedSongsPlaylistID {
                    return .liked(
                        playlistsByID[MusicLibrary.likedSongsPlaylistID]
                            ?? Playlist(
                                id: MusicLibrary.likedSongsPlaylistID,
                                name: String(localized: "playlist_liked_name")
                            )
                    )
                }
                return playlistsByID[pin.itemID]
                    .map(makeHomePlaylistTile)
                    .map(HomeQuickItem.playlist)
            }
        }
    }

    nonisolated private static func makeRecentlyAddedAlbumTiles(
        songs: [Song],
        albums: [Album],
        limit: Int
    ) -> [HomeAlbumTile] {
        // 旧实现先在 MusicLibrary 内把全库按专辑分组一次，再回到这里二次
        // 分组并逐专辑排序。万首库上仅这一段就会占用主线程约 40ms。
        // 单次遍历同时收集最近日期、第一首歌和第一首带封面的歌，结果与旧
        // 规则一致，但不再创建两套包含所有歌曲的临时数组。
        var accumulators: [String: HomeAlbumAccumulator] = [:]
        accumulators.reserveCapacity(albums.count)

        for song in songs {
            guard let albumID = song.albumID, !albumID.isEmpty else { continue }
            let hasCover = song.coverArtFileName?.isEmpty == false

            if var accumulator = accumulators[albumID] {
                if song.dateAdded > accumulator.latestDate {
                    accumulator.latestDate = song.dateAdded
                }
                if Self.homeAlbumSongPrecedes(song, accumulator.firstSong) {
                    accumulator.firstSong = song
                }
                if hasCover {
                    if let firstCoveredSong = accumulator.firstCoveredSong {
                        if Self.homeAlbumSongPrecedes(song, firstCoveredSong) {
                            accumulator.firstCoveredSong = song
                        }
                    } else {
                        accumulator.firstCoveredSong = song
                    }
                }
                accumulators[albumID] = accumulator
            } else {
                accumulators[albumID] = HomeAlbumAccumulator(
                    latestDate: song.dateAdded,
                    firstSong: song,
                    firstCoveredSong: hasCover ? song : nil
                )
            }
        }

        return RecentlyAddedAlbumPolicy.sorted(
            albums: albums,
            latestDates: accumulators.mapValues(\.latestDate),
            limit: limit
        )
            .map { album in
                let accumulator = accumulators[album.id]
                return HomeAlbumTile(
                    album: album,
                    artworkSong: accumulator?.firstCoveredSong ?? accumulator?.firstSong
                )
            }
    }

    nonisolated private static func homeAlbumSongPrecedes(_ lhs: Song, _ rhs: Song) -> Bool {
        let leftTrack = lhs.trackNumber ?? Int.max
        let rightTrack = rhs.trackNumber ?? Int.max
        if leftTrack != rightTrack { return leftTrack < rightTrack }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    // MARK: - Stats Glimpse

    @ViewBuilder
    private func statsGlimpseSection(_ summary: PlayHistoryStore.Summary) -> some View {
        NavigationLink {
            ListeningStatsView(initialRange: .week, initiallyShowsLocalHistory: true)
                #if os(iOS)
                .minimalNavigationDetail()
                #endif
        } label: {
            if skin.usesPosterHome {
                posterStatsGlimpseLabel(summary)
            } else {
                statsGlimpseLabel(summary)
            }
        }
        .buttonStyle(.pmPressable)
    }

    private func statsGlimpseLabel(_ summary: PlayHistoryStore.Summary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("stats_title")
                    .font(.subheadline.weight(.semibold))
                Text(String(
                    format: String(localized: "home_stats_glimpse_format"),
                    summary.totalPlays,
                    formattedDuration(summary.totalSec),
                    summary.activeDays
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(homeCardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(.primary.opacity(0.06), lineWidth: 0.5)
                }
        }
        .padding(.horizontal, 16)
    }

    /// 海报版式的本周听歌:大号时长做主角,次数与活跃天数一行小字,右边一个统计图标。
    private func posterStatsGlimpseLabel(_ summary: PlayHistoryStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("stats_title")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .lastTextBaseline) {
                Text(verbatim: formattedDuration(summary.totalSec))
                    .font(.system(.title, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chart.bar.xaxis")
                    .font(.title2)
                    .foregroundStyle(.tint)
            }
            Text(String(
                format: String(localized: "home_stats_glimpse_format"),
                summary.totalPlays,
                formattedDuration(summary.totalSec),
                summary.activeDays
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(homeCardSurface)
        }
        .padding(.horizontal, 16)
    }

    /// Compact "Xh Ym" / "Ym" formatter for the stats glimpse line.
    /// Uses DateComponentsFormatter so locale-correct strings come
    /// out for Chinese / English without extra plumbing.
    private func formattedDuration(_ totalSec: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = totalSec >= 3600 ? [.hour, .minute] : [.minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(60, totalSec)) ?? "—"
    }

    /// Soft gradient tinted background pulled from a song's cover.
    /// Falls back to ultra-thin material when the tint hasn't been
    /// extracted yet (or the cover failed to load) — gives every
    /// card a consistent shape without blocking on extraction.
    @ViewBuilder
    private func tintedCardBackground(for song: Song) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        if let tint = tintProvider.tint(forSongID: song.id) {
            shape.fill(LinearGradient(
                colors: [tint.opacity(0.22), tint.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            ))
        } else {
            shape.fill(homeCardSurface)
        }
    }

    // MARK: - Library Hero / Today's Pick

    /// 用户库里随机抽 4 首带封面的歌, 在 hero 右侧错落拼贴。每次进入页面
    /// 重新洗一组, 让 hero 有「在看自己音乐」的存在感。挑过封面的, 没封面
    /// 的歌跳过 (放占位太单调)。 Used as cold-start fallback when no
    /// `todaysPick` can be derived (e.g. zero playback history AND no
    /// covered library songs at all).
    /// Daily-stable pick — yyyymmdd hash mod available pool. Stays
    /// the same all day so the user gets a "today's hero" feel
    /// without it shuffling on every refresh. Computed lazily from
    /// the cached home snapshot; recent songs are the cold-start
    /// fallback when forYou is empty.
    private var todaysPick: Song? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: Date())
        let stamp = (comps.year ?? 0) * 10000 + (comps.month ?? 0) * 100 + (comps.day ?? 0)
        let pool: [Song] = !forYouPicks.isEmpty ? forYouPicks
            : Array(model.snapshot.recentSongs.filter { $0.coverArtFileName?.isEmpty == false }.prefix(20))
        guard !pool.isEmpty else { return nil }
        let idx = abs(stamp) % pool.count
        return pool[idx]
    }

    /// Hero 顶部 ── 一直走 libraryMixHeroFallback (问候语 + 4 张封面拼贴 +
    /// 随机播放 / 全部播放两个按钮)。
    /// 之前的 todaysPickHero (今日精选大封面 + Play / Shuffle) 视觉上不够干净,
    /// 用户反馈不好看, 暂时不用; 代码保留方便将来需要时切回去。
    @ViewBuilder
    private var libraryHeroSection: some View {
        if skin.usesPosterHome {
            posterLibraryHero
        } else {
            libraryMixHeroFallback
        }
    }

    @ViewBuilder
    private func todaysPickHero(pick: Song) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            homeFaceHeader(.music)

            HStack(alignment: .center, spacing: 14) {
                CachedArtworkView(
                    coverRef: pick.coverArtFileName,
                    songID: pick.id,
                    size: 96, cornerRadius: 12,
                    sourceID: pick.sourceID,
                    filePath: pick.filePath,
                    fileFormat: pick.fileFormat
                )
                .shadow(color: .black.opacity(0.18), radius: 6, y: 3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                    Text("home_todays_pick_title")
                        .font(.title3).fontWeight(skin.usesPosterHome ? .heavy : .bold)
                        .lineLimit(1)
                    Text(pick.title)
                        .font(.subheadline).fontWeight(.medium)
                        .lineLimit(1)
                    Text(library.artistDisplayName(for: pick) ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Button {
                    playSong(pick)
                } label: {
                    Label("play", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(heroTintGradient(for: pick))
        }
        .padding(.horizontal, 16)
        .task(id: pick.id) {
            // Make sure the hero's tint gets extracted right away
            // even if it isn't part of the forYou row.
            tintProvider.prepare([pick])
        }
    }

    /// Hero background gradient: same per-song tint pattern as the
    /// list cards but stronger (Hero's bigger surface = bigger
    /// visual presence, can carry more saturation). Falls back to
    /// thinMaterial while extraction is pending.
    /// 返回 ShapeStyle 而不是 View, 让 RoundedRectangle.fill(_:) 能直接接住。
    /// (View 不能传给 fill, fill 要 ShapeStyle。)
    private func heroTintGradient(for song: Song) -> AnyShapeStyle {
        if let tint = tintProvider.tint(forSongID: song.id) {
            return AnyShapeStyle(LinearGradient(
                colors: [tint.opacity(0.32), tint.opacity(0.10)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        } else {
            return AnyShapeStyle(Material.thin)
        }
    }

    /// Cold-start: no songs eligible for the today's pick. Keep the
    /// old library-mix CTA so the user always has something to tap.
    private var libraryMixHeroFallback: some View {
        VStack(spacing: heightClass.value(14, compact: 10)) {
            homeFaceHeader(.music)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("home_library_mix_title")
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(heightClass.pick(2, compact: 1))
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                heroCoverCollage
            }

            HStack(spacing: 10) {
                Button {
                    playLibrary(shuffled: true)
                } label: {
                    Label("shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Capsule())

                Button {
                    playLibrary(shuffled: false)
                } label: {
                    Label("play_all", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
            }
        }
        .padding(heroPadding)
        .background {
            Button(action: openLibrarySongs) {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(homeCardSurface)
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(.primary.opacity(0.06), lineWidth: 0.5)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("tab_songs"))
            .accessibilityHint(Text("library_browse"))
            .accessibilityIdentifier("homeLibraryHeroOpenSongs")
        }
        .padding(.horizontal, 16)
    }

    /// 4 张封面错落叠放 — 用 ZStack 加旋转 + 偏移, 跟 Spotify Mix /
    /// Apple Music「For You」拼贴风格一致。封面来自最近添加 + 最近播放
    /// 的随机抽样, 每次 view 出现重洗一次。
    @ViewBuilder
    private var heroCoverCollage: some View {
        // 手机横屏整块 hero 要压到视口四成以内,拼贴跟着等比缩一档:
        // 封面、错开的距离、外框三处必须一起缩,只改外框会让封面溢出去压到文字。
        let size = heightClass.value(50, compact: 38)
        let radius = heightClass.value(8, compact: 6)
        let spread = heightClass.value(1, compact: 0.75)
        ZStack {
            // 4 张依次叠, 角度 + 偏移让它们看起来散开
            ForEach(Array(model.snapshot.heroCoverSongs.prefix(4).enumerated()), id: \.element.id) { index, song in
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: size,
                    cornerRadius: radius,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .rotationEffect(.degrees(coverRotation(for: index)))
                .offset(coverOffset(for: index, spread: spread))
                .zIndex(Double(4 - index))
            }
            if model.snapshot.heroCoverSongs.isEmpty {
                Image(systemName: "music.note.list")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(
            width: heightClass.value(110, compact: 90),
            height: heightClass.value(80, compact: 56)
        )
    }

    private func coverRotation(for index: Int) -> Double {
        switch index {
        case 0: return -10
        case 1: return -3
        case 2: return 5
        case 3: return 12
        default: return 0
        }
    }

    private func coverOffset(for index: Int, spread: CGFloat) -> CGSize {
        let base: CGSize
        switch index {
        case 0: base = CGSize(width: -28, height: 0)
        case 1: base = CGSize(width: -10, height: -4)
        case 2: base = CGSize(width: 10, height: 2)
        case 3: base = CGSize(width: 28, height: 0)
        default: base = .zero
        }
        return CGSize(width: base.width * spread, height: base.height * spread)
    }

    /// 海报版式的首页头图:资料库里的封面斜着铺成一面墙,向下压暗,问候语、标题和两颗按钮
    /// 压在压暗的那一段上。整块仍是「打开全部歌曲」的入口(按钮以外的地方点下去就进歌曲)。
    /// 颜色全部来自封面,不依赖皮肤底色。
    private var posterLibraryHero: some View {
        let compact = heightClass.isCompact
        let heroHeight: CGFloat = compact ? 196 : 318
        return ZStack(alignment: .bottomLeading) {
            heroMosaic(height: heroHeight)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: compact ? 8 : 12) {
                homeFaceHeader(.music, onDarkSurface: true)

                Spacer(minLength: 0)

                Text(greeting)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.78))
                Text("home_library_mix_title")
                    .font(compact ? .title2.weight(.heavy) : .largeTitle.weight(.heavy))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Button {
                        playLibrary(shuffled: true)
                    } label: {
                        Label("shuffle", systemImage: "shuffle")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 48)
                            .background(.white, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pmPressable)

                    Button {
                        playLibrary(shuffled: false)
                    } label: {
                        Label("play_all", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: compact ? 40 : 48)
                            .background(.ultraThinMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.pmPressable)
                }
            }
            .padding(heroPadding)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        // 海报一律是深色的,里面的材质与语义色按深色取值。
        .environment(\.colorScheme, .dark)
        .background {
            Button(action: openLibrarySongs) {
                Color.black
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("tab_songs"))
            .accessibilityHint(Text("library_browse"))
            .accessibilityIdentifier("homeLibraryHeroOpenSongs")
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        .padding(.horizontal, 16)
    }

    /// 斜铺的封面墙。封面不够铺满时循环使用;一张都没有时用主题色渐变兜底。
    ///
    /// 墙面挂在 overlay 里,不参与布局:一行五张固定尺寸的封面比手机屏幕宽,放进布局里会把
    /// 头图连同整列首页内容一起撑宽。头图的尺寸只由提议宽度与 `height` 决定。
    private func heroMosaic(height: CGFloat) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { heroMosaicWall }
            .clipped()
    }

    @ViewBuilder
    private var heroMosaicWall: some View {
        let songs = model.snapshot.heroCoverSongs
        let tile: CGFloat = heightClass.value(108, compact: 78)
        let columns = 5
        let rows = 4
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.55), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if !songs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 8) {
                            ForEach(0..<columns, id: \.self) { column in
                                let song = songs[(row * columns + column + row) % songs.count]
                                CachedArtworkView(
                                    coverRef: song.coverArtFileName,
                                    songID: song.id,
                                    size: tile,
                                    cornerRadius: 12,
                                    sourceID: song.sourceID,
                                    filePath: song.filePath,
                                    fileFormat: song.fileFormat
                                )
                            }
                        }
                        // 行与行错开半张,墙面看起来是斜着铺过去的,不是一张表格。
                        .offset(x: row.isMultiple(of: 2) ? 0 : -tile / 2)
                    }
                }
                .rotationEffect(.degrees(-10))
                .scaleEffect(1.12)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.22), location: 0),
                    .init(color: .black.opacity(0.05), location: 0.28),
                    .init(color: .black.opacity(0.42), location: 0.58),
                    .init(color: .black.opacity(0.86), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// Hero 的内边距。手机横屏整块要控制在视口的四成以内,四周先收一档。
    private var heroPadding: CGFloat {
        heightClass.value(16, compact: 10)
    }

    nonisolated private static func makeHeroCoverSongs(
        songs: [Song],
        recentSongs: [Song]
    ) -> [Song] {
        // 优先最近播放, 不够再补最近添加, 都过滤出有 cover 的歌, 最后随机
        // 抽 4 首。结果跟随首页快照刷新,避免每次 tab 回首页都重排。
        let added = songs.sorted { $0.dateAdded > $1.dateAdded }.prefix(60)
        // 用 seen-set 按 id 去重: recentSongs 自身可能含重复 id (脏快照/跨源未彻底
        // 去重), 否则下方 ForEach(id: \.element.id) 会因重复 id 触发 SwiftUI 告警/崩溃。
        var pool: [Song] = []
        var seenIDs = Set<String>()
        for song in recentSongs + added where seenIDs.insert(song.id).inserted {
            pool.append(song)
        }
        let withCover = pool.filter { $0.coverArtFileName?.isEmpty == false }
        // 海报版式的头图是一面封面墙,抽 12 张(不够时墙面循环使用);经典头图只取前 4 张。
        return Array(withCover.shuffled().prefix(12))
    }

    // MARK: - Quick Access

    @ViewBuilder
    private func quickAccessSection(_ style: HomeSectionLayoutStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            homeSectionTitle("home_section_quick_access")

            if style == .carousel {
                // 横排档去掉整块底卡:一行图标本来就不高,再包一层圆角面板
                // 会让它看着比内容重。
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows(.quickAccess, height: 96, spacing: 16), spacing: 16) {
                        ForEach(model.snapshot.quickItems) { item in
                            homeQuickDockItem(item)
                                .frame(width: 76)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            } else if skin.usesPosterHome {
                // 海报版式的网格档是两列胶囊磁贴:左边封面、右边名称与一行说明,
                // 一屏能放六个,比一排小图标好认。
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 10),
                        count: usesPadMetrics ? 3 : 2
                    ),
                    spacing: 10
                ) {
                    ForEach(model.snapshot.quickItems) { item in
                        homeQuickDockItem(item, pill: true)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 10),
                        count: 3
                    ),
                    spacing: 14
                ) {
                    ForEach(model.snapshot.quickItems) { item in
                        homeQuickDockItem(item)
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(homeCardSurface)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(.primary.opacity(0.06), lineWidth: 0.5)
                        }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    @ViewBuilder
    private func homeQuickDockItem(_ item: HomeQuickItem, pill: Bool = false) -> some View {
        let side: CGFloat = pill ? 46 : 52
        switch item {
        case .liked(let playlist):
            NavigationLink(value: playlist) {
                quickAccessLabel(title: String(localized: "sidebar_liked_songs"), subtitle: nil, pill: pill) {
                    QuickAccessArtworkView(item: .playlist(playlist), size: side, cornerRadius: 9) {
                        likedSongsArtwork(size: side)
                    }
                }
            }
            .buttonStyle(.pmPressable)
            .mediaZoomSource(.playlist, id: playlist.id)
        case .album(let album):
            NavigationLink(value: album) {
                quickAccessLabel(title: album.title, subtitle: album.artistName, pill: pill) {
                    QuickAccessArtworkView(item: .album(album), size: side, cornerRadius: 9) {
                        AlbumArtworkView(album: album, size: side, cornerRadius: 9)
                    }
                }
            }
            .buttonStyle(.pmPressable)
            .mediaZoomSource(.album, id: album.id)
        case .artist(let artist):
            NavigationLink(value: artist) {
                quickAccessLabel(title: artist.name, subtitle: nil, pill: pill) {
                    QuickAccessArtworkView(item: .artist(artist), size: side, cornerRadius: 9) {
                        ArtistArtworkView(artist: artist, size: side, cornerRadius: side / 2)
                    }
                }
            }
            .buttonStyle(.pmPressable)
            .mediaZoomSource(.artist, id: artist.id)
        case .playlist(let tile):
            NavigationLink(value: tile.playlist) {
                quickAccessLabel(
                    title: tile.playlist.name,
                    subtitle: "\(tile.songCount) " + String(localized: "songs_count"),
                    pill: pill
                ) {
                    QuickAccessArtworkView(item: .playlist(tile.playlist), size: side, cornerRadius: 9) {
                        homePlaylistArtwork(tile, size: side, cornerRadius: 9)
                    }
                }
            }
            .buttonStyle(.pmPressable)
            .mediaZoomSource(.playlist, id: tile.playlist.id)
        }
    }

    @ViewBuilder
    private func quickAccessLabel<Artwork: View>(
        title: String,
        subtitle: String?,
        pill: Bool,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        if pill {
            HStack(spacing: 10) {
                artwork()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(homeCardSurface)
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            quickAccessDockLabel(title: title, artwork: artwork)
        }
    }

    private func quickAccessDockLabel<Artwork: View>(
        title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        VStack(spacing: 7) {
            artwork()
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .top)
        .contentShape(Rectangle())
    }

    private func likedSongsArtwork(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.pink, Color.accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }

    // MARK: - Playlists

    @ViewBuilder
    private func playlistsSection(_ style: HomeSectionLayoutStyle) -> some View {
        let tiles = model.snapshot.playlists

        VStack(alignment: .leading, spacing: 10) {
            homeSectionTitle("home_section_playlists")

            switch style {
            case .carousel:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows(.playlists, height: homeAlbumCardHeight), spacing: 14) {
                        ForEach(tiles.prefix(sectionItemCount(.playlists, usesPadMetrics ? 16 : 12))) { tile in
                            NavigationLink(value: tile.playlist) {
                                playlistCard(tile)
                            }
                            .buttonStyle(.pmPressable)
                            .mediaZoomSource(.playlist, id: tile.playlist.id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            case .grid:
                // 歌单封面是固定尺寸视图,撑不满自适应列宽,所以列宽直接按卡片宽
                // 来定 —— 否则窄屏两列会在卡片之间裂开一道空隙。
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: homeAlbumCardWidth), spacing: 16, alignment: .top)],
                    spacing: 20
                ) {
                    ForEach(tiles.prefix(sectionItemCount(.playlists, usesPadMetrics ? 12 : 6))) { tile in
                        NavigationLink(value: tile.playlist) {
                            playlistCard(tile)
                        }
                        .buttonStyle(.pmPressable)
                        .mediaZoomSource(.playlist, id: tile.playlist.id)
                    }
                }
                .padding(.horizontal, 20)
            case .list:
                VStack(spacing: 0) {
                    let displayed = Array(tiles.prefix(sectionItemCount(.playlists, usesPadMetrics ? 5 : 4)))
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, tile in
                        NavigationLink(value: tile.playlist) {
                            playlistListRow(tile)
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(.playlist, id: tile.playlist.id)

                        if index < displayed.count - 1 {
                            Divider()
                                .padding(.leading, 66)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// 横排与网格共用一张卡,宽度固定 —— 否则 LazyHStack 会按内容自适应,
    /// 长短不一的歌单名把这一行撑得参差不齐。
    private func playlistCard(_ tile: HomePlaylistTile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            homePlaylistArtwork(tile, size: homeAlbumCardWidth, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(tile.playlist.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("\(tile.songCount) " + String(localized: "songs_count"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: homeAlbumCardWidth, alignment: .leading)
    }

    @ViewBuilder
    private func homePlaylistArtwork(
        _ tile: HomePlaylistTile,
        size: CGFloat,
        cornerRadius: CGFloat
    ) -> some View {
        PlaylistArtworkView(
            playlist: tile.playlist,
            size: size,
            cornerRadius: cornerRadius
        )
    }

    private func playlistListRow(_ tile: HomePlaylistTile) -> some View {
        let playlist = tile.playlist
        return HStack(spacing: 12) {
            homePlaylistArtwork(tile, size: 54, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    "\(tile.songCount) "
                        + String(localized: "songs_count")
                        + " · "
                        + playlist.updatedAt.formatted(.relative(presentation: .named))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: - For You

    /// 首页只读与资料库推荐页同源的本地每日推荐快照。远程重排由资料库
    /// 推荐页在用户进入时触发，避免首页生命周期反复发起服务调用。
    private var displayedForYouResults: [MusicDiscoveryResult] {
        model.snapshot.forYouResults
    }

    private var forYouPicks: [Song] { displayedForYouResults.map(\.song) }

    @ViewBuilder
    private func forYouSection(_ style: HomeSectionLayoutStyle) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            homeSectionTitle("home_for_you_title")

            if style == .list {
                VStack(spacing: 8) {
                    ForEach(displayedForYouResults.prefix(sectionItemCount(.forYou, usesPadMetrics ? 8 : 5))) { result in
                        Button { playSong(result.song) } label: {
                            forYouListRow(result)
                        }
                        .buttonStyle(.pmPressable)
                    }
                }
                .padding(.horizontal, 20)
            } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(displayedForYouResults) { result in
                        let song = result.song
                        Button { playSong(song) } label: {
                            HStack(spacing: 14) {
                                VStack(alignment: .leading, spacing: 6) {
                                    DiscoveryReasonsView(reasons: result.reasons, maxCount: 1)

                                    Text(song.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)

                                    Text(
                                        library.artistDisplayName(for: song)
                                            ?? String(localized: "unknown_artist")
                                    )
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)

                                    Spacer(minLength: 4)

                                    Label("play", systemImage: "play.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                CachedArtworkView(
                                    coverRef: song.coverArtFileName,
                                    songID: song.id,
                                    size: usesPadMetrics ? 136 : 124,
                                    cornerRadius: 13,
                                    sourceID: song.sourceID,
                                    filePath: song.filePath,
                                    fileFormat: song.fileFormat
                                )
                                .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
                            }
                            .padding(14)
                            .frame(
                                width: usesPadMetrics ? 372 : 316,
                                height: usesPadMetrics ? 176 : 164
                            )
                            .background(recommendationCardBackground(for: song))
                        }
                        .buttonStyle(.pmPressable)
                    }
                }
                .padding(.horizontal, 20)
                .scrollTargetLayout()
            }
            .pmStopsAtVerticalBar()
            .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    /// 列表档只保留一条推荐理由 —— 竖排里理由标签一多就把标题挤成两行,
    /// 反而不如横排卡片好读。
    private func forYouListRow(_ result: MusicDiscoveryResult) -> some View {
        let song = result.song
        return HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 54,
                cornerRadius: 9,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 3) {
                DiscoveryReasonsView(reasons: result.reasons, maxCount: 1)
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(homeCardSurface)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func recommendationCardBackground(for song: Song) -> some View {
        let poster = skin.usesPosterHome
        let shape = RoundedRectangle(cornerRadius: poster ? 20 : 18, style: .continuous)
        if let tint = tintProvider.tint(forSongID: song.id) {
            // 海报版式的推荐卡整张铺这首歌的封面色,一眼看得出是哪一首。
            shape.fill(
                LinearGradient(
                    colors: poster
                        ? [tint.opacity(0.46), tint.opacity(0.14)]
                        : [tint.opacity(0.28), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            // Repeated live Material blurs create off-screen render passes
            // while the horizontal row moves. A stable system surface keeps
            // the same card hierarchy until the batched tint result arrives.
            shape.fill(homeCardSurface)
        }
    }

    // MARK: - Continue Listening (formerly Recently Played)

    @ViewBuilder
    private func continueListeningSection(_ style: HomeSectionLayoutStyle) -> some View {
        let songs = model.snapshot.recentSongs

        VStack(alignment: .leading, spacing: 10) {
            homeSectionTitle("home_continue_listening")

            switch style {
            // 继续听不提供网格：`resolved` 会把它夹回支持的方案，这里并到横排
            // 只是不让任何意外取值渲染成一片空白。
            case .carousel, .grid:
                ScrollView(.horizontal, showsIndicators: false) {
                    Group {
                        if skin.usesPosterHome {
                            LazyHGrid(
                                rows: carouselRows(.continueListening, height: continueCardSide + 46, spacing: 16),
                                spacing: 14
                            ) {
                                ForEach(songs.prefix(sectionItemCount(.continueListening, 12)), id: \.id) { song in
                                    Button { playSong(song) } label: {
                                        continueListeningCard(song)
                                    }
                                    .buttonStyle(.pmPressable)
                                }
                            }
                        } else {
                            LazyHGrid(rows: carouselRows(.continueListening, height: 60, spacing: 10), spacing: 10) {
                                ForEach(songs.prefix(sectionItemCount(.continueListening, 12)), id: \.id) { song in
                                    Button { playSong(song) } label: {
                                        continueListeningRow(song)
                                    }
                                    .buttonStyle(.pmPressable)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            case .list:
                VStack(spacing: 8) {
                    ForEach(songs.prefix(sectionItemCount(.continueListening, usesPadMetrics ? 8 : 5)), id: \.id) { song in
                        Button { playSong(song) } label: {
                            continueListeningRow(song, fillsWidth: true)
                        }
                        .buttonStyle(.pmPressable)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// 横排档的方形大卡:封面占满卡宽,下面两行歌名与艺术家。
    private var continueCardSide: CGFloat {
        usesPadMetrics ? 168 : heightClass.value(148, compact: 104)
    }

    private func continueListeningCard(_ song: Song) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: continueCardSide,
                cornerRadius: 14,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            .shadow(color: .black.opacity(0.14), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(width: continueCardSide, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// 纵向列表里要铺满一行 —— 沿用横排的固定宽度会在右侧留一条空白。
    private func continueListeningRow(_ song: Song, fillsWidth: Bool = false) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 48,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "play.circle.fill")
                .font(.title3)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 6)
        .frame(
            width: fillsWidth ? nil : (usesPadMetrics ? 300 : 250),
            height: 60
        )
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(homeCardSurface)
        }
        .contentShape(Rectangle())
    }

    /// 首页各区块的标题。海报版式的字重再重一档,区块之间靠标题分隔,不再靠卡片边框。
    private func homeSectionTitle(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.title3.weight(skin.usesPosterHome ? .heavy : .bold))
            .padding(.horizontal, 20)
            .accessibilityAddTraits(.isHeader)
    }

    /// 首页所有卡片共用的底。经典皮肤下 `.surface` 就是 secondarySystemBackground,与原来一致。
    private var homeCardSurface: Color {
        #if os(iOS)
        skin.color(.surface)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func makeRecentSongs() -> [Song] {
        let recent = library.recentlyPlayedSongs(limit: 30)
        if !recent.isEmpty { return recent }
        return model.snapshot.recentSongs.compactMap { library.unobservedVisibleSong(id: $0.id) }
    }

    // MARK: - Recently Added Albums

    /// 横排卡片的宽度。窄屏下比网格的一半略窄,好让第三张卡露出一角 ——
    /// 边缘不留半张卡,用户看不出这一行还能往右滑。
    /// 手机横屏再收一档:一行货架加上标题就要占掉半个视口,后面的区块全落在
    /// 折叠线以下。
    private var homeAlbumCardWidth: CGFloat {
        usesPadMetrics ? 160 : heightClass.value(132, compact: 108)
    }

    /// 封面 + 两行说明文字。多行横排要用 LazyHGrid,而它要求行高固定。
    private var homeAlbumCardHeight: CGFloat { homeAlbumCardWidth + 42 }

    /// 横排的行数由用户配置,1 行时等价于原来的 LazyHStack。
    /// 手机横屏只渲染一行 —— 存档里的行数不动,设置页仍显示用户选的值。
    private func carouselRows(
        _ section: HomeSectionKind,
        height: CGFloat,
        spacing: CGFloat = 14
    ) -> [GridItem] {
        Array(
            repeating: GridItem(.fixed(height), spacing: spacing, alignment: .top),
            count: HomeSectionLayoutPolicy.renderedRowCount(
                configured: homeLayout.rowCount(for: section),
                isCompactHeight: heightClass.isCompact
            )
        )
    }

    @ViewBuilder
    private func recentlyAddedAlbumsSection(_ style: HomeSectionLayoutStyle) -> some View {
        let albums = model.snapshot.recentlyAddedAlbums

        VStack(alignment: .leading, spacing: style == .grid ? 14 : 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(HomeDiscoveryText.string("recent_albums"))
                    .font(.title3).fontWeight(skin.usesPosterHome ? .heavy : .bold)
                Spacer()
                NavigationLink {
                    RecentlyAddedAlbumsView()
                        #if os(iOS)
                        .minimalNavigationDetail()
                        #endif
                } label: {
                    Text("home_section_view_all")
                        .font(.subheadline)
                }
                .accessibilityIdentifier("home.recentAlbums.viewAll")
            }
            .padding(.horizontal, 20)

            switch style {
            case .carousel:
                // 横排一次只占一张卡的高度,这正是 issue #106 想要的:同样的内容
                // 不再吃掉整屏,后面的「继续听」还留在首屏里。
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows(.recentlyAdded, height: homeAlbumCardHeight), spacing: 14) {
                        ForEach(albums.prefix(sectionItemCount(.recentlyAdded, usesPadMetrics ? 16 : 12))) { tile in
                            NavigationLink(value: tile.album) {
                                AlbumCardView(album: tile.album, showsSongCount: true)
                                    .frame(width: homeAlbumCardWidth)
                            }
                            .buttonStyle(.pmPressable)
                            .mediaZoomSource(.album, id: tile.album.id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            case .list:
                VStack(spacing: 0) {
                    let displayed = Array(albums.prefix(sectionItemCount(.recentlyAdded, usesPadMetrics ? 8 : 6)))
                    ForEach(Array(displayed.enumerated()), id: \.element.id) { index, tile in
                        NavigationLink(value: tile.album) {
                            albumListRow(tile.album)
                        }
                        .buttonStyle(.plain)
                        .mediaZoomSource(.album, id: tile.album.id)

                        if index < displayed.count - 1 {
                            Divider().padding(.leading, 66)
                        }
                    }
                }
                .padding(.horizontal, 20)
            case .grid:
                LazyVGrid(columns: recentlyAddedGridColumns, spacing: 20) {
                    ForEach(albums.prefix(sectionItemCount(.recentlyAdded, usesPadMetrics ? 12 : 6))) { tile in
                        NavigationLink(value: tile.album) {
                            AlbumCardView(album: tile.album, showsSongCount: true)
                        }
                        .buttonStyle(.pmPressable)
                        .mediaZoomSource(.album, id: tile.album.id)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    /// 「最近添加」网格的列方案。
    ///
    /// 手机竖屏照旧钉死两列 —— 换成按最小宽自适应的话，开了显示放大的小屏
    /// (逻辑宽 320) 会掉成一列。手机横屏反过来:一行只有两列时每列三百多点，
    /// 一张方形封面就占满整屏，所以按最小宽自适应铺成四五列。
    private var recentlyAddedGridColumns: [GridItem] {
        if usesPadMetrics {
            return [GridItem(.adaptive(minimum: 150), spacing: 16, alignment: .top)]
        }
        if heightClass.isCompact {
            return [GridItem(.adaptive(minimum: 120), spacing: 16, alignment: .top)]
        }
        return [
            GridItem(.flexible(), spacing: 16, alignment: .top),
            GridItem(.flexible(), spacing: 16, alignment: .top),
        ]
    }

    private func albumListRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(album: album, size: 54, cornerRadius: 9)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(
                    (album.artistName ?? String(localized: "unknown_artist"))
                        + " · \(album.songCount) "
                        + String(localized: "songs_count")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    // MARK: - Top Artists

    /// Eight artists, ranked by recent listening — falls back to
    /// alphabetical library order when the user has no playback
    /// history yet (fresh install / no songs cleared the 30s
    /// scrobble threshold). Section title swaps between
    /// "frequently listened" and the generic "artists" depending
    /// which path produced the data.
    @ViewBuilder
    private func artistsSection(_ style: HomeSectionLayoutStyle) -> some View {
        let displayed = model.snapshot.topArtists
        let titleKey: LocalizedStringKey = model.snapshot.topArtistsHasHistory ? "home_top_artists_title" : "tab_artists"

        VStack(alignment: .leading, spacing: 10) {
            Text(titleKey)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal, 20)

            if style == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 92), spacing: 14, alignment: .top)],
                    spacing: 16
                ) {
                    ForEach(displayed.prefix(sectionItemCount(.topArtists, usesPadMetrics ? 16 : 8))) { artist in
                        NavigationLink(value: artist) { artistBubble(artist) }
                            .buttonStyle(.pmPressable)
                            .mediaZoomSource(.artist, id: artist.id)
                    }
                }
                .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: carouselRows(.topArtists, height: 104), spacing: 14) {
                        ForEach(displayed.prefix(sectionItemCount(.topArtists, usesPadMetrics ? 16 : 8))) { artist in
                            NavigationLink(value: artist) { artistBubble(artist) }
                                .buttonStyle(.pmPressable)
                                .mediaZoomSource(.artist, id: artist.id)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .pmStopsAtVerticalBar()
            }
        }
    }

    private func artistBubble(_ artist: Artist) -> some View {
        VStack(spacing: 6) {
            ArtistArtworkView(artist: artist, size: 80, cornerRadius: 40)
            Text(artist.name).font(.caption).lineLimit(1).frame(width: 80)
        }
    }

    /// Map RankedItem (history) to the actual library Artist objects
    /// (NavigationLink needs the Artist value, not the ranked stub).
    /// Match by artist name. Top up with alphabetical leftovers when
    /// history doesn't fill the row.
    private func topArtistsForHome(history: [PlayHistoryStore.RankedItem]) -> [Artist] {
        guard !history.isEmpty else {
            return Array(library.visibleArtists.prefix(Self.topArtistPoolLimit))
        }
        let byName = Dictionary(library.visibleArtists.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Artist] = []
        var seen = Set<String>()
        for item in history {
            if let a = byName[item.title], !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
            }
        }
        if result.count < Self.topArtistPoolLimit {
            for a in library.visibleArtists where !seen.contains(a.id) {
                result.append(a)
                seen.insert(a.id)
                if result.count >= Self.topArtistPoolLimit { break }
            }
        }
        return result
    }



    // MARK: - Empty

    private var emptyView: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 24)
            EmptyStateView(
                titleKey: "welcome_title",
                descriptionKey: "home_empty_desc",
                systemImage: "externaldrive.badge.plus",
                actionLabel: "manage_sources",
                action: { openSourcesManagement() }
            )
            .padding(.horizontal, 24)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    /// 直达「设置 › 音乐源」。以前只切到设置页的首屏，新用户还得自己在列表里找
    /// 「音乐源」这一行；资料库空状态上的同名按钮走的也是这一处，两个入口落点一致。
    private func openSourcesManagement() {
        #if os(iOS)
        SettingsNavigation.shared.open(SettingsPage.sources.id)
        #else
        switchToSettingsTab?()
        #endif
    }

    private func playSong(_ song: Song) {
        plog("🏠 playSong TAPPED: '\(song.title)' id=\(song.id.prefix(12)) path=\(song.filePath)")

        // Build queue from recently played songs, supplemented by library.
        // Those are songs only; a chapter found by search plays on its own
        // rather than running on into music.
        let isSpokenWord = library.spokenWordSongIDs.contains(song.id)
        var queueSongs = isSpokenWord ? [song] : library.recentlyPlayedSongs(limit: 50)
        plog("🏠 recentlyPlayed queue: \(queueSongs.count) songs, first3=\(queueSongs.prefix(3).map(\.title))")

        // If tapped song isn't in recent list, prepend it
        if !queueSongs.contains(where: { $0.id == song.id }) {
            queueSongs.insert(song, at: 0)
            plog("🏠 song not in recent, prepended")
        }

        // Supplement with library songs if queue is too small
        if queueSongs.count < 20, !isSpokenWord {
            let existingIDs = Set(queueSongs.map(\.id))
            let extra = library.musicSongs.filter { !existingIDs.contains($0.id) }
            queueSongs.append(contentsOf: extra)
        }

        // Drop non-playable entries so auto-advance can't land on a Phase A
        // bare song. The tapped song itself was already filtered to
        // playable by SongRowView's tap intercept; if it slipped through
        // (recently-played list with stale data) bail rather than crash
        // on an empty queue or play a song that isn't in the queue.
        queueSongs = queueSongs.filteredPlayable()
        guard let startIndex = queueSongs.firstIndex(where: { $0.id == song.id }) else {
            plog("🏠 tapped song dropped by playable filter — skipping")
            return
        }
        plog("🏠 setQueue: \(queueSongs.count) songs, startIndex=\(startIndex), songAtIndex='\(queueSongs[startIndex].title)'")
        player.shuffleEnabled = false
        let resolved = queueSongs[startIndex]
        plog("🏠 calling player.play(song: '\(resolved.title)')")
        SiriMediaInteractionDonor.donate(song: resolved)
        Task { await player.play(queue: queueSongs, startingAt: startIndex) }
    }

    private func playLibrary(shuffled: Bool) {
        // Skip cloud songs that haven't been backfilled yet — they have no
        // duration / cover / metadata and would land in the queue with a
        // blank progress bar. Once backfill catches up they become eligible.
        let candidates = library.musicSongs.filteredPlayable()
        guard !candidates.isEmpty else { return }

        let queueSongs = shuffled ? candidates.shuffled() : candidates
        guard !queueSongs.isEmpty else { return }

        player.shuffleEnabled = false
        Task { await player.play(queue: queueSongs, startingAt: 0) }
    }
}
