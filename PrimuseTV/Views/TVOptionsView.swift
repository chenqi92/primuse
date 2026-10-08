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
    private var sections: [OptionSection] {
        let sleepOn = store.sleepTimerMinutes > 0
        // 有声内容不给卡拉OK、歌词字号与串烧这些音乐的玩法。有声书的每个文件也能加进「我喜欢」,
        // 播客单集不在曲库里,喜欢的记在播客自己那份(和手机同一份,经 iCloud 同步)。
        let isSpokenWord = store.currentItemIsSpokenWord
        let podcastEpisodeID = isSpokenWord ? store.currentPodcastEpisodeID : nil
        let liked = podcastEpisodeID.map { PodcastStore.shared.isLiked(episodeID: $0) }
            ?? (store.currentSongID.map(store.isLiked) ?? false)
        var song: [Action] = []
        song.append(.init(id: "love", icon: liked ? "heart.fill" : "heart",
                          label: liked ? PMString("ext.tv.options.loved") : PMString("ext.tv.options.love"), on: liked,
                          run: {
                              if let podcastEpisodeID {
                                  PodcastStore.shared.toggleLiked(episodeID: podcastEpisodeID)
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
        playback.append(.init(id: "sleep", icon: "moon.zzz.fill",
                              label: sleepOn ? PMString("ext.tv.options.sleepActive", store.sleepTimerMinutes) : PMString("ext.tv.options.sleepTimer"), on: sleepOn,
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
        .onExitCommand { dismiss() }
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

    @FocusState private var focusedEffect: FullscreenPlayerEffect?
    @FocusState private var lyricsToggleFocused: Bool
    @FocusState private var frameRateFocused: Bool

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

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 24) {
                            ForEach(FullscreenEffectCollection.allCases) { collection in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(collection.title)
                                        .tvFont(.caption, weight: .semibold)
                                        .foregroundStyle(.white.opacity(0.66))

                                    LazyVGrid(columns: columns, spacing: 18) {
                                        ForEach(collection.effects) { candidate in
                                            effectChoice(candidate)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 70)
                .padding(.vertical, 46)
            }
        }
        .focusSection()
        .onAppear { focusedEffect = selectedEffect }
        .accessibilityAddTraits(.isModal)
        .environment(\.colorScheme, .dark)
    }

    /// 遥控器上按一下换到下一档，四档循环。
    private var frameRateButton: some View {
        Button {
            let modes = ImmersiveFrameRateMode.allCases
            let index = modes.firstIndex(of: frameRate) ?? 0
            frameRateRawValue = modes[(index + 1) % modes.count].rawValue
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
                ImmersiveEffectPreview(
                    effect: candidate,
                    isActive: focused || selected,
                    palette: previewPalette
                )
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            .tvFocusRing(focused, radius: 14, accent: .white, scale: 1.04, lift: 6)
        }
        .buttonStyle(TVBareButtonStyle())
        .focused($focusedEffect, equals: candidate)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
