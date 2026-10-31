#if os(tvOS)
import SwiftUI
import PrimuseKit

/// tvOS 正在播放选项覆层 — 宽面板,左边是这首歌,右边按「这首歌 / 播放 / 前往」分组平铺,
/// 一眼看全,不再挤在一行横向滚动里(对应 TVOptionsArtboard)。
/// Apple TV 无右键,由播放页的「更多」键升起此层。
struct TVOptionsView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// 给了就显示「前往」一组:选了之后收起本层,由播放页升起货架的对应一栏。
    var onGoTo: ((TVPlayerShelfTab) -> Void)? = nil
    @State private var showKaraoke = false
    @State private var showMedleySettings = false
    @State private var pendingMedleyIDs: [String]?
    @State private var matchTarget: TVSongMatchTarget?
    @AppStorage(TVLyricsFontLevel.storageKey)
    private var lyricsFontLevelRawValue = TVLyricsFontLevel.standard.rawValue
    /// 歌词字体(#332),和 iPhone、Mac 同一份(经 iCloud 同步)。
    @AppStorage(PlayerAppearancePreferences.lyricsFontKey)
    private var lyricsFontRawValue = PlayerTextFont.system.rawValue
    @State private var albumScrapeTarget: TVSongMatchTarget?
    @State private var playbackRangeTarget: TVSongMatchTarget?

    private struct Action: Identifiable {
        let id: String
        let icon: String
        let label: String
        var on: Bool = false
        let run: () -> Void
    }

    private struct OptionSection: Identifiable {
        let id: String
        let title: String
        let actions: [Action]
    }

    // 仅保留已真实接通的动作(其余如「加入歌单/相似歌曲/AirPlay 输出」需额外基建,
    // 暂不放占位假按钮)。
    /// 按选单里的先后找下一种装着的;现在这种是从手机同步来、电视上没有的,也从它的位置往后找。
    /// 手机或 Mac 上导入的字体电视上没有、画的是系统字体,按一下换成系统字体,再往后轮。
    private static func nextLyricsFont(after current: PlayerTextFont, in installed: [PlayerTextFont]) -> PlayerTextFont {
        let all = PlayerTextFont.builtins
        guard let start = all.firstIndex(of: current) else { return .system }
        for offset in 1...all.count {
            let candidate = all[(start + offset) % all.count]
            if installed.contains(candidate) { return candidate }
        }
        return .system
    }

    private var sections: [OptionSection] {
        let sleepOn = store.isSleepTimerActive
        // 有声内容不给卡拉OK、歌词字号与串烧这些音乐的玩法。有声书的每个文件也能加进「我喜欢」,
        // 播客单集不在曲库里,喜欢的记在播客自己那份(和手机同一份,经 iCloud 同步)。
        let isSpokenWord = store.currentItemIsSpokenWord
        let podcastEpisodeID = isSpokenWord ? store.currentPodcastEpisodeID : nil
        // 搜索或 Apple Music 专辑里点播的歌不在播放队列里,喜欢标在 iPhone 同步来的那一行上。
        let appleMusicTarget = store.currentSongID == nil ? store.appleMusicNowPlayingLikeTarget : nil
        let liked = podcastEpisodeID.map { PodcastStore.shared.isLiked(episodeID: $0) }
            ?? appleMusicTarget.map(store.isAppleMusicLiked)
            ?? (store.currentSongID.map(store.isLiked) ?? false)
        var song: [Action] = []
        song.append(.init(id: "love", icon: liked ? "heart.fill" : "heart",
                          label: liked ? PMString("ext.tv.options.loved") : PMString("ext.tv.options.love"), on: liked,
                          run: {
                              if let podcastEpisodeID {
                                  PodcastStore.shared.toggleLiked(episodeID: podcastEpisodeID)
                              } else if let appleMusicTarget {
                                  store.toggleAppleMusicLike(appleMusicTarget)
                              } else if let id = store.currentSongID {
                                  store.toggleLiked(id)
                              }
                          }))
        // 不喜欢(#193):记下来并切到下一首;已经不喜欢时再点只撤销。
        if let id = store.currentSongID, !isSpokenWord, !store.isLiveRadio, store.canDislike(id) {
            let disliked = store.isDisliked(id)
            song.append(.init(id: "dislike", icon: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                              label: disliked ? String(localized: "song_undislike") : String(localized: "song_dislike"),
                              on: disliked,
                              run: { store.toggleDisliked(id) }))
        }
        // 用刮削源手动匹配这首歌的标签、封面和歌词(只改这台 Apple TV 上的曲库)。
        if store.canMatchMetadata(songID: store.currentSongID) {
            song.append(.init(id: "match", icon: "wand.and.stars", label: String(localized: "tv_scrape_match_title"), run: {
                if let id = store.currentSongID { matchTarget = TVSongMatchTarget(id: id) }
            }))
        }
        if store.currentSongID != nil, !isSpokenWord, !store.isMedleyActive {
            song.append(.init(id: "karaoke", icon: "music.mic", label: String(localized: "karaoke_title"),
                              run: { showKaraoke = true }))
        }
        // 歌词字号:按一下换下一档,和睡眠定时一样就地循环。
        if !isSpokenWord, !store.isLiveRadio {
            let level = TVLyricsFontLevel.resolved(lyricsFontLevelRawValue)
            song.append(.init(
                id: "lyricsFontSize", icon: "textformat.size",
                label: String(format: String(localized: "tv_lyrics_font_size_format"), level.title),
                run: { lyricsFontLevelRawValue = level.next.rawValue }
            ))
            // 歌词字体:同样就地轮换,只在这台 Apple TV 上装着的几种里转(电视上没有下载字体的入口)。
            let font = PlayerTextFont(rawValue: lyricsFontRawValue) ?? .system
            song.append(.init(
                id: "lyricsFont", icon: "textformat",
                label: String(format: String(localized: "tv_lyrics_font_format"), font.localizedTitle),
                run: {
                    let next = Self.nextLyricsFont(after: font, in: PlayerTextFontLibrary.shared.installedFonts())
                    lyricsFontRawValue = next.rawValue
                    CloudKVSSync.shared.markChanged(key: PlayerAppearancePreferences.lyricsFontKey)
                }
            ))
        }

        var playback: [Action] = []
        if store.isMedleyActive {
            playback.append(.init(id: "medleyFull", icon: "music.note", label: String(localized: "medley_continue_full"), run: {
                store.continueCurrentMedleySongInFull()
            }))
        } else if store.canPlayMedleyFromQueue {
            playback.append(.init(id: "medley", icon: "shuffle", label: String(localized: "medley_play_selection"), run: {
                pendingMedleyIDs = store.medleyCandidateIDs
            }))
        }
        if !isSpokenWord, !store.isLiveRadio {
            playback.append(.init(id: "medleyLength", icon: "timer", label: String(localized: "medley_segment_length"),
                                  run: { showMedleySettings = true }))
        }
        // 播放时间段:设过时一块磁贴就地开关(下面写着时间段),另一块进编辑页;
        // 没设过时只有「设置播放时间段…」。
        if let id = store.currentSongID, !isSpokenWord, !store.isLiveRadio, !store.isMedleyActive,
           let song = store.library.song(id: id), store.supportsPlaybackRange(for: song) {
            let rangeStore = SongPlaybackRangeStore.shared
            if let range = rangeStore.range(for: song) {
                playback.append(.init(
                    id: "playbackRange", icon: "selection.pin.in.out",
                    label: String(localized: "playback_range_title") + "\n" + SongPlaybackRangePolicy.rangeLabel(range),
                    on: range.isEnabled,
                    run: { rangeStore.setEnabled(!range.isEnabled, for: song) }
                ))
                playback.append(.init(id: "playbackRangeEdit", icon: "slider.horizontal.3",
                                      label: String(localized: "playback_range_edit"),
                                      run: { playbackRangeTarget = TVSongMatchTarget(id: id) }))
            } else {
                playback.append(.init(id: "playbackRangeSet", icon: "selection.pin.in.out",
                                      label: String(localized: "playback_range_set"),
                                      run: { playbackRangeTarget = TVSongMatchTarget(id: id) }))
            }
        }
        // 随机时连播(#335):一块磁贴一边,下面写着相邻那首的歌名,就地开关。
        if let id = store.currentSongID, !isSpokenWord, !store.isLiveRadio {
            for direction in ShuffleLinkDirection.allCases {
                guard let title = store.shuffleLinkNeighborTitle(id, direction) else { continue }
                let label = direction == .next
                    ? String(localized: "shuffle_link_next_long")
                    : String(localized: "shuffle_link_previous_long")
                playback.append(.init(
                    id: "shuffleLink.\(direction.rawValue)",
                    icon: direction == .next ? "forward.end" : "backward.end",
                    label: label + "\n" + title,
                    on: store.isShuffleLinked(id, direction),
                    run: { store.toggleShuffleLink(id, direction) }
                ))
            }
        }
        playback.append(.init(id: "sleep", icon: "moon.zzz.fill",
                              label: store.sleepTimerMinutes > 0
                                  ? PMString("ext.tv.options.sleepActive", store.sleepTimerMinutes)
                                  : store.sleepStopAfterItemID != nil && !isSpokenWord
                                      ? String(localized: "sleep_at_track_end")
                                      : PMString("ext.tv.options.sleepTimer"),
                              on: sleepOn,
                              run: { store.cycleSleepTimer() }))

        var goTo: [Action] = []
        if let onGoTo, !isSpokenWord, !store.isLiveRadio {
            // 与长按封面、播放页货架同一套名字和图标。
            for tab in TVPlayerShelfTab.goToDestinations
            where tab != .upNext || !store.queueUpNextIDs.isEmpty {
                goTo.append(.init(id: "goTo.\(tab.rawValue)", icon: tab.systemImage, label: tab.title, run: {
                    onGoTo(tab)
                    dismiss()
                }))
            }
        }

        return [
            OptionSection(id: "song", title: PMString("ext.tv.options.section.song"), actions: song),
            OptionSection(id: "playback", title: PMString("ext.tv.options.section.playback"), actions: playback),
            OptionSection(id: "goTo", title: PMString("ext.tv.options.section.goTo"), actions: goTo),
        ].filter { !$0.actions.isEmpty }
    }

    var body: some View {
        let np = store.nowPlaying
        let colors = store.nowPlayingPresentationColors
        ZStack {
            TVAmbientBackdrop(tint: colors.primary, tint2: colors.secondary, strength: 0.5)
            TVColor.bg.opacity(0.52).ignoresSafeArea()

            HStack(alignment: .top, spacing: 64) {
                VStack(alignment: .leading, spacing: 0) {
                    TVEyebrow(text: PMString("ext.tv.options.eyebrow")).padding(.bottom, 20)
                    Group {
                        if store.currentPodcastEpisodeID != nil {
                            TVPodcastArtwork(url: np.coverRef.flatMap(URL.init(string:)), side: 300, radius: 18)
                        } else {
                            TVArtworkView(coverKey: np.albumID, artist: np.artist, album: np.album,
                                          songID: np.songID, coverRef: np.coverRef,
                                          tint: colors.primary, tint2: colors.secondary,
                                          glyph: np.glyph, size: 300, radius: 18)
                        }
                    }
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
                    Text(np.title).tvFont(size: 36, weight: .bold, relativeTo: .title2)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(2)
                        .padding(.top, 24)
                    Text(np.artist).tvFont(.caption).foregroundStyle(TVColor.textMuted)
                        .lineLimit(1)
                        .padding(.top, 6)
                    if !np.album.isEmpty {
                        Text(np.album).tvFont(.meta).foregroundStyle(TVColor.textFaint)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                }
                .frame(width: 300, alignment: .leading)

                VStack(alignment: .leading, spacing: 34) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 16) {
                            TVEyebrow(text: section.title)
                            HStack(spacing: 22) {
                                ForEach(section.actions) { actionTile($0) }
                            }
                        }
                        .focusSection()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(48)
            .frame(maxWidth: 1500, alignment: .leading)
            .tvPanel(radius: 28)
            .padding(.horizontal, 100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .modifier(TVMedleyConfirmation(pendingIDs: $pendingMedleyIDs))
        .task(id: store.nowPlaying.songID) {
            if let song = store.library.song(id: store.nowPlaying.songID) {
                await store.refreshArtworkForFocusedSong(song)
            }
        }
        .onExitCommand { dismiss() }
        .onAppear {
            FullscreenPlayerEffectSync.shared.install()
            #if DEBUG
            // 截图 / 取证:TV_SCREEN=options 配 TV_SCRAPE_DEBUG=match|album 直接打开刮削面板。
            switch ProcessInfo.processInfo.environment["TV_SCRAPE_DEBUG"] {
            case "match":
                // 演示播放态(TV_SCREEN=options)不建队列,取「正在播放」那首。
                let id = store.currentSongID ?? store.nowPlaying.songID
                if !id.isEmpty { matchTarget = TVSongMatchTarget(id: id) }
            case "album":
                if !store.nowPlaying.albumID.isEmpty {
                    albumScrapeTarget = TVSongMatchTarget(id: store.nowPlaying.albumID)
                }
            default: break
            }
            #endif
        }
        .fullScreenCover(isPresented: $showKaraoke) {
            TVKaraokeStageView()
        }
        .fullScreenCover(isPresented: $showMedleySettings) { TVMedleySettingsView() }
        .fullScreenCover(item: $matchTarget) { target in
            TVSongMatchView(songID: target.id).environment(store)
        }
        .fullScreenCover(item: $albumScrapeTarget) { target in
            TVAlbumScrapeView(albumID: target.id).environment(store)
        }
        .fullScreenCover(item: $playbackRangeTarget) { target in
            TVPlaybackRangeEditorView(songID: target.id).environment(store)
        }
    }

    private func actionTile(_ a: Action) -> some View {
        // 不 dismiss:执行后菜单保留,用户能看到状态变化(喜欢/睡眠定时切换);按返回键关闭。
        TVFocusButton(radius: 16, scale: 1.05, lift: 4, action: { a.run() }) { focused in
            VStack(spacing: 14) {
                Image(systemName: a.icon).font(.system(size: 40, weight: .regular))
                    .foregroundStyle(focused ? TVColor.onBrand : (a.on ? TVColor.brand : TVColor.text))
                Text(a.label).tvFont(.caption, weight: focused ? .bold : .medium)
                    .foregroundStyle(focused ? TVColor.onBrand : TVColor.text)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .minimumScaleFactor(0.85)
                    .padding(.horizontal, 10)
            }
            .frame(width: 184, height: 150)
            .background(focused ? AnyShapeStyle(TVColor.brand) : AnyShapeStyle(TVColor.surfaceStrong))
        }
        .accessibilityAddTraits(a.on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Apple TV 上的播放时间段编辑页。遥控器拖不了把手:开始、结束各一行,按钮逐秒或
/// 逐五秒挪,正在播的这首还能「设为当前位置」。开关和时间段在最上面一行;挪动时间段
/// 会顺手打开开关,关掉只是暂时整首播放。每一步立刻存下,和 iPhone 一样随即生效。
struct TVPlaybackRangeEditorView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let songID: String
    @State private var draft = SongPlaybackRange(start: 0, end: 0, isEnabled: false)
    @State private var hasStoredRange = false
    @State private var highlightTask: Task<Void, Never>?
    @State private var highlightNotice: String?

    private var song: Song? { store.library.song(id: songID) }
    private var songDuration: Double { max(0, song?.duration ?? 0) }
    private var isCurrentSong: Bool { store.nowPlaying.songID == songID }

    var body: some View {
        ZStack {
            TVColor.bg.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    TVEyebrow(text: String(localized: "playback_range_title"))
                    Text(song?.title ?? store.nowPlaying.title)
                        .tvFont(.sectionTitle, weight: .bold)
                        .foregroundStyle(TVColor.text)
                        .lineLimit(1)
                }
                if songDuration > 0 {
                    TVSwitchRow(
                        icon: "selection.pin.in.out",
                        title: String(localized: "playback_range_toggle") + " · " + summary,
                        isOn: Binding(
                            get: { draft.isEnabled },
                            set: { draft.isEnabled = $0; commit(enabling: false) }
                        ),
                        maxWidth: 1200
                    )
                    .focusSection()
                    timeline
                    edgeRow(.start)
                    edgeRow(.end)
                    highlightRow
                    HStack(spacing: 22) {
                        if isCurrentSong {
                            TVPillButton(title: String(localized: "playback_range_preview_start"), systemImage: "play.fill") {
                                store.engine.seek(to: draft.start)
                            }
                            TVPillButton(title: String(localized: "playback_range_preview_end"), systemImage: "forward.end.fill") {
                                store.engine.seek(to: max(draft.start, draft.end - 5))
                            }
                        }
                        if hasStoredRange {
                            TVPillButton(title: String(localized: "playback_range_clear"), systemImage: "arrow.uturn.backward") {
                                clear()
                            }
                        }
                        TVPillButton(title: String(localized: "done"), systemImage: "checkmark", style: .solid) {
                            dismiss()
                        }
                    }
                    .focusSection()
                    Text("playback_range_footer")
                        .tvFont(.caption)
                        .foregroundStyle(TVColor.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("playback_range_unknown_duration")
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                    TVPillButton(title: String(localized: "done"), systemImage: "checkmark", style: .solid) {
                        dismiss()
                    }
                }
            }
            .padding(56)
            .frame(maxWidth: 1300, alignment: .leading)
            .tvPanel(radius: 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear(perform: load)
        .onDisappear { highlightTask?.cancel() }
        .onExitCommand { dismiss() }
    }

    /// 「定位到高潮」:找的时候按钮写着「正在找」,再按一下不重来;没找到在旁边说一句。
    private var highlightRow: some View {
        HStack(spacing: 22) {
            TVPillButton(
                title: highlightTask == nil
                    ? String(localized: "playback_range_highlight")
                    : String(localized: "playback_range_highlight_running"),
                systemImage: "waveform.badge.magnifyingglass"
            ) {
                locateHighlight()
            }
            if let highlightNotice, highlightTask == nil {
                Text(verbatim: highlightNotice)
                    .tvFont(.caption)
                    .foregroundStyle(TVColor.textMuted)
                    .lineLimit(2)
            }
        }
        .focusSection()
    }

    private func locateHighlight() {
        guard highlightTask == nil, let song else { return }
        highlightNotice = nil
        var whole = song
        if whole.duration <= 0 { whole.duration = songDuration }
        let target = whole
        let duration = songDuration
        highlightTask = Task {
            let highlight = await store.locatePlaybackRangeHighlight(for: target)
            highlightTask = nil
            guard !Task.isCancelled else { return }
            guard let highlight, let range = AudioClipExportPolicy.range(
                highlightStart: highlight.start,
                highlightEnd: highlight.end,
                songDuration: duration
            ) else {
                highlightNotice = String(localized: "playback_range_highlight_none")
                return
            }
            draft = range
            commit()
        }
    }

    private var summary: String {
        String(
            format: String(localized: "playback_range_summary %@ %@"),
            SongPlaybackRangePolicy.rangeLabel(draft, showsTenths: true),
            SongPlaybackRangePolicy.timeLabel(draft.length, showsTenths: true)
        )
    }

    /// 整首歌的时间轴:选中的一段着色,正在播这首时画出播放头。只看不按。
    private var timeline: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let scale = songDuration > 0 ? width / CGFloat(songDuration) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(TVColor.surfaceStrong).frame(height: 10)
                Capsule()
                    .fill(draft.isEnabled ? TVColor.brand : TVColor.textFaint)
                    .frame(width: max(0, CGFloat(draft.end - draft.start) * scale), height: 10)
                    .offset(x: CGFloat(draft.start) * scale)
                if isCurrentSong {
                    Capsule()
                        .fill(TVColor.text)
                        .frame(width: 4, height: 28)
                        .offset(x: CGFloat(min(max(0, store.currentTime), songDuration)) * scale - 2)
                }
            }
            .frame(height: 28)
        }
        .frame(maxWidth: 1200)
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    /// 一行写值,一行放按钮:同一行塞下五颗胶囊会顶出面板。
    private func edgeRow(_ edge: SongPlaybackRangePolicy.Edge) -> some View {
        let value = edge == .start ? draft.start : draft.end
        let title = edge == .start
            ? String(localized: "playback_range_start")
            : String(localized: "playback_range_end")
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(verbatim: title)
                    .tvFont(.rowTitle, weight: .semibold)
                    .foregroundStyle(TVColor.textMuted)
                Text(verbatim: SongPlaybackRangePolicy.timeLabel(value, showsTenths: true))
                    .tvFont(.sectionTitle, weight: .bold)
                    .monospacedDigit()
                    .foregroundStyle(TVColor.text)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 18) {
                TVPillButton(title: String(format: String(localized: "playback_range_minus_seconds %lld"), 5),
                             systemImage: "gobackward.5") { move(edge, to: value - 5) }
                TVPillButton(title: String(format: String(localized: "playback_range_minus_seconds %lld"), 1),
                             systemImage: "minus") { move(edge, to: value - 1) }
                TVPillButton(title: String(format: String(localized: "playback_range_plus_seconds %lld"), 1),
                             systemImage: "plus") { move(edge, to: value + 1) }
                TVPillButton(title: String(format: String(localized: "playback_range_plus_seconds %lld"), 5),
                             systemImage: "goforward.5") { move(edge, to: value + 5) }
                if isCurrentSong {
                    TVPillButton(title: String(localized: "playback_range_set_to_current"), systemImage: "scope") {
                        move(edge, to: (store.currentTime * 10).rounded() / 10)
                    }
                }
            }
            .focusSection()
        }
    }

    private func load() {
        guard let song else { return }
        let stored = SongPlaybackRangeStore.shared.range(for: song)
        draft = stored ?? SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
        hasStoredRange = stored != nil
    }

    private func move(_ edge: SongPlaybackRangePolicy.Edge, to value: Double) {
        draft = SongPlaybackRangePolicy.moving(edge, of: draft, to: value, songDuration: songDuration)
        commit()
    }

    private func commit(enabling: Bool = true) {
        guard let song else { return }
        if enabling { draft.isEnabled = true }
        SongPlaybackRangeStore.shared.setRange(draft, for: song)
        hasStoredRange = true
    }

    private func clear() {
        guard let song else { return }
        SongPlaybackRangeStore.shared.clearRange(for: song)
        draft = SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
        hasStoredRange = false
    }
}

struct TVFullscreenEffectPicker: View {
    @Environment(TVStore.self) private var store
    @Binding var selectedRawValue: String
    @Binding var lyricsMotionEnabled: Bool
    let onDismiss: () -> Void

    @AppStorage(AppThemePreferences.accentHexKey)
    private var accentHex = AppThemePreferences.defaultAccentHex
    @AppStorage(AppThemePreferences.coverDrivenAmbientKey)
    private var coverDrivenAmbient = AppThemePreferences.defaultCoverDrivenAmbient
    @AppStorage(ImmersiveFrameRateMode.storageKey)
    private var frameRateRawValue = ImmersiveFrameRateMode.defaultValue.rawValue
    @AppStorage(ImmersiveMotionIntensity.storageKey)
    private var motionIntensityRawValue = ImmersiveMotionIntensity.defaultValue.rawValue
    @AppStorage(ImmersiveEffectRotationMode.storageKey)
    private var rotationModeRawValue = ImmersiveEffectRotationMode.defaultValue.rawValue
    @AppStorage(ImmersiveEffectRotationScope.storageKey)
    private var rotationScopeRawValue = ImmersiveEffectRotationScope.defaultValue.rawValue
    @AppStorage(ImmersiveKineticScenePreference.storageKey)
    private var kineticSceneRawValue = ImmersiveKineticScenePreference.automaticValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 按到 60 帧时先弹说明，确认了才换。
    @State private var pendingHighRefresh: ImmersiveFrameRateMode?

    @FocusState private var focusedEffect: FullscreenPlayerEffect?
    @FocusState private var lyricsToggleFocused: Bool
    @FocusState private var frameRateFocused: Bool
    @FocusState private var motionIntensityFocused: Bool
    @FocusState private var rotationFocused: Bool
    @FocusState private var rotationScopeFocused: Bool
    @FocusState private var kineticSceneFocused: Bool
    /// 只有焦点停稳的那张卡片播放预览动画。遥控器一路按过去时不逐张启停整套舞台。
    @State private var animatedEffect: FullscreenPlayerEffect?

    private var frameRate: ImmersiveFrameRateMode {
        ImmersiveFrameRateMode(storedValue: frameRateRawValue)
    }

    private var selectedEffect: FullscreenPlayerEffect {
        FullscreenPlayerEffect(rawValue: selectedRawValue) ?? .defaultValue
    }

    private var previewPalette: ImmersiveArtworkPalette {
        let playbackColors = store.nowPlayingPresentationColors
        return ImmersiveArtworkPalette(
            primary: coverDrivenAmbient ? playbackColors.primary : TVColor.brand(hex: accentHex),
            secondary: coverDrivenAmbient ? playbackColors.secondary : TVColor.brandSecondary(hex: accentHex)
        )
    }

    /// 有歌在放时卡片里放这首，没有（或在听电台）才用演示内容。
    private var previewSong: ImmersivePreviewSong? {
        let np = store.nowPlaying
        let title = np.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.hasNowPlaying, !store.isLiveRadio, !title.isEmpty else { return nil }
        return ImmersivePreviewSong(
            id: np.songID,
            title: title,
            artist: np.artist,
            album: np.album,
            format: TVImmersivePlayerView.formatLine(np, store: store),
            artwork: { side in AnyView(TVEffectPreviewArtwork(nowPlaying: np, side: side)) }
        )
    }

    var body: some View {
        GeometryReader { _ in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 18), count: 4)
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()

                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(PMString("ext.tv.settings.immersive"))
                                .tvFont(size: 38, weight: .bold, relativeTo: .title2)
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        frameRateButton
                        motionIntensityButton
                        rotationButton
                        if rotationMode.isEnabled {
                            rotationScopeButton
                        }
                        Button {
                            lyricsMotionEnabled.toggle()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(
                                    PMString("immersive_lyrics_motion_title"),
                                    systemImage: lyricsMotionEnabled ? "checkmark.circle.fill" : "circle"
                                )
                                    .tvFont(.caption, weight: .semibold)
                                Text(PMString("immersive_lyrics_motion_subtitle"))
                                    .tvFont(.meta)
                                    .foregroundStyle(.white.opacity(0.58))
                                // 原生全屏是播放页本身，不用这项；选着原生时写明，免得拨了看不出变化。
                                if selectedEffect.isNative {
                                    Text(PMString("immersive_lyrics_motion_native_note"))
                                        .tvFont(.meta)
                                        .foregroundStyle(TVColor.warn)
                                }
                            }
                            .foregroundStyle(lyricsMotionEnabled ? previewPalette.primary : .white.opacity(0.82))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 13)
                            .background(.white.opacity(lyricsToggleFocused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
                            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.20), lineWidth: 1) }
                            .tvFocusRing(lyricsToggleFocused, radius: 14, accent: .white, scale: 1.04, lift: 5)
                        }
                        .buttonStyle(TVBareButtonStyle())
                        .focused($lyricsToggleFocused)
                        .focusEffectDisabled()
                        .accessibilityAddTraits(
                            lyricsMotionEnabled ? [.isButton, .isSelected] : .isButton
                        )
                    }
                    // 两个开关在右上角,和左边第一列卡片没有上下重叠:不划成焦点区,从网格往上按不过去。
                    .focusSection()

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                ForEach(FullscreenEffectCollection.allCases) { collection in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .bottom, spacing: 18) {
                                            Text(collection.title)
                                                .tvFont(.caption, weight: .semibold)
                                                .foregroundStyle(.white.opacity(0.66))
                                            Spacer(minLength: 0)
                                            // 「动态歌词」的背景放在它这一组的标题旁：顶上那排已经排满了。
                                            if collection == FullscreenPlayerEffect.kineticLyrics.collection {
                                                kineticSceneButton
                                            }
                                        }

                                        LazyVGrid(columns: columns, spacing: 18) {
                                            ForEach(collection.effects) { @Sendable candidate in
                                                LazyItemCell {
                                                    effectChoice(candidate)
                                                }
                                            }
                                        }
                                    }
                                    // 每组一个焦点区:下一组卡片少、正下方没有卡时,按下也能进到这一组。
                                    .focusSection()
                                    .id(collection)
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 14)
                        }
                        .onAppear {
                            // 当前效果排在下面几排时还没建出来,直接设焦点会落空,焦点只能留在
                            // 被盖住的播放控件上。先把它那一组滚到中间建好,再把焦点放上去。
                            // 网格保持懒加载:一次建齐十几套舞台缩略图,屏幕外那几张模拟效果也会跟着重绘。
                            proxy.scrollTo(selectedEffect.collection, anchor: .center)
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(80))
                                focusedEffect = selectedEffect
                            }
                        }
                    }
                }
                .padding(.horizontal, 70)
                .padding(.vertical, 46)
            }
        }
        .focusSection()
        .defaultFocus($focusedEffect, selectedEffect)
        .task(id: focusedEffect) {
            animatedEffect = nil
            guard let focusedEffect else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            animatedEffect = focusedEffect
        }
        .accessibilityAddTraits(.isModal)
        .environment(\.colorScheme, .dark)
        .alert(
            Text("immersive_high_refresh_title"),
            isPresented: Binding(
                get: { pendingHighRefresh != nil },
                set: { if !$0 { pendingHighRefresh = nil } }
            ),
            presenting: pendingHighRefresh
        ) { mode in
            Button {
                frameRateRawValue = mode.rawValue
                motionIntensityRawValue = ImmersiveMotionIntensity.maximum.rawValue
            } label: {
                Text("immersive_high_refresh_maximize")
            }
            Button {
                frameRateRawValue = mode.rawValue
            } label: {
                Text("immersive_high_refresh_frame_rate_only")
            }
            Button(role: .cancel) {
            } label: {
                Text("cancel")
            }
        } message: { _ in
            Text(verbatim: ImmersiveFrameRateMode.highRefreshExplanation)
        }
    }

    /// 遥控器上按一下换到下一档，四档循环。
    private var frameRateButton: some View {
        Button {
            let modes = ImmersiveFrameRateMode.allCases
            let index = modes.firstIndex(of: frameRate) ?? 0
            let next = modes[(index + 1) % modes.count]
            if ImmersiveFrameRateMode.requiresConfirmation(from: frameRate, to: next) {
                pendingHighRefresh = next
            } else {
                frameRateRawValue = next.rawValue
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Label(
                    String(localized: "immersive_frame_rate_title"),
                    systemImage: "speedometer"
                )
                    .tvFont(.caption, weight: .semibold)
                Text(verbatim: frameRate.localizedTitle)
                    .tvFont(.meta)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(.white.opacity(frameRateFocused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.20), lineWidth: 1) }
            .tvFocusRing(frameRateFocused, radius: 14, accent: .white, scale: 1.04, lift: 5)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($frameRateFocused)
        .focusEffectDisabled()
        .accessibilityLabel(Text("immersive_frame_rate_title"))
        .accessibilityValue(Text(verbatim: frameRate.localizedTitle))
    }

    private var motionIntensity: ImmersiveMotionIntensity {
        ImmersiveMotionIntensity(storedValue: motionIntensityRawValue)
    }

    /// 动效强度:细腻、标准、强烈、拉满循环。电视上帧率仍按各层的上限走,拉满只加幅度、灵敏度和粒子。
    private var motionIntensityButton: some View {
        headerCycleButton(
            title: String(localized: "immersive_motion_intensity_title"),
            symbol: "dial.medium",
            value: motionIntensity.localizedTitle,
            isHighlighted: motionIntensity != .standard,
            focused: $motionIntensityFocused
        ) {
            let levels = ImmersiveMotionIntensity.allCases
            let index = levels.firstIndex(of: motionIntensity) ?? 0
            motionIntensityRawValue = levels[(index + 1) % levels.count].rawValue
        }
    }

    private var rotationMode: ImmersiveEffectRotationMode {
        ImmersiveEffectRotationMode(storedValue: rotationModeRawValue)
    }

    private var rotationScope: ImmersiveEffectRotationScope {
        ImmersiveEffectRotationScope(storedValue: rotationScopeRawValue)
    }

    /// 自动换效果(#312):按一下换下一档,关、每首歌、每 1/2/5/10 分钟循环。
    private var rotationButton: some View {
        headerCycleButton(
            title: String(localized: "immersive_effect_rotation_title"),
            symbol: "shuffle",
            value: rotationMode.localizedTitle,
            isHighlighted: rotationMode.isEnabled,
            focused: $rotationFocused
        ) {
            let modes = ImmersiveEffectRotationMode.allCases
            let index = modes.firstIndex(of: rotationMode) ?? 0
            rotationModeRawValue = modes[(index + 1) % modes.count].rawValue
        }
    }

    /// 轮换在哪些效果里挑,只在开着轮换时出现。
    private var rotationScopeButton: some View {
        headerCycleButton(
            title: String(localized: "immersive_effect_rotation_scope_title"),
            symbol: "square.stack.3d.up",
            value: rotationScope.localizedTitle,
            isHighlighted: false,
            focused: $rotationScopeFocused
        ) {
            let scopes = ImmersiveEffectRotationScope.allCases
            let index = scopes.firstIndex(of: rotationScope) ?? 0
            rotationScopeRawValue = scopes[(index + 1) % scopes.count].rawValue
        }
    }

    /// 「动态歌词」的背景：按一下换下一个，每首歌随机、各个背景依次循环。
    private var kineticSceneButton: some View {
        let options = ImmersiveKineticScenePreference.options
        let current = ImmersiveKineticScenePreference.normalized(kineticSceneRawValue)
        let index = options.firstIndex { $0.value == current } ?? 0
        return headerCycleButton(
            title: String(localized: "kinetic_scene_title"),
            symbol: "photo.on.rectangle.angled",
            value: options[index].title,
            isHighlighted: current != ImmersiveKineticScenePreference.automaticValue,
            focused: $kineticSceneFocused
        ) {
            kineticSceneRawValue = options[(index + 1) % options.count].value
        }
    }

    private func headerCycleButton(
        title: String,
        symbol: String,
        value: String,
        isHighlighted: Bool,
        focused: FocusState<Bool>.Binding,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(title, systemImage: symbol)
                    .tvFont(.caption, weight: .semibold)
                Text(verbatim: value)
                    .tvFont(.meta)
                    .foregroundStyle(.white.opacity(0.58))
            }
            .foregroundStyle(isHighlighted ? previewPalette.primary : .white.opacity(0.82))
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(.white.opacity(focused.wrappedValue ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.20), lineWidth: 1) }
            .tvFocusRing(focused.wrappedValue, radius: 14, accent: .white, scale: 1.04, lift: 5)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused(focused)
        .focusEffectDisabled()
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(verbatim: value))
    }

    private func effectChoice(_ candidate: FullscreenPlayerEffect) -> some View {
        let focused = focusedEffect == candidate
        let selected = selectedEffect == candidate
        return Button {
            // 先写本地值并立刻开始收起:iCloud 键值同步和变更通知留到淡出结束后再做。
            // 它们在主线程上有明显开销,和收起动画同帧执行会丢帧,看起来就是「白闪一下」。
            selectedRawValue = candidate.rawValue
            onDismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(360))
                FullscreenPlayerEffectSync.shared.select(candidate)
            }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                TVEffectPickerThumbnail(
                    effect: candidate,
                    isActive: animatedEffect == candidate,
                    palette: previewPalette,
                    song: previewSong
                )
                .equatable()
                .overlay(alignment: .topTrailing) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(selected ? previewPalette.primary : .white.opacity(0.56))
                        .symbolRenderingMode(.hierarchical)
                        .padding(10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.localizedTitle)
                        .tvFont(.caption, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(candidate.localizedSubtitle)
                        .tvFont(.meta)
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(2)
                    Label(candidate.motionDescription, systemImage: "waveform.path")
                        .tvFont(.meta)
                        .foregroundStyle(previewPalette.primary.opacity(0.84))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(selected ? previewPalette.primary : .white.opacity(0.90))
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.white.opacity(focused ? 0.18 : 0.08), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? previewPalette.primary : .white.opacity(0.20), lineWidth: selected ? 2 : 1)
            }
            // 不用 tvFocusRing:它给每张卡都挂一层阴影,十几张整套舞台缩略图的阴影在焦点缩放时逐帧重算,
            // 而这里是近黑的底,阴影本来就看不见。
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white, lineWidth: focused ? 3 : 0)
            }
            .scaleEffect(focused && !reduceMotion ? 1.04 : 1)
            .offset(y: focused && !reduceMotion ? -4 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: focused)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedEffect, equals: candidate)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 选择器卡片里的效果预览。每张都是一整套缩小的舞台,输入没变时不重算:
/// 移动焦点、换歌词都会让选择器整体重新求值,不该带着十几套舞台一起重建。
private struct TVEffectPickerThumbnail: View, @MainActor Equatable {
    let effect: FullscreenPlayerEffect
    let isActive: Bool
    let palette: ImmersiveArtworkPalette
    let song: ImmersivePreviewSong?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.effect == rhs.effect
            && lhs.isActive == rhs.isActive
            && lhs.palette.primary == rhs.palette.primary
            && lhs.palette.secondary == rhs.palette.secondary
            && sameSong(lhs.song, rhs.song)
    }

    private static func sameSong(_ lhs: ImmersivePreviewSong?, _ rhs: ImmersivePreviewSong?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (lhs?, rhs?): lhs.showsSameContent(as: rhs)
        default: false
        }
    }

    var body: some View {
        ImmersiveEffectPreview(effect: effect, isActive: isActive, palette: palette, song: song)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// 卡片里正在听的这首的封面：取到之前透明，露出舞台底下的占位，和全屏舞台一样。
private struct TVEffectPreviewArtwork: View {
    let nowPlaying: TVNowPlaying
    let side: CGFloat

    @State private var hasResolvedArtwork = false

    var body: some View {
        TVArtworkView(
            coverKey: nowPlaying.albumID,
            artist: nowPlaying.artist,
            album: nowPlaying.album,
            songID: nowPlaying.songID,
            coverRef: nowPlaying.coverRef,
            tint: nowPlaying.tint,
            tint2: nowPlaying.tint2,
            glyph: nowPlaying.glyph,
            size: side,
            onResolutionChange: { hasResolvedArtwork = $0 }
        )
        .opacity(hasResolvedArtwork ? 1 : 0)
    }
}
// MARK: - 歌词翻译

extension TVLyricsTranslationController.Activity {
    /// 播放页歌词上方的提示与翻译面板共用的一句话;nil 表示不必说。
    var statusText: String? {
        switch self {
        case .idle:
            return nil
        case .notNeeded:
            return String(localized: "lyrics_translation_not_needed")
        case .translating(.intelligent):
            return String(localized: "lyrics_translation_ai_loading")
        case .translating(.offline):
            return String(localized: "lyrics_translation_local_translating")
        case .translating(.baidu):
            return String(localized: "baidu_translate_loading")
        case .done(.baidu):
            return String(localized: "baidu_translate_success")
        case .done(.intelligent(let provider)):
            guard let provider else { return String(localized: "lyrics_translation_ai_cached") }
            return String(format: String(localized: "lyrics_translation_ai_success_format"), provider)
        case .done(.offline):
            return String(localized: "lyrics_translation_offline_done")
        case .needsModel(let pack):
            return String(
                format: String(localized: "lyrics_translation_offline_needs_pack_format"),
                String(localized: String.LocalizationValue(pack.pairsKey))
            )
        case .unsupported:
            return String(localized: "lyrics_translation_offline_unsupported")
        case .failed:
            return String(localized: "lyrics_translation_unavailable")
        }
    }

    var systemImage: String {
        switch self {
        case .idle, .notNeeded: "character.bubble"
        case .translating(.intelligent), .done(.intelligent): "sparkles"
        case .translating(.offline), .done(.offline): "character.book.closed"
        case .translating(.baidu), .done(.baidu): "character.bubble"
        case .needsModel: "arrow.down.circle"
        case .unsupported, .failed: "exclamationmark.triangle"
        }
    }

    @MainActor var tint: Color {
        switch self {
        case .done: TVColor.ok
        case .needsModel: TVColor.brand
        case .unsupported, .failed: TVColor.warn
        case .idle, .notNeeded, .translating: TVColor.textMuted
        }
    }

    /// 翻好或不必翻的提示看一眼就够;要动手或出了问题的一直留着。
    var isTransient: Bool {
        switch self {
        case .done, .notNeeded: true
        case .idle, .translating, .needsModel, .unsupported, .failed: false
        }
    }
}

extension TVLyricsTranslationController.IntelligentIssue {
    var explanation: String {
        switch self {
        case .notReady(.needsBuiltInConsent):
            String(localized: "lyrics_translation_ai_needs_builtin_consent")
        case .notReady(.needsRemoteConsent):
            String(localized: "lyrics_translation_ai_needs_remote_consent")
        case .notReady(.noService):
            String(localized: "lyrics_translation_ai_no_service")
        case .notReady(.ready), .notReady(.regionUnavailable), .requestFailed:
            String(localized: "lyrics_translation_ai_request_failed")
        case .baidu(.notConfigured):
            String(localized: "baidu_translate_tv_needs_setup")
        case .baidu(let issue):
            issue.reason
        }
    }

    /// 播放页歌词上方那一行:没用上、改用了离线翻译包。
    var fellBackText: String {
        switch self {
        case .baidu: String(localized: "baidu_translate_tv_fell_back_offline")
        case .notReady, .requestFailed: String(localized: "lyrics_translation_ai_fell_back_offline")
        }
    }

    var systemImage: String {
        switch self {
        case .baidu: "character.bubble"
        case .notReady, .requestFailed: "sparkles"
        }
    }
}

/// 歌词翻译:开关、译成什么、交给谁翻,以及这首歌现在翻成什么样。播放页的翻译键和设置页
/// 都打开它。电视没有系统翻译,翻译方式是离线翻译包、智能翻译与百度翻译三种;智能翻译或
/// 百度翻译没用上时这里说清楚差哪一步,并就地给出解决办法。
struct TVLyricsTranslationPanel: View {
    @Environment(TVStore.self) private var store
    @Environment(MusicIntelligenceService.self) private var intelligence
    @Environment(\.dismiss) private var dismiss
    /// 从播放页打开时,最上面先说这首歌的翻译情况。
    var showsCurrentSong = true
    @State private var settings = LyricsTranslationSettingsStore.shared
    @State private var showsLanguagePicker = false
    @State private var showsSkippedLanguagePicker = false
    @State private var showsAISettings = false
    @State private var aiSettingsRevision: UInt64 = 0
    @State private var builtInConsent: BuiltInAIConsentRequest?
    @State private var pendingRemoval: LocalLyricsTranslationModel.Pack?
    private var controller: TVLyricsTranslationController { .shared }
    private var local: LocalLyricsTranslationService { .shared }

    private var offersSmartTranslation: Bool { intelligence.shouldExposeRemoteConfiguration }
    private var usesSmartTranslation: Bool {
        offersSmartTranslation && settings.mode == .intelligentWithSystemFallback
    }
    private var usesBaidu: Bool { settings.mode == .baidu }
    private var targetCodes: [String] {
        LyricsTranslationSettingsStore.tvTargetLanguages(intelligent: usesSmartTranslation || usesBaidu)
    }
    private var target: String {
        LyricsTranslationSettingsStore.target(settings.targetLanguageCode, within: targetCodes)
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if showsCurrentSong { currentSongSection }
                    preferencesSection
                    if settings.isEnabled, usesSmartTranslation { smartSection }
                    if settings.isEnabled, usesBaidu { baiduSection }
                    if settings.isEnabled { offlineSection }
                }
                .frame(maxWidth: 1240, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
            .disabled(pendingRemoval != nil)

            if let pendingRemoval {
                removalConfirmation(pendingRemoval)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .foregroundStyle(TVColor.text)
        .animation(.easeInOut(duration: 0.2), value: pendingRemoval)
        .onExitCommand {
            if pendingRemoval != nil {
                pendingRemoval = nil
            } else {
                dismiss()
            }
        }
        .task { local.refreshAvailability() }
        .builtInAIConsentSheet($builtInConsent)
        .fullScreenCover(isPresented: $showsLanguagePicker) {
            TVLyricsTranslationLanguagePicker(codes: targetCodes, selected: target) { code in
                settings.targetLanguageCode = code
            }
        }
        .fullScreenCover(isPresented: $showsSkippedLanguagePicker) {
            TVLyricsTranslationSkippedLanguagesPicker(target: target)
        }
        .fullScreenCover(isPresented: $showsAISettings, onDismiss: {
            // 在智能功能里换了服务、开了内置 AI 或允许了发送:这首歌按新的设置重翻。
            if intelligence.settingsStore.revision != aiSettingsRevision {
                controller.retranslateCurrentLyrics()
            }
        }) {
            TVAISettingsView().environment(intelligence)
        }
        .accessibilityIdentifier("tv.lyricsTranslation.panel")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("lyrics_translation_title").tvFont(.pageTitle)
                if showsCurrentSong, !store.nowPlaying.title.isEmpty {
                    Text(verbatim: store.nowPlaying.title)
                        .tvFont(.body)
                        .foregroundStyle(TVColor.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
        }
        .padding(.bottom, 28)
    }

    // MARK: 这首歌

    @ViewBuilder
    private var currentSongSection: some View {
        let songID = store.currentSongID
        TVAISection(title: PMString("ext.tv.options.section.song")) {
            if !settings.isEnabled {
                TVAINoteRow(
                    icon: "character.bubble",
                    tint: TVColor.textFaint,
                    text: String(localized: "lyrics_translation_off_status")
                )
            } else if !controller.hasLyrics(forSongID: songID) {
                TVAINoteRow(icon: "text.quote", tint: TVColor.textFaint, text: String(localized: "no_lyrics"))
            } else {
                let activity = controller.activitySongID == songID ? controller.activity : .idle
                TVAINoteRow(
                    icon: activity.systemImage,
                    tint: activity.tint,
                    text: activity.statusText ?? String(localized: "lyrics_translation_preparing")
                )
                if case .needsModel(let pack) = activity {
                    TVAIDivider()
                    packRow(pack)
                }
                if let issue = controller.intelligentIssue, controller.activitySongID == songID {
                    TVAIDivider()
                    TVAINoteRow(icon: issue.systemImage, tint: TVColor.warn, text: issue.explanation)
                    if case .notReady(let readiness) = issue {
                        fixRow(for: readiness)
                    }
                }
            }
        }
    }

    // MARK: 设置

    private var preferencesSection: some View {
        TVAISection(title: String(localized: "lyrics_translation_preferences_section")) {
            TVAIToggleRow(
                icon: "character.bubble",
                title: String(localized: "lyrics_translation_enabled"),
                isOn: Binding(
                    get: { settings.isEnabled },
                    set: { enabled in
                        if enabled { settings.targetLanguageCode = target }
                        settings.isEnabled = enabled
                    }
                )
            )
            .accessibilityIdentifier("tv.lyricsTranslation.enabled")
            TVAIDivider()
            TVAIToggleRow(
                icon: "text.bubble",
                title: String(localized: "lyrics_bundled_translation_shown"),
                isOn: Binding(
                    get: { settings.showsBundledTranslations },
                    set: { settings.showsBundledTranslations = $0 }
                )
            )
            .accessibilityIdentifier("tv.lyricsTranslation.bundled")
            if settings.isEnabled {
                TVAIDivider()
                TVAIActionRow(
                    icon: "globe",
                    title: String(localized: "lyrics_translation_target"),
                    value: Self.languageName(target)
                ) {
                    showsLanguagePicker = true
                }
                .accessibilityIdentifier("tv.lyricsTranslation.target")
                TVAIDivider()
                TVAIActionRow(
                    icon: "text.badge.xmark",
                    title: String(localized: "lyrics_translation_skipped_languages"),
                    value: LyricsTranslationSettingsStore.skippedLanguagesSummary(
                        settings.skippedSourceLanguageCodes,
                        targetLanguageCode: target,
                        displayName: { Self.languageName($0) }
                    )
                ) {
                    showsSkippedLanguagePicker = true
                }
                .accessibilityIdentifier("tv.lyricsTranslation.skippedLanguages")
                TVAIDivider()
                TVAIActionRow(
                    icon: modeIcon,
                    title: String(localized: "lyrics_translation_mode"),
                    value: modeTitle,
                    trailing: "arrow.left.arrow.right"
                ) {
                    cycleMode()
                }
                .accessibilityIdentifier("tv.lyricsTranslation.mode")
                TVAIDivider()
                TVAINoteRow(
                    icon: "info.circle",
                    tint: TVColor.textFaint,
                    text: modeFooter
                )
            }
        }
    }

    /// 能选的方式:离线翻译包、(这个地区有智能服务时)智能翻译、百度翻译。电视上 `.system` 就是离线翻译包。
    private var offeredModes: [LyricsTranslationMode] {
        offersSmartTranslation ? [.system, .intelligentWithSystemFallback, .baidu] : [.system, .baidu]
    }

    private var currentMode: LyricsTranslationMode {
        usesSmartTranslation ? .intelligentWithSystemFallback : (usesBaidu ? .baidu : .system)
    }

    private var modeTitle: String {
        switch currentMode {
        case .intelligentWithSystemFallback: String(localized: "lyrics_translation_mode_smart")
        case .baidu: String(localized: "lyrics_translation_mode_baidu")
        case .system: String(localized: "lyrics_translation_mode_offline")
        }
    }

    private var modeIcon: String {
        switch currentMode {
        case .intelligentWithSystemFallback: "sparkles"
        case .baidu: "character.bubble"
        case .system: "character.book.closed"
        }
    }

    private var modeFooter: String {
        switch currentMode {
        case .intelligentWithSystemFallback: String(localized: "lyrics_translation_tv_mode_smart_footer")
        case .baidu: String(localized: "lyrics_translation_tv_mode_baidu_footer")
        case .system: String(localized: "lyrics_translation_tv_mode_offline_footer")
        }
    }

    /// 点一下换到下一种方式。
    private func cycleMode() {
        let modes = offeredModes
        let index = modes.firstIndex(of: currentMode) ?? 0
        setMode(modes[(index + 1) % modes.count])
    }

    private func setMode(_ mode: LyricsTranslationMode) {
        // 离线翻译包只覆盖几种语言:换回它时目标语言跟着落到它能译的那几种里。
        let codes = LyricsTranslationSettingsStore.tvTargetLanguages(intelligent: mode != .system)
        let newTarget = LyricsTranslationSettingsStore.target(settings.targetLanguageCode, within: codes)
        if newTarget != settings.targetLanguageCode { settings.targetLanguageCode = newTarget }
        settings.mode = mode
    }

    // MARK: 百度翻译

    /// 电视上不填 APP ID 和密钥(遥控器输长串太累):用 iPhone、iPad 或 Mac 上填好的那一份,
    /// 经 iCloud 钥匙串同步过来,或者随扫码直传带过来。
    private var baiduSection: some View {
        TVAISection(title: String(localized: "lyrics_translation_mode_baidu")) {
            let account = BaiduTranslateAccount.shared
            if let masked = account.maskedAppID {
                TVAINoteRow(
                    icon: "checkmark.circle.fill",
                    tint: TVColor.ok,
                    text: String(format: String(localized: "baidu_translate_status_ready_format"), masked)
                )
                if let lastError = account.lastError {
                    TVAIDivider()
                    TVAINoteRow(icon: "exclamationmark.circle", tint: TVColor.warn, text: lastError)
                }
            } else {
                TVAINoteRow(
                    icon: "exclamationmark.circle",
                    tint: TVColor.warn,
                    text: String(localized: "baidu_translate_tv_needs_setup")
                )
                TVAIDivider()
                TVAIActionRow(
                    icon: "arrow.clockwise",
                    title: String(localized: "baidu_translate_tv_check_again")
                ) {
                    account.reload()
                    controller.retranslateCurrentLyrics()
                }
            }
            TVAIDivider()
            TVAINoteRow(
                icon: "info.circle",
                tint: TVColor.textFaint,
                text: String(localized: "baidu_translate_privacy_footer")
            )
        }
        .onAppear { BaiduTranslateAccount.shared.reload() }
    }

    // MARK: 智能翻译

    private var smartSection: some View {
        TVAISection(title: String(localized: "lyrics_translation_mode_smart")) {
            let readiness = intelligence.lyricsAITranslationReadiness
            if readiness == .ready {
                TVAINoteRow(
                    icon: "checkmark.circle.fill",
                    tint: TVColor.ok,
                    text: String(localized: "lyrics_translation_ai_ready")
                )
            } else {
                TVAINoteRow(
                    icon: "exclamationmark.circle",
                    tint: TVColor.warn,
                    text: TVLyricsTranslationController.IntelligentIssue.notReady(readiness).explanation
                )
                fixRow(for: readiness)
            }
            TVAIDivider()
            TVAIActionRow(
                icon: "arrow.triangle.branch",
                title: String(localized: "ai_route_label"),
                subtitle: String(localized: "ai_settings_title")
            ) {
                openAISettings()
            }
            .accessibilityIdentifier("tv.lyricsTranslation.aiSettings")
        }
    }

    /// 智能翻译差的那一步,就地解决。
    @ViewBuilder
    private func fixRow(for readiness: LyricsAITranslationReadiness) -> some View {
        switch readiness {
        case .needsBuiltInConsent:
            TVAIDivider()
            TVAIActionRow(
                icon: "hand.raised",
                title: String(localized: "ai_consent_pending_action")
            ) {
                builtInConsent = BuiltInAIConsentRequest {
                    TVLyricsTranslationController.shared.retranslateCurrentLyrics()
                }
            }
        case .needsRemoteConsent:
            TVAIDivider()
            TVAIActionRow(
                icon: "paperplane",
                title: String(localized: "lyrics_translation_ai_allow_sending")
            ) {
                do {
                    try intelligence.grantRemoteConsent()
                } catch {
                    return
                }
                controller.retranslateCurrentLyrics()
            }
        case .noService:
            TVAIDivider()
            TVAIActionRow(
                icon: "sparkles",
                title: String(localized: "ai_settings_title")
            ) {
                openAISettings()
            }
        case .ready, .regionUnavailable:
            EmptyView()
        }
    }

    private func openAISettings() {
        aiSettingsRevision = intelligence.settingsStore.revision
        showsAISettings = true
    }

    // MARK: 离线翻译包

    private var offlineSection: some View {
        TVAISection(title: String(localized: "lyrics_translation_local_section")) {
            let packs = LocalLyricsTranslationModel.Pack.allCases.filter {
                local.modelState(for: $0) != .unsupportedSystem
            }
            if packs.isEmpty {
                TVAINoteRow(
                    icon: "info.circle",
                    tint: TVColor.textFaint,
                    text: String(localized: "lyrics_translation_offline_unavailable_system")
                )
            }
            ForEach(Array(packs.enumerated()), id: \.element) { index, pack in
                if index > 0 { TVAIDivider() }
                packRow(pack)
            }
            // 翻译包下不来(App Store 那边暂时不给)时,能换智能翻译就给一键换过去。
            if offersSmartTranslation, currentMode == .system,
               packs.contains(where: { local.modelState(for: $0) == .failed }) {
                TVAIDivider()
                TVAIActionRow(
                    icon: "sparkles",
                    title: String(localized: "lyrics_translation_offline_failed_try_smart"),
                    trailing: "arrow.left.arrow.right"
                ) {
                    setMode(.intelligentWithSystemFallback)
                }
            }
            TVAIDivider()
            TVAINoteRow(
                icon: "info.circle",
                tint: TVColor.textFaint,
                text: String(localized: "lyrics_translation_tv_offline_footer")
            )
        }
    }

    private func packRow(_ pack: LocalLyricsTranslationModel.Pack) -> some View {
        let state = local.modelState(for: pack)
        let status: String
        let trailing: String
        switch state {
        case .ready:
            status = String(localized: "lyrics_translation_local_ready")
            trailing = "trash"
        case .downloading(let fraction):
            status = fraction.formatted(.percent.precision(.fractionLength(0)))
            trailing = "hourglass"
        case .failed:
            status = local.modelFailureReason(for: pack) ?? String(localized: "lyrics_translation_local_retry")
            trailing = "arrow.clockwise"
        case .notDownloaded, .unsupportedSystem:
            status = String(
                format: String(localized: "lyrics_translation_local_download_size_format"),
                ByteCountFormatter.string(fromByteCount: pack.approximateDownloadBytes, countStyle: .file)
            )
            trailing = "arrow.down.circle"
        }
        return TVAIActionRow(
            icon: "character.book.closed",
            title: String(localized: String.LocalizationValue(pack.pairsKey)),
            value: status,
            trailing: trailing
        ) {
            switch state {
            case .notDownloaded, .failed:
                local.downloadModel(pack)
            case .ready:
                pendingRemoval = pack
            case .downloading, .unsupportedSystem:
                break
            }
        }
        .accessibilityIdentifier("tv.lyricsTranslation.pack.\(pack.rawValue)")
    }

    private func removalConfirmation(_ pack: LocalLyricsTranslationModel.Pack) -> some View {
        ZStack {
            TVColor.bg.opacity(0.62).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 24) {
                Text("lyrics_translation_local_remove_confirm").tvFont(.sectionTitle)
                Text(verbatim: String(localized: String.LocalizationValue(pack.pairsKey)))
                    .tvFont(.body)
                    .foregroundStyle(TVColor.textMuted)
                HStack(spacing: 18) {
                    TVPillButton(
                        title: String(localized: "lyrics_translation_local_remove"),
                        systemImage: "trash",
                        style: .solid
                    ) {
                        pendingRemoval = nil
                        Task { await local.removeModel(pack) }
                    }
                    TVPillButton(title: String(localized: "cancel"), systemImage: "xmark") {
                        pendingRemoval = nil
                    }
                }
            }
            .padding(36)
            .frame(width: 780, alignment: .leading)
            .tvPanel(radius: 22)
        }
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// 「不翻译的语言」:按一下勾上或取消,勾上的语言歌词保持原文。目标语言本来就不翻译,不列出来。
struct TVLyricsTranslationSkippedLanguagesPicker: View {
    let target: String
    @State private var settings = LyricsTranslationSettingsStore.shared
    @Environment(\.dismiss) private var dismiss

    private var codes: [String] {
        let listed = LyricsTranslationSettingsStore.availableTargetLanguages.map(\.code)
        let extra = settings.skippedSourceLanguageCodes.filter { !listed.contains($0) }
        return (listed + extra).filter {
            !LyricTranslationGroupingPolicy.representsSameTranslationLanguage($0, target)
        }
    }

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 24) {
                        Text("lyrics_translation_skipped_languages").tvFont(.pageTitle)
                        Spacer(minLength: 0)
                        TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
                    }
                    .padding(.bottom, 28)
                    TVAISection(title: String(localized: "lyrics_translation_skipped_languages_section")) {
                        ForEach(Array(codes.enumerated()), id: \.element) { index, code in
                            if index > 0 { TVAIDivider() }
                            let isSkipped = settings.isSourceLanguageSkipped(code)
                            TVAIActionRow(
                                icon: "globe",
                                title: TVLyricsTranslationPanel.languageName(code),
                                trailing: isSkipped ? "checkmark" : "circle",
                                tint: isSkipped ? TVColor.brand : TVColor.text
                            ) {
                                settings.setSourceLanguage(code, skipped: !isSkipped)
                            }
                        }
                        TVAIDivider()
                        TVAINoteRow(
                            icon: "info.circle",
                            tint: TVColor.textFaint,
                            text: String(localized: "lyrics_translation_skipped_languages_footer")
                        )
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand { dismiss() }
    }
}

/// 「翻译为」的选择页:一屏列出能选的语言,选中即返回。
struct TVLyricsTranslationLanguagePicker: View {
    let codes: [String]
    let selected: String
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            TVColor.bg.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 24) {
                        Text("lyrics_translation_target").tvFont(.pageTitle)
                        Spacer(minLength: 0)
                        TVPillButton(title: String(localized: "done"), systemImage: "xmark") { dismiss() }
                    }
                    .padding(.bottom, 28)
                    TVAISection(title: String(localized: "lyrics_translation_target_language")) {
                        ForEach(Array(codes.enumerated()), id: \.element) { index, code in
                            if index > 0 { TVAIDivider() }
                            let isSelected = LyricTranslationGroupingPolicy
                                .representsSameTranslationLanguage(code, selected)
                            TVAIActionRow(
                                icon: "globe",
                                title: TVLyricsTranslationPanel.languageName(code),
                                trailing: isSelected ? "checkmark" : "circle",
                                tint: isSelected ? TVColor.brand : TVColor.text
                            ) {
                                onSelect(code)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.horizontal, 80)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(TVColor.text)
        .onExitCommand { dismiss() }
    }
}
#endif
