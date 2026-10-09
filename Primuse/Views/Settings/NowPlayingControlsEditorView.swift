#if os(iOS)
import PrimuseKit
import SwiftUI

/// 设置 › 播放器 › 播放页按钮:音乐播放页上六个位置各放哪颗按钮,以及最底下那行状态显示哪几项。
/// 上面是一张缩小的播放页,虚线框就是能换的位置,点一下挑按钮;没放上去的都在「更多」里。
/// 配置经 iCloud 同步(`InterfaceLayoutSync`),有声书与播客的播放页不受影响。
struct NowPlayingControlsEditorView: View {
    @AppStorage(NowPlayingControlLayout.musicStorageKey) private var storage = ""
    @State private var editingSlot: NowPlayingControlSlot?

    private var layout: NowPlayingControlLayout { .decode(storage) }

    var body: some View {
        Form {
            Section {
                NowPlayingControlsPreview(layout: layout, selectedSlot: editingSlot) { editingSlot = $0 }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            } footer: {
                Text("player_controls_footer")
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

    private func statusBinding(_ item: NowPlayingStatusItem) -> Binding<Bool> {
        Binding(
            get: { layout.showsStatusItem(item) },
            set: { storage = layout.settingStatusItem(item, visible: $0).encoded() }
        )
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
