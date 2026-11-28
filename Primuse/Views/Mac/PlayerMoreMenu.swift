#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 播放器「更多」菜单的挂载位置。底栏、播放页和迷你播放器本身已有封面头与传输键,
/// 只在右侧队列面板里保留曲目头与基础传输控制。
enum PlayerMoreMenuSurface: Equatable {
    case playerBar
    case queuePanel

    var showsHeaderAndTransport: Bool {
        self == .queuePanel
    }
}

/// 单浮层内的子页面路由,避免多层 Popover 套娃。
enum PlayerMoreMenuSubpage: Equatable {
    case root
    case playbackOrder
    case lyricsDisplay
    case audioEffects
    case editing
}

enum PlayerMoreMenuPolicy {
    static func repeatTitleKey(for mode: RepeatMode) -> String {
        switch mode {
        case .off: return "repeat"
        case .all: return "play_mode_repeat_all"
        case .one: return "play_mode_repeat_one"
        }
    }

    static func repeatChoiceTitleKey(for mode: RepeatMode) -> LocalizedStringKey {
        switch mode {
        case .off: return "repeat_behavior_off"
        case .all: return "play_mode_repeat_all"
        case .one: return "play_mode_repeat_one"
        }
    }

    static func playbackOrderSummary(shuffleEnabled: Bool, repeatMode: RepeatMode, bundle: Bundle = .main) -> String {
        var parts: [String] = []
        if shuffleEnabled {
            parts.append(bundle.localizedString(forKey: "shuffle", value: nil, table: nil))
        }
        if repeatMode != .off {
            let key = repeatTitleKey(for: repeatMode)
            parts.append(bundle.localizedString(forKey: key, value: nil, table: nil))
        }
        return parts.joined(separator: " · ")
    }
}

/// 限制最大高度并在内容超高时才回退到滚动容器,短页面紧贴内容高度不留空白。
/// 高度按里面那一份 ScrollView 的理想高度(即内容高度)量,超过上限才截到上限、由它接着滚。
/// 不用 ViewThatFits 在「原样 / 包一层滚动」两份之间挑:它测量候选分支时会在后台线程调菜单里
/// ForEach 的闭包,触发 MainActor 断言闪退(1.15.0 macOS 刮削写回卡片同一个坑,见
/// check-crash-patterns 的 viewthatfits-foreach),而且每次都把整份菜单建两遍。
struct PlayerMoreMenuHeightCapLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let ideal = first.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(ideal.height, proposal.height ?? maxHeight, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        first.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}

struct PlayerMoreMenuBoundedScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        PlayerMoreMenuHeightCapLayout(maxHeight: maxHeight) {
            // 滚动条走全局的 overlay 样式(PMScrollViewStyle),内容放得下时不露滚动条也不回弹。
            ScrollView(.vertical) {
                content()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// 全部"播放器层面"菜单项的统一入口 —— 按职能收敛为一级高频操作与单浮层内子页导航。
///
/// 之前 NowPlaying 顶部和 BottomBar 各有一份不一致的 more 菜单,
/// NowPlaying 的菜单项甚至比底栏多 2/3。把所有菜单项集中到这里,两边
/// 同样行为；状态(加入歌单 / showSongInfo 等)和对应 sheet 都
/// 在本组件内部,调用方只给一个 label 就行。
struct PlayerMoreMenu<MenuLabel: View>: View {
    let surface: PlayerMoreMenuSurface
    let maxPopoverHeightOverride: CGFloat?
    let rendersInlineForTesting: Bool
    private let label: () -> MenuLabel

    init(
        surface: PlayerMoreMenuSurface = .playerBar,
        initialSubpage: PlayerMoreMenuSubpage = .root,
        maxPopoverHeightOverride: CGFloat? = nil,
        rendersInlineForTesting: Bool = false,
        @ViewBuilder label: @escaping () -> MenuLabel
    ) {
        self.surface = surface
        self.maxPopoverHeightOverride = maxPopoverHeightOverride
        self.rendersInlineForTesting = rendersInlineForTesting
        self.label = label
        self._subpage = State(initialValue: initialSubpage)
    }

    @Environment(AudioPlayerService.self) private var player
    @Environment(SongBatchRemovalService.self) private var batchRemoval
    @Environment(MusicLibrary.self) private var library
    @Environment(MusicScraperService.self) private var scraperService
    @Environment(ScraperSettingsStore.self) private var scraperSettings
    @Environment(SourceManager.self) private var sourceManager
    @Environment(SourcesStore.self) private var sourcesStore
    /// 迷你播放器在独立窗口里,环境里不一定有它;没有时菜单不给「智能翻译」。
    @Environment(MusicIntelligenceService.self) private var intelligence: MusicIntelligenceService?

    @AppStorage("lyricsFontScale") private var lyricsFontScale: Double = 1.0
    @AppStorage(CloudKVSKey.lyricsTranslationFontScale) private var lyricsTranslationFontScale: Double = 0
    /// 歌词字体(#332),和设置里同一个键。
    @AppStorage(ImmersiveLyricsMotionSettings.storageKey)
    private var lyricsMotionEnabled = ImmersiveLyricsMotionSettings.defaultValue
    @AppStorage(FullscreenPlayerEffect.storageKey)
    private var fullscreenEffectRawValue = FullscreenPlayerEffect.defaultValue.rawValue

    /// 「加入歌单」:搜索里点播的 Apple Music 歌要先加进资料库、同步进曲库,拿到那一行再弹歌单。
    @State private var libraryActions = NowPlayingLibraryActions()
    @State private var showScrapeOptions = false
    @State private var showNoScraperSourceAlert = false
    @State private var showSongInfo = false
    /// 播放时间段编辑面板的目标(整首)与页签;打开时冻结,自然切歌后仍改这一首。
    @State private var playbackRangeEditorRequest: SongPlaybackRangeEditor.Request?
    @State private var shareSong: Song?
    @State private var showTagEditor = false
    @State private var lyricsEditorTargetSong: Song?
    /// 「生成文稿」(#314):打开给哪一集的面板;这一集现在有没有文稿(读缓存得出)。
    @State private var transcriptGenerationSong: Song?
    @State private var currentHasTranscript: Bool?
    @State private var showSimilarSongs = false
    @State private var commentServerStore = CommentAPIServerStore.shared
    @State private var showComments = false
    @State private var showSleepTimer = false
    @State private var showChapterList = false
    @State private var showKaraoke = false
    @State private var deletionTarget: SongFileDeletionRequest?
    @State private var cueRemovalTarget: Song?
    /// 从音乐服务器删歌的第二次确认。
    @State private var serverDeletionRequest: ServerSongDeletionRequest?
    @State private var deleteErrorMessage: String?
    @State private var scrapeAlertMessage: String?
    @State private var pendingMedleySongs: [Song]?
    @State private var isScrapingCurrentSong = false
    @State private var sourceLyricsReloadAlertMessage: String?
    @State private var sourceLyricsReloadingSongID: String?
    /// 「重新读取服务器文字稿」碰上用户自己编辑、导入的那份时问一句;「导入文字稿」给哪本书(#461)。
    @State private var serverTranscriptReplaceSong: Song?
    @State private var transcriptImportRequest: SpokenTranscriptImportRequest?
    /// 用 Button + Popover 自己画菜单,不用 SwiftUI Menu。原因:
    /// SwiftUI Menu + .borderlessButton 在 macOS 上落到 NSPopUpButton,
    /// 它的 hit test 只覆盖可见图标,玻璃圆环空白区会穿透到下层(歌词)。
    /// Button 是真 Button,整个 frame 都是 hit-testable。
    @State private var menuShown = false
    @State private var subpage: PlayerMoreMenuSubpage
    @State private var fontPickerShown = false
    @State private var lyricsFontPickerShown = false
    /// 「导出歌词 / 文字稿」选格式的那一层,和点了之后要导出的那一份(#362)。
    @State private var textExportPickerShown = false
    @State private var lyricsExportRequest: LyricsExportRequest?
    @State private var equalizerPickerShown = false
    @State private var playbackRatePickerShown = false
    @State private var pitchPickerShown = false
    /// 「伴唱」(#377)的第二层。
    @State private var singAlongPanelShown = false
    /// 播客单集的详情(「转到这本书」对单集是空页, 换成这一页)。
    @State private var podcastSheet: PodcastPlayerSheetTarget?

    var body: some View {
        Group {
            if rendersInlineForTesting {
                popoverMenuContent
            } else {
                baseBody
                    .popover(isPresented: $showSleepTimer, arrowEdge: .top) {
                        MacSleepTimerPopover {
                            showSleepTimer = false
                        }
                        .focusEffectDisabled()
                    }
            }
        }
    }

    private var baseBody: some View {
        Button { menuShown.toggle() } label: {
            label()
                .opacity(libraryActions.isBusy ? 0 : 1)
                .overlay {
                    if libraryActions.isBusy { ProgressView().controlSize(.small) }
                }
        }
        .buttonStyle(.plain)
        .help(Text("more"))
        .accessibilityLabel(Text("more"))
        .popover(isPresented: $menuShown, arrowEdge: .top) {
            popoverMenuContent
        }
        .onChange(of: menuShown) { _, shown in
            if !shown {
                closeChildPopovers()
                subpage = .root
            }
        }
        // 开着菜单时换成有声内容(或反过来)回到第一层:播放顺序那一页只给音乐,各页标题也跟着换。
        .onChange(of: isSpokenWord) { _, _ in
            openSubpage(.root)
        }
        .sheet(item: $libraryActions.playlistSong) { song in
            AddToPlaylistSheet(song: song)
        }
        .nowPlayingLibraryActionAlert(libraryActions)
        // macOS 走 ScrapeWindowController 独立 NSWindow,带原生红灯。
        // showScrapeOptions 仅作为触发开关,window 自己管生命周期。
        .onChange(of: showScrapeOptions) { _, new in
            guard new, let song = player.currentSong else {
                if new { showScrapeOptions = false }
                return
            }
            ScrapeWindowController.shared.show(song: song) { u in
                CachedArtworkView.invalidateCache(for: u.id)
                if let oldRef = song.coverArtFileName {
                    CachedArtworkView.invalidateCache(for: oldRef)
                }
                player.syncSongMetadata(u)
                // 写入在后台做完时可能已经换了歌。
                if player.currentSong?.id == u.id { player.forceRefreshNowPlayingArtwork() }
            }
            showScrapeOptions = false
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = player.currentSong {
                SongInfoSheet(song: song)
            }
        }
        .sheet(item: $playbackRangeEditorRequest) { request in
            SongPlaybackRangeEditor(song: request.song, purpose: request.purpose)
        }
        .sheet(isPresented: $showChapterList) {
            SpokenWordContentsView()
                .frame(minWidth: 380, minHeight: 440)
        }
        .sheet(item: $shareSong) { song in
            SongShareSheet(song: song)
        }
        .sheet(item: $podcastSheet) { target in
            NowPlayingPodcastSheet(target: target)
        }
        .sheet(isPresented: $showTagEditor) {
            if let song = tagEditorSong {
                TagEditorView(song: song) { updated in
                    player.syncSongMetadata(updated)
                    player.forceRefreshNowPlayingArtwork()
                }
            }
        }
        .sheet(isPresented: $showKaraoke) {
            KaraokeStageView()
        }
        .sheet(isPresented: $showComments) {
            SongCommentsSheet(song: player.currentSong)
        }
        .modifier(PlayerMoreMenuTranscriptGeneration(
            songID: player.currentSong?.id,
            transcriptGenerationSong: $transcriptGenerationSong,
            currentHasTranscript: $currentHasTranscript,
            lyricsExportRequest: $lyricsExportRequest
        ))
        .sheet(item: $lyricsEditorTargetSong) { song in
            LyricsEditorSheet(song: song) { updated in
                guard player.currentSong?.id == updated.id else { return }
                player.syncSongMetadata(updated)
            }
        }
        .medleyDataUsageConfirmation(pendingSongs: $pendingMedleySongs) { songs in
            Task { await player.playMedley(songs) }
        }
        .alert(String(localized: "scrape_song"),
               isPresented: Binding(get: { scrapeAlertMessage != nil },
                                    set: { if !$0 { scrapeAlertMessage = nil } })) {
            Button("done", role: .cancel) {}
        } message: { Text(scrapeAlertMessage ?? "") }
        .alert(
            String(localized: isSpokenWord ? "transcript_reload_from_server" : "lyrics_reload_from_source"),
            isPresented: Binding(
                get: { sourceLyricsReloadAlertMessage != nil },
                set: { if !$0 { sourceLyricsReloadAlertMessage = nil } }
            )
        ) {
            Button("done", role: .cancel) {}
        } message: {
            Text(sourceLyricsReloadAlertMessage ?? "")
        }
        .modifier(SpokenTranscriptSourcePresentations(
            replaceSong: $serverTranscriptReplaceSong,
            importRequest: $transcriptImportRequest,
            onConfirmReplace: { reloadServerTranscript(song: $0, replacingUserTranscript: true) }
        ))
        .scraperSourceRequiredAlert(isPresented: $showNoScraperSourceAlert)
        .cueTrackRemovalConfirmation($cueRemovalTarget, using: batchRemoval)
        .songFileDeletionConfirmation($deletionTarget, using: batchRemoval, perform: confirmDeleteCurrentSong)
        .serverSongDeletionConfirmation($serverDeletionRequest)
        .alert(
            String(localized: "delete_song_failed_title"),
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "done"), role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private func closeChildPopovers() {
        fontPickerShown = false
        lyricsFontPickerShown = false
        textExportPickerShown = false
        equalizerPickerShown = false
        playbackRatePickerShown = false
        pitchPickerShown = false
        singAlongPanelShown = false
        showSimilarSongs = false
    }

    private func openSubpage(_ target: PlayerMoreMenuSubpage) {
        closeChildPopovers()
        subpage = target
    }

    private var maximumPopoverHeight: CGFloat {
        if let maxPopoverHeightOverride { return maxPopoverHeightOverride }
        let screenHeight = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height ?? 820
        return max(340, screenHeight - 120)
    }

    /// 正在播有声内容: 收起相似歌曲、串烧、卡拉OK、随机/循环、在线刮削、
    /// 歌词动效与听歌记录这些音乐的玩法, 「转到专辑/艺人」换成「转到这本书」。
    private var isSpokenWord: Bool {
        player.currentItemIsSpokenWord && !player.isLiveRadio
    }

    /// 「生成文稿」那一行的字:没有文稿时「生成」,生成过的「重新生成」,生成中写进度;
    /// 自带文稿的不给(#314)。
    private var transcriptGenerationRow: String? {
        guard isSpokenWord, let song = player.currentSong,
              SpokenTranscriptGenerator.canGenerate(for: song) else { return nil }
        let generator = SpokenTranscriptGenerator.shared
        if let job = generator.activeJob, job.song.id == song.id {
            return SpokenTranscriptGenerationSheet.phaseText(job.phase)
        }
        if generator.records[song.id] != nil {
            return String(localized: "transcript_generation_regenerate")
        }
        return currentHasTranscript == false ? String(localized: "transcript_generation_action") : nil
    }

    /// 「导入文字稿」:资料库里的有声书(本机下载的播客节目也算);订阅里的播客单集不在资料库里(#461)。
    private var canImportTranscripts: Bool {
        guard isSpokenWord, !isPodcastEpisode, let song = player.currentSong else { return false }
        return library.song(id: song.id) != nil
    }

    /// 这一首有歌词(有声内容是文字稿)时才能导出成文件(#362)。
    private var canExportText: Bool {
        player.currentSong != nil && !player.isLiveRadio && currentHasTranscript == true
    }

    private var hasEditingItems: Bool {
        !isPodcastEpisode
            || playbackRangeSong != nil
            || transcriptGenerationRow != nil
            || canImportTranscripts
            || canExportText
            || !isSpokenWord
            || canReloadLyricsFromSource
    }

    private var offersSingAlongRow: Bool {
        !isSpokenWord && player.currentSong != nil && !player.isLiveRadio && !player.currentItemIsAmbient
    }

    private var textExportRow: some View {
        flyoutRow(
            symbol: "doc.text",
            title: isSpokenWord ? "transcript_export_menu" : "lyrics_export_menu"
        ) {
            closeChildPopovers()
            textExportPickerShown = true
        }
        .popover(isPresented: $textExportPickerShown, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(LyricsExportFormat.allCases) { format in
                    Button {
                        textExportPickerShown = false
                        menuShown = false
                        guard let song = player.currentSong else { return }
                        lyricsExportRequest = LyricsExportRequest(
                            song: song,
                            format: format,
                            isTranscript: isSpokenWord
                        )
                    } label: {
                        Text(verbatim: LyricsFileExporter.title(for: format))
                            .font(.callout)
                            .foregroundStyle(PMColor.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .pmRowBackground(cornerRadius: 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(minWidth: 200)
        }
    }

    /// 播客单集不在曲库里: 加歌单、改标签与歌词、歌曲信息都没有落处。
    private var isPodcastEpisode: Bool {
        PodcastPlaybackSong.isEpisode(player.currentSong)
    }

    /// 标签编辑器改的那一行。Apple Music 正在放的可能是目录里的那一份(id 不同),改动要存在
    /// 资料库那一行上;资料库里没有的目录歌没处存,不给改。
    private var tagEditorSong: Song? {
        guard let song = player.currentSong else { return nil }
        guard song.sourceID == AppleMusicLibraryService.systemSourceID else { return song }
        return library.song(id: NowPlayingLibraryActions.locationSongID(for: song, library: library))
    }

    private var isCurrentDisliked: Bool {
        guard let songID = player.currentSong?.id else { return false }
        return library.isDisliked(songID: songID)
    }

    /// 播客这一集:标为已播放(有下一集就接着放)、下载或取消下载。
    /// 已经下好的不给删:正在播的就是这个文件。
    @ViewBuilder
    private var podcastEpisodeRows: some View {
        if SpokenWordPlayerText.openablePodcastEpisodeID(player) != nil {
            menuRow(title: "podcast_mark_played", symbol: "checkmark.circle") {
                player.markCurrentPodcastEpisodePlayed()
            }
            switch PodcastPlayerEpisodeActions.download(player) {
            case .available:
                menuRow(title: "podcast_download", symbol: "arrow.down.circle") {
                    PodcastPlayerEpisodeActions.toggleDownload(player)
                }
            case .inProgress:
                menuRow(title: "podcast_cancel_download", symbol: "xmark.circle") {
                    PodcastPlayerEpisodeActions.toggleDownload(player)
                }
            case .downloaded, nil:
                EmptyView()
            }
        }
    }

    /// Popover 内的菜单内容。外层限制最大高度并在屏幕装不下时自动转成滚动容器。
    private var popoverMenuContent: some View {
        PlayerMoreMenuBoundedScroll(maxHeight: maximumPopoverHeight) {
            VStack(alignment: .leading, spacing: 0) {
                switch subpage {
                case .root:
                    rootMenuRows
                case .playbackOrder:
                    playbackOrderSubpage
                case .lyricsDisplay:
                    lyricsDisplaySubpage
                case .audioEffects:
                    audioEffectsSubpage
                case .editing:
                    editingSubpage
                }
            }
            .padding(.vertical, 6)
            .frame(width: 260)
        }
        .frame(width: 260)
        // 迷你播放器是深色面板, 系统 popover 的半透材质叠在它上面会把菜单染得发灰/
        // 发白、文字对比度很低。铺一层 flat 不透明 bg (不画圆角描边 —— 系统 chrome
        // 已经裁圆角带边框, 自己再画会变双框)。
        .background(PMColor.bg)
        // popover 一打开, SwiftUI 就把初始键盘焦点放在第一个按钮(上一首)上, 给它描一圈
        // accent 焦点环。菜单行是整幅宽的, 环的左右两边正好落在菜单边界外被裁掉, 屏幕上
        // 只剩贴着行上下沿的两条横线, 看着像凭空多了两条分隔线。这个菜单是鼠标点开的,
        // 原生菜单打开时同样不高亮任何一项, 所以直接关掉焦点描边。
        .focusEffectDisabled()
    }

    // MARK: - Root Menu

    @ViewBuilder
    private var rootMenuRows: some View {
        if surface.showsHeaderAndTransport {
            if let song = player.currentSong {
                menuHeader(song)
                divider()
            }
            menuRow(
                title: player.isPlaying ? "pause" : "play",
                symbol: player.isPlaying ? "pause.fill" : "play.fill",
                disabled: player.currentSong == nil && !player.isLiveRadio
            ) {
                player.togglePlayPause()
            }
            menuRow(title: "previous_song", symbol: "backward.fill") {
                Task { await player.previous() }
            }
            menuRow(title: "next_song", symbol: "forward.fill") {
                Task { await player.next() }
            }
            divider()
        }

        rootCurateAndShareSection
        divider()
        rootDiscoverAndNavigateSection
        divider()
        rootPlaybackAndSessionSection
        divider()
        rootSubpagesSection
        divider()
        rootSettingsAndDeleteSection
    }

    @ViewBuilder
    private var rootCurateAndShareSection: some View {
        if isPodcastEpisode {
            podcastEpisodeRows
        } else {
            menuRow(title: "add_to_playlist",
                    symbol: "text.badge.plus",
                    disabled: player.currentSong == nil || libraryActions.isBusy) {
                guard let song = player.currentSong else { return }
                Task { await libraryActions.perform(.addToPlaylist, song: song, library: library) }
            }
        }
        if commentServerStore.hasEnabledServers, !isSpokenWord, !player.isLiveRadio, player.currentSong != nil {
            menuRow(title: "comments_view_action", symbol: "bubble.left.and.text.bubble.right") {
                showComments = true
            }
        }
        if player.canDislikeCurrentSong {
            // 不喜欢(#193): 记下来并切到下一首; 已经不喜欢时再点只撤销。
            // 心形保持「喜欢 / 取消喜欢」两态, 不叠第三态。
            menuRow(title: isCurrentDisliked ? "song_undislike" : "song_dislike",
                    symbol: isCurrentDisliked ? "hand.thumbsdown.fill" : "hand.thumbsdown") {
                player.toggleDislikeForCurrentSong()
            }
        }
        if isPodcastEpisode {
            // 单集分享网页地址: 歌曲分享页的可播放链接和歌词海报对它都用不上。
            if let url = SpokenWordPlayerText.podcastShareURL(player) {
                ShareLink(item: url) {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.arrow.up")
                            .frame(width: 18)
                            .foregroundStyle(PMColor.textMuted)
                        Text("share")
                            .font(.callout)
                            .foregroundStyle(PMColor.text)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .pmRowBackground(cornerRadius: 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } else {
            menuRow(
                title: "share",
                symbol: "square.and.arrow.up",
                disabled: player.currentSong == nil
            ) {
                shareSong = player.currentSong
            }
        }
    }

    @ViewBuilder
    private var rootDiscoverAndNavigateSection: some View {
        if !isSpokenWord {
            if !player.isLiveRadio {
                menuRow(
                    title: "start_song_radio",
                    symbol: "dot.radiowaves.left.and.right",
                    disabled: player.currentSong == nil
                ) {
                    guard let seed = player.currentSong else { return }
                    menuShown = false
                    Task { @MainActor in
                        let queue = await SongRadioBuilder.queue(from: seed, in: library, limit: 48).filteredPlayable()
                        guard queue.count > 1 else { return }
                        player.shuffleEnabled = false
                        await player.play(queue: queue, startingAt: 0)
                    }
                }
            }
            // 相似歌曲 —— 飞出二级浮层 (和字号子菜单一致),点外部自动消失,
            // 不是之前那个没关闭按钮的固定 sheet。整行 hit-testable。
            flyoutRow(
                symbol: "sparkles",
                title: "similar_songs",
                disabled: player.currentSong == nil
            ) {
                guard player.currentSong != nil else { return }
                closeChildPopovers()
                showSimilarSongs = true
            }
            .popover(isPresented: $showSimilarSongs, arrowEdge: .leading) {
                if let song = player.currentSong {
                    MacSimilarSongsPopover(seed: song) {
                        showSimilarSongs = false
                        menuShown = false
                    }
                    .focusEffectDisabled()
                }
            }
        }

        if isPodcastEpisode, let episodeID = SpokenWordPlayerText.openablePodcastEpisodeID(player) {
            menuRow(title: "podcast_player_episode_details", symbol: "info.circle") {
                podcastSheet = .episode(episodeID)
            }
        }
        if let target = PodcastPlayerSheetTarget.show(for: player) {
            menuRow(title: "podcast_go_to_show", symbol: "rectangle.stack") {
                podcastSheet = target
            }
        }
        if !isPodcastEpisode {
            if player.currentItemIsAudiobook, let bookID = player.currentBookID {
                menuRow(title: "spoken_word_go_to_book", symbol: "books.vertical") {
                    NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: bookID)
                }
            } else if !isSpokenWord, let song = player.currentSong {
                let songID = NowPlayingLibraryActions.locationSongID(for: song, library: library)
                if !player.isLiveRadio, library.visibleSong(id: songID) != nil {
                    menuRow(title: "show_in_library", symbol: "music.note.list") {
                        SongLibraryNavigation.shared.pending = SongLibraryLocationRequest(songID: songID)
                        MainWindowOpener.openMainWindow()
                    }
                    .accessibilityIdentifier("nowPlaying.showInLibrary")
                }
                if let album = matchingAlbum(for: song) {
                    menuRow(titleText: "\(goToAlbumTitle) · \(album.title)",
                            symbol: "rectangle.stack.fill") {
                        NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
                    }
                }
                if let artist = matchingArtist(for: song) {
                    menuRow(titleText: "\(goToArtistTitle) · \(artist.name)",
                            symbol: "music.mic") {
                        NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
                    }
                }
            }
            menuRow(title: "song_info", symbol: "info.circle",
                    disabled: player.currentSong == nil) {
                showSongInfo = true
            }
        }
    }

    @ViewBuilder
    private var rootPlaybackAndSessionSection: some View {
        // 有声内容按书的顺序听, 随机与列表循环只会打乱章节；有声书单独支持单章循环。
        if !isSpokenWord {
            subpageRow(
                symbol: playbackOrderSymbol,
                title: "player_menu_playback_order",
                value: playbackOrderSummary,
                target: .playbackOrder
            )
        } else if player.currentItemIsAudiobook {
            checkRow(title: "spoken_word_repeat_chapter",
                     symbol: "repeat.1",
                     isChecked: player.isRepeatingCurrentSpokenWordChapter) {
                player.toggleSpokenWordChapterRepeat()
            }
        }
        if player.isMedleyActive {
            menuRow(title: "medley_continue_full", symbol: "music.note") {
                Task { await player.continueCurrentMedleySongInFull() }
            }
        } else if !isSpokenWord, !player.isLiveRadio, !player.isAppleMusicMode, player.canPlayMedleyFromQueue {
            menuRow(titleText: player.playbackSettings.medleyPlayQueueTitle,
                    symbol: "rectangle.stack.badge.play") {
                let songs = player.medleyCandidatesFromQueue
                if player.medleyNeedsDataUsageConfirmation(for: songs) {
                    pendingMedleySongs = songs
                } else {
                    Task { await player.playMedley(songs) }
                }
            }
        }
        if !isSpokenWord, player.currentSong != nil, !player.isLiveRadio, !player.isAppleMusicMode {
            menuRow(title: "karaoke_title", symbol: "music.mic.circle") {
                showKaraoke = true
            }
        }
        if player.currentItemIsSpokenWord, !player.isLiveRadio {
            menuRow(title: "spoken_word_add_bookmark", symbol: "bookmark") {
                player.addSpokenWordBookmark()
            }
        }
        if player.hasChapters || player.currentItemIsSpokenWord {
            menuRow(title: "spoken_word_chapters_and_bookmarks", symbol: "list.bullet.indent") {
                showChapterList = true
            }
        }
    }

    @ViewBuilder
    private var rootSubpagesSection: some View {
        subpageRow(
            symbol: "textformat.size",
            title: isSpokenWord ? "player_menu_transcript_display" : "player_menu_lyrics_display",
            value: lyricsDisplaySummary,
            target: .lyricsDisplay
        )
        subpageRow(
            symbol: "slider.vertical.3",
            title: offersSingAlongRow ? "player_menu_audio_and_sing_along" : "audio_effects",
            value: audioEffectsSummary,
            target: .audioEffects
        )
        if hasEditingItems {
            subpageRow(
                symbol: "square.and.pencil",
                title: isSpokenWord ? "player_menu_transcript_and_edit" : "player_menu_edit_and_clips",
                value: editingSummary,
                target: .editing
            )
        }
    }

    @ViewBuilder
    private var rootSettingsAndDeleteSection: some View {
        menuRow(titleText: playbackSettingsTitle, symbol: "gearshape") {
            openSettingsWindow()
        }
        if let song = player.currentSong {
            let librarySong = library.song(id: song.id)
            let target = librarySong ?? song
            let isSegment = SourceFileDeletionPolicy.isFileSegment(target)
            let showsCueRemoval = isSegment && librarySong != nil
            let showsDelete = canDeleteSourceFile(target)
            if showsCueRemoval || showsDelete {
                divider()
                if isSegment, let librarySong {
                    menuRow(title: "cue_remove_track_from_device", symbol: "minus.circle", role: .destructive,
                            disabled: batchRemoval.isBusy) {
                        cueRemovalTarget = librarySong
                    }
                }
                if showsDelete {
                    menuRow(title: isSegment ? "batch_delete_source_files" : "delete_song",
                            symbol: "trash", role: .destructive, disabled: isSegment && batchRemoval.isBusy) {
                        deletionTarget = SongFileDeletionRequest(song: target, library: library)
                    }
                }
            }
        }
    }

    // MARK: - Subpages

    @ViewBuilder
    private var playbackOrderSubpage: some View {
        subpageHeader(title: "player_menu_playback_order")
        divider()
        toggleRow(title: "shuffle", symbol: "shuffle",
                  isOn: Binding(get: { player.shuffleEnabled },
                                set: { player.shuffleEnabled = $0 }))
        divider()
        ForEach([RepeatMode.off, .all, .one], id: \.self) { mode in
            checkRow(
                title: PlayerMoreMenuPolicy.repeatChoiceTitleKey(for: mode),
                symbol: mode == .one ? "repeat.1" : "repeat",
                isChecked: player.repeatMode == mode
            ) {
                player.repeatMode = mode
            }
        }
        divider()
        sectionCaption("shuffle_preference_title")
        ForEach(ShufflePreference.allCases) { preference in
            checkRowText(
                titleText: preference.displayName,
                isChecked: preference == player.playbackSettings.shufflePreference
            ) {
                player.playbackSettings.shufflePreference = preference
            }
        }
        // Apple Music 自己排随机顺序时偏好不生效:照样能选,这里写明原因。
        if player.isAppleMusicMode, !player.isPrimuseManagingAppleMusicQueue {
            Text("shuffle_preference_apple_music_note")
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 4)
        }
        if let link = shuffleLinkState, let songID = player.currentSong?.id,
           link.nextTitle != nil || link.previousTitle != nil {
            // 随机时连播(#335):两行开关,不收起面板。
            divider()
            if link.nextTitle != nil {
                checkRow(title: "shuffle_link_next_long", symbol: "forward.end", isChecked: link.linksNext) {
                    library.setShuffleLinked(songID: songID, direction: .next, isLinked: !link.linksNext)
                }
            }
            if link.previousTitle != nil {
                checkRow(title: "shuffle_link_previous_long", symbol: "backward.end", isChecked: link.linksPrevious) {
                    library.setShuffleLinked(songID: songID, direction: .previous, isLinked: !link.linksPrevious)
                }
            }
        }
        divider()
        menuRow(title: "scrobble_title", symbol: "waveform.path.ecg") {
            NotificationCenter.default.post(name: .primuseSelectScrobble, object: nil)
        }
    }

    @ViewBuilder
    private var lyricsDisplaySubpage: some View {
        subpageHeader(title: isSpokenWord ? "player_menu_transcript_display" : "player_menu_lyrics_display")
        divider()
        // 字号子菜单 —— 用 popover 打开第二层。
        flyoutRow(symbol: "textformat.size", title: "lyrics_font_size") {
            closeChildPopovers()
            fontPickerShown = true
        }
        .popover(isPresented: $fontPickerShown, arrowEdge: .leading) {
            fontPickerPopover
        }
        // 歌词字体:每一种用它自己写个样字,要下载的选了就开始下。
        flyoutRow(symbol: "textformat", title: "transcript_font") {
            closeChildPopovers()
            lyricsFontPickerShown = true
        }
        .popover(isPresented: $lyricsFontPickerShown, arrowEdge: .leading) {
            lyricsFontPickerPopover
        }
        // 有文稿的有声内容:这一集 / 这本书的文稿往前、往后挪(#320)。
        if isSpokenWord, let song = player.currentSong,
           SpokenWordTranscriptOffsetStore.shared.itemKey(for: song) != nil {
            SpokenWordTranscriptOffsetRow(scope: .item(song), compact: true)
                .font(.callout)
                .foregroundStyle(PMColor.text)
                .padding(.leading, 12)
                .padding(.trailing, 2)
        }
        // 歌词翻译:关闭 / 系统翻译 / 智能翻译直接在这里选,和 iPhone 播放页菜单一致。
        if !isSpokenWord {
            divider()
            sectionCaption("lyrics_translation_title")
            ForEach(availableLyricsTranslationChoices, id: \.self) { choice in
                checkRow(
                    title: lyricsTranslationChoiceTitle(choice),
                    isChecked: choice == selectedLyricsTranslationChoice
                ) {
                    let settings = LyricsTranslationSettingsStore.shared
                    if let choice {
                        settings.mode = choice
                        settings.isEnabled = true
                    } else {
                        settings.isEnabled = false
                    }
                }
            }
            // 歌词文件里本来就有的译文，和上面的机翻方式分开管。
            checkRow(
                title: "lyrics_bundled_translation_shown",
                isChecked: LyricsTranslationSettingsStore.shared.showsBundledTranslations
            ) {
                LyricsTranslationSettingsStore.shared.showsBundledTranslations.toggle()
            }
            .help(Text("lyrics_bundled_translation_shown_footer"))
            divider()
            lyricsMotionRow
        }
    }

    @ViewBuilder
    private var audioEffectsSubpage: some View {
        subpageHeader(title: offersSingAlongRow ? "player_menu_audio_and_sing_along" : "audio_effects")
        divider()
        // 伴唱 Apple Music 时也给:画灰、写原因,点开说明为什么只能放原唱。
        if offersSingAlongRow {
            singAlongRow
        }
        // Apple Music 由系统播放器出声,投放时由对方设备出声,都不经过本机均衡器。
        if !player.isAppleMusicMode, player.castingRenderer == nil {
            equalizerRow
        }
        // 播放速度与升降调(#332),和 iPhone 播放页同一套:Apple Music 由系统播放器出声、
        // 电台是直播流,都没有这两项;升降调只给音乐。
        if !player.isAppleMusicMode, !player.isLiveRadio, player.currentSong != nil {
            playbackRateRow
            if MacPlaybackPitchPanel.availability(player) != .notOffered {
                pitchRow
            }
        }
        menuRow(title: player.isSleepTimerActive ? "sleep_timer_active" : "sleep_timer",
                symbol: player.isSleepTimerActive ? "moon.zzz.fill" : "moon.zzz") {
            showSleepTimer = true
        }
    }

    @ViewBuilder
    private var editingSubpage: some View {
        subpageHeader(title: isSpokenWord ? "player_menu_transcript_and_edit" : "player_menu_edit_and_clips")
        divider()
        if let rangeSong = playbackRangeSong {
            // 播放时间段:设过时这一行就是开关(行尾写着时间段,开着打勾),
            // 下面一行编辑;没设过时只有「设置播放时间段…」。
            if let range = SongPlaybackRangeStore.shared.range(for: rangeSong) {
                playbackRangeToggleRow(song: rangeSong, range: range)
                menuRow(title: "playback_range_edit", symbol: "slider.horizontal.3") {
                    playbackRangeEditorRequest = .init(song: rangeSong, purpose: .playbackRange)
                }
            } else {
                menuRow(title: "playback_range_set", symbol: "selection.pin.in.out") {
                    playbackRangeEditorRequest = .init(song: rangeSong, purpose: .playbackRange)
                }
            }
            menuRow(title: "clip_export_menu_mac", symbol: SongPlaybackRangeEditor.clipSymbol) {
                playbackRangeEditorRequest = .init(song: rangeSong, purpose: .clip)
            }
            divider()
        }
        if !isPodcastEpisode {
            menuRow(title: "tag_editor_menu",
                    symbol: "tag",
                    disabled: tagEditorSong == nil) {
                showTagEditor = true
            }
            menuRow(title: "lyrics_editor_menu",
                    symbol: "quote.bubble",
                    disabled: player.currentSong == nil) {
                lyricsEditorTargetSong = player.currentSong
            }
        }
        if let generation = transcriptGenerationRow {
            menuRow(titleText: generation, symbol: "waveform.and.mic") {
                transcriptGenerationSong = player.currentSong
            }
        }
        if canImportTranscripts {
            menuRow(title: "transcript_import_menu", symbol: "square.and.arrow.down.on.square") {
                transcriptImportRequest = SpokenTranscriptImportRequest.currentBook(player: player, library: library)
            }
        }
        if canExportText {
            textExportRow
        }
        // 在线刮削查的是音乐资料库, 拿有声内容的章节名去搜只会配错。
        if !isSpokenWord {
            menuRow(title: "scrape_song", symbol: "wand.and.stars",
                    disabled: player.currentSong == nil || isScrapingCurrentSong) {
                requestScrapeOptions()
            }
        }
        if canReloadLyricsFromSource {
            menuRow(
                title: isSpokenWord ? "transcript_reload_from_server" : "lyrics_reload_from_source",
                symbol: "arrow.clockwise.circle",
                disabled: isReloadingLyricsFromSource
            ) {
                reloadLyricsFromSource()
            }
        }
    }

    // MARK: - Summaries & Row Helpers

    private var playbackOrderSymbol: String {
        if player.repeatMode == .one { return "repeat.1" }
        return player.shuffleEnabled ? "shuffle" : "repeat"
    }

    private var playbackOrderSummary: String {
        PlayerMoreMenuPolicy.playbackOrderSummary(
            shuffleEnabled: player.shuffleEnabled,
            repeatMode: player.repeatMode
        )
    }

    private var lyricsDisplaySummary: String {
        if isSpokenWord {
            guard let song = player.currentSong,
                  let key = SpokenWordTranscriptOffsetStore.shared.itemKey(for: song) else { return "" }
            let delay = SpokenWordTranscriptOffsetStore.shared.itemDelay(forKey: key) ?? 0
            return abs(delay) >= 0.05 ? SpokenWordTranscriptOffsetRow.valueText(delay) : ""
        }
        guard let choice = selectedLyricsTranslationChoice else { return "" }
        return String(localized: lyricsTranslationChoiceResource(choice))
    }

    private var audioEffectsSummary: String {
        var parts: [String] = []
        if offersSingAlongRow, KaraokeSingAlong.shared.isEnabled {
            parts.append(String(localized: "sing_along_title"))
        }
        if !player.isAppleMusicMode, player.castingRenderer == nil,
           player.outputMode(for: player.currentSong) != .highFidelity,
           player.equalizerService.menuSelectionID != EqualizerService.menuOffID {
            parts.append(player.equalizerService.menuSelectionTitle)
        }
        if !player.isAppleMusicMode, !player.isLiveRadio, player.currentSong != nil,
           MacPlaybackRatePanel.canChangeRate(player) {
            let rate = MacPlaybackRatePanel.currentRate(player)
            if abs(rate - 1) >= 0.001 {
                parts.append(MacPlaybackRatePanel.valueLabel(rate))
            }
        }
        if !player.isAppleMusicMode, !player.isLiveRadio, player.currentSong != nil,
           MacPlaybackPitchPanel.availability(player) == .available,
           player.playbackSettings.pitchSemitones != 0 {
            parts.append(PlaybackPitchText.valueLabel(player.playbackSettings.pitchSemitones))
        }
        if player.isSleepTimerActive {
            parts.append(String(localized: "sleep_timer_active"))
        }
        return parts.joined(separator: " · ")
    }

    private var editingSummary: String {
        guard let rangeSong = playbackRangeSong,
              let range = SongPlaybackRangeStore.shared.range(for: rangeSong),
              range.isEnabled else { return "" }
        return SongPlaybackRangePolicy.rangeLabel(range)
    }

    private func subpageHeader(title: LocalizedStringKey) -> some View {
        Button { openSubpage(.root) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PMColor.textMuted)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PMColor.text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("back"))
        // 读屏先读到这一行:「返回」之外还要说清楚现在在哪一页。
        .accessibilityValue(Text(title))
    }

    private func sectionCaption(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(PMColor.textMuted)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    private func subpageRow(
        symbol: String,
        title: LocalizedStringKey,
        value: String,
        target: PlayerMoreMenuSubpage
    ) -> some View {
        flyoutRow(symbol: symbol, title: title, value: value) {
            openSubpage(target)
        }
    }

    /// 打开第二层(或子页)的行,与均衡器那一行同一画法。用不了时画灰、第二行写原因,不显示当前值,
    /// 仍然能点开看说明。
    private func flyoutRow(
        symbol: String,
        title: LocalizedStringKey,
        value: String = "",
        unavailableReason: String? = nil,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isUnavailable = unavailableReason != nil
        return Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(isUnavailable ? PMColor.textFaint : PMColor.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .foregroundStyle(isUnavailable ? PMColor.textMuted : PMColor.text)
                    if let unavailableReason {
                        Text(verbatim: unavailableReason)
                            .font(.caption2)
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 当前值(预设名)长时先截它,别把标题截掉。
                .layoutPriority(1)
                Spacer(minLength: 8)
                if !isUnavailable, !value.isEmpty {
                    Text(verbatim: value)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(PMColor.textFaint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: unavailableReason ?? value))
    }

    private func menuHeader(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42,
                cornerRadius: 7,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PMColor.text)
                    .lineLimit(1)
                Text(
                    library.artistDisplayName(for: song)
                        ?? String(localized: "unknown_artist")
                )
                    .font(.caption)
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func menuRow(title: LocalizedStringKey, symbol: String,
                         role: ButtonRole? = nil, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(role: role) {
            menuShown = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.textMuted)
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.callout)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.text)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private func menuRow(titleText: String, symbol: String,
                         role: ButtonRole? = nil, disabled: Bool = false,
                         action: @escaping () -> Void) -> some View {
        Button(role: role) {
            menuShown = false
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.textMuted)
                    .contentTransition(.symbolEffect(.replace))
                Text(verbatim: titleText)
                    .font(.callout)
                    .foregroundStyle(role == .destructive ? PMColor.bad : PMColor.text)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// 开关项:和其它行同一套图标、字号、行高,开着时行尾打勾 —— Mac 菜单表示开关
    /// 状态的方式,与字号子菜单的勾同一画法。不用 `.switch` 开关:它的尺寸不跟行走,
    /// 放在这列里会顶出面板右缘。图标固定不换,勾只占位不增删,行宽不跳。
    /// 原生全屏是播放页本身，不用「歌词动效」。选着原生时整行画灰、第二行写明，
    /// 但仍然能拨 —— 换成别的全屏效果就按这里的设置来。
    private var lyricsMotionRow: some View {
        let isNative = (FullscreenPlayerEffect(rawValue: fullscreenEffectRawValue) ?? .defaultValue).isNative
        return Button { lyricsMotionEnabled.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .frame(width: 18)
                    .foregroundStyle(isNative ? PMColor.textFaint : PMColor.textMuted)
                VStack(alignment: .leading, spacing: 1) {
                    Text("immersive_lyrics_motion_title")
                        .font(.callout)
                        .foregroundStyle(isNative ? PMColor.textMuted : PMColor.text)
                    if isNative {
                        Text("immersive_lyrics_motion_native_note")
                            .font(.caption2)
                            .foregroundStyle(PMColor.textFaint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(PMColor.brand)
                    .opacity(lyricsMotionEnabled ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("immersive_lyrics_motion_subtitle"))
        .accessibilityAddTraits(lyricsMotionEnabled ? [.isToggle, .isSelected] : .isToggle)
    }

    private func toggleRow(title: LocalizedStringKey, symbol: String,
                           isOn: Binding<Bool>) -> some View {
        checkRow(title: title, symbol: symbol, isChecked: isOn.wrappedValue) {
            isOn.wrappedValue.toggle()
        }
    }

    /// 带状态的行。点了不收起菜单,当场看得到勾的变化。
    private func checkRow(title: LocalizedStringKey, symbol: String? = nil, isChecked: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol)
                        .frame(width: 18)
                        .foregroundStyle(PMColor.textMuted)
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(title)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(PMColor.brand)
                    .opacity(isChecked ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? [.isToggle, .isSelected] : .isToggle)
    }

    private func checkRowText(titleText: String, isChecked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(verbatim: titleText)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                Spacer()
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(PMColor.brand)
                    .opacity(isChecked ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChecked ? [.isToggle, .isSelected] : .isToggle)
    }

    /// 「随机时连播」(#335):曲库里有专辑曲序可依的音乐才有;有声内容、Apple Music、电台没有。
    private var shuffleLinkState: ShuffleLinkMenuState? {
        guard !player.isAppleMusicMode, !player.isLiveRadio, !player.currentItemIsSpokenWord,
              let songID = player.currentSong?.id else { return nil }
        return ShuffleLinkMenuState(songID: songID, library: library)
    }

    /// 能设播放时间段的当前歌曲(整首);有声内容、Apple Music、电台没有这一项。
    private var playbackRangeSong: Song? {
        guard !player.isAppleMusicMode, !player.isLiveRadio, !player.currentItemIsSpokenWord,
              let song = player.currentSong?.withoutAppliedPlaybackRange,
              SongPlaybackRangeAvailability.supports(song) else { return nil }
        return song
    }

    /// 播放时间段的开关行:与 `checkRow` 同一画法,标题后面多写一个时间段。
    private func playbackRangeToggleRow(song: Song, range: SongPlaybackRange) -> some View {
        Button {
            SongPlaybackRangeStore.shared.setEnabled(!range.isEnabled, for: song)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "selection.pin.in.out")
                    .frame(width: 18)
                    .foregroundStyle(PMColor.textMuted)
                Text("playback_range_title")
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(verbatim: SongPlaybackRangePolicy.rangeLabel(range))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundStyle(PMColor.brand)
                    .opacity(range.isEnabled ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("playback_range_title"))
        .accessibilityValue(Text(verbatim: SongPlaybackRangePolicy.rangeLabel(range)))
        .accessibilityAddTraits(range.isEnabled ? [.isToggle, .isSelected] : .isToggle)
    }

    private func divider() -> some View {
        Rectangle()
            .fill(PMColor.divider)
            .frame(height: 0.5)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }

    /// 均衡器 —— 和字号一样用 popover 打开第二层,行尾带着当前值。高保真直通的图里
    /// 没有均衡器:整行画成灰的、第二行写明原因,但仍然能点,第二层先说明原因。
    private var equalizerRow: some View {
        let isBypassed = player.outputMode(for: player.currentSong) == .highFidelity
        return flyoutRow(
            symbol: "slider.vertical.3",
            title: "equalizer",
            value: player.equalizerService.menuSelectionTitle,
            unavailableReason: isBypassed ? String(localized: "eq_menu_high_fidelity_unavailable") : nil
        ) {
            closeChildPopovers()
            equalizerPickerShown = true
        }
        .popover(isPresented: $equalizerPickerShown, arrowEdge: .leading) {
            MacEqualizerMenuPanel(
                player: player,
                onPicked: { equalizerPickerShown = false },
                onAdjust: {
                    equalizerPickerShown = false
                    menuShown = false
                    SettingsWindowController.shared.show(tab: .equalizer)
                }
            )
        }
    }

    /// 播放速度 —— 和均衡器一样用 popover 打开第二层,行尾带着当前值。高保真直通下音乐
    /// 不能变速:整行画灰、第二行写原因,仍然能点,第二层先说明原因并能一键切到音效输出。
    private var playbackRateRow: some View {
        let isUnavailable = !MacPlaybackRatePanel.canChangeRate(player)
        return flyoutRow(
            symbol: "speedometer",
            title: "playback_rate",
            value: MacPlaybackRatePanel.valueLabel(MacPlaybackRatePanel.currentRate(player)),
            unavailableReason: isUnavailable ? String(localized: "eq_menu_high_fidelity_unavailable") : nil
        ) {
            closeChildPopovers()
            playbackRatePickerShown = true
        }
        .popover(isPresented: $playbackRatePickerShown, arrowEdge: .leading) {
            MacPlaybackRatePanel(player: player) { playbackRatePickerShown = false }
        }
    }

    /// 伴唱:行尾是原唱留多少或在准备什么;放不了时画灰、第二行写原因,仍能点开看说明。
    private var singAlongRow: some View {
        let singAlong = KaraokeSingAlong.shared
        return flyoutRow(
            symbol: KaraokeSingAlongText.symbol,
            title: "sing_along_title",
            value: KaraokeSingAlongText.summary(singAlong.phase, level: singAlong.level, showsProgress: true),
            unavailableReason: KaraokeSingAlongText.unavailableReason(singAlong.phase)
        ) {
            closeChildPopovers()
            singAlongPanelShown = true
        }
        .popover(isPresented: $singAlongPanelShown, arrowEdge: .leading) {
            MacSingAlongPanel(player: player)
        }
    }

    /// 升降调:第二层是 降调 / 当前调 / 升调 三个键,点了不收起,能连着调。
    private var pitchRow: some View {
        let availability = MacPlaybackPitchPanel.availability(player)
        return flyoutRow(
            symbol: PlaybackPitchText.symbol,
            title: "karaoke_key",
            value: PlaybackPitchText.valueLabel(player.playbackSettings.pitchSemitones),
            unavailableReason: PlaybackPitchText.shortReason(availability)
        ) {
            closeChildPopovers()
            pitchPickerShown = true
        }
        .popover(isPresented: $pitchPickerShown, arrowEdge: .leading) {
            MacPlaybackPitchPanel(player: player)
        }
    }

    private var offersSmartLyricsTranslation: Bool {
        intelligence?.shouldExposeRemoteConfiguration == true
    }

    private var availableLyricsTranslationChoices: [LyricsTranslationMode?] {
        var choices: [LyricsTranslationMode?] = offersSmartLyricsTranslation
            ? [nil, .system, .intelligentWithSystemFallback]
            : [nil, .system]
        // 填好了百度翻译(或正选着它)才列出来,没用它的人不多一项(#320)。
        if BaiduTranslateAccount.shared.isConfigured || LyricsTranslationSettingsStore.shared.mode == .baidu {
            choices.append(.baidu)
        }
        return choices
    }

    /// nil 是关闭。
    private var selectedLyricsTranslationChoice: LyricsTranslationMode? {
        let settings = LyricsTranslationSettingsStore.shared
        guard settings.isEnabled else { return nil }
        return settings.mode == .intelligentWithSystemFallback && !offersSmartLyricsTranslation
            ? .system : settings.mode
    }

    private func lyricsTranslationChoiceTitle(_ choice: LyricsTranslationMode?) -> LocalizedStringKey {
        switch choice {
        case nil: "lyrics_translation_mode_off"
        case .system: "lyrics_translation_mode_system"
        case .intelligentWithSystemFallback: "lyrics_translation_mode_smart"
        case .baidu: "lyrics_translation_mode_baidu"
        }
    }

    private func lyricsTranslationChoiceResource(_ choice: LyricsTranslationMode?) -> String.LocalizationValue {
        switch choice {
        case nil: "lyrics_translation_mode_off"
        case .system: "lyrics_translation_mode_system"
        case .intelligentWithSystemFallback: "lyrics_translation_mode_smart"
        case .baidu: "lyrics_translation_mode_baidu"
        }
    }

    private var fontPickerPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            fontPickerRow("lyrics_font_small", value: 0.85)
            fontPickerRow("lyrics_font_medium", value: 1.0)
            fontPickerRow("lyrics_font_large", value: 1.2)
            fontPickerRow("lyrics_font_xlarge", value: 1.5)
            // 译文(和注音)行单独的字号(#320)。
            divider()
            Text("lyrics_translation_font_size")
                .font(.caption)
                .foregroundStyle(PMColor.textMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            fontPickerRow("lyrics_translation_font_follow", value: 0, translation: true)
            fontPickerRow("lyrics_font_small", value: 0.85, translation: true)
            fontPickerRow("lyrics_font_medium", value: 1.0, translation: true)
            fontPickerRow("lyrics_font_large", value: 1.2, translation: true)
            fontPickerRow("lyrics_font_xlarge", value: 1.5, translation: true)
        }
        .padding(.vertical, 6)
        .frame(width: 180)
        .focusEffectDisabled()
    }

    private var lyricsFontPickerPopover: some View {
        // 字体块按宽度折行,一排四块。
        ScrollView {
            LyricsLanguageFontPicker()
                .padding(16)
        }
        .frame(width: 460, height: 520)
        .focusEffectDisabled()
    }

    private func fontPickerRow(_ title: LocalizedStringKey, value: Double, translation: Bool = false) -> some View {
        let current = translation ? lyricsTranslationFontScale : lyricsFontScale
        return Button {
            // 播放页没打开时(底栏、迷你播放器的「更多」)没有别处替它推上 iCloud。
            if translation {
                lyricsTranslationFontScale = value
                CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsTranslationFontScale)
            } else {
                lyricsFontScale = value
                CloudKVSSync.shared.markChanged(key: CloudKVSKey.lyricsFontScale)
            }
            fontPickerShown = false
        } label: {
            HStack {
                Text(title)
                    .font(.callout)
                    .foregroundStyle(PMColor.text)
                Spacer()
                if abs(current - value) < 0.001 {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(PMColor.brand)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func requestScrapeOptions() {
        scraperSettings.performSingleSongScrapeAction(
            from: .macPlayerMenu,
            onProceed: { showScrapeOptions = true },
            onRequireSource: { showNoScraperSourceAlert = true }
        )
    }

    private var canReloadLyricsFromSource: Bool {
        guard let song = player.currentSong else { return false }
        return LyricsAuthoritativeSourcePolicy.supportsServerDocument(
            sourcesStore.source(id: song.sourceID)?.type
        )
    }

    private var isReloadingLyricsFromSource: Bool {
        sourceLyricsReloadingSongID == player.currentSong?.id
    }

    /// 有声内容的「重新读取服务器文字稿」(#461):没登记的请服务端扫描,用户自己的那份问过再换。
    private func reloadServerTranscript(song: Song, replacingUserTranscript: Bool) {
        guard sourceLyricsReloadingSongID != song.id else { return }
        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        sourceLyricsReloadingSongID = song.id
        Task { @MainActor in
            let outcome = await ServerTranscriptReload.run(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                cachedDocument: nil,
                replacingUserTranscript: replacingUserTranscript
            )
            if sourceLyricsReloadingSongID == song.id {
                sourceLyricsReloadingSongID = nil
            }
            guard LyricsAuthoritativeSourcePolicy.shouldApply(
                responseForSongID: song.id,
                currentlyPlayingSongID: player.currentSong?.id
            ) else { return }
            if outcome == .needsReplaceConfirmation {
                serverTranscriptReplaceSong = song
            } else {
                sourceLyricsReloadAlertMessage = outcome.message
            }
        }
    }

    private func reloadLyricsFromSource() {
        guard !isReloadingLyricsFromSource,
              let song = player.currentSong else { return }
        if isSpokenWord {
            reloadServerTranscript(song: song, replacingUserTranscript: false)
            return
        }
        let sourceType = sourcesStore.source(id: song.sourceID)?.type
        guard LyricsAuthoritativeSourcePolicy.supportsServerDocument(sourceType) else {
            sourceLyricsReloadAlertMessage = String(
                localized: "lyrics_source_reload_unsupported"
            )
            return
        }

        sourceLyricsReloadingSongID = song.id
        Task { @MainActor in
            let result = await LyricsLoader.refreshFromSource(
                for: song,
                sourceType: sourceType,
                sourceManager: sourceManager,
                trigger: .explicit
            )
            if sourceLyricsReloadingSongID == song.id {
                sourceLyricsReloadingSongID = nil
            }
            guard LyricsAuthoritativeSourcePolicy.shouldApply(
                responseForSongID: song.id,
                currentlyPlayingSongID: player.currentSong?.id
            ) else { return }

            switch result {
            case .updated:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_success"
                )
            case .unchanged, .throttled:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_unchanged"
                )
            case .emptyPreservingCache:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_empty_kept"
                )
            case .failedPreservingCache:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_failed_kept"
                )
            case .unsupported:
                sourceLyricsReloadAlertMessage = String(
                    localized: "lyrics_source_reload_unsupported"
                )
            }
        }
    }

    /// 音乐服务器上的歌再确认一次（服务器上的所有用户和客户端都会失去它），文件来源直接删。
    private func confirmDeleteCurrentSong(_ song: Song) {
        guard player.currentSong?.id == song.id else { return }
        guard let request = ServerSongDeletionRequest.make(
            deleting: [song],
            sources: sourcesStore.allSources,
            perform: { deleteCurrentSong(song) }
        ) else {
            deleteCurrentSong(song)
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: ServerSongDeletionRequest.presentationDelay)
            serverDeletionRequest = request
        }
    }

    private func deleteCurrentSong(_ song: Song) {
        guard player.currentSong?.id == song.id, canDeleteSourceFile(song) else { return }
        if SourceFileDeletionPolicy.isFileSegment(song) {
            batchRemoval.remove([song], mode: .sourceFiles)
            return
        }
        let songID = song.id
        // 先切歌、等 next() 内部 play(song:) 完成,再删缓存/库记录 ——
        // 否则正在播放/预载的音频文件会被抽走 (异步 next() 与同步删除竞态)。
        Task {
            await player.next()

            // 别的歌还用着的旁挂文件不删。要整库来判断:歌曲模型放掉了就先装回来,答不了时不删(6c 单元 4 U2b)。
            let deleteSidecars = await SongModelArrayRead.deletesSidecars(for: song, in: library)
            let result = await sourceManager.deleteSourceFilesAndCaches(
                for: song,
                deleteSidecars: deleteSidecars
            )
            guard result.shouldRemoveLibraryRecord else {
                deleteErrorMessage = deletionFailureMessage(result)
                return
            }

            await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
            await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
            CachedArtworkView.invalidateCache(for: songID)
            sourceManager.deleteAudioCache(for: song)
            // 源文件已确认删除, 墓碑可以在同一路径换了文件时让路。
            let remaining = library.deleteSong(song, sourceFileDeleted: true)
            sourcesStore.updateLocal(song.sourceID) { $0.songCount = remaining }

            // AudioPlayerService 不监听 .primuseSongsRemoved, 删除后这首歌仍留在
            // 播放队列里 —— 用户点上一首或在队列面板点该行就会再次播放一首库里已不
            // 存在的歌。这里把它从队列剔除, 并修正 currentIndex 指向当前在播的歌。
            removeFromPlayerQueue(songID)
        }
    }

    private func canDeleteSourceFile(_ song: Song) -> Bool {
        SourceFileDeletionPolicy.shouldShowDeleteAction(
            for: song,
            sourceType: sourcesStore.source(id: song.sourceID)?.type
        )
    }

    private func deletionFailureMessage(_ result: SongFileDeletionResult) -> String {
        let summary = String(localized: "delete_song_failed_message")
        guard let detail = result.failedPaths.first?.message, !detail.isEmpty else { return summary }
        return "\(summary)\n\(detail)"
    }

    /// 把已删除的歌从播放队列剔除。AudioPlayerService 没有"按 id 移除单曲"的 API,
    /// 用公开的 setQueue 重建队列即可:过滤掉该曲, 并把起点对齐到当前在播的歌。
    /// 若队列原本只有这一首 (next() 又把它重播了), 过滤后为空 → 停止播放并清队列。
    private func removeFromPlayerQueue(_ songID: String) {
        let filtered = player.queue.filter { $0.id != songID }
        guard filtered.count != player.queue.count else { return }
        guard !filtered.isEmpty else {
            player.stop()
            player.clearQueue()
            return
        }
        let startIndex = player.currentSong.flatMap { current in
            filtered.firstIndex { $0.id == current.id }
        } ?? 0
        player.setQueue(filtered, startAt: startIndex, keepsContinuation: true)
    }

    private var goToAlbumTitle: String {
        NSLocalizedString("go_to_album", tableName: nil, bundle: .main, value: "Go to Album", comment: "")
    }

    private var goToArtistTitle: String {
        NSLocalizedString("go_to_artist", tableName: nil, bundle: .main, value: "Go to Artist", comment: "")
    }

    private var playbackSettingsTitle: String {
        NSLocalizedString("playback_settings_title", tableName: nil, bundle: .main, value: "Playback Settings", comment: "")
    }

    private func matchingAlbum(for song: Song) -> Album? {
        library.linkedAlbum(for: song)
            // 曲库里一首都没有的 Apple Music 专辑按目录现拼一张。
            ?? AppServices.shared.appleMusicLibrary.catalogAlbum(forCatalogOnlySong: song)
    }

    private func matchingArtist(for song: Song) -> Artist? {
        if let id = song.artistID,
           let artist = library.visibleArtist(id: id) {
            return artist
        }

        guard let name = trimmed(library.artistNames(for: song).first), !name.isEmpty else { return nil }
        return library.visibleArtist(named: name)
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 睡眠定时面板。选项按正在播的空间给 (`SleepTimerOptionPolicy`): 音乐是分钟数
/// + 本曲结束; 电台只有分钟数 (直播流没有「结束」); 有声是分钟数 + 本章 /
/// 本集 / 整本结束。底栏的月亮键和「更多」菜单打开的是同一个面板。
struct MacSleepTimerPopover: View {
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @State private var customMinutes: Double = 30
    @State private var now = Date()
    @AppStorage(SleepTimerSchedulePolicy.finishesTrackPreferenceKey) private var finishesTrack = false
    /// 和 iPhone / iPad 的定时面板同一个键:上次选的「到几点停」。
    @AppStorage("primuse.sleepTimer.clockMinuteOfDay") private var clockMinuteOfDay = 23 * 60
    /// 环境音那一行快捷定时记下的选择(右栏那一行读同一份);在这里关掉定时记成不限时。
    @AppStorage(AmbientQuickTimerRow.storageKey) private var ambientQuickTimerMinutes = 0

    private var space: ListeningSpace {
        // 底栏的空间分不出环境音(按音乐算),定时这里要分开:环境音没有「播完这首」。
        if player.currentItemIsAmbient { return .ambient }
        return MacListeningSpaceStyle.playingSpace(of: player) ?? .music
    }

    private var options: [SleepTimerOption] {
        SleepTimerOptionPolicy.options(for: space, hasChapters: player.hasChapters)
    }

    private var presets: [Int] {
        options.compactMap { option in
            if case .minutes(let minutes) = option { return minutes }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if space == .ambient {
                // 环境音:与右栏、环境音页那一行快捷定时同一套,含「不限时」,亮的是同一颗。
                AmbientQuickTimerRow(onChoose: onClose)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(presets, id: \.self) { minutes in
                        presetButton(minutes)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    endOptionRow(option)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Lz("Custom (minutes)"))
                            .font(.system(size: 11))
                            .foregroundStyle(PMColor.textFaint)
                        Spacer()
                        Text("\(Int(customMinutes))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(PMColor.textMuted)
                    }
                    Slider(value: $customMinutes, in: 5...120, step: 5)
                        .tint(PMColor.brand)
                        .accessibilityLabel(Text(Lz("Custom (minutes)")))
                        .accessibilityValue(Text(verbatim: "\(Int(customMinutes))"))
                    Button {
                        player.scheduleSleep(minutes: Int(customMinutes))
                        onClose()
                    } label: {
                        Text(Lz("Set Custom Timer"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 28)
                            .background(PMColor.brand, in: .rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }

                clockRow

                if space == .music, !player.isLiveRadio {
                    Toggle(isOn: $finishesTrack) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sleep_timer_finish_track")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(PMColor.text)
                            Text("sleep_timer_finish_track_footer")
                                .font(.system(size: 10.5))
                                .foregroundStyle(PMColor.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            footer
        }
        .frame(width: 280)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { value in
            now = value
        }
    }

    private var clockTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.startOfDay(for: now).addingTimeInterval(TimeInterval(clockMinuteOfDay * 60))
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                clockMinuteOfDay = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var clockEndDate: Date {
        SleepTimerSchedulePolicy.nextOccurrence(hour: clockMinuteOfDay / 60, minute: clockMinuteOfDay % 60, after: now)
    }

    /// 「到几点停」:比现在早的时刻算明天,旁边写清是今天还是明天。
    private var clockRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("sleep_timer_custom_mode_clock")
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            HStack(spacing: 8) {
                DatePicker(selection: clockTime, displayedComponents: .hourAndMinute) {
                    Text("sleep_timer_custom_mode_clock")
                }
                .datePickerStyle(.field)
                .labelsHidden()
                .fixedSize()
                Text(verbatim: SleepTimerStatusText.stopTime(clockEndDate, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Button {
                    player.scheduleSleep(until: clockEndDate)
                    onClose()
                } label: {
                    Text("sleep_timer_start")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(PMColor.brand, in: .rect(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 「……结束后停止」这几行。分钟数在上面的网格里, 这里不出现。
    @ViewBuilder
    private func endOptionRow(_ option: SleepTimerOption) -> some View {
        switch option {
        case .minutes:
            EmptyView()
        case .endOfTrack:
            endRow(
                title: space.playbackFamily == .spokenWord
                    ? String(localized: "sleep_at_item_end")
                    : String(localized: "sleep_at_track_end"),
                symbol: "play.fill",
                isSelected: player.sleepStopAfterSongID != nil
            ) {
                player.scheduleSleepAtTrackEnd()
            }
        case .endOfChapter:
            endRow(
                title: String(localized: "sleep_at_chapter_end"),
                symbol: "list.bullet.indent",
                isSelected: player.sleepStopAfterChapter != nil
            ) {
                player.scheduleSleepAtChapterEnd()
            }
            .disabled(player.currentChapterIndex == nil)
        case .endOfBook:
            endRow(
                title: String(localized: "sleep_at_book_end"),
                symbol: "book.closed",
                isSelected: player.sleepStopAfterBook != nil
            ) {
                player.scheduleSleepAtBookEnd()
            }
        }
    }

    private func endRow(
        title: String,
        symbol: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            onClose()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 10))
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(PMColor.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(PMColor.glassBtn, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(PMColor.cardBorder, lineWidth: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Lz("Sleep Timer"))
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(PMColor.text)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }

    private func presetButton(_ minutes: Int) -> some View {
        let selected = selectedPreset == minutes
        return Button {
            player.scheduleSleep(minutes: minutes)
            onClose()
        } label: {
            Text("\(minutes) \(String(localized: "minutes"))")
                .font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? .white : PMColor.text)
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(selected ? PMColor.brand : PMColor.glassBtn, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(selected ? .clear : PMColor.cardBorder, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        // 带 value: —— 这个面板每秒会被倒计时刷新一次, 不带触发值的 .animation
        // 会每秒开一次事务。
        .pmAnimation(.hover, value: selected)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(player.isSleepTimerActive ? PMColor.brand : PMColor.textFaint)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            if player.isSleepTimerActive {
                footerActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var footerActions: some View {
        HStack(spacing: 6) {
            if player.sleepTimerEndDate != nil {
                // 倒数中:往后推几分钟,不用重新选。
                ForEach(SleepTimerSchedulePolicy.extensionMinutes, id: \.self) { minutes in
                    Button {
                        player.extendSleep(minutes: minutes)
                    } label: {
                        Text(verbatim: String(format: String(localized: "sleep_timer_extend_format"), minutes))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(PMColor.glassBtn, in: .rect(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 4)
            Button {
                player.cancelSleep()
                if space == .ambient {
                    ambientQuickTimerMinutes = AmbientQuickTimerSelection.unlimitedMinutes
                }
                onClose()
            } label: {
                Text("cancel_timer")
                    .font(.system(size: 11.5))
                    .foregroundStyle(PMColor.bad)
                    .frame(height: 24)
            }
            .buttonStyle(.plain)
        }
    }

    private var selectedPreset: Int? {
        guard let end = player.sleepTimerEndDate else { return nil }
        let minutes = round(end.timeIntervalSince(now) / 60.0).finiteInt()
        return presets.min(by: { abs($0 - minutes) < abs($1 - minutes) })
            .flatMap { abs($0 - minutes) <= 1 ? $0 : nil }
    }

    private var statusText: String {
        if let end = player.sleepTimerEndDate {
            let remaining = max(0, end.timeIntervalSince(now).finiteInt())
            return "\(Lz("Remaining")) \(TimeInterval(remaining).formattedDuration) · "
                + SleepTimerStatusText.stopTime(end, now: now)
        }
        if player.sleepStopAfterSongID != nil {
            return Lz("Stop After Current Song")
        }
        if player.sleepStopAfterChapter != nil {
            return String(localized: "sleep_at_chapter_end")
        }
        if player.sleepStopAfterBook != nil {
            return String(localized: "sleep_at_book_end")
        }
        return Lz("Not Enabled")
    }
}

// MARK: - Similar Songs Popover (相似歌曲浮层)

/// 设计稿「相似歌曲」浮层 —— 从 More 菜单 / 歌曲右键飞出的悬浮面板,点外部
/// 自动消失 (系统 popover 行为),不再是没关闭按钮的固定 sheet。
///
/// 把本地特征相似 (MusicDiscoveryEngine, 看 metadata 重叠) 和 Last.fm 听众
/// 重叠 (看播放行为) 合并成一个按匹配度排序的列表:每行一条匹配进度条 + 0~99
/// 分值,来源是 Apple Music 的标 AM。底部一个整宽「播放相似电台」。
struct MacSimilarSongsPopover: View {
    let seed: Song
    /// 关闭整组浮层 (含父级 More 菜单)。播放后或点外部时调用。
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    @Environment(SourcesStore.self) private var sourcesStore

    @State private var lastFmCandidates: [SimilarTracksCandidate] = []
    @State private var isLoadingLastFm = true
    // 缓存计算结果, 不在 body 里实时算。否则 `rows` 每次 body 重算都会跑一遍全库
    // 相似度 (MusicDiscoveryEngine.similarSongs over 全库); 回填/播放进度在改
    // library.songs 时 body 又频繁重算 → 滚动时一帧算一次全库, 极卡。
    @State private var localRows: [Row] = []
    @State private var displayRows: [Row] = []
    /// 「播放相似电台」要等 Last.fm(最多几秒),按钮先转圈。
    @State private var isBuildingRadio = false

    /// 合并去重后的展示行。`affinity` 统一到 0~1,本地分按软上限折算。
    private struct Row: Identifiable {
        let song: Song
        let affinity: Double
        var id: String { song.id }
        var score: Int { min(99, max(1, (affinity * 100).rounded().finiteInt(or: 1))) }
    }

    /// 全库相似度计算 (较重) —— 只在 seed 变化时算一次, 结果缓存到 `localRows`。
    private func computeLocalRows() -> [Row] {
        // 本地特征分用 120 作软上限:同专辑 (~46+) 叠到接近满,同艺术家+流派+年代
        // (~84) 折到 0.7 左右,跟 Last.fm 的 0~1 同量级,合并排序才不串味。
        MusicDiscoveryEngine.similarSongs(to: seed, in: library, limit: 30).map { result in
            Row(song: result.song, affinity: min(1.0, max(0.0, result.score / 120.0)))
        }
    }

    /// 合并本地 + Last.fm 候选 (去重 + 排序), 较轻 —— lastFm 加载完后再算一次即可。
    private func mergedRows() -> [Row] {
        var byID: [String: Row] = [:]
        for row in localRows {
            if row.affinity >= (byID[row.song.id]?.affinity ?? -1) {
                byID[row.song.id] = row
            }
        }
        for candidate in lastFmCandidates {
            guard let song = candidate.librarySong else { continue }
            let affinity = min(1.0, max(0.0, candidate.match))
            if affinity >= (byID[song.id]?.affinity ?? -1) {
                byID[song.id] = Row(song: song, affinity: affinity)
            }
        }
        return byID.values.sorted {
            $0.affinity != $1.affinity
                ? $0.affinity > $1.affinity
                : $0.song.title.localizedCompare($1.song.title) == .orderedAscending
        }
    }

    private var subtitle: String {
        let source = lastFmCandidates.isEmpty ? String(localized: "library") : "Last.fm"
        return String(format: String(localized: "similar_subtitle_format"), seed.title, source)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            divider
            content
            divider
            footer
        }
        .frame(width: 320)
        // 跟主菜单一致: 铺 flat 不透明底, 避免半透材质叠深色背景发灰 (不画圆角边框)。
        .background(PMColor.bg)
        .task(id: seed.id) {
            localRows = computeLocalRows()
            displayRows = mergedRows()
            await loadLastFm()
            // Last.fm 候选加载完后再合并一次 (SimilarTracksCandidate 非 Equatable,
            // 不走 onChange, 直接在这里重算)。
            displayRows = mergedRows()
        }
    }

    private var divider: some View {
        Rectangle().fill(PMColor.divider).frame(height: 0.5)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(PMColor.brand)
            VStack(alignment: .leading, spacing: 2) {
                Text("similar_songs")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private var content: some View {
        if displayRows.isEmpty {
            VStack(spacing: 8) {
                if isLoadingLastFm {
                    ProgressView().controlSize(.small)
                    Text("similar_loading")
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .multilineTextAlignment(.center)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(PMColor.textFaint)
                    Text("similar_empty")
                        .font(.system(size: 12))
                        .foregroundStyle(PMColor.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(displayRows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, ordinal: index + 1, totalCount: displayRows.count)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 360)
            .scrollIndicators(.hidden)
            // 系统「总是显示滚动条」时直接在底层 NSScrollView 上隐藏。
            .pmForceHideScrollers()
        }
    }

    private func rowView(_ row: Row, ordinal: Int, totalCount: Int) -> some View {
        Button {
            play(row.song)
        } label: {
            HStack(spacing: 10) {
                CachedArtworkView(
                    coverRef: row.song.coverArtFileName,
                    songID: row.song.id,
                    size: 38,
                    cornerRadius: 6,
                    sourceID: row.song.sourceID,
                    filePath: row.song.filePath,
                    fileFormat: row.song.fileFormat
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        SongRowTrackNumber(number: ordinal, largestNumber: totalCount, respectsLibraryPreference: false)
                        Text(row.song.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PMColor.text)
                            .lineLimit(1)
                    }
                    Text(
                        library.artistDisplayName(for: row.song)
                            ?? String(localized: "unknown_artist")
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(PMColor.textMuted)
                        .lineLimit(1)
                    matchBar(row.affinity)
                }

                if isAppleMusic(row.song) {
                    Text(verbatim: "AM")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(PMColor.bad)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(PMColor.bad.opacity(0.14), in: Capsule())
                }

                Text("\(row.score)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .pmRowBackground(cornerRadius: 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func matchBar(_ fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PMColor.divider)
                Capsule()
                    .fill(PMColor.brand)
                    .frame(width: max(2, geo.size.width * fraction))
            }
        }
        .frame(height: 3)
        .padding(.top, 1)
    }

    private var footer: some View {
        Button {
            playRadio()
        } label: {
            HStack(spacing: 6) {
                if isBuildingRadio {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text("play_similar_radio")
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(PMColor.brand, in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(displayRows.isEmpty || isBuildingRadio)
        .opacity(displayRows.isEmpty ? 0.5 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func isAppleMusic(_ song: Song) -> Bool {
        guard let type = sourcesStore.source(id: song.sourceID)?.type else { return false }
        return type == .appleMusic || type == .appleMusicLibrary
    }

    private func play(_ song: Song) {
        let tail = displayRows.map(\.song).filter { $0.id != song.id }
        let queue = ([song] + tail).filteredPlayable()
        guard let first = queue.first else { return }
        player.shuffleEnabled = false
        onClose()
        SiriMediaInteractionDonor.donate(song: first)
        Task { await player.play(queue: queue, startingAt: 0) }
    }

    private func playRadio() {
        guard !isBuildingRadio else { return }
        isBuildingRadio = true
        Task { @MainActor in
            await Task.yield()
            let queue = await SongRadioBuilder.queue(from: seed, in: library, limit: 48).filteredPlayable()
            isBuildingRadio = false
            guard !queue.isEmpty else { return }
            player.shuffleEnabled = false
            onClose()
            await player.play(queue: queue, startingAt: 0)
        }
    }

    private func loadLastFm() async {
        isLoadingLastFm = true
        guard !LastFmCredentialsStore.effectiveAPIKey().isEmpty else {
            isLoadingLastFm = false
            return
        }
        let service = AppServices.shared.similarTracks
        guard let pool = await SongModelArrayRead.read(library, { library.musicSongs }) else { // 模型装不回来:不给候选
            isLoadingLastFm = false
            return
        }
        do {
            lastFmCandidates = try await service.fetchSimilar(
                to: seed,
                limit: 30,
                library: pool,
                excluding: library.dislikedSongIDs,
                includeUnmatched: false
            )
        } catch {
            lastFmCandidates = []
        }
        isLoadingLastFm = false
    }
}

/// 「生成文字稿」的面板,和「这一集现在有没有文字稿」(读缓存得出,歌词一变就重读)(#314)。
/// 单独成一个修饰,不再加长菜单那条修饰链。
private struct PlayerMoreMenuTranscriptGeneration: ViewModifier {
    let songID: String?
    @Binding var transcriptGenerationSong: Song?
    @Binding var currentHasTranscript: Bool?
    /// 「导出歌词 / 文字稿」(#362)。
    @Binding var lyricsExportRequest: LyricsExportRequest?

    func body(content: Content) -> some View {
        content
            .modifier(LyricsExportPresenter(request: $lyricsExportRequest))
            .sheet(item: $transcriptGenerationSong) { song in
                SpokenTranscriptGenerationSheet(song: song)
                    .environment(AppServices.shared.musicIntelligence)
            }
            .task(id: songID) { await refresh(songID) }
            .onReceive(NotificationCenter.default.publisher(for: .primuseLyricsDidChange)) { note in
                guard let changed = note.object as? String, changed == songID else { return }
                Task { await refresh(changed) }
            }
    }

    private func refresh(_ songID: String?) async {
        guard let songID else {
            currentHasTranscript = nil
            return
        }
        let cached = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID)
        currentHasTranscript = cached?.isEmpty == false
    }
}
#endif
