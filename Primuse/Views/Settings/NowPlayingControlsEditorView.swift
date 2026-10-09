#if os(iOS)
import PrimuseKit
import SwiftUI

/// 设置 › 播放器 › 播放页按钮。分音乐、有声书、播客三页:
/// - 音乐:一张缩小的播放页,虚线框就是能换的六个位置,点一下挑按钮;没放上去的都在「更多」里。
///   最底下那行状态显示哪几项也在这里。
/// - 有声书、播客:那一排功能块的显隐与顺序,以及喜欢、文字稿键与上一章 / 下一章。
/// 配置经 iCloud 同步(`InterfaceLayoutSync`)。
struct NowPlayingControlsEditorView: View {
    private enum Page: String, CaseIterable, Identifiable {
        case music
        case audiobook
        case podcast

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .music: "listening_space_music"
            case .audiobook: "listening_space_spoken_word"
            case .podcast: "listening_space_podcast"
            }
        }
    }

    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .audiobook)) private var audiobookStorage = ""
    @AppStorage(SpokenWordControlLayout.storageKey(for: .podcast)) private var podcastStorage = ""
    @State private var page: Page = Self.initialPage
    @State private var editingSlot: NowPlayingControlSlot?

    #if DEBUG
    /// 取证用:`PRIMUSE_DEBUG_PLAYER_CONTROLS=music|audiobook|podcast` 时从设置 › 播放器直接推进这一页并停在那一栏。
    static let debugPage = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_PLAYER_CONTROLS"]
    private static var initialPage: Page { debugPage.flatMap(Page.init(rawValue:)) ?? .music }
    #else
    private static var initialPage: Page { .music }
    #endif

    private var layout: NowPlayingControlLayout { .decode(storage) }

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
                musicSections
            case .audiobook:
                SpokenWordControlsSections(kind: .audiobook, storage: $audiobookStorage)
            case .podcast:
                SpokenWordControlsSections(kind: .podcast, storage: $podcastStorage)
            }
        }
        .navigationTitle("player_controls_title")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingSlot) { slot in
            NowPlayingControlPicker(slot: slot, layout: layout) { action in
                storage = layout.placing(action, in: slot).encoded()
                editingSlot = nil
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private var musicSections: some View {
            Section {
                NowPlayingControlsPreview(layout: layout, selectedSlot: editingSlot) { editingSlot = $0 }
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
            }
    }

    private func statusBinding(_ item: NowPlayingStatusItem) -> Binding<Bool> {
        Binding(
            get: { layout.showsStatusItem(item) },
            set: { storage = layout.settingStatusItem(item, visible: $0).encoded() }
        )
    }
}

// MARK: - 有声书、播客

/// 有声书或播客播放页:那一排功能块(按住拖动排序、开关显隐),以及几个单独的按钮开关。
private struct SpokenWordControlsSections: View {
    let kind: SpokenWordPlayerKind
    @Binding var storage: String

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
            Button("player_controls_reset") {
                storage = ""
            }
            .disabled(layout.isDefault)
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
                    placeholderLine(width: 92, height: 9)
                    placeholderLine(width: 64, height: 7)
                }
                Spacer(minLength: 0)
                slotButton(.header)
                fixedIcon("ellipsis")
            }
            .padding(.top, 14)

            VStack(spacing: 4) {
                Capsule().fill(.quaternary).frame(height: 4)
                HStack {
                    placeholderLine(width: 18, height: 5)
                    Spacer()
                    placeholderLine(width: 18, height: 5)
                }
            }
            .padding(.top, 10)

            HStack(spacing: 0) {
                slotButton(.leadingEdge)
                Spacer(minLength: 0)
                fixedIcon("backward.fill", size: 17)
                Spacer(minLength: 0)
                fixedIcon("play.circle.fill", size: 34)
                Spacer(minLength: 0)
                fixedIcon("forward.fill", size: 17)
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
        .padding(.horizontal, 18)
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

    private func slotButton(_ slot: NowPlayingControlSlot) -> some View {
        let action = layout.action(in: slot)
        let isSelected = selectedSlot == slot
        return Button { onSelect(slot) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear))
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                Image(systemName: action?.editorSymbol ?? "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(action == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(slot.editorTitleKey))
        .accessibilityValue(Text(action?.editorTitleKey ?? "player_controls_empty"))
        .accessibilityHint(Text("player_controls_slot_hint"))
    }

    private func fixedIcon(_ symbol: String, size: CGFloat = 14) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: max(size, 26), height: 34)
            .accessibilityHidden(true)
    }

    private func placeholderLine(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
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
                placeholderLine(width: 22, height: 4)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(height: 14)
        .accessibilityHidden(true)
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
#endif
