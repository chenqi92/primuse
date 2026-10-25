#if os(iOS)
import PrimuseKit
import SwiftUI

/// 设置 › 播放器 › 播放页样式与按钮。右上角切换音乐、有声书、播客、电台;每一种都有一张按真机比例实时画的
/// 播放页(`NowPlayingStylePreview`),像画中画一样浮在列表上,拖到哪儿停在哪儿、双指缩放大小。
/// - 音乐:封面、歌词、全屏歌词、全屏效果四种界面在浮动预览下面那一排切换,列表跟着换成这一种界面的设置。
///   封面那一面还管封面样式、进度条、音量条、颜色、背景、播放键图标与最底下那行状态。最下面那一排按钮
///   颗数不固定:这台设备一排放得下几个就能加几个,按顺序平均排开。
/// - 有声书、播客:能换按钮的几格,那一排功能块的显隐与顺序(AirPlay 也能挪进来),喜欢、文字稿键与
///   上一章 / 下一章,有声书最底下写不写音乐源,上滑文字稿时收不收控件。
/// - 电台:最下面那一排的顺序与显隐,以及音量条。
/// 按钮位置在列表里一格一行地换,也能在「实际大小」里打开编辑直接点虚线框;没放上去的都在「更多」里。
/// 配置经 iCloud 同步(`InterfaceLayoutSync`)。
struct NowPlayingControlsEditorView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case music
        case audiobook
        case podcast
        case radio

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .music: "listening_space_music"
            case .audiobook: "listening_space_spoken_word"
            case .podcast: "listening_space_podcast"
            case .radio: "listening_space_radio"
            }
        }

        var symbol: String {
            switch self {
            case .music: ListeningSpace.music.systemImage
            case .audiobook: ListeningSpace.spokenWord.systemImage
            case .podcast: ListeningSpace.podcast.systemImage
            case .radio: ListeningSpace.radio.systemImage
            }
        }
    }

    /// 音乐播放页的几种界面。
    private enum MusicSurface: String, CaseIterable, Identifiable {
        case cover
        case lyrics
        case immersiveLyrics
        case effect

        var id: String { rawValue }

        var previewSurface: NowPlayingPreviewSurface {
            switch self {
            case .cover: .cover
            case .lyrics: .lyrics
            case .immersiveLyrics: .immersiveLyrics
            case .effect: .effect
            }
        }

        init?(_ surface: NowPlayingPreviewSurface) {
            switch surface {
            case .cover: self = .cover
            case .lyrics: self = .lyrics
            case .immersiveLyrics: self = .immersiveLyrics
            case .effect: self = .effect
            case .audiobook, .podcast, .radio: return nil
            }
        }
    }

    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(NowPlayingLyricsPageControls.storageKey) private var lyricsStorage = ""
    @AppStorage(NowPlayingImmersiveLyricsControls.storageKey) private var immersiveStorage = ""
    @AppStorage(NowPlayingEffectPlayerControls.storageKey) private var effectStorage = ""
    @AppStorage(NowPlayingRadioControlLayout.storageKey) private var radioStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .audiobook)) private var audiobookStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .podcast)) private var podcastStorage = ""
    @AppStorage(NowPlayingTextScrollPreference.collapsesKey(for: .audiobook))
    private var audiobookTextCollapses = NowPlayingTextScrollPreference.collapsesByDefault
    @AppStorage(NowPlayingTextScrollPreference.collapsesKey(for: .podcast))
    private var podcastTextCollapses = NowPlayingTextScrollPreference.collapsesByDefault
    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey)
    private var playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue
    @AppStorage(PlayerAppearancePreferences.skipButtonStyleKey)
    private var skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.showsAlbumInSubtitleKey)
    private var showsAlbumInSubtitle = PlayerAppearancePreferences.showsAlbumInSubtitleByDefault
    @AppStorage(PlayerAppearancePreferences.showsOrientationButtonKey)
    private var showsOrientationButton = PlayerAppearancePreferences.showsOrientationButtonByDefault
    @AppStorage(PlayerAppearancePreferences.followsDeviceOrientationKey)
    private var followsDeviceOrientation = PlayerAppearancePreferences.followsDeviceOrientationByDefault
    @State private var page: Page = Self.initialPage
    @State private var surface: MusicSurface = Self.initialSurface
    @State private var editing: NowPlayingPreviewSlot?
    @State private var showsActualSizePreview = false
    /// 浮动预览放在哪儿、多大(记在本机,下次进来还在原处)。
    @AppStorage(FloatingPreviewWindowMetrics.positionKey) private var previewPosition = ""
    @AppStorage(FloatingPreviewWindowMetrics.widthKey) private var previewWidth = 0.0

    #if DEBUG
    /// 取证用:`PRIMUSE_DEBUG_PLAYER_CONTROLS=music|audiobook|podcast|radio`(音乐可以接界面,
    /// 如 `music.lyrics`、`music.immersiveLyrics`、`music.effect`)时从设置 › 播放器直接推进这一页并停在那一栏。
    static let debugPage = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYER_CONTROLS"]
    private static var initialPage: Page {
        debugPage.flatMap { $0.split(separator: ".").first.map(String.init) }.flatMap(Page.init(rawValue:)) ?? .music
    }
    private static var initialSurface: MusicSurface {
        debugPage.flatMap { $0.split(separator: ".").dropFirst().first.map(String.init) }
            .flatMap(MusicSurface.init(rawValue:)) ?? .cover
    }
    #else
    private static var initialPage: Page { .music }
    private static var initialSurface: MusicSurface { .cover }
    #endif

    private var layout: NowPlayingControlLayout { .decode(storage) }
    private var lyricsControls: NowPlayingLyricsPageControls { .decode(lyricsStorage) }
    private var immersiveControls: NowPlayingImmersiveLyricsControls { .decode(immersiveStorage) }
    private var effectControls: NowPlayingEffectPlayerControls { .decode(effectStorage) }
    /// 看歌词时实际用的那组按钮(全屏歌词「跟歌名旁」跟的就是它的歌名旁那一格)。
    private var lyricsLayout: NowPlayingControlLayout { lyricsControls.resolvedLayout(cover: layout) }

    private var previewSurface: NowPlayingPreviewSurface {
        switch page {
        case .music: surface.previewSurface
        case .audiobook: .audiobook
        case .podcast: .podcast
        case .radio: .radio
        }
    }

    /// 「实际大小」里左右滑切换音乐那几种界面时写回这里,列表也跟着换。
    private var previewSurfaceBinding: Binding<NowPlayingPreviewSurface> {
        Binding(
            get: { previewSurface },
            set: { if let music = MusicSurface($0) { surface = music } }
        )
    }

    private var switchableSurfaces: [NowPlayingPreviewSurface] {
        page == .music ? MusicSurface.allCases.map(\.previewSurface) : [previewSurface]
    }

    var body: some View {
        let canvas = NowPlayingPreviewCanvas.current()
        GeometryReader { geometry in
            let window = FloatingPreviewWindowMetrics.frame(
                position: previewPosition,
                storedWidth: previewWidth,
                shape: .player(canvas),
                in: geometry.size
            )
            form
                // 预览放在下半屏时,列表底下多留出一截,最后几行能滚到它上面。
                .contentMargins(
                    .bottom,
                    window.midY > geometry.size.height / 2 ? geometry.size.height - window.minY + 8 : 0,
                    for: .scrollContent
                )
                .overlay {
                    FloatingPreviewWindow(
                        area: geometry.size,
                        shape: .player(canvas),
                        position: $previewPosition,
                        storedWidth: $previewWidth
                    ) {
                        NowPlayingStylePreview(
                            canvas: canvas,
                            surface: previewSurface,
                            selectedSlot: editing,
                            slotMode: .selectionOnly
                        )
                    } strip: {
                        PreviewSurfaceStrip(
                            surfaces: switchableSurfaces,
                            selection: previewSurfaceBinding,
                            kindTitle: page.titleKey
                        ) {
                            showsActualSizePreview = true
                        }
                    }
                }
        }
        .navigationTitle("player_style_editor_title")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                kindMenu
            }
        }
        .sheet(item: $editing) { target in
            NowPlayingSlotPickerSheet(target: target) { editing = nil }
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $showsActualSizePreview) {
            NowPlayingActualSizePreview(surface: previewSurfaceBinding, surfaces: switchableSurfaces)
        }
    }

    /// 右上角切换音乐、有声书、播客、电台。
    private var kindMenu: some View {
        Menu {
            Picker(selection: $page) {
                ForEach(Page.allCases) { page in
                    Label(page.titleKey, systemImage: page.symbol).tag(page)
                }
            } label: {
                Text("player_controls_title")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: page.symbol)
                Text(page.titleKey)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
        }
        .accessibilityLabel(Text("player_controls_title"))
        .accessibilityValue(Text(page.titleKey))
    }

    private var form: some View {
        Form {
            switch page {
            case .music:
                switch surface {
                case .cover: coverSections
                case .lyrics: lyricsSections
                case .immersiveLyrics: immersiveSections
                case .effect: effectSections
                }
            case .audiobook:
                SpokenWordControlsSections(
                    kind: .audiobook,
                    storage: $audiobookStorage,
                    collapsesOnScroll: $audiobookTextCollapses,
                    editing: $editing
                )
            case .podcast:
                SpokenWordControlsSections(
                    kind: .podcast,
                    storage: $podcastStorage,
                    collapsesOnScroll: $podcastTextCollapses,
                    editing: $editing
                )
            case .radio:
                RadioControlsSections(storage: $radioStorage)
            }
        }
    }

    // MARK: 封面

    /// 这台设备竖屏时最下面那一排放得下几颗(有声书、播客那排功能块也按这个数)。
    fileprivate static var barCapacity: Int {
        NowPlayingBarMetrics.capacity(forWidth: Double(NowPlayingPreviewCanvas.current().size.width))
    }

    @ViewBuilder
    private var coverSections: some View {
            // 一键换成一整套样子(#101、#332、#338),下面各项照样能一项项再改。
            NowPlayingStylePresetSection()

            Section {
                ForEach(NowPlayingControlSlot.single) { slot in
                    slotRow(slot)
                }
                NavigationLink {
                    NowPlayingMenuItemsEditor(storage: $storage)
                } label: {
                    LabeledContent {
                        let hidden = layout.hiddenMenuItems.count
                        if hidden > 0 {
                            Text("player_menu_items_hidden_count \(hidden)")
                        }
                    } label: {
                        Label("player_menu_items_title", systemImage: "ellipsis.circle")
                    }
                }
            } header: {
                SettingsInfoHeader("player_controls_slots_title") {
                    Text("player_controls_slots_info")
                }
            } footer: {
                Text("player_style_preview_pip_hint")
            }

            // 歌名下面那一行只写艺人还是「艺人 · 专辑」(#338、#101)。
            Section {
                Toggle(isOn: $showsAlbumInSubtitle) {
                    SettingsInfoLabel("player_album_in_subtitle") {
                        Text("player_album_in_subtitle_description")
                    }
                }
                .settingsAnchor("appearance.playerAlbumInSubtitle")
            }

            // 横竖屏(只有手机有横屏播放页):右上角那颗切换键,以及跟不跟着手机方向转。
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Toggle(isOn: $showsOrientationButton) {
                        SettingsInfoLabel("player_orientation_button_title") {
                            Text("player_orientation_button_description")
                        }
                    }
                    .settingsAnchor("appearance.playerOrientationButton")
                    Toggle(isOn: $followsDeviceOrientation) {
                        SettingsInfoLabel("player_follows_device_orientation_title") {
                            Text("player_follows_device_orientation_description")
                        }
                    }
                    .settingsAnchor("appearance.playerFollowsDeviceOrientation")
                } header: {
                    Text("player_orientation_section_title")
                }
            }

            NowPlayingBarSection(
                bar: layout.bar,
                capacity: Self.barCapacity,
                select: { editing = .cover($0) },
                move: { storage = layout.movingBar(fromOffsets: $0, toOffset: $1).encoded() },
                remove: { storage = layout.placing(nil, at: .bar($0)).encoded() }
            )

            NowPlayingTransportStyleSection(
                playKey: PlayerAppearancePreferences.playButtonStyleKey,
                skipKey: PlayerAppearancePreferences.skipButtonStyleKey,
                info: "player_transport_style_footer",
                anchorID: "appearance.playerTransportIcons"
            )

            PlayerLookSettingsSections()

            Section {
                Toggle("player_controls_status_source", isOn: statusBinding(.source))
                Toggle("player_controls_status_output", isOn: statusBinding(.output))
                Toggle("player_controls_status_sleep", isOn: statusBinding(.sleepTimer))
            } header: {
                Text("player_controls_status_header")
            } footer: {
                Text("player_controls_status_footer")
            }

            Section {
                Button("player_controls_reset") {
                    storage = layout.resettingActions().encoded()
                    playButtonStyleRawValue = NowPlayingPlayButtonStyle.filledCircle.rawValue
                    skipButtonStyleRawValue = NowPlayingSkipButtonStyle.standard.rawValue
                }
                .disabled(
                    layout.buttonsAreDefault
                        && playButtonStyleBinding.wrappedValue == .filledCircle
                        && skipButtonStyleBinding.wrappedValue == .standard
                )
            } footer: {
                Text("player_controls_duo_footer")
            }
    }

    private func slotRow(_ slot: NowPlayingControlSlot) -> some View {
        let action = layout.action(in: slot)
        return SlotChoiceRow(
            title: slot.editorTitleKey,
            symbol: action?.editorSymbol,
            value: action?.editorTitleKey ?? "player_controls_empty"
        ) { editing = .cover(.slot(slot)) }
    }

    private var playButtonStyleBinding: Binding<NowPlayingPlayButtonStyle> {
        Binding(
            get: { PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue) },
            set: { playButtonStyleRawValue = $0.rawValue }
        )
    }

    private var skipButtonStyleBinding: Binding<NowPlayingSkipButtonStyle> {
        Binding(
            get: { PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue) },
            set: { skipButtonStyleRawValue = $0.rawValue }
        )
    }

    private func statusBinding(_ item: NowPlayingStatusItem) -> Binding<Bool> {
        Binding(
            get: { layout.showsStatusItem(item) },
            set: { storage = layout.settingStatusItem(item, visible: $0).encoded() }
        )
    }

    // MARK: 歌词

    @ViewBuilder
    private var lyricsSections: some View {
        let controls = lyricsControls
        Section {
            Toggle("player_controls_lyrics_own_buttons", isOn: Binding(
                get: { controls.usesOwnButtons },
                set: { lyricsStorage = controls.settingUsesOwnButtons($0, cover: layout).encoded() }
            ))
        } footer: {
            Text("player_controls_lyrics_own_buttons_footer")
        }

        Section {
            SlotChoiceRow(
                title: "player_controls_slot_lyrics_extra",
                symbol: controls.headerExtra?.editorSymbol,
                value: controls.headerExtra?.editorTitleKey ?? "player_controls_empty"
            ) { editing = .lyricsExtra }
            // 没单独设置时按钮位置与最下面那一排跟封面界面一样,只列出来、不让点。
            ForEach(NowPlayingControlSlot.single) { slot in
                SlotChoiceRow(
                    title: slot.editorTitleKey,
                    symbol: lyricsLayout.action(in: slot)?.editorSymbol,
                    value: lyricsLayout.action(in: slot)?.editorTitleKey ?? "player_controls_empty",
                    isEnabled: controls.usesOwnButtons
                ) { editing = .lyrics(.slot(slot)) }
            }
        } header: {
            Text("player_controls_slots_title")
        } footer: {
            Text(controls.usesOwnButtons
                ? LocalizedStringKey("player_controls_lyrics_preview_footer_own")
                : LocalizedStringKey("player_controls_lyrics_preview_footer_follow"))
        }

        NowPlayingBarSection(
            bar: lyricsLayout.bar,
            capacity: Self.barCapacity,
            isEnabled: controls.usesOwnButtons,
            select: { editing = .lyrics($0) },
            move: { lyricsStorage = controls.movingOwnBar(fromOffsets: $0, toOffset: $1).encoded() },
            remove: { lyricsStorage = controls.placingOwnButton(nil, at: .bar($0)).encoded() }
        )

        Section {
            Toggle("player_controls_lyrics_collapse", isOn: Binding(
                get: { controls.collapsesControlsOnScroll },
                set: { lyricsStorage = controls.settingCollapsesControlsOnScroll($0).encoded() }
            ))
        } footer: {
            Text("player_controls_lyrics_collapse_footer")
        }

        Section {
            Button("player_controls_reset") {
                lyricsStorage = ""
            }
            .disabled(controls.isDefault)
        }
    }

    // MARK: 全屏歌词

    @ViewBuilder
    private var immersiveSections: some View {
        Section {
            ForEach(NowPlayingImmersiveLyricsSlot.allCases) { slot in
                immersiveRow(slot)
            }
        } header: {
            Text("player_controls_slots_title")
        } footer: {
            Text("player_controls_immersive_footer")
        }

        Section {
            Button("player_controls_reset") {
                immersiveStorage = ""
            }
            .disabled(immersiveControls.isDefault)
        }
    }

    private func immersiveRow(_ slot: NowPlayingImmersiveLyricsSlot) -> some View {
        let choice = immersiveControls.choice(in: slot)
        let shown: NowPlayingControlAction? = switch choice {
        case .followHeader: NowPlayingImmersiveLyricsControls.followedHeaderAction(lyricsLayout.action(in: .header))
        case .action(let action): action
        case .empty: nil
        }
        return SlotChoiceRow(
            title: slot.editorTitleKey,
            symbol: shown?.editorSymbol,
            value: choice == .followHeader
                ? "player_controls_follow_header"
                : (shown?.editorTitleKey ?? "player_controls_empty"),
            badge: choice == .followHeader ? "link" : nil
        ) { editing = .immersive(slot) }
    }

    // MARK: 全屏效果

    @ViewBuilder
    private var effectSections: some View {
        Section {
            ForEach(NowPlayingEffectPlayerSlot.allCases) { slot in
                SlotChoiceRow(
                    title: slot.editorTitleKey,
                    symbol: effectControls.action(in: slot)?.editorSymbol,
                    value: effectControls.action(in: slot)?.editorTitleKey ?? "player_controls_empty"
                ) { editing = .effect(slot) }
            }
        } header: {
            Text("player_controls_slots_title")
        } footer: {
            Text("player_controls_effect_footer")
        }

        Section {
            Button("player_controls_reset") {
                effectStorage = ""
            }
            .disabled(effectControls.isDefault)
        }
    }
}

extension NowPlayingControlsEditorView {
    /// 挑按钮面板里的选项:(跟歌名旁)、空着,然后是这一格能放的按钮。
    fileprivate static func choices(
        allowing allows: (NowPlayingControlAction) -> Bool,
        followsHeader: Bool
    ) -> [NowPlayingSlotChoice] {
        var choices: [NowPlayingSlotChoice] = []
        if followsHeader { choices.append(.followHeader) }
        choices.append(.empty)
        for action in NowPlayingControlAction.allCases where allows(action) {
            choices.append(.action(action))
        }
        return choices
    }
}

/// 播放页封面那一面的样子:封面样式与封面下的歌词、进度条、音量条、控件颜色与深色、背景。
/// 原来在「设置 › 播放器」,挪到这里和顶上的实时预览放在一起,改了立刻看得到。
private struct PlayerLookSettingsSections: View {
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey)
    private var artworkStyleRawValue = NowPlayingArtworkStyle.card.rawValue
    @AppStorage(PlayerAppearancePreferences.fullBleedTopSofteningKey)
    private var fullBleedTopSoftening = PlayerAppearancePreferences.fullBleedTopSofteningByDefault
    @AppStorage(PlayerAppearancePreferences.showsArtworkLyricsKey)
    private var showsArtworkLyrics = PlayerAppearancePreferences.showsArtworkLyricsByDefault
    @AppStorage(PlayerAppearancePreferences.artworkLyricsLinesKey)
    private var artworkLyricsLinesRawValue = NowPlayingArtworkLyricsLines.one.rawValue
    @AppStorage(PlayerAppearancePreferences.artworkLyricsFontScaleKey)
    private var artworkLyricsFontScale = PlayerAppearancePreferences.artworkLyricsFontScaleByDefault
    @AppStorage(PlayerAppearancePreferences.progressStyleKey)
    private var progressStyleRawValue = NowPlayingProgressStyle.standard.rawValue
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
    @AppStorage(PlayerAppearancePreferences.progressStyleAppliesToAudiobooksKey)
    private var progressStyleAppliesToAudiobooks = PlayerAppearancePreferences.progressStyleAppliesToAudiobooksByDefault
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.volumeBarStyleKey)
    private var volumeBarStyleRawValue = NowPlayingVolumeBarStyle.system.rawValue
    @AppStorage(PlayerAppearancePreferences.controlTintKey)
    private var controlTintRawValue = NowPlayingControlTint.theme.rawValue
    @AppStorage(PlayerAppearancePreferences.alwaysDarkKey)
    private var playerAlwaysDark = PlayerAppearancePreferences.alwaysDarkByDefault
    @State private var themeSettings = ThemeColorSettings.shared
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        Section {
            Picker(selection: Binding(
                get: { PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) },
                set: { artworkStyleRawValue = $0.rawValue }
            )) {
                ForEach(NowPlayingArtworkStyle.allCases, id: \.self) { style in
                    Text(LocalizedStringKey(style.titleKey)).tag(style)
                }
            } label: {
                Text("player_artwork_style_title")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .settingsAnchor("appearance.playerArtworkStyle")
            // 「封面播放」小组件跟着换卡片 / 铺满, 立刻重新发布一次。
            .onChange(of: artworkStyleRawValue) { player.updatePlaybackState() }
            if PlayerAppearancePreferences.artworkStyle(rawValue: artworkStyleRawValue) == .fullBleed {
                FullBleedTopSofteningToggle(isOn: $fullBleedTopSoftening)
            }
            Toggle(isOn: $showsArtworkLyrics) {
                SettingsInfoLabel("player_artwork_lyrics") {
                    Text("player_artwork_lyrics_description")
                }
            }
            .settingsAnchor("appearance.artworkLyrics")
            if showsArtworkLyrics {
                Picker(selection: Binding(
                    get: { PlayerAppearancePreferences.artworkLyricsLines(rawValue: artworkLyricsLinesRawValue) },
                    set: { artworkLyricsLinesRawValue = $0.rawValue }
                )) {
                    ForEach(NowPlayingArtworkLyricsLines.allCases, id: \.self) { lines in
                        Text(LocalizedStringKey(lines.titleKey)).tag(lines)
                    }
                } label: {
                    SettingsInfoLabel("player_artwork_lyrics_lines") {
                        Text("player_artwork_lyrics_lines_description")
                    }
                }
                // 和「歌词」设置里那把字号滑块同一种写法,只管封面下这几行。
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("player_artwork_lyrics_font_size")
                        Spacer(minLength: 12)
                        Text(verbatim: "\(Int((artworkLyricsFontScale * 100).rounded()))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $artworkLyricsFontScale,
                        in: PlayerAppearancePreferences.artworkLyricsFontScaleRange,
                        step: 0.05
                    ) {
                        Text("player_artwork_lyrics_font_size")
                    }
                }
            }
        } header: {
            SettingsInfoHeader("player_artwork_style_title") {
                Text("player_artwork_style_footer")
            }
        }

        Section {
            Picker(selection: Binding(
                get: { PlayerAppearancePreferences.progressStyle(rawValue: progressStyleRawValue) },
                set: { progressStyleRawValue = $0.rawValue }
            )) {
                ForEach(NowPlayingProgressStyle.allCases, id: \.self) { style in
                    Text(LocalizedStringKey(style.titleKey)).tag(style)
                }
            } label: {
                Text("player_progress_style_title")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .settingsAnchor("appearance.playerProgressStyle")
            Toggle("player_progress_glow", isOn: $progressGlows)
                .settingsAnchor("appearance.playerProgressGlow")
                .accessibilityHint(Text("player_progress_glow_description"))
            // 有声书竖屏专版默认只跟着换成波浪,打开后三种都跟(#320)。
            PlayerAudiobookToggleRow(isOn: $progressStyleAppliesToAudiobooks) {
                Text("player_progress_audiobooks_hint")
            }
        } header: {
            SettingsInfoHeader("player_progress_style_title") {
                Text("player_progress_style_footer")
            }
        }

        Section {
            Toggle(isOn: $showsVolumeBar) {
                SettingsInfoLabel("player_volume_bar") {
                    Text("player_volume_bar_description")
                }
            }
            .settingsAnchor("appearance.volumeBar")
            // 系统样式(带圆钮)或和上面的进度条同一种画法(#338)。
            if showsVolumeBar {
                Picker(selection: Binding(
                    get: { PlayerAppearancePreferences.volumeBarStyle(rawValue: volumeBarStyleRawValue) },
                    set: { volumeBarStyleRawValue = $0.rawValue }
                )) {
                    ForEach(NowPlayingVolumeBarStyle.allCases, id: \.self) { style in
                        Text(LocalizedStringKey(style.titleKey)).tag(style)
                    }
                } label: {
                    SettingsInfoLabel("player_volume_style_title") {
                        Text("player_volume_style_footer")
                    }
                }
                .settingsAnchor("appearance.playerVolumeStyle")
            }
        }

        Section {
            Picker(selection: Binding(
                get: { PlayerAppearancePreferences.controlTint(rawValue: controlTintRawValue) },
                set: { controlTintRawValue = $0.rawValue }
            )) {
                ForEach(NowPlayingControlTint.allCases, id: \.self) { tint in
                    Text(LocalizedStringKey(tint.titleKey)).tag(tint)
                }
            } label: {
                SettingsInfoLabel("player_control_tint_title") {
                    Text("player_control_tint_footer")
                }
            }
            .settingsAnchor("appearance.playerControlTint")
            Toggle(isOn: $playerAlwaysDark) {
                Label {
                    SettingsInfoLabel("player_always_dark_title") {
                        Text("player_always_dark_footer")
                    }
                } icon: {
                    Image(systemName: "moon.circle")
                }
            }
            .settingsAnchor("appearance.playerAlwaysDark")
        } header: {
            Text("player_style_section_colors")
        } footer: {
            // 主题色选了「白色」时控件颜色两个选项画出来一样,说一声免得以为没生效。
            if themeSettings.isWhiteTheme {
                Text("player_control_tint_white_theme_note")
            }
        }

        // 播放页背景:选哪种背景,再调封面色有多浓(#69)。
        PlayerBackdropSettingsSections()

        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label {
                        SettingsInfoLabel(verbatim: PMString("ext.tv.settings.ambientIntensity")) {
                            Text("player_backdrop_strength_footer")
                        }
                    } icon: {
                        Image(systemName: "sun.haze.fill")
                    }
                    Spacer()
                    Text(verbatim: "\(Int(round(themeSettings.ambientStrength * 100)))%")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { themeSettings.ambientStrength },
                    set: { themeSettings.ambientStrength = AppThemePreferences.normalizedAmbientStrength($0) }
                ), in: 0...1, step: 0.05)
            }
            .padding(.vertical, 4)
            .settingsAnchor("appearance.ambientStrength")
        }
    }
}

/// 「播放键样式」:播放 / 暂停键与上一首 / 下一首的样子。音乐、有声书、播客、电台各存一份,
/// 只改正在编辑的这一页。有声书和播客的快退、快进是秒数键,那两页不放下面那一排。
private struct NowPlayingTransportStyleSection: View {
    let showsSkipRow: Bool
    let info: LocalizedStringKey
    /// 设置搜索落到这一节(只有音乐那一页登记了)。
    let anchorID: String?

    @AppStorage private var playButtonStyleRawValue: String
    @AppStorage private var skipButtonStyleRawValue: String

    /// `skipKey` 为 nil 时不放上一首 / 下一首那一排。
    init(
        playKey: String,
        skipKey: String?,
        info: LocalizedStringKey,
        anchorID: String? = nil
    ) {
        _playButtonStyleRawValue = AppStorage(
            wrappedValue: NowPlayingPlayButtonStyle.filledCircle.rawValue,
            playKey
        )
        _skipButtonStyleRawValue = AppStorage(
            wrappedValue: NowPlayingSkipButtonStyle.standard.rawValue,
            skipKey ?? PlayerAppearancePreferences.skipButtonStyleKey
        )
        showsSkipRow = skipKey != nil
        self.info = info
        self.anchorID = anchorID
    }

    var body: some View {
        Section {
            playRow
            if showsSkipRow {
                NowPlayingStyleChoiceRow(
                    choices: NowPlayingSkipButtonStyle.allCases,
                    selection: Binding(
                        get: { PlayerAppearancePreferences.skipButtonStyle(rawValue: skipButtonStyleRawValue) },
                        set: { skipButtonStyleRawValue = $0.rawValue }
                    ),
                    title: { LocalizedStringKey($0.titleKey) }
                ) { style in
                    HStack(spacing: 4) {
                        Image(systemName: style.symbol(forward: false))
                        Image(systemName: style.symbol(forward: true))
                    }
                    .font(style.font(scale: 0.5))
                    .foregroundStyle(.primary)
                }
            }
        } header: {
            SettingsInfoHeader("player_transport_style_title") {
                Text(info)
            }
        }
    }

    @ViewBuilder
    private var playRow: some View {
        let row = NowPlayingStyleChoiceRow(
            choices: NowPlayingPlayButtonStyle.allCases,
            selection: Binding(
                get: { PlayerAppearancePreferences.playButtonStyle(rawValue: playButtonStyleRawValue) },
                set: { playButtonStyleRawValue = $0.rawValue }
            ),
            title: { LocalizedStringKey($0.titleKey) }
        ) { style in
            NowPlayingPlayPauseFace(style: style, showsPause: false, diameter: 34, tint: .primary)
        }
        if let anchorID {
            row.settingsAnchor(anchorID)
        } else {
            row
        }
    }
}

/// 一排样式小样,点一个就选它。每格等宽分掉这一行,放不下的名字缩小一点。
private struct NowPlayingStyleChoiceRow<Choice: Hashable, Face: View>: View {
    let choices: [Choice]
    @Binding var selection: Choice
    let title: (Choice) -> LocalizedStringKey
    @ViewBuilder let face: (Choice) -> Face

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(choices, id: \.self) { choice in
                let isSelected = choice == selection
                Button {
                    selection = choice
                } label: {
                    VStack(spacing: 6) {
                        face(choice)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color(uiColor: .tertiarySystemFill))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 2)
                            )
                        Text(title(choice))
                            .font(.caption)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title(choice)))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(.vertical, 6)
    }
}

/// 给一格挑按钮。编辑页和「实际大小」都弹这一张,直接读写各自那份设置。
private struct NowPlayingSlotPickerSheet: View {
    let target: NowPlayingPreviewSlot
    let onDone: () -> Void

    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(NowPlayingLyricsPageControls.storageKey) private var lyricsStorage = ""
    @AppStorage(NowPlayingImmersiveLyricsControls.storageKey) private var immersiveStorage = ""
    @AppStorage(NowPlayingEffectPlayerControls.storageKey) private var effectStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .audiobook)) private var audiobookStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .podcast)) private var podcastStorage = ""

    private var layout: NowPlayingControlLayout { .decode(storage) }
    private var lyricsControls: NowPlayingLyricsPageControls { .decode(lyricsStorage) }
    private var immersiveControls: NowPlayingImmersiveLyricsControls { .decode(immersiveStorage) }
    private var effectControls: NowPlayingEffectPlayerControls { .decode(effectStorage) }
    private var lyricsLayout: NowPlayingControlLayout { lyricsControls.resolvedLayout(cover: layout) }

    var body: some View {
        switch target {
        case .cover(let position):
            NowPlayingControlPicker(position: position, layout: layout) { action in
                storage = layout.placing(action, at: position).encoded()
                onDone()
            }
        case .lyrics(let position):
            let controls = lyricsControls
            NowPlayingControlPicker(position: position, layout: controls.ownButtons) { action in
                lyricsStorage = controls.placingOwnButton(action, at: position).encoded()
                onDone()
            }
        case .lyricsExtra:
            let controls = lyricsControls
            NowPlayingSlotChoicePicker(
                title: "player_controls_slot_lyrics_extra",
                choices: NowPlayingControlsEditorView.choices(
                    allowing: NowPlayingLyricsPageControls.allowsHeaderExtra,
                    followsHeader: false
                ),
                current: controls.headerExtra.map(NowPlayingSlotChoice.action) ?? .empty,
                footer: "player_controls_lyrics_extra_picker_footer"
            ) { choice in
                lyricsStorage = controls.settingHeaderExtra(choice.pickedAction).encoded()
                onDone()
            }
        case .immersive(let slot):
            let controls = immersiveControls
            let followed = NowPlayingImmersiveLyricsControls.followedHeaderAction(lyricsLayout.action(in: .header))
            NowPlayingSlotChoicePicker(
                title: slot.editorTitleKey,
                choices: NowPlayingControlsEditorView.choices(
                    allowing: NowPlayingImmersiveLyricsControls.allows,
                    followsHeader: NowPlayingImmersiveLyricsControls.allowsFollowingHeader(in: slot)
                ),
                current: controls.choice(in: slot),
                followedHeader: followed,
                swapTitle: { choice in
                    guard case .action = choice else { return nil }
                    return NowPlayingImmersiveLyricsSlot.allCases
                        .first { $0 != slot && controls.choice(in: $0) == choice }?.editorTitleKey
                },
                footer: "player_controls_picker_footer"
            ) { choice in
                immersiveStorage = controls.placing(choice, in: slot).encoded()
                onDone()
            }
        case .effect(let slot):
            let controls = effectControls
            NowPlayingSlotChoicePicker(
                title: slot.editorTitleKey,
                choices: NowPlayingControlsEditorView.choices(allowing: NowPlayingEffectPlayerControls.allows, followsHeader: false),
                current: controls.action(in: slot).map(NowPlayingSlotChoice.action) ?? .empty,
                swapTitle: { choice in
                    guard let action = choice.pickedAction else { return nil }
                    return NowPlayingEffectPlayerSlot.allCases
                        .first { $0 != slot && controls.action(in: $0) == action }?.editorTitleKey
                },
                footer: "player_controls_effect_picker_footer"
            ) { choice in
                effectStorage = controls.placing(choice.pickedAction, in: slot).encoded()
                onDone()
            }
        case .spoken(let kind, let slot):
            let layout = SpokenWordControlLayout.decode(
                kind == .audiobook ? audiobookStorage : podcastStorage,
                kind: kind
            )
            SpokenWordSlotPicker(kind: kind, slot: slot, layout: layout) { choice in
                let encoded = layout.placing(choice, in: slot).encoded()
                if kind == .audiobook {
                    audiobookStorage = encoded
                } else {
                    podcastStorage = encoded
                }
                onDone()
            }
        }
    }
}

/// 能换按钮的一格占一行:左边此刻放的按钮图标,中间这一格的名字,右边按钮名字;点了挑按钮,
/// 浮动预览里圈出这一格。`badge` 是图标右下角的小标(跟歌名旁的链子、自动的魔杖)。
private struct SlotChoiceRow: View {
    let title: LocalizedStringKey
    let symbol: String?
    let value: LocalizedStringKey?
    var badge: String? = nil
    var isEnabled = true
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: symbol ?? "circle.dashed")
                    .font(.body)
                    .foregroundStyle(symbol == nil || !isEnabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
                    .frame(width: 28)
                    .overlay(alignment: .bottomTrailing) {
                        if let badge {
                            Image(systemName: badge)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tint)
                                .offset(x: 5, y: 4)
                        }
                    }
                Text(title)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityHint(isEnabled ? Text("player_controls_slot_hint") : Text(verbatim: ""))
    }
}

/// 音乐播放页最下面那一排:一颗一行,点了换按钮,按住拖动换顺序,左滑拿掉;最后一行添加,加满这台设备
/// 一排放得下的颗数就不能再加。AirPlay 只能挪、不能拿掉。封面界面与歌词界面(单独摆按钮时)共用。
private struct NowPlayingBarSection: View {
    let bar: [NowPlayingControlAction]
    let capacity: Int
    var isEnabled = true
    let select: (NowPlayingControlPosition) -> Void
    let move: (IndexSet, Int) -> Void
    let remove: (Int) -> Void

    var body: some View {
        Section {
            ForEach(Array(bar.enumerated()), id: \.element) { index, action in
                SlotChoiceRow(
                    title: action.editorTitleKey,
                    symbol: action.editorSymbol,
                    value: nil,
                    badge: action.isRequiredOnPage ? "lock.fill" : nil,
                    isEnabled: isEnabled
                ) { select(.bar(index)) }
                .deleteDisabled(!isEnabled || action.isRequiredOnPage)
                .moveDisabled(!isEnabled)
            }
            .onMove { move($0, $1) }
            .onDelete { offsets in
                // 一次只会划掉一行;从后往前删,前面的下标不受影响。
                for index in offsets.sorted(by: >) { remove(index) }
            }
            if isEnabled {
                Button {
                    select(.bar(bar.count))
                } label: {
                    Label("player_controls_bar_add", systemImage: "plus.circle.fill")
                }
                .disabled(bar.count >= capacity)
            }
        } header: {
            Text("player_controls_bar_header \(bar.count) \(capacity)")
        } footer: {
            Text("player_controls_bar_footer \(capacity)")
        }
    }
}

/// 浮动预览的形状:宽高比、圆角、没调过时多宽、最宽多宽。播放页按真机竖屏比例,CarPlay 按车机横屏 16:9。
struct FloatingPreviewShape {
    /// 宽 ÷ 高。
    let aspect: CGFloat
    /// 预览这么宽时圆角多大。
    let cornerRadius: (CGFloat) -> CGFloat
    /// 没调过大小时多宽(按可用区域算)。
    let defaultWidth: (CGSize) -> CGFloat
    let maximumWidth: CGFloat

    static func player(_ canvas: NowPlayingPreviewCanvas) -> FloatingPreviewShape {
        FloatingPreviewShape(
            aspect: canvas.aspect,
            cornerRadius: { canvas.cornerRadius * $0 / max(canvas.size.width, 1) },
            defaultWidth: { min($0.width * 0.32, 150) },
            maximumWidth: 420
        )
    }
}

/// 浮动预览的位置与大小。位置存的是可移动范围里的比例(0…1),换了大小、转了屏也落在同一个相对位置。
enum FloatingPreviewWindowMetrics {
    static let positionKey = "primuse.settings.playerStylePreviewPosition"
    static let widthKey = "primuse.settings.playerStylePreviewWidth"
    static let stripHeight: CGFloat = 36
    static let stripMinimumWidth: CGFloat = 156
    static let spacing: CGFloat = 6
    static let margin: CGFloat = 10
    static let minimumWidth: CGFloat = 96

    /// 预览本身的宽:没调过时按形状给的默认宽;双指缩放后记住,夹在放得下的范围里。
    static func width(stored: Double, shape: FloatingPreviewShape, in area: CGSize) -> CGFloat {
        let maximum = max(
            minimumWidth,
            min(area.width - margin * 2, (area.height - margin * 2 - stripHeight - spacing) * shape.aspect, shape.maximumWidth)
        )
        let base = stored > 0 ? CGFloat(stored) : shape.defaultWidth(area)
        return min(max(base, minimumWidth), maximum)
    }

    /// 连同下面那排切换键的整块大小。
    static func size(width: CGFloat, shape: FloatingPreviewShape) -> CGSize {
        CGSize(
            width: max(width, stripMinimumWidth),
            height: width / shape.aspect + spacing + stripHeight
        )
    }

    static func fraction(_ stored: String) -> CGPoint {
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return CGPoint(x: 1, y: 1) }
        return CGPoint(x: min(max(parts[0], 0), 1), y: min(max(parts[1], 0), 1))
    }

    static func center(fraction: CGPoint, size: CGSize, in area: CGSize) -> CGPoint {
        let rangeX = max(0, area.width - size.width - margin * 2)
        let rangeY = max(0, area.height - size.height - margin * 2)
        return CGPoint(
            x: margin + size.width / 2 + rangeX * fraction.x,
            y: margin + size.height / 2 + rangeY * fraction.y
        )
    }

    static func storedPosition(center: CGPoint, size: CGSize, in area: CGSize) -> String {
        let rangeX = max(0, area.width - size.width - margin * 2)
        let rangeY = max(0, area.height - size.height - margin * 2)
        let x = rangeX > 0 ? (center.x - margin - size.width / 2) / rangeX : 1
        let y = rangeY > 0 ? (center.y - margin - size.height / 2) / rangeY : 1
        return String(format: "%.4f,%.4f", Double(min(max(x, 0), 1)), Double(min(max(y, 0), 1)))
    }

    static func frame(
        position: String,
        storedWidth: Double,
        shape: FloatingPreviewShape,
        in area: CGSize
    ) -> CGRect {
        let size = size(width: width(stored: storedWidth, shape: shape, in: area), shape: shape)
        let center = center(fraction: fraction(position), size: size, in: area)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    /// 预览在下半屏时,列表底下多留出一截,最后几行能滚到它上面。
    static func bottomContentMargin(for window: CGRect, in area: CGSize) -> CGFloat {
        window.midY > area.height / 2 ? area.height - window.minY + 8 : 0
    }
}

/// 像画中画一样浮在设置列表上的那张实时预览:按住拖到哪儿就停在哪儿,双指捏合调大小,下面一排切换键。
/// 拖动、捏合中只改位移和缩放,不重画里面的预览;松手才记下新位置。
/// 预览里面自己能滚、能拖的(CarPlay 画布)用 `movesByStripOnly`:只有按住下面那一排才挪窗口,双指捏合照样调大小。
struct FloatingPreviewWindow<Content: View, Strip: View>: View {
    let area: CGSize
    let shape: FloatingPreviewShape
    @Binding var position: String
    @Binding var storedWidth: Double
    let movesByStripOnly: Bool
    let accessibilityTitle: LocalizedStringKey
    let content: Content
    let strip: Strip
    @GestureState private var drag: CGSize = .zero
    @GestureState private var pinch: CGFloat = 1

    init(
        area: CGSize,
        shape: FloatingPreviewShape,
        position: Binding<String>,
        storedWidth: Binding<Double>,
        movesByStripOnly: Bool = false,
        accessibilityTitle: LocalizedStringKey = "player_style_preview_title",
        @ViewBuilder content: () -> Content,
        @ViewBuilder strip: () -> Strip
    ) {
        self.area = area
        self.shape = shape
        _position = position
        _storedWidth = storedWidth
        self.movesByStripOnly = movesByStripOnly
        self.accessibilityTitle = accessibilityTitle
        self.content = content()
        self.strip = strip()
    }

    var body: some View {
        let width = FloatingPreviewWindowMetrics.width(stored: storedWidth, shape: shape, in: area)
        let size = FloatingPreviewWindowMetrics.size(width: width, shape: shape)
        let center = FloatingPreviewWindowMetrics.center(
            fraction: FloatingPreviewWindowMetrics.fraction(position),
            size: size,
            in: area
        )
        let corner = shape.cornerRadius(width)
        let move = moveGesture(center: center, size: size)
        let resize = resizeGesture(width: width)
        return VStack(spacing: FloatingPreviewWindowMetrics.spacing) {
            content
                .frame(width: width, height: width / shape.aspect)
                // 阴影垫在一块同样圆角的底上,拖动时不用跟着预览重算。
                .background {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.32), radius: 14, y: 6)
                }
            strip
                .frame(
                    width: max(width, FloatingPreviewWindowMetrics.stripMinimumWidth),
                    height: FloatingPreviewWindowMetrics.stripHeight
                )
                .gesture(move, including: movesByStripOnly ? .all : .none)
        }
        .scaleEffect(pinch)
        .offset(drag)
        .gesture(move.simultaneously(with: resize), including: movesByStripOnly ? .subviews : .all)
        .simultaneousGesture(resize, including: movesByStripOnly ? .all : .none)
        .position(center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityTitle))
    }

    /// 位移按全局坐标量:按窗口自己的坐标量时,窗口一跟手,量到的位移就被抵掉一截,拖起来来回抖。
    private func moveGesture(center: CGPoint, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .updating($drag) { value, state, _ in state = value.translation }
            .onEnded { value in
                let moved = CGPoint(
                    x: center.x + value.translation.width,
                    y: center.y + value.translation.height
                )
                position = FloatingPreviewWindowMetrics.storedPosition(center: moved, size: size, in: area)
            }
    }

    private func resizeGesture(width: CGFloat) -> some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, state, _ in state = value.magnification }
            .onEnded { value in
                storedWidth = Double(width * value.magnification)
            }
    }
}

/// 浮动预览下面那一排:音乐的四种界面各一颗(当前那颗亮着),别的播放页写名字;最右边看实际大小。
private struct PreviewSurfaceStrip: View {
    let surfaces: [NowPlayingPreviewSurface]
    @Binding var selection: NowPlayingPreviewSurface
    let kindTitle: LocalizedStringKey
    let onActualSize: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            if surfaces.count > 1 {
                ForEach(surfaces) { surface in
                    let isSelected = surface == selection
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selection = surface }
                    } label: {
                        Image(systemName: surface.symbol)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background {
                                if isSelected {
                                    Capsule()
                                        .fill(.tint.opacity(0.16))
                                        .padding(3)
                                }
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(surface.titleKey))
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            } else {
                Text(kindTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            Divider()
                .frame(height: 18)
                .padding(.horizontal, 2)
            Button(action: onActualSize) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: 34)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("player_style_preview_actual_size"))
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
    }
}

/// 「实际大小」:预览铺满整屏,和真的播放页一样大。音乐那几种界面左右滑、或点顶上那一排切换;
/// 左上角打开编辑后能换的位置描虚线,点一下直接换按钮。
private struct NowPlayingActualSizePreview: View {
    @Binding var surface: NowPlayingPreviewSurface
    let surfaces: [NowPlayingPreviewSurface]
    @Environment(\.dismiss) private var dismiss
    @State private var editsSlots = false
    @State private var editingSlot: NowPlayingPreviewSlot?

    var body: some View {
        let canvas = NowPlayingPreviewCanvas.current()
        ZStack(alignment: .top) {
            // 预览这一层铺到安全区外,和播放页一样从屏幕顶端画到底;上面那排键留在安全区里。
            Group {
                if surfaces.count > 1 {
                    TabView(selection: $surface) {
                        ForEach(surfaces) { item in
                            previewPage(item, canvas: canvas)
                                .tag(item)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                } else {
                    previewPage(surface, canvas: canvas)
                }
            }
            .ignoresSafeArea()

            HStack(spacing: 10) {
                chromeButton(
                    symbol: editsSlots ? "checkmark" : "pencil",
                    label: editsSlots ? "done" : "player_style_preview_edit_buttons"
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) { editsSlots.toggle() }
                }
                Spacer(minLength: 0)
                if surfaces.count > 1 {
                    surfaceSwitcher
                }
                Spacer(minLength: 0)
                chromeButton(symbol: "xmark", label: "close") { dismiss() }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $editingSlot) { target in
            NowPlayingSlotPickerSheet(target: target) { editingSlot = nil }
                .presentationDetents([.medium, .large])
        }
    }

    private func previewPage(_ surface: NowPlayingPreviewSurface, canvas: NowPlayingPreviewCanvas) -> some View {
        GeometryReader { geometry in
            NowPlayingStylePreview(
                canvas: canvas,
                surface: surface,
                selectedSlot: editingSlot,
                slotMode: editsSlots ? .editable : .plain,
                animatesStage: true
            ) { editingSlot = $0 }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    /// 顶上那排中间:音乐四种界面,当前那颗亮着。
    private var surfaceSwitcher: some View {
        HStack(spacing: 2) {
            ForEach(surfaces) { item in
                let isSelected = item == surface
                Button {
                    withAnimation(.snappy(duration: 0.3)) { surface = item }
                } label: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .frame(width: 38, height: 32)
                        .background {
                            if isSelected {
                                Capsule().fill(.tint.opacity(0.2))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.titleKey))
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func chromeButton(
        symbol: String,
        label: LocalizedStringKey,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - 有声书、播客

/// 有声书或播客播放页:能换按钮的几格(示意图上的虚线框)、那一排功能块(按住拖动排序、开关显隐)、
/// 几个单独的按钮开关,以及上滑文字稿时收不收控件。
private struct SpokenWordControlsSections: View {
    let kind: SpokenWordPlayerKind
    @Binding var storage: String
    @Binding var collapsesOnScroll: Bool
    @Binding var editing: NowPlayingPreviewSlot?

    private var layout: SpokenWordControlLayout { .decode(storage, kind: kind) }

    /// 选「自动」的格子按有文字稿的一条显示。
    private var controls: SpokenWordResolvedControls {
        layout.resolved(in: SpokenWordControlContext(
            hasTranscript: true,
            hasPartRow: kind == .audiobook,
            hasInnerChapterPair: kind == .podcast
        ))
    }

    /// 章节那一行只有有声书的专版才有。
    private var slots: [SpokenWordControlSlot] {
        SpokenWordControlSlot.allCases.filter { $0 != .partRow || kind == .audiobook }
    }

    var body: some View {
        // 播客的单集封面可以像音乐一样铺满;有声书的书封是竖版,照旧是卡片。
        if kind == .podcast {
            PlayerArtworkStyleSection(
                key: PlayerAppearancePreferences.podcastArtworkStyleKey,
                title: "player_artwork_style_title",
                footer: "player_artwork_style_podcast_footer",
                offersTopSoftening: true
            )
        }

        NowPlayingTransportStyleSection(
            playKey: kind == .podcast
                ? PlayerAppearancePreferences.podcastPlayButtonStyleKey
                : PlayerAppearancePreferences.audiobookPlayButtonStyleKey,
            skipKey: nil,
            info: "player_transport_style_spoken_footer"
        )

        Section {
            ForEach(slots) { slot in
                let choice = layout.choice(in: slot)
                SlotChoiceRow(
                    title: slot.editorTitleKey,
                    symbol: controls.action(in: slot)?.editorSymbol(for: kind, in: slot),
                    value: choice.editorTitleKey(for: kind, in: slot),
                    badge: choice == .automatic ? "wand.and.stars" : nil
                ) { editing = .spoken(kind, slot) }
            }
        } header: {
            Text("player_controls_slots_title")
        } footer: {
            Text("player_controls_spoken_slot_footer")
        }

        // 这台设备一排放得下几块(和音乐底栏同一个上限):开满了,关着的那几块先不能开。
        let capacity = NowPlayingControlsEditorView.barCapacity
        let isFull = layout.visibleTiles().count >= capacity
        Section {
            ForEach(layout.order) { tile in
                Toggle(isOn: Binding(
                    get: { layout.isShown(tile) },
                    set: { storage = layout.settingTile(tile, shown: $0).encoded() }
                )) {
                    Label {
                        Text(tile.editorTitleKey(for: kind))
                        // 投放、喜欢、「更多」、文字稿默认在别处,打开才挪进这一排。
                        if let home = tile.editorHomeKey {
                            Text(home)
                        }
                    } icon: {
                        Image(systemName: tile.editorSymbol(for: kind))
                    }
                }
                .disabled(isFull && !layout.isShown(tile))
            }
            .onMove { storage = layout.movingTiles(fromOffsets: $0, toOffset: $1).encoded() }
            Picker(selection: Binding(
                get: { layout.tileLabelStyle },
                set: { storage = layout.settingTileLabelStyle($0).encoded() }
            )) {
                Text("player_controls_tile_label_icon_text").tag(SpokenWordTileLabelStyle.iconAndText)
                Text("player_controls_tile_label_icon_only").tag(SpokenWordTileLabelStyle.iconOnly)
            } label: {
                Label("player_controls_tile_label_style", systemImage: "textformat.abc")
            }
        } header: {
            Text("player_controls_tiles_header \(layout.visibleTiles().count) \(capacity)")
        } footer: {
            Text("player_controls_tiles_footer \(capacity)")
        }

        Section {
            Toggle(isOn: Binding(
                get: { layout.showsLike },
                set: { storage = layout.settingShowsLike($0).encoded() }
            )) {
                Label("player_controls_action_like", systemImage: "heart")
            }
            Toggle(isOn: Binding(
                get: { layout.showsTranscriptToggle },
                set: { storage = layout.settingShowsTranscriptToggle($0).encoded() }
            )) {
                Label("player_controls_spoken_transcript", systemImage: "text.bubble")
            }
            Toggle(isOn: Binding(
                get: { layout.showsChapterButtons },
                set: { storage = layout.settingShowsChapterButtons($0).encoded() }
            )) {
                Label("player_controls_spoken_chapters", systemImage: "arrow.left.and.right")
            }
        } header: {
            Text("player_controls_spoken_buttons_header")
        } footer: {
            Text("player_controls_spoken_buttons_footer")
        }

        // 只有有声书的专版最底下写音乐源(播客页没有那一行)。
        if kind == .audiobook {
            Section {
                Toggle(isOn: Binding(
                    get: { layout.showsSource },
                    set: { storage = layout.settingShowsSource($0).encoded() }
                )) {
                    Label("player_controls_spoken_source", systemImage: "externaldrive")
                }
            } footer: {
                Text("player_controls_spoken_source_footer")
            }
        }

        Section {
            NavigationLink {
                SpokenWordMenuItemsEditor(kind: kind, storage: $storage)
            } label: {
                LabeledContent {
                    let hidden = layout.hiddenMenuItems.count
                    if hidden > 0 {
                        Text("player_menu_items_hidden_count \(hidden)")
                    }
                } label: {
                    Label("player_menu_items_title", systemImage: "ellipsis.circle")
                }
            }
        }

        Section {
            Toggle(isOn: $collapsesOnScroll) {
                Label("player_controls_text_collapse", systemImage: "rectangle.compress.vertical")
            }
        } footer: {
            Text("player_controls_text_collapse_footer")
        }

        Section {
            Button("player_controls_reset") {
                storage = ""
                collapsesOnScroll = NowPlayingTextScrollPreference.collapsesByDefault
            }
            .disabled(layout.isDefault && collapsesOnScroll == NowPlayingTextScrollPreference.collapsesByDefault)
        }
    }
}

/// 给有声书、播客的一格挑按钮:自动、空着,然后是这一种播放页能放的按钮。已经明确放在另一格的选了就两格对调。
private struct SpokenWordSlotPicker: View {
    let kind: SpokenWordPlayerKind
    let slot: SpokenWordControlSlot
    let layout: SpokenWordControlLayout
    let onPick: (SpokenWordSlotChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    private var choices: [SpokenWordSlotChoice] {
        [.automatic, .empty] + SpokenWordSlotAction.allCases
            .filter { $0.isAvailable(for: kind) }
            .map(SpokenWordSlotChoice.action)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choices, id: \.self) { choice in
                        row(choice)
                    }
                } footer: {
                    Text("player_controls_spoken_slot_picker_footer")
                }
            }
            .navigationTitle(Text(slot.editorTitleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ choice: SpokenWordSlotChoice) -> some View {
        let isCurrent = layout.choice(in: slot) == choice
        // 上一章 / 下一章在两侧各放一颗不算对调。
        let otherSlot: SpokenWordControlSlot? = choice.action.flatMap { action in
            SpokenWordControlSlot.allCases.first { other in
                other != slot && layout.choice(in: other) == choice
                    && !(action == .chapters && other != .partRow && slot != .partRow)
            }
        }
        return Button {
            onPick(choice)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: choice.editorSymbol(for: kind, in: slot))
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.editorTitleKey(for: kind, in: slot))
                        .foregroundStyle(.primary)
                    if choice == .automatic {
                        Text(slot == .partRow
                            ? LocalizedStringKey("player_controls_spoken_slot_automatic_part_row")
                            : LocalizedStringKey("player_controls_spoken_slot_automatic_sides"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let otherSlot {
                    // 选它就和那一格对调。
                    Label {
                        Text(otherSlot.editorTitleKey)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - 电台

/// 电台播放页最下面那一排:按住拖动排序、开关显隐;隔空播放不能关(点了说明原因)。另有音量条开关。
private struct RadioControlsSections: View {
    @Binding var storage: String
    @State private var showsAirPlayNote = false

    private var layout: NowPlayingRadioControlLayout { .decode(storage) }

    var body: some View {
        PlayerArtworkStyleSection(
            key: PlayerAppearancePreferences.radioArtworkStyleKey,
            title: "player_radio_artwork_style_title",
            footer: "player_artwork_style_radio_footer"
        )

        NowPlayingTransportStyleSection(
            playKey: PlayerAppearancePreferences.radioPlayButtonStyleKey,
            skipKey: PlayerAppearancePreferences.radioSkipButtonStyleKey,
            info: "player_transport_style_radio_footer"
        )

        Section {
            ForEach(layout.order) { item in
                if item.isRequired {
                    Button {
                        showsAirPlayNote = true
                    } label: {
                        HStack {
                            Label {
                                Text(item.editorTitleKey)
                                    .foregroundStyle(.primary)
                            } icon: {
                                Image(systemName: item.editorSymbol)
                            }
                            Spacer()
                            Image(systemName: "lock.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(Text("a11y_value_on"))
                    .accessibilityHint(Text("player_controls_radio_airplay_required"))
                } else {
                    Toggle(isOn: Binding(
                        get: { layout.isShown(item) },
                        set: { storage = layout.settingItem(item, shown: $0).encoded() }
                    )) {
                        Label {
                            Text(item.editorTitleKey)
                        } icon: {
                            Image(systemName: item.editorSymbol)
                        }
                    }
                }
            }
            .onMove { storage = layout.movingItems(fromOffsets: $0, toOffset: $1).encoded() }
        } header: {
            Text("player_controls_radio_items_header")
        } footer: {
            Text("player_controls_radio_items_footer")
        }

        Section {
            Toggle(isOn: Binding(
                get: { layout.showsVolumeBar },
                set: { storage = layout.settingShowsVolumeBar($0).encoded() }
            )) {
                Label("player_volume_bar", systemImage: "speaker.wave.2")
            }
        } footer: {
            Text("player_controls_radio_volume_footer")
        }

        Section {
            Button("player_controls_reset") {
                storage = ""
            }
            .disabled(layout.isDefault)
        }
        .alert(Text("player_controls_title"), isPresented: $showsAirPlayNote) {
            Button("done", role: .cancel) {}
        } message: {
            Text("player_controls_radio_airplay_required")
        }
    }
}

/// 铺满时顶部柔化的开关(#338),音乐与播客共用一个键,哪一页选了铺满就在哪一页出现。
private struct FullBleedTopSofteningToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            SettingsInfoLabel("player_full_bleed_top_softening") {
                Text("player_full_bleed_top_softening_description")
            }
        }
    }
}

/// 播客、电台那一页的封面(台标)样式:卡片或铺满,各存各的键;音乐的在 `PlayerLookSettingsSections`。
private struct PlayerArtworkStyleSection: View {
    @AppStorage private var rawValue: String
    @AppStorage(PlayerAppearancePreferences.fullBleedTopSofteningKey)
    private var fullBleedTopSoftening = PlayerAppearancePreferences.fullBleedTopSofteningByDefault
    let title: LocalizedStringKey
    let footer: LocalizedStringKey
    /// 播客的单集封面铺满时也做顶部柔化;电台台标不做。
    let offersTopSoftening: Bool

    init(key: String, title: LocalizedStringKey, footer: LocalizedStringKey, offersTopSoftening: Bool = false) {
        _rawValue = AppStorage(wrappedValue: NowPlayingArtworkStyle.card.rawValue, key)
        self.title = title
        self.footer = footer
        self.offersTopSoftening = offersTopSoftening
    }

    var body: some View {
        Section {
            Picker(selection: Binding(
                get: { PlayerAppearancePreferences.artworkStyle(rawValue: rawValue) },
                set: { rawValue = $0.rawValue }
            )) {
                ForEach(NowPlayingArtworkStyle.allCases, id: \.self) { style in
                    Text(LocalizedStringKey(style.titleKey)).tag(style)
                }
            } label: {
                Text(title)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if offersTopSoftening, PlayerAppearancePreferences.artworkStyle(rawValue: rawValue) == .fullBleed {
                FullBleedTopSofteningToggle(isOn: $fullBleedTopSoftening)
            }
        } header: {
            SettingsInfoHeader(title) {
                Text(footer)
            }
        }
    }
}

// MARK: - 「更多」菜单

/// 音乐播放页「更多」菜单里哪些项出现(#198)。按菜单里的分组排,关掉的项不再出现;
/// 页面按钮缺了时补进菜单的喜欢、歌词、队列、随机、循环不在这里,那是兜底入口。
private struct NowPlayingMenuItemsEditor: View {
    @Binding var storage: String

    private var layout: NowPlayingControlLayout { .decode(storage) }

    private static let groups: [(LocalizedStringKey, [NowPlayingMenuItem])] = [
        ("player_menu_group_quick", [.fullScreen, .immersiveFaceToggle, .share, .addToPlaylist, .delete]),
        ("player_menu_group_modes", [.karaoke, .medley]),
        ("player_menu_group_song", [
            .scrape, .reloadLyrics, .similarSongs, .dislike, .playbackRange, .clipExport, .editTags, .editLyrics,
        ]),
        ("player_menu_group_go", [.songInfo, .goToAlbum, .goToArtist, .openInAppleMusic]),
        ("player_menu_group_playback", [.cast, .lyricsDisplay, .lyricsMotion, .sleepTimer, .equalizer, .playbackSpeed]),
    ]

    var body: some View {
        NowPlayingMenuItemsForm(
            groups: Self.groups,
            footerKey: "player_menu_items_footer",
            hiddenCount: layout.hiddenMenuItems.count,
            shows: { layout.showsMenuItem($0) },
            setShown: { storage = layout.settingMenuItem($0, visible: $1).encoded() },
            showAll: { storage = layout.showingAllMenuItems().encoded() }
        )
    }
}

/// 有声书或播客播放页「更多」菜单里哪些项出现。只列这一种播放页的菜单里会出现的项;
/// 页面上关掉后补进菜单的喜欢、文字稿、书签、「接下来」不在这里,那是兜底入口。
private struct SpokenWordMenuItemsEditor: View {
    let kind: SpokenWordPlayerKind
    @Binding var storage: String

    private var layout: SpokenWordControlLayout { .decode(storage, kind: kind) }

    /// 资料库里的播客(自己下载、标成播客的歌)走的也是播客这一份配置,菜单里有加歌单、
    /// 改标签这些曲库项,所以播客这边把它们也列出来。
    private static let audiobookGroups: [(LocalizedStringKey, [NowPlayingMenuItem])] = [
        ("player_menu_group_quick", [.share, .addToPlaylist, .delete]),
        ("player_menu_group_book", [
            .chaptersAndBookmarks, .goToBook, .generateTranscript, .songInfo, .editTags, .editLyrics, .reloadLyrics,
        ]),
        ("player_menu_group_spoken_playback", [.cast, .lyricsDisplay, .sleepTimer, .equalizer, .playbackSpeed]),
    ]

    private static let podcastGroups: [(LocalizedStringKey, [NowPlayingMenuItem])] = [
        ("player_menu_group_quick", [.share, .addToPlaylist, .delete]),
        ("player_menu_group_episode", [
            .podcastMarkPlayed, .podcastDownload, .podcastEpisodeDetails, .podcastGoToShow,
            .chaptersAndBookmarks, .goToBook, .generateTranscript, .songInfo, .editTags, .editLyrics, .reloadLyrics,
        ]),
        ("player_menu_group_spoken_playback", [.cast, .lyricsDisplay, .sleepTimer, .equalizer, .playbackSpeed]),
    ]

    var body: some View {
        NowPlayingMenuItemsForm(
            groups: kind == .podcast ? Self.podcastGroups : Self.audiobookGroups,
            footerKey: "player_menu_items_spoken_footer",
            hiddenCount: layout.hiddenMenuItems.count,
            shows: { layout.showsMenuItem($0) },
            setShown: { storage = layout.settingMenuItem($0, visible: $1).encoded() },
            showAll: { storage = layout.showingAllMenuItems().encoded() }
        )
    }
}

/// 「更多」菜单项开关的表单,音乐与有声内容共用:按分组列开关,底下一键全部显示。
private struct NowPlayingMenuItemsForm: View {
    let groups: [(LocalizedStringKey, [NowPlayingMenuItem])]
    let footerKey: LocalizedStringKey
    let hiddenCount: Int
    let shows: (NowPlayingMenuItem) -> Bool
    let setShown: (NowPlayingMenuItem, Bool) -> Void
    let showAll: () -> Void

    var body: some View {
        Form {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.1) { item in
                        Toggle(isOn: Binding(
                            get: { shows(item) },
                            set: { setShown(item, $0) }
                        )) {
                            Label {
                                Text(item.editorTitleKey)
                            } icon: {
                                Image(systemName: item.editorSymbol)
                            }
                        }
                    }
                } header: {
                    Text(group.0)
                }
            }

            Section {
                Button("player_menu_items_show_all", action: showAll)
                    .disabled(hiddenCount == 0)
            } footer: {
                Text(footerKey)
            }
        }
        .navigationTitle("player_menu_items_title")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension NowPlayingMenuItem {
    /// 和「更多」菜单里那一项同一个图标。
    var editorSymbol: String {
        switch self {
        case .fullScreen: "viewfinder.rectangular"
        case .share: "square.and.arrow.up"
        case .addToPlaylist: "text.badge.plus"
        case .delete: "trash"
        case .karaoke: "music.mic.circle"
        case .medley: "rectangle.stack.badge.play"
        case .scrape: "wand.and.stars"
        case .reloadLyrics: "arrow.clockwise.circle"
        case .similarSongs: "sparkles"
        case .dislike: "hand.thumbsdown"
        case .playbackRange: "selection.pin.in.out"
        case .editTags: "tag"
        case .editLyrics: "quote.bubble"
        case .songInfo: "info.circle"
        case .goToAlbum: "square.stack"
        case .goToArtist: "music.mic"
        case .openInAppleMusic: "arrow.up.right.square"
        case .cast: "airplayaudio"
        case .lyricsDisplay: "textformat.size"
        case .lyricsMotion: "text.line.first.and.arrowtriangle.forward"
        case .sleepTimer: "moon.zzz"
        case .equalizer: "slider.vertical.3"
        case .playbackSpeed: "speedometer"
        case .goToBook: "books.vertical"
        case .chaptersAndBookmarks: "list.bullet.indent"
        case .podcastEpisodeDetails: "info.circle"
        case .podcastGoToShow: "rectangle.stack"
        case .podcastMarkPlayed: "checkmark.circle"
        case .podcastDownload: "arrow.down.circle"
        case .clipExport: SongPlaybackRangeEditor.clipSymbol
        case .generateTranscript: "waveform.and.mic"
        case .immersiveFaceToggle: "photo"
        }
    }

    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .fullScreen: "full_screen_player"
        case .share: "share"
        case .addToPlaylist: "add_to_playlist"
        case .delete: "delete"
        case .karaoke: "karaoke_title"
        case .medley: "player_menu_item_medley"
        case .scrape: "scrape_song"
        case .reloadLyrics: "lyrics_reload_from_source"
        case .similarSongs: "similar_songs"
        case .dislike: "song_dislike"
        case .playbackRange: "playback_range_title"
        case .editTags: "tag_editor_menu"
        case .editLyrics: "lyrics_editor_menu"
        case .songInfo: "song_info"
        case .goToAlbum: "go_to_album"
        case .goToArtist: "go_to_artist"
        case .openInAppleMusic: "apple_music_open_in_app"
        case .cast: "cast_to_device"
        case .lyricsDisplay: "player_menu_item_lyrics_display"
        case .lyricsMotion: "immersive_lyrics_motion_title"
        case .sleepTimer: "sleep_timer"
        case .equalizer: "equalizer"
        case .playbackSpeed: "playback_rate"
        case .goToBook: "spoken_word_go_to_book"
        case .chaptersAndBookmarks: "spoken_word_chapters_and_bookmarks"
        case .podcastEpisodeDetails: "podcast_player_episode_details"
        case .podcastGoToShow: "podcast_go_to_show"
        case .podcastMarkPlayed: "podcast_mark_played"
        case .podcastDownload: "podcast_download"
        case .clipExport: "clip_export_tab"
        case .generateTranscript: "transcript_generation_title"
        case .immersiveFaceToggle: "player_menu_item_immersive_face"
        }
    }
}

// MARK: - 挑按钮

/// 给一个位置挑按钮。已经在别处的按钮选了就两处对调;给最下面那一排添一颗时,已经在别处的挪过来、原处空着。
/// 隔空播放只能挪、不能拿掉,也不放在播放键两侧。不能选的项照样能点,点了说明原因。
private struct NowPlayingControlPicker: View {
    let position: NowPlayingControlPosition
    let layout: NowPlayingControlLayout
    let onPick: (NowPlayingControlAction?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var blockedReason: LocalizedStringKey?

    /// 最下面那一排里的一颗(或者添到最后)。
    private var isBar: Bool {
        if case .bar = position { return true }
        return false
    }

    /// 给最下面那一排添一颗:没有「空着」可选,选了就加到最后。
    private var isAppending: Bool {
        if case .bar(let index) = position { return index >= layout.bar.count }
        return false
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !isAppending {
                        row(nil)
                    }
                    ForEach(NowPlayingControlAction.allCases) { action in
                        row(action)
                    }
                } footer: {
                    Text(isAppending
                        ? LocalizedStringKey("player_controls_bar_add_footer")
                        : LocalizedStringKey("player_controls_picker_footer"))
                }
            }
            .navigationTitle(Text(isAppending ? LocalizedStringKey("player_controls_bar_add") : position.editorTitleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
            .alert(
                Text("player_controls_title"),
                isPresented: Binding(
                    get: { blockedReason != nil },
                    set: { if !$0 { blockedReason = nil } }
                )
            ) {
                Button("done", role: .cancel) {}
            } message: {
                if let blockedReason { Text(blockedReason) }
            }
        }
    }

    private func row(_ action: NowPlayingControlAction?) -> some View {
        let isCurrent = !isAppending && layout.action(at: position) == action
        let isAllowed = layout.canPlace(action, at: position)
        let otherPosition = action.flatMap { layout.position(of: $0) }.flatMap { $0 == position ? nil : $0 }
        return Button {
            if isAllowed {
                onPick(action)
            } else {
                blockedReason = blockedReasonKey(for: action)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action?.editorSymbol ?? (isBar ? "minus.circle" : "circle.dashed"))
                    .font(.body)
                    .foregroundStyle(isAllowed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 28)
                Text(action?.editorTitleKey ?? (isBar ? "player_controls_bar_remove" : "player_controls_empty"))
                    .foregroundStyle(isAllowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                Spacer(minLength: 8)
                if let otherPosition {
                    // 选它就和那一处对调(添到最后时是从那一处挪过来)。
                    Label {
                        Text(otherPosition.editorTitleKey)
                    } icon: {
                        Image(systemName: isAppending ? "arrow.down.to.line" : "arrow.left.arrow.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// 两种挡下来的情况:隔空播放会被换到播放键两侧,或者会从页面上消失。
    private func blockedReasonKey(for action: NowPlayingControlAction?) -> LocalizedStringKey {
        if action == .airPlay, case .slot(let slot) = position, slot.isTransportEdge {
            return "player_controls_airplay_edge"
        }
        if layout.action(at: position) == .airPlay,
           let action,
           case .slot(let slot)? = layout.position(of: action),
           slot.isTransportEdge {
            return "player_controls_airplay_edge"
        }
        return "player_controls_airplay_required"
    }
}

/// 歌词页多出来那一格、全屏歌词与全屏效果的位置用的挑选面板:列出这一格能放的
/// (全屏歌词顶上那几格还有「跟歌名旁」),已经在别处的按钮选了就两格对调。
private struct NowPlayingSlotChoicePicker: View {
    let title: LocalizedStringKey
    let choices: [NowPlayingSlotChoice]
    let current: NowPlayingSlotChoice
    /// 「跟歌名旁」此刻跟到的是哪颗(行尾写出来)。
    var followedHeader: NowPlayingControlAction?
    var swapTitle: (NowPlayingSlotChoice) -> LocalizedStringKey? = { _ in nil }
    let footer: LocalizedStringKey
    let onPick: (NowPlayingSlotChoice) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(choices, id: \.self) { choice in
                        row(choice)
                    }
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ choice: NowPlayingSlotChoice) -> some View {
        let isCurrent = choice == current
        return Button {
            onPick(choice)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol(for: choice))
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(titleKey(for: choice))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if choice == .followHeader {
                    Text(followedHeader?.editorTitleKey ?? "player_controls_empty")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let other = swapTitle(choice) {
                    // 选它就和那一格对调。
                    Label {
                        Text(other)
                    } icon: {
                        Image(systemName: "arrow.left.arrow.right")
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func symbol(for choice: NowPlayingSlotChoice) -> String {
        switch choice {
        case .followHeader: "link"
        case .action(let action): action.editorSymbol
        case .empty: "circle.dashed"
        }
    }

    private func titleKey(for choice: NowPlayingSlotChoice) -> LocalizedStringKey {
        switch choice {
        case .followHeader: "player_controls_follow_header"
        case .action(let action): action.editorTitleKey
        case .empty: "player_controls_empty"
        }
    }
}

// MARK: - 名字与图标

extension NowPlayingControlAction {
    /// 编辑页里的图标,不随播放状态变。
    var editorSymbol: String {
        switch self {
        case .like: "heart"
        case .dislike: "hand.thumbsdown"
        case .lyrics: "quote.bubble"
        case .airPlay: "airplayaudio"
        case .queue: "list.bullet"
        case .shuffle: "shuffle"
        case .repeatMode: "repeat"
        case .sleepTimer: "moon.zzz"
        case .equalizer: "slider.vertical.3"
        case .playbackSpeed: "speedometer"
        case .karaoke: "music.mic"
        case .fullScreen: "viewfinder.rectangular"
        case .addToPlaylist: "text.badge.plus"
        case .share: "square.and.arrow.up"
        case .cast: "hifispeaker"
        }
    }

    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .like: "player_controls_action_like"
        case .dislike: "song_dislike"
        case .lyrics: "player_controls_action_lyrics"
        case .airPlay: "player_controls_action_airplay"
        case .queue: "a11y_queue"
        case .shuffle: "shuffle"
        case .repeatMode: "repeat"
        case .sleepTimer: "sleep_timer"
        case .equalizer: "equalizer"
        case .playbackSpeed: "playback_rate"
        case .karaoke: "karaoke_title"
        case .fullScreen: "full_screen_player"
        case .addToPlaylist: "add_to_playlist"
        case .share: "share"
        case .cast: "cast_to_device"
        }
    }
}

extension SpokenWordControlTile {
    func editorSymbol(for kind: SpokenWordPlayerKind) -> String {
        switch self {
        case .speed: "gauge.with.dots.needle.50percent"
        case .sleepTimer: "moon.zzz"
        case .bookmark: "bookmark"
        case .contents: kind == .podcast ? "text.alignleft" : "list.bullet"
        case .upNext: "list.bullet"
        case .airPlay: "airplayaudio"
        case .transcript: "text.bubble"
        case .like: "heart"
        case .more: "ellipsis"
        }
    }

    func editorTitleKey(for kind: SpokenWordPlayerKind) -> LocalizedStringKey {
        switch self {
        case .speed: "spoken_word_speed_short"
        case .sleepTimer: "sleep_timer"
        case .bookmark: "spoken_word_bookmarks_title"
        case .contents: kind == .podcast ? "podcast_show_notes" : "spoken_word_contents_title"
        case .upNext: "up_next"
        case .airPlay: "player_controls_action_airplay"
        case .transcript: "spoken_word_text_tab"
        case .like: "player_controls_action_like"
        case .more: "more"
        }
    }

    /// 默认在别处的几块,关着时在哪儿(编辑页那一行下面的小字)。
    var editorHomeKey: LocalizedStringKey? {
        switch self {
        case .airPlay, .like, .more: "player_controls_tile_home_header"
        case .transcript: "player_controls_tile_home_transport"
        case .speed, .sleepTimer, .bookmark, .contents, .upNext: nil
        }
    }
}

extension SpokenWordSlotAction {
    /// 编辑页里的图标。上一章 / 下一章按格子:左边那格画上一章,右边画下一章,章节那一行画一对。
    func editorSymbol(for kind: SpokenWordPlayerKind, in slot: SpokenWordControlSlot) -> String {
        switch self {
        case .transcript: "text.bubble"
        case .contents: kind == .podcast ? "text.alignleft" : "list.bullet"
        case .chapters:
            switch slot {
            case .leadingSide: "backward.end"
            case .trailingSide: "forward.end"
            case .partRow: "arrow.left.and.right"
            }
        case .bookmark: "bookmark"
        case .speed: "gauge.with.dots.needle.50percent"
        case .sleepTimer: "moon.zzz"
        case .upNext: "list.bullet"
        case .like: "heart"
        case .more: "ellipsis"
        }
    }

    func editorTitleKey(for kind: SpokenWordPlayerKind) -> LocalizedStringKey {
        switch self {
        case .transcript: "spoken_word_text_tab"
        case .contents: kind == .podcast ? "podcast_show_notes" : "spoken_word_contents_title"
        case .chapters: "player_controls_spoken_chapters"
        case .bookmark: "spoken_word_bookmarks_title"
        case .speed: "spoken_word_speed_short"
        case .sleepTimer: "sleep_timer"
        case .upNext: "up_next"
        case .like: "player_controls_action_like"
        case .more: "player_menu_items_title"
        }
    }
}

extension SpokenWordSlotChoice {
    func editorSymbol(for kind: SpokenWordPlayerKind, in slot: SpokenWordControlSlot) -> String {
        switch self {
        case .automatic: "wand.and.stars"
        case .empty: "circle.dashed"
        case .action(let action): action.editorSymbol(for: kind, in: slot)
        }
    }

    func editorTitleKey(for kind: SpokenWordPlayerKind, in slot: SpokenWordControlSlot) -> LocalizedStringKey {
        switch self {
        case .automatic: "player_controls_spoken_slot_automatic"
        case .empty: "player_controls_empty"
        case .action(let action): action.editorTitleKey(for: kind)
        }
    }
}

extension SpokenWordControlSlot {
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .leadingSide: "player_controls_spoken_slot_leading"
        case .trailingSide: "player_controls_spoken_slot_trailing"
        case .partRow: "player_controls_spoken_slot_part_row"
        }
    }
}

extension NowPlayingControlSlot {
    /// 旧版底栏那三个名字不会出现在编辑页上(底栏按颗数写,见 `NowPlayingControlPosition`)。
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .header: "player_controls_slot_header"
        case .leadingEdge: "player_controls_slot_leading_edge"
        case .trailingEdge: "player_controls_slot_trailing_edge"
        case .barLeading, .barCenter, .barTrailing: "player_controls_bar_title"
        }
    }
}

extension NowPlayingControlPosition {
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .slot(let slot): slot.editorTitleKey
        case .bar(let index): "player_controls_bar_position \(index + 1)"
        }
    }

    /// 预览里这一处的标识(`NowPlayingPreviewSlot.id`)。
    var previewID: String {
        switch self {
        case .slot(let slot): slot.rawValue
        case .bar(let index): "bar.\(index)"
        }
    }
}

extension NowPlayingImmersiveLyricsSlot {
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .topPrimary: "player_controls_slot_immersive_top_primary"
        case .topSecondary: "player_controls_slot_immersive_top_secondary"
        case .dockLeading: "player_controls_slot_dock_leading"
        case .dockTrailing: "player_controls_slot_dock_trailing"
        }
    }
}

extension NowPlayingEffectPlayerSlot {
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .topTrailing: "player_controls_slot_effect_top"
        case .pillLeading: "player_controls_slot_dock_leading"
        case .pillTrailing: "player_controls_slot_dock_trailing"
        }
    }
}

extension NowPlayingRadioControlItem {
    var editorSymbol: String {
        switch self {
        case .airPlay: "airplayaudio"
        case .info: "waveform"
        case .share: "square.and.arrow.up"
        case .history: "clock.arrow.circlepath"
        case .sleepTimer: "moon.zzz"
        }
    }

    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .airPlay: "player_controls_action_airplay"
        case .info: "player_controls_radio_info"
        case .share: "share"
        case .history: "radio_detail_heard_title"
        case .sleepTimer: "sleep_timer"
        }
    }
}
// MARK: - 一键套用

/// 「播放页样式与按钮」最上面那一节的一键套用(#101、#332、#338)。只换音乐播放页封面那一面的样子:
/// 按钮位置、播放键、歌名下的专辑名、音量条、进度条、控件颜色、封面样式、背景与封面下的歌词。
/// 歌词动效,有声书、播客、电台各自的设置都不动。
enum NowPlayingStylePreset: String, CaseIterable, Identifiable {
    /// 大封面、只写艺人、无框大播放键,播放键两边不放随机与循环(还在「更多」里),音量条和进度条一个样子,
    /// 控件单色,流动色彩背景。
    case concise
    /// 上面这些都回到默认。
    case standard

    enum Value: Equatable {
        case string(String)
        case bool(Bool)
    }

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .concise: "player_style_preset_concise"
        case .standard: "player_style_preset_standard"
        }
    }

    var descriptionKey: LocalizedStringKey {
        switch self {
        case .concise: "player_style_preset_concise_description"
        case .standard: "player_style_preset_standard_description"
        }
    }

    /// 直接写进偏好的那几项。两套写的是同一批键;按钮布局与背景另算。
    var values: [String: Value] {
        switch self {
        case .concise:
            [
                PlayerAppearancePreferences.playButtonStyleKey: .string(NowPlayingPlayButtonStyle.largePlain.rawValue),
                PlayerAppearancePreferences.skipButtonStyleKey: .string(NowPlayingSkipButtonStyle.standard.rawValue),
                PlayerAppearancePreferences.showsAlbumInSubtitleKey: .bool(false),
                PlayerAppearancePreferences.showsVolumeBarKey: .bool(true),
                PlayerAppearancePreferences.volumeBarStyleKey: .string(NowPlayingVolumeBarStyle.matchesProgress.rawValue),
                PlayerAppearancePreferences.progressStyleKey: .string(NowPlayingProgressStyle.standard.rawValue),
                PlayerAppearancePreferences.progressGlowKey: .bool(false),
                PlayerAppearancePreferences.controlTintKey: .string(NowPlayingControlTint.monochrome.rawValue),
                PlayerAppearancePreferences.artworkStyleKey: .string(NowPlayingArtworkStyle.card.rawValue),
                PlayerAppearancePreferences.showsArtworkLyricsKey: .bool(false),
            ]
        case .standard:
            Self.defaultValues
        }
    }

    /// 这批键没存过时的值(就是「Primuse 默认」)。
    static let defaultValues: [String: Value] = [
        PlayerAppearancePreferences.playButtonStyleKey: .string(NowPlayingPlayButtonStyle.filledCircle.rawValue),
        PlayerAppearancePreferences.skipButtonStyleKey: .string(NowPlayingSkipButtonStyle.standard.rawValue),
        PlayerAppearancePreferences.showsAlbumInSubtitleKey: .bool(PlayerAppearancePreferences.showsAlbumInSubtitleByDefault),
        PlayerAppearancePreferences.showsVolumeBarKey: .bool(PlayerAppearancePreferences.showsVolumeBarByDefault),
        PlayerAppearancePreferences.volumeBarStyleKey: .string(NowPlayingVolumeBarStyle.system.rawValue),
        PlayerAppearancePreferences.progressStyleKey: .string(NowPlayingProgressStyle.standard.rawValue),
        PlayerAppearancePreferences.progressGlowKey: .bool(PlayerAppearancePreferences.progressGlowByDefault),
        PlayerAppearancePreferences.controlTintKey: .string(NowPlayingControlTint.theme.rawValue),
        PlayerAppearancePreferences.artworkStyleKey: .string(NowPlayingArtworkStyle.card.rawValue),
        PlayerAppearancePreferences.showsArtworkLyricsKey: .bool(PlayerAppearancePreferences.showsArtworkLyricsByDefault),
    ]

    var backdropSource: PlayerBackdropSource {
        switch self {
        case .concise: .liquid
        case .standard: .defaultValue
        }
    }

    /// 按钮摆法:从现在这份出发,状态行与「更多」里关掉的项不动。
    func layout(from current: NowPlayingControlLayout) -> NowPlayingControlLayout {
        let reset = current.resettingActions()
        switch self {
        case .concise:
            // 随机与循环从两端拿掉之后照样在「更多」里(`needsMenuFallback`)。
            return reset
                .placing(nil, at: .slot(.leadingEdge))
                .placing(nil, at: .slot(.trailingEdge))
        case .standard:
            return reset
        }
    }

    /// 现在的设置是不是正好是这一套。
    func matches(defaults: UserDefaults, backdropSource current: PlayerBackdropSource) -> Bool {
        for (key, value) in values where Self.currentValue(for: key, defaults: defaults) != value {
            return false
        }
        let layout = NowPlayingControlLayout.decode(defaults.string(forKey: NowPlayingControlLayout.musicStorageKey) ?? "")
        let target = self.layout(from: layout)
        return layout.actions == target.actions && layout.bar == target.bar && current == backdropSource
    }

    static func currentValue(for key: String, defaults: UserDefaults) -> Value? {
        switch defaultValues[key] {
        case .string(let fallback)?:
            return .string(defaults.string(forKey: key) ?? fallback)
        case .bool(let fallback)?:
            // 照 `bool(forKey:)` 读：启动参数写进来的 "NO"/"YES" 是字符串，播放页认得，这里也要认。
            return .bool(defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key))
        case nil:
            return nil
        }
    }
}

/// 套用前那几项设置原来的样子,只记在这台设备上(不进 iCloud),「恢复套用前的样子」照它写回去。
struct NowPlayingStylePresetSnapshot: Codable, Equatable {
    /// 本机偏好里存这一份的键。
    static let storageKey = "primuse.player.stylePresetSnapshot.v1"

    var strings: [String: String] = [:]
    var bools: [String: Bool] = [:]
    /// 套用前没存过的键,恢复时删掉(回到默认、也跟着以后改默认)。
    var absent: [String] = []
    var backdropSource: String

    static func decode(_ raw: String) -> NowPlayingStylePresetSnapshot? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
enum NowPlayingStylePresetApplier {
    /// 套用会改的键:各项设置与音乐按钮布局(背景单独记来源)。
    static var touchedKeys: [String] {
        NowPlayingStylePreset.defaultValues.keys.sorted() + [NowPlayingControlLayout.musicStorageKey]
    }

    static func apply(
        _ preset: NowPlayingStylePreset,
        defaults: UserDefaults = .standard,
        backdrop: PlayerBackdropSettingsStore = .shared
    ) {
        defaults.set(snapshot(defaults: defaults, backdrop: backdrop).encoded(), forKey: NowPlayingStylePresetSnapshot.storageKey)
        for (key, value) in preset.values {
            switch value {
            case .string(let string): defaults.set(string, forKey: key)
            case .bool(let bool): defaults.set(bool, forKey: key)
            }
        }
        let current = NowPlayingControlLayout.decode(defaults.string(forKey: NowPlayingControlLayout.musicStorageKey) ?? "")
        defaults.set(preset.layout(from: current).encoded(), forKey: NowPlayingControlLayout.musicStorageKey)
        backdrop.update { $0.source = preset.backdropSource }
    }

    /// 写回套用前的样子,用过就清掉这一份。
    static func restore(defaults: UserDefaults = .standard, backdrop: PlayerBackdropSettingsStore = .shared) {
        guard let snapshot = NowPlayingStylePresetSnapshot.decode(
            defaults.string(forKey: NowPlayingStylePresetSnapshot.storageKey) ?? ""
        ) else { return }
        for (key, value) in snapshot.strings { defaults.set(value, forKey: key) }
        for (key, value) in snapshot.bools { defaults.set(value, forKey: key) }
        for key in snapshot.absent { defaults.removeObject(forKey: key) }
        backdrop.update { $0.source = PlayerBackdropSource(rawValue: snapshot.backdropSource) ?? .defaultValue }
        defaults.removeObject(forKey: NowPlayingStylePresetSnapshot.storageKey)
    }

    static func snapshot(defaults: UserDefaults, backdrop: PlayerBackdropSettingsStore) -> NowPlayingStylePresetSnapshot {
        var snapshot = NowPlayingStylePresetSnapshot(backdropSource: backdrop.settings.source.rawValue)
        for key in touchedKeys {
            switch defaults.object(forKey: key) {
            case let string as String: snapshot.strings[key] = string
            case let bool as Bool: snapshot.bools[key] = bool
            default: snapshot.absent.append(key)
            }
        }
        return snapshot
    }
}

/// 一键套用那一节:两行预设,正好是哪一套就打勾;套用过就多一行「恢复套用前的样子」。
private struct NowPlayingStylePresetSection: View {
    // 下面这几项变了要重新判断打不打勾,所以都挂在这里。
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(PlayerAppearancePreferences.playButtonStyleKey) private var playStyle = ""
    @AppStorage(PlayerAppearancePreferences.skipButtonStyleKey) private var skipStyle = ""
    @AppStorage(PlayerAppearancePreferences.showsAlbumInSubtitleKey)
    private var showsAlbum = PlayerAppearancePreferences.showsAlbumInSubtitleByDefault
    @AppStorage(PlayerAppearancePreferences.showsVolumeBarKey)
    private var showsVolumeBar = PlayerAppearancePreferences.showsVolumeBarByDefault
    @AppStorage(PlayerAppearancePreferences.volumeBarStyleKey) private var volumeStyle = ""
    @AppStorage(PlayerAppearancePreferences.progressStyleKey) private var progressStyle = ""
    @AppStorage(PlayerAppearancePreferences.progressGlowKey)
    private var progressGlows = PlayerAppearancePreferences.progressGlowByDefault
    @AppStorage(PlayerAppearancePreferences.controlTintKey) private var controlTint = ""
    @AppStorage(PlayerAppearancePreferences.artworkStyleKey) private var artworkStyle = ""
    @AppStorage(PlayerAppearancePreferences.showsArtworkLyricsKey)
    private var showsArtworkLyrics = PlayerAppearancePreferences.showsArtworkLyricsByDefault
    @AppStorage(NowPlayingStylePresetSnapshot.storageKey) private var snapshot = ""
    @State private var backdrop = PlayerBackdropSettingsStore.shared
    @State private var pendingPreset: NowPlayingStylePreset?

    var body: some View {
        // 只为让上面这些值参与这一次重画。
        let _ = (storage, playStyle, skipStyle, showsAlbum, showsVolumeBar, volumeStyle,
                 progressStyle, progressGlows, controlTint, artworkStyle, showsArtworkLyrics)
        let source = backdrop.settings.source
        Section {
            presetRow(.concise, backdropSource: source)
                .settingsAnchor("appearance.playerStylePresets")
            presetRow(.standard, backdropSource: source)

            if !snapshot.isEmpty {
                Button {
                    NowPlayingStylePresetApplier.restore(backdrop: backdrop)
                } label: {
                    Label("player_style_preset_restore", systemImage: "arrow.uturn.backward")
                }
            }
        } header: {
            Text("player_style_presets_title")
        } footer: {
            Text("player_style_presets_footer")
        }
        .alert(
            Text("player_style_preset_confirm_title \(pendingPreset.map { String(localized: String.LocalizationValue($0.titleKey)) } ?? "")"),
            isPresented: Binding(
                get: { pendingPreset != nil },
                set: { if !$0 { pendingPreset = nil } }
            ),
            presenting: pendingPreset
        ) { preset in
            Button("player_style_preset_apply") {
                NowPlayingStylePresetApplier.apply(preset, backdrop: backdrop)
                pendingPreset = nil
            }
            Button("cancel", role: .cancel) { pendingPreset = nil }
        } message: { _ in
            Text("player_style_preset_confirm_message")
        }
    }

    private func presetRow(_ preset: NowPlayingStylePreset, backdropSource: PlayerBackdropSource) -> some View {
        let isCurrent = preset.matches(defaults: .standard, backdropSource: backdropSource)
        return Button {
            pendingPreset = preset
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey(preset.titleKey))
                        .foregroundStyle(.primary)
                    Text(preset.descriptionKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
#endif
