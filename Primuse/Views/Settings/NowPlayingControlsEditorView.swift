#if os(iOS)
import PrimuseKit
import SwiftUI

/// 设置 › 播放器 › 播放页按钮。分音乐、有声书、播客、电台四页:
/// - 音乐:封面、歌词、全屏歌词、全屏效果四种界面,各一张缩小的示意,虚线框就是能换的位置,
///   点一下挑按钮;没放上去的都在「更多」里。最底下那行状态显示哪几项也在封面那一页。
/// - 有声书、播客:那一排功能块的显隐与顺序,喜欢、文字稿键与上一章 / 下一章,上滑文字稿时收不收控件。
/// - 电台:最下面那一排的顺序与显隐,以及音量条。
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
    }

    /// 音乐播放页的几种界面。
    private enum MusicSurface: String, CaseIterable, Identifiable {
        case cover
        case lyrics
        case immersiveLyrics
        case effect

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .cover: "player_controls_surface_cover"
            case .lyrics: "player_controls_surface_lyrics"
            case .immersiveLyrics: "player_controls_surface_immersive_lyrics"
            case .effect: "player_controls_surface_effect"
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
    @State private var page: Page = Self.initialPage
    @State private var surface: MusicSurface = Self.initialSurface
    @State private var editing: NowPlayingControlEditingTarget?

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

    var body: some View {
        Form {
            Section {
                Picker(selection: $page) {
                    ForEach(Page.allCases) { page in
                        Text(page.titleKey).tag(page)
                    }
                } label: {
                    Text("player_controls_title")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            switch page {
            case .music:
                Section {
                    Picker(selection: $surface) {
                        ForEach(MusicSurface.allCases) { surface in
                            Text(surface.titleKey).tag(surface)
                        }
                    } label: {
                        Text("player_controls_surface_header")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    Text("player_controls_surface_header")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

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
                    collapsesOnScroll: $audiobookTextCollapses
                )
            case .podcast:
                SpokenWordControlsSections(
                    kind: .podcast,
                    storage: $podcastStorage,
                    collapsesOnScroll: $podcastTextCollapses
                )
            case .radio:
                RadioControlsSections(storage: $radioStorage)
            }
        }
        .navigationTitle("player_controls_title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            picker(for: target)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: 封面

    @ViewBuilder
    private var coverSections: some View {
            Section {
                NowPlayingControlsPreview(layout: layout, selectedSlot: editing?.coverSlot) { editing = .cover($0) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } footer: {
                Text("player_controls_footer")
            }

            Section {
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
            }

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
                }
                .disabled(layout.actions == NowPlayingControlLayout.defaultActions)
            } footer: {
                Text("player_controls_duo_footer")
            }
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
            NowPlayingLyricsControlsPreview(
                layout: lyricsLayout,
                headerExtra: controls.headerExtra,
                slotsEditable: controls.usesOwnButtons,
                selected: editing
            ) { editing = $0 }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } footer: {
            Text(controls.usesOwnButtons
                ? LocalizedStringKey("player_controls_lyrics_preview_footer_own")
                : LocalizedStringKey("player_controls_lyrics_preview_footer_follow"))
        }

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
            NowPlayingImmersiveControlsPreview(
                controls: immersiveControls,
                header: lyricsLayout.action(in: .header),
                selected: editing?.immersiveSlot
            ) { editing = .immersive($0) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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

    // MARK: 全屏效果

    @ViewBuilder
    private var effectSections: some View {
        Section {
            NowPlayingEffectControlsPreview(
                controls: effectControls,
                selected: editing?.effectSlot
            ) { editing = .effect($0) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
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

    // MARK: 挑按钮

    @ViewBuilder
    private func picker(for target: NowPlayingControlEditingTarget) -> some View {
        switch target {
        case .cover(let slot):
            NowPlayingControlPicker(slot: slot, layout: layout) { action in
                storage = layout.placing(action, in: slot).encoded()
                editing = nil
            }
        case .lyrics(let slot):
            let controls = lyricsControls
            NowPlayingControlPicker(slot: slot, layout: controls.ownButtons) { action in
                lyricsStorage = controls.placingOwnButton(action, in: slot).encoded()
                editing = nil
            }
        case .lyricsExtra:
            let controls = lyricsControls
            NowPlayingSlotChoicePicker(
                title: "player_controls_slot_lyrics_extra",
                choices: Self.choices(
                    allowing: NowPlayingLyricsPageControls.allowsHeaderExtra,
                    followsHeader: false
                ),
                current: controls.headerExtra.map(NowPlayingSlotChoice.action) ?? .empty,
                footer: "player_controls_lyrics_extra_picker_footer"
            ) { choice in
                lyricsStorage = controls.settingHeaderExtra(choice.pickedAction).encoded()
                editing = nil
            }
        case .immersive(let slot):
            let controls = immersiveControls
            let followed = NowPlayingImmersiveLyricsControls.followedHeaderAction(lyricsLayout.action(in: .header))
            NowPlayingSlotChoicePicker(
                title: slot.editorTitleKey,
                choices: Self.choices(
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
                editing = nil
            }
        case .effect(let slot):
            let controls = effectControls
            NowPlayingSlotChoicePicker(
                title: slot.editorTitleKey,
                choices: Self.choices(allowing: NowPlayingEffectPlayerControls.allows, followsHeader: false),
                current: controls.action(in: slot).map(NowPlayingSlotChoice.action) ?? .empty,
                swapTitle: { choice in
                    guard let action = choice.pickedAction else { return nil }
                    return NowPlayingEffectPlayerSlot.allCases
                        .first { $0 != slot && controls.action(in: $0) == action }?.editorTitleKey
                },
                footer: "player_controls_effect_picker_footer"
            ) { choice in
                effectStorage = controls.placing(choice.pickedAction, in: slot).encoded()
                editing = nil
            }
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

/// 正在给哪一格挑按钮。
private enum NowPlayingControlEditingTarget: Identifiable, Hashable {
    case cover(NowPlayingControlSlot)
    case lyrics(NowPlayingControlSlot)
    case lyricsExtra
    case immersive(NowPlayingImmersiveLyricsSlot)
    case effect(NowPlayingEffectPlayerSlot)

    var id: String {
        switch self {
        case .cover(let slot): "cover.\(slot.rawValue)"
        case .lyrics(let slot): "lyrics.\(slot.rawValue)"
        case .lyricsExtra: "lyrics.extra"
        case .immersive(let slot): "immersive.\(slot.rawValue)"
        case .effect(let slot): "effect.\(slot.rawValue)"
        }
    }

    var coverSlot: NowPlayingControlSlot? {
        if case .cover(let slot) = self { return slot }
        return nil
    }

    var immersiveSlot: NowPlayingImmersiveLyricsSlot? {
        if case .immersive(let slot) = self { return slot }
        return nil
    }

    var effectSlot: NowPlayingEffectPlayerSlot? {
        if case .effect(let slot) = self { return slot }
        return nil
    }
}

// MARK: - 有声书、播客

/// 有声书或播客播放页:那一排功能块(按住拖动排序、开关显隐)、几个单独的按钮开关,以及上滑文字稿时收不收控件。
private struct SpokenWordControlsSections: View {
    let kind: SpokenWordPlayerKind
    @Binding var storage: String
    @Binding var collapsesOnScroll: Bool

    private var layout: SpokenWordControlLayout { .decode(storage, kind: kind) }

    var body: some View {
        Section {
            ForEach(layout.order) { tile in
                Toggle(isOn: Binding(
                    get: { layout.isShown(tile) },
                    set: { storage = layout.settingTile(tile, shown: $0).encoded() }
                )) {
                    Label {
                        Text(tile.editorTitleKey(for: kind))
                    } icon: {
                        Image(systemName: tile.editorSymbol(for: kind))
                    }
                }
            }
            .onMove { storage = layout.movingTiles(fromOffsets: $0, toOffset: $1).encoded() }
        } header: {
            Text("player_controls_tiles_header")
        } footer: {
            Text("player_controls_tiles_footer")
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

// MARK: - 电台

/// 电台播放页最下面那一排:按住拖动排序、开关显隐;隔空播放不能关(点了说明原因)。另有音量条开关。
private struct RadioControlsSections: View {
    @Binding var storage: String
    @State private var showsAirPlayNote = false

    private var layout: NowPlayingRadioControlLayout { .decode(storage) }

    var body: some View {
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

// MARK: - 「更多」菜单

/// 音乐播放页「更多」菜单里哪些项出现(#198)。按菜单里的分组排,关掉的项不再出现;
/// 页面按钮缺了时补进菜单的喜欢、歌词、队列、随机、循环不在这里,那是兜底入口。
private struct NowPlayingMenuItemsEditor: View {
    @Binding var storage: String

    private var layout: NowPlayingControlLayout { .decode(storage) }

    private static let groups: [(LocalizedStringKey, [NowPlayingMenuItem])] = [
        ("player_menu_group_quick", [.fullScreen, .share, .addToPlaylist, .delete]),
        ("player_menu_group_modes", [.karaoke, .medley]),
        ("player_menu_group_song", [.scrape, .reloadLyrics, .similarSongs, .dislike, .playbackRange, .editTags, .editLyrics]),
        ("player_menu_group_go", [.songInfo, .goToAlbum, .goToArtist, .openInAppleMusic]),
        ("player_menu_group_playback", [.cast, .lyricsDisplay, .lyricsMotion, .sleepTimer, .equalizer, .playbackSpeed]),
    ]

    var body: some View {
        Form {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group.1) { item in
                        Toggle(isOn: Binding(
                            get: { layout.showsMenuItem(item) },
                            set: { storage = layout.settingMenuItem(item, visible: $0).encoded() }
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
                Button("player_menu_items_show_all") {
                    storage = layout.showingAllMenuItems().encoded()
                }
                .disabled(layout.hiddenMenuItems.isEmpty)
            } footer: {
                Text("player_menu_items_footer")
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
        }
    }
}

// MARK: - 缩小的播放页

/// 竖屏音乐播放页的示意:封面、歌名、进度、传输键、底栏与状态行。固定不动的部分画淡,
/// 能换的六个位置画成虚线框,里面是此刻放的按钮(空着时是一个加号)。
private struct NowPlayingControlsPreview: View {
    let layout: NowPlayingControlLayout
    let selectedSlot: NowPlayingControlSlot?
    let onSelect: (NowPlayingControlSlot) -> Void

    private let width: CGFloat = 236

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 30, height: 4)
                .padding(.top, 10)

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.tint.opacity(0.18))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.tint.opacity(0.55))
                }
                .frame(width: width - 64, height: width - 64)
                .padding(.top, 16)

            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    EditorPlaceholderLine(width: 92, height: 9)
                    EditorPlaceholderLine(width: 64, height: 7)
                }
                Spacer(minLength: 0)
                slotButton(.header)
                EditorFixedIcon(symbol: "ellipsis")
            }
            .padding(.top, 14)

            EditorProgressLine()
                .padding(.top, 10)

            HStack(spacing: 0) {
                slotButton(.leadingEdge)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "backward.fill", size: 17)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "play.circle.fill", size: 34)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "forward.fill", size: 17)
                Spacer(minLength: 0)
                slotButton(.trailingEdge)
            }
            .padding(.top, 8)

            HStack(spacing: 0) {
                slotButton(.barLeading)
                Spacer(minLength: 0)
                slotButton(.barCenter)
                Spacer(minLength: 0)
                slotButton(.barTrailing)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            statusLine
                .padding(.top, 6)
                .padding(.bottom, 12)
        }
        .editorPhoneFrame(width: width)
    }

    private func slotButton(_ slot: NowPlayingControlSlot) -> some View {
        let action = layout.action(in: slot)
        return EditorSlotButton(
            symbol: action?.editorSymbol,
            isSelected: selectedSlot == slot,
            title: slot.editorTitleKey,
            value: action?.editorTitleKey ?? "player_controls_empty"
        ) { onSelect(slot) }
    }

    /// 最底下那行:关掉的项不写,全关了就空着一行。
    private var statusLine: some View {
        let items: [(item: NowPlayingStatusItem, symbol: String)] = [
            (item: .source, symbol: "externaldrive"),
            (item: .output, symbol: "headphones"),
            (item: .sleepTimer, symbol: "moon.zzz.fill"),
        ]
        let shown = items.filter { layout.showsStatusItem($0.item) }
        return HStack(spacing: 5) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text(verbatim: "·")
                }
                Image(systemName: entry.symbol)
                    .imageScale(.small)
                EditorPlaceholderLine(width: 22, height: 4)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// 竖屏看歌词的示意:顶上小封面与歌名、歌词页多出来那一格、歌名旁那一格和更多,中间几行歌词,
/// 下面进度、传输键与底栏。没单独设置时六个位置跟封面界面一样,只画不让点(多出来那一格总能换)。
private struct NowPlayingLyricsControlsPreview: View {
    let layout: NowPlayingControlLayout
    let headerExtra: NowPlayingControlAction?
    let slotsEditable: Bool
    let selected: NowPlayingControlEditingTarget?
    let onSelect: (NowPlayingControlEditingTarget) -> Void

    private let width: CGFloat = 236

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 30, height: 4)
                .padding(.top, 10)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.tint.opacity(0.22))
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    EditorPlaceholderLine(width: 54, height: 7)
                    EditorPlaceholderLine(width: 38, height: 5)
                }
                Spacer(minLength: 0)
                EditorSlotButton(
                    symbol: headerExtra?.editorSymbol,
                    isSelected: selected == .lyricsExtra,
                    title: "player_controls_slot_lyrics_extra",
                    value: headerExtra?.editorTitleKey ?? "player_controls_empty"
                ) { onSelect(.lyricsExtra) }
                slotButton(.header)
                EditorFixedIcon(symbol: "ellipsis", size: 13, width: 20)
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 9) {
                EditorPlaceholderLine(width: 150, height: 8)
                Capsule()
                    .fill(.tint.opacity(0.6))
                    .frame(width: 176, height: 11)
                    .accessibilityHidden(true)
                EditorPlaceholderLine(width: 128, height: 8)
                EditorPlaceholderLine(width: 160, height: 8)
                EditorPlaceholderLine(width: 96, height: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)
            .padding(.bottom, 14)

            EditorProgressLine()

            HStack(spacing: 0) {
                slotButton(.leadingEdge)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "backward.fill", size: 17)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "play.circle.fill", size: 34)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "forward.fill", size: 17)
                Spacer(minLength: 0)
                slotButton(.trailingEdge)
            }
            .padding(.top, 8)

            HStack(spacing: 0) {
                slotButton(.barLeading)
                Spacer(minLength: 0)
                slotButton(.barCenter)
                Spacer(minLength: 0)
                slotButton(.barTrailing)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .editorPhoneFrame(width: width)
    }

    private func slotButton(_ slot: NowPlayingControlSlot) -> some View {
        let action = layout.action(in: slot)
        return EditorSlotButton(
            symbol: action?.editorSymbol,
            isSelected: selected == .lyrics(slot),
            isEditable: slotsEditable,
            title: slot.editorTitleKey,
            value: action?.editorTitleKey ?? "player_controls_empty"
        ) { onSelect(.lyrics(slot)) }
    }
}

/// 全屏歌词的示意:顶上锁、全屏效果、能换的两格、更多与退出,中间放大的歌词,底下播放条两侧各一格。
private struct NowPlayingImmersiveControlsPreview: View {
    let controls: NowPlayingImmersiveLyricsControls
    /// 看歌词时歌名旁那一格(「跟歌名旁」画成它)。
    let header: NowPlayingControlAction?
    let selected: NowPlayingImmersiveLyricsSlot?
    let onSelect: (NowPlayingImmersiveLyricsSlot) -> Void

    private let width: CGFloat = 236

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                EditorFixedIcon(symbol: "lock", size: 12, width: 22)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "viewfinder.rectangular", size: 12, width: 22)
                slotButton(.topPrimary)
                slotButton(.topSecondary)
                EditorFixedIcon(symbol: "ellipsis", size: 12, width: 22)
                EditorFixedIcon(symbol: "arrow.down.right.and.arrow.up.left", size: 12, width: 22)
            }
            .padding(.top, 14)

            VStack(alignment: .leading, spacing: 12) {
                EditorPlaceholderLine(width: 140, height: 10)
                Capsule()
                    .fill(.tint.opacity(0.6))
                    .frame(width: 178, height: 15)
                    .accessibilityHidden(true)
                EditorPlaceholderLine(width: 150, height: 10)
                EditorPlaceholderLine(width: 112, height: 10)
                EditorPlaceholderLine(width: 160, height: 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 30)

            VStack(spacing: 6) {
                Capsule().fill(.quaternary).frame(height: 4)
                HStack(spacing: 0) {
                    slotButton(.dockLeading)
                    Spacer(minLength: 0)
                    EditorFixedIcon(symbol: "backward.fill", size: 15)
                    Spacer(minLength: 0)
                    EditorFixedIcon(symbol: "play.circle.fill", size: 30)
                    Spacer(minLength: 0)
                    EditorFixedIcon(symbol: "forward.fill", size: 15)
                    Spacer(minLength: 0)
                    slotButton(.dockTrailing)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.bottom, 16)
        }
        .editorPhoneFrame(width: width, horizontalPadding: 12)
    }

    private func slotButton(_ slot: NowPlayingImmersiveLyricsSlot) -> some View {
        let choice = controls.choice(in: slot)
        let shown: NowPlayingControlAction? = switch choice {
        case .followHeader: NowPlayingImmersiveLyricsControls.followedHeaderAction(header)
        case .action(let action): action
        case .empty: nil
        }
        return EditorSlotButton(
            symbol: shown?.editorSymbol,
            isSelected: selected == slot,
            isLinked: choice == .followHeader,
            title: slot.editorTitleKey,
            value: choice == .followHeader
                ? "player_controls_follow_header"
                : (shown?.editorTitleKey ?? "player_controls_empty")
        ) { onSelect(slot) }
    }
}

/// 全屏效果页的示意:顶上收起与效果抽屉、右上角那一格,中间舞台,底下播放胶囊两侧各一格。
private struct NowPlayingEffectControlsPreview: View {
    let controls: NowPlayingEffectPlayerControls
    let selected: NowPlayingEffectPlayerSlot?
    let onSelect: (NowPlayingEffectPlayerSlot) -> Void

    private let width: CGFloat = 236

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                EditorFixedIcon(symbol: "chevron.down", size: 12, width: 24)
                Spacer(minLength: 0)
                EditorFixedIcon(symbol: "viewfinder.rectangular", size: 12, width: 24)
                slotButton(.topTrailing)
            }
            .padding(.top, 14)

            ZStack {
                Circle()
                    .fill(.tint.opacity(0.12))
                    .frame(width: 170, height: 170)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.tint.opacity(0.24))
                    .frame(width: 118, height: 118)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.tint.opacity(0.6))
                    }
            }
            .padding(.vertical, 26)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                slotButton(.pillLeading)
                EditorFixedIcon(symbol: "backward.fill", size: 14, width: 24)
                EditorFixedIcon(symbol: "play.circle", size: 26, width: 32)
                EditorFixedIcon(symbol: "forward.fill", size: 14, width: 24)
                slotButton(.pillTrailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .padding(.bottom, 18)
        }
        .editorPhoneFrame(width: width, horizontalPadding: 12)
    }

    private func slotButton(_ slot: NowPlayingEffectPlayerSlot) -> some View {
        let action = controls.action(in: slot)
        return EditorSlotButton(
            symbol: action?.editorSymbol,
            isSelected: selected == slot,
            title: slot.editorTitleKey,
            value: action?.editorTitleKey ?? "player_controls_empty"
        ) { onSelect(slot) }
    }
}

// MARK: 示意图的零件

/// 一个能换的位置:虚线框,里面是此刻放的按钮(空着时是加号)。不让换时只画、画淡,不响应。
/// `isLinked` 是「跟歌名旁那一格」,右下角挂一个小链子。
private struct EditorSlotButton: View {
    let symbol: String?
    let isSelected: Bool
    var isEditable = true
    var isLinked = false
    let title: LocalizedStringKey
    let value: LocalizedStringKey
    let onSelect: () -> Void

    var body: some View {
        if isEditable {
            Button(action: onSelect) { face }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value))
                .accessibilityHint(Text("player_controls_slot_hint"))
        } else {
            face
                .opacity(0.45)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(value))
        }
    }

    private var face: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isEditable ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary),
                    style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5])
                )
            Image(systemName: symbol ?? "plus")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(symbol == nil || !isEditable ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
        }
        .frame(width: 34, height: 34)
        .overlay(alignment: .bottomTrailing) {
            if isLinked {
                Image(systemName: "link")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.tint)
                    .padding(2)
                    .background(Circle().fill(Color(uiColor: .systemBackground)))
                    .offset(x: 3, y: 3)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct EditorFixedIcon: View {
    let symbol: String
    var size: CGFloat = 14
    var width: CGFloat?

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: width ?? max(size, 26), height: 34)
            .accessibilityHidden(true)
    }
}

private struct EditorPlaceholderLine: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
    }
}

/// 进度条与两端的时间。
private struct EditorProgressLine: View {
    var body: some View {
        VStack(spacing: 4) {
            Capsule().fill(.quaternary).frame(height: 4)
            HStack {
                EditorPlaceholderLine(width: 18, height: 5)
                Spacer()
                EditorPlaceholderLine(width: 18, height: 5)
            }
        }
        .accessibilityHidden(true)
    }
}

private extension View {
    /// 缩小的手机外框。
    func editorPhoneFrame(width: CGFloat, horizontalPadding: CGFloat = 18) -> some View {
        padding(.horizontal, horizontalPadding)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(.quaternary, lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
    }
}

// MARK: - 挑按钮

/// 给一个位置挑按钮。已经在别的位置上的按钮选了就两格对调;隔空播放只能挪、不能拿掉,
/// 也不放在播放键两侧。不能选的项照样能点,点了说明原因。
private struct NowPlayingControlPicker: View {
    let slot: NowPlayingControlSlot
    let layout: NowPlayingControlLayout
    let onPick: (NowPlayingControlAction?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var blockedReason: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row(nil)
                    ForEach(NowPlayingControlAction.allCases) { action in
                        row(action)
                    }
                } footer: {
                    Text("player_controls_picker_footer")
                }
            }
            .navigationTitle(Text(slot.editorTitleKey))
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
        let isCurrent = layout.action(in: slot) == action
        let isAllowed = layout.canPlace(action, in: slot)
        let otherSlot = action.flatMap { layout.slot(of: $0) }.flatMap { $0 == slot ? nil : $0 }
        return Button {
            if isAllowed {
                onPick(action)
            } else {
                blockedReason = blockedReasonKey(for: action)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action?.editorSymbol ?? "circle.dashed")
                    .font(.body)
                    .foregroundStyle(isAllowed ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 28)
                Text(action?.editorTitleKey ?? "player_controls_empty")
                    .foregroundStyle(isAllowed ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
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

    private func blockedReasonKey(for action: NowPlayingControlAction?) -> LocalizedStringKey {
        if action == .airPlay, slot.isTransportEdge {
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
        }
    }

    func editorTitleKey(for kind: SpokenWordPlayerKind) -> LocalizedStringKey {
        switch self {
        case .speed: "spoken_word_speed_short"
        case .sleepTimer: "sleep_timer"
        case .bookmark: "spoken_word_bookmarks_title"
        case .contents: kind == .podcast ? "podcast_show_notes" : "spoken_word_contents_title"
        case .upNext: "up_next"
        }
    }
}

extension NowPlayingControlSlot {
    var editorTitleKey: LocalizedStringKey {
        switch self {
        case .header: "player_controls_slot_header"
        case .leadingEdge: "player_controls_slot_leading_edge"
        case .trailingEdge: "player_controls_slot_trailing_edge"
        case .barLeading: "player_controls_slot_bar_leading"
        case .barCenter: "player_controls_slot_bar_center"
        case .barTrailing: "player_controls_slot_bar_trailing"
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
#endif
