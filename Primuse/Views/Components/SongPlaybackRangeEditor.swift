import SwiftUI
import PrimuseKit

/// 「播放时间段」在菜单里的样子:设过时间段时是一个开关(标题下面写着时间段)
/// 加一项「编辑」,一点就能开关;没设过时只有「设置播放时间段…」。
/// 读写都走 `SongPlaybackRangeStore`,不依赖环境,菜单放在单独的宿主里也能用。
struct SongPlaybackRangeMenuItems: View {
    let song: Song
    let onEdit: () -> Void

    var body: some View {
        let store = SongPlaybackRangeStore.shared
        if SongPlaybackRangeAvailability.supports(song) {
            if let range = store.range(for: song) {
                Toggle(isOn: Binding(
                    get: { range.isEnabled },
                    set: { store.setEnabled($0, for: song) }
                )) {
                    Label {
                        Text("playback_range_title")
                        Text(verbatim: SongPlaybackRangePolicy.rangeLabel(range))
                    } icon: {
                        Image(systemName: "selection.pin.in.out")
                    }
                }
                Button(action: onEdit) {
                    Label(String(localized: "playback_range_edit"), systemImage: "slider.horizontal.3")
                }
            } else {
                Button(action: onEdit) {
                    Label(String(localized: "playback_range_set"), systemImage: "selection.pin.in.out")
                }
            }
        }
    }
}

/// 设置一首歌的播放时间段。开关和时间段放在同一张卡片里:开关下面直接写着
/// 时间段与时长;拖动把手、微调或「设为当前位置」都会顺手把开关打开,
/// 关掉开关只是暂时整首播放,时间段还留着。每一步都立刻存下,正在播的就是
/// 这首歌时播放器随即按新的时间段接着播。
struct SongPlaybackRangeEditor: View {
    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss

    private let song: Song
    @State private var draft: SongPlaybackRange
    @State private var hasStoredRange: Bool

    init(song: Song) {
        let whole = song.withoutAppliedPlaybackRange
        self.song = whole
        let stored = SongPlaybackRangeStore.shared.range(for: whole)
        _draft = State(initialValue: stored ?? SongPlaybackRangePolicy.initialRange(songDuration: whole.duration))
        _hasStoredRange = State(initialValue: stored != nil)
    }

    private var isCurrentSong: Bool { player.currentSong?.id == song.id }

    /// 曲库里记的时长;还没有时用播放器这次量到的。
    private var songDuration: TimeInterval {
        if song.duration > 0 { return song.duration }
        if isCurrentSong, let current = player.currentSong {
            let whole = current.withoutAppliedPlaybackRange.duration
            return whole > 0 ? whole : player.duration
        }
        return 0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if songDuration > 0 {
                        rangeCard
                        if isCurrentSong { previewButtons }
                        Text("playback_range_footer")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if hasStoredRange {
                            Button(role: .destructive, action: clear) {
                                Label(String(localized: "playback_range_clear"), systemImage: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Text("playback_range_unknown_duration")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("playback_range_title"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) { dismiss() }
                }
            }
        }
        .onAppear {
            // 曲库里还没有时长、打开时才从播放器知道的那种,结束点补成整首。
            if draft.end <= 0, songDuration > 0 {
                draft = SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, idealWidth: 500, minHeight: 420, idealHeight: 460)
        #else
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(song.title)
                .font(.headline)
                .lineLimit(2)
            if let artist = song.artistName, !artist.isEmpty {
                Text(artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var summary: String {
        String(
            format: String(localized: "playback_range_summary %@ %@"),
            SongPlaybackRangePolicy.rangeLabel(draft, showsTenths: true),
            SongPlaybackRangePolicy.timeLabel(draft.length, showsTenths: true)
        )
    }

    private var rangeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(
                get: { draft.isEnabled },
                set: { enabled in
                    draft.isEnabled = enabled
                    commit(enabling: false)
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("playback_range_toggle")
                        .font(.body.weight(.semibold))
                    Text(verbatim: summary)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            SongPlaybackRangeTrack(
                range: $draft,
                songDuration: songDuration,
                playhead: isCurrentSong ? player.currentTime : nil,
                onCommit: { commit() }
            )

            edgeRow(.start)
            edgeRow(.end)
        }
        .padding(16)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func edgeRow(_ edge: SongPlaybackRangePolicy.Edge) -> some View {
        let value = edge == .start ? draft.start : draft.end
        let title = edge == .start
            ? String(localized: "playback_range_start")
            : String(localized: "playback_range_end")
        return HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 40, alignment: .leading)
            Button {
                move(edge, to: value - SongPlaybackRangePolicy.nudgeStep)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 16, height: 16)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel(Text("playback_range_nudge_earlier"))
            Text(verbatim: SongPlaybackRangePolicy.timeLabel(value, showsTenths: true))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64)
                .accessibilityLabel(Text(verbatim: title))
            Button {
                move(edge, to: value + SongPlaybackRangePolicy.nudgeStep)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .buttonRepeatBehavior(.enabled)
            .accessibilityLabel(Text("playback_range_nudge_later"))
            Spacer(minLength: 4)
            if isCurrentSong {
                Button {
                    // 十分之一秒够准,也不会把 2:03.4567 这种数显示出来。
                    move(edge, to: (player.currentTime * 10).rounded() / 10)
                } label: {
                    Label(String(localized: "playback_range_set_to_current"), systemImage: "scope")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var previewButtons: some View {
        HStack(spacing: 10) {
            Button {
                player.seek(to: draft.start, startPlaying: true)
            } label: {
                Label(String(localized: "playback_range_preview_start"), systemImage: "play.fill")
            }
            Button {
                player.seek(to: max(draft.start, draft.end - 5), startPlaying: true)
            } label: {
                Label(String(localized: "playback_range_preview_end"), systemImage: "forward.end.fill")
            }
        }
        .buttonStyle(.bordered)
    }

    private func move(_ edge: SongPlaybackRangePolicy.Edge, to value: TimeInterval) {
        draft = SongPlaybackRangePolicy.moving(edge, of: draft, to: value, songDuration: songDuration)
        commit()
    }

    /// 存下草稿。调整时间段默认就是要用它,所以顺手打开开关。
    private func commit(enabling: Bool = true) {
        if enabling { draft.isEnabled = true }
        SongPlaybackRangeStore.shared.setRange(draft, for: song)
        hasStoredRange = true
    }

    private func clear() {
        SongPlaybackRangeStore.shared.clearRange(for: song)
        draft = SongPlaybackRangePolicy.initialRange(songDuration: songDuration)
        hasStoredRange = false
    }
}

/// 整首歌的时间轴,两个把手框出播放时间段;正在播这首时画出播放头。
/// 拖动按整秒吸附,松手才存;读屏可以用上下滑逐秒调整。
struct SongPlaybackRangeTrack: View {
    @Binding var range: SongPlaybackRange
    let songDuration: TimeInterval
    let playhead: TimeInterval?
    let onCommit: () -> Void

    private let handleSize: CGFloat = 22
    private let hitSize: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let usable = max(1, geometry.size.width - handleSize)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.14))
                    .frame(width: usable, height: 6)
                    .offset(x: handleSize / 2)
                Capsule()
                    .fill(range.isEnabled ? Color.accentColor : Color.secondary.opacity(0.6))
                    .frame(width: max(0, position(range.end, usable) - position(range.start, usable)), height: 6)
                    .offset(x: position(range.start, usable))
                if let playhead, playhead.isFinite {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: 18)
                        .offset(x: position(min(max(0, playhead), songDuration), usable) - 1)
                        .accessibilityHidden(true)
                }
                handle(.start, usable: usable)
                handle(.end, usable: usable)
            }
            .frame(height: hitSize)
            .coordinateSpace(name: Self.coordinateSpace)
        }
        .frame(height: hitSize)
    }

    private static let coordinateSpace = "playbackRangeTrack"

    private func position(_ time: TimeInterval, _ usable: CGFloat) -> CGFloat {
        guard songDuration > 0 else { return handleSize / 2 }
        return handleSize / 2 + CGFloat(time / songDuration) * usable
    }

    private func handle(_ edge: SongPlaybackRangePolicy.Edge, usable: CGFloat) -> some View {
        let value = edge == .start ? range.start : range.end
        let title = edge == .start
            ? String(localized: "playback_range_start")
            : String(localized: "playback_range_end")
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(range.isEnabled ? Color.accentColor : Color.secondary, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: handleSize, height: handleSize)
            .frame(width: hitSize, height: hitSize)
            .contentShape(Rectangle())
            .offset(x: position(value, usable) - hitSize / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
                    .onChanged { drag in
                        let fraction = Double((drag.location.x - handleSize / 2) / usable)
                        let raw = fraction * songDuration
                        let step = SongPlaybackRangePolicy.dragStep
                        range = SongPlaybackRangePolicy.moving(
                            edge,
                            of: range,
                            to: (raw / step).rounded() * step,
                            songDuration: songDuration
                        )
                    }
                    .onEnded { _ in onCommit() }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(verbatim: title))
            .accessibilityValue(Text(verbatim: SongPlaybackRangePolicy.timeLabel(value, showsTenths: true)))
            .accessibilityAdjustableAction { direction in
                let step = SongPlaybackRangePolicy.nudgeStep
                switch direction {
                case .increment:
                    range = SongPlaybackRangePolicy.moving(edge, of: range, to: value + step, songDuration: songDuration)
                case .decrement:
                    range = SongPlaybackRangePolicy.moving(edge, of: range, to: value - step, songDuration: songDuration)
                @unknown default:
                    return
                }
                onCommit()
            }
    }
}

/// 播放页进度条上的一道刻度:这首歌开着播放时间段时,标出时间段从哪里开始。
/// 进度条仍是整首歌的时间,开头那一截不会播到。画法与有声书书签刻度一致。
struct SongPlaybackRangeStartTick: View {
    let color: Color
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        if let applied = player.currentSong?.appliedPlaybackRange,
           applied.start > 0, player.duration > 0 {
            let fraction = min(1, applied.start / player.duration)
            GeometryReader { proxy in
                Capsule()
                    .fill(color)
                    .frame(width: 2, height: 9)
                    .position(x: proxy.size.width * fraction, y: proxy.size.height / 2 - 5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

