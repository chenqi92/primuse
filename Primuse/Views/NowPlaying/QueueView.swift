import SwiftUI
import PrimuseKit

struct QueueView: View {
    let player: AudioPlayerService
    /// 嵌在播放页分栏的右栏里(iPhone Duo 内屏):不套导航栈、不带导航栏按钮 ——
    /// 分栏容器里不放导航容器,随机与循环就在旁边的播放器上。
    var isEmbedded = false
    @Environment(MusicLibrary.self) private var library
    // 拖拽预览宿主要用: 行里的 CachedArtworkView 同时读 MusicLibrary 与
    // SourceManager, 两个都得显式带过去。见 queueRow 里的说明。
    @Environment(SourceManager.self) private var sourceManager
    /// 队列以半屏 sheet 呈现, 手机横屏下可视高度只够两行出头, 行距与底部留白收一档。
    @Environment(\.pmHeightClass) private var heightClass
    /// 系统工具栏竖排到侧边时(iPhone Duo)非 nil:随机键带上标题、优先留在竖栏里。
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.dismiss) private var dismiss
    @State private var dropTarget: QueueReorderOccurrenceID?

    var body: some View {
        if isEmbedded {
            content
        } else {
            // 在这里取值再传给工具栏:导航栏条目由独立宿主渲染,不在那里读环境。
            let close = dismiss
            NavigationStack {
                content
                    .navigationTitle("queue_title")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        closeToolbarItem(close)
                        playbackModeToolbarContent(titled: verticalBarEdge != nil)
                    }
            }
        }
    }

    /// 左上角的关闭键:拉到全屏后不必再把手伸到顶上往下拉(#348)。
    @ToolbarContentBuilder
    private func closeToolbarItem(_ close: DismissAction) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                close()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(Text("close"))
        }
    }

    /// 队列页右上角的「随机方式」与「播放方式」两颗键(#338),左上角是关闭键。
    ///
    /// 以前这里只有一颗随机开关,循环要回播放页才能改;现在随机、列表循环、单曲循环与顺序播放合成一颗,
    /// 点一下换下一种,长按直接选。状态就是播放器上那两个开关,和播放页、锁屏、车机是同一份。
    /// 紧挨着它的是抽歌偏好(#332),只在随机时起作用:别的方式下画成灰色,但照样点得开,
    /// 点开先说明、给一颗「打开随机播放」,偏好也能先选好。
    /// 有声书章节、播客单集与电台没有随机和循环这回事,两颗都不出现(播放页上同样不给)。
    /// 只读 `player` 这个存储属性, 不碰 @Environment: 导航栏条目会在转场期间
    /// 由独立的宿主渲染, 在那里读必需的环境值会直接崩。
    @ToolbarContentBuilder
    private func playbackModeToolbarContent(titled: Bool) -> some ToolbarContent {
        if !player.currentItemIsSpokenWord, !player.isLiveRadio {
            if titled {
                // 系统竖栏(iPhone Duo):带上标题(收进系统溢出菜单时要用),空间不够时最后才收。
                shufflePreferenceToolbarItem(titled: true)
                    .pmHighVisibilityPriority()
                playbackModeToolbarItem(titled: true)
                    .pmHighVisibilityPriority()
            } else {
                shufflePreferenceToolbarItem(titled: false)
                playbackModeToolbarItem(titled: false)
            }
        }
    }

    private var playbackMode: PlaybackOrderMode {
        PlaybackOrderMode(shuffleEnabled: player.shuffleEnabled, repeatMode: player.repeatMode)
    }

    /// 队列不到两首时随机打不开(原来的随机键也是这时置灰),轮换和菜单里都跳过它。
    private var allowsShuffle: Bool { player.queueCount >= 2 }

    private func applyPlaybackMode(_ mode: PlaybackOrderMode) {
        let target = mode.settings(from: player.repeatMode)
        if player.repeatMode != target.repeatMode { player.repeatMode = target.repeatMode }
        if player.shuffleEnabled != target.shuffleEnabled { player.shuffleEnabled = target.shuffleEnabled }
    }

    private static func titleKey(for mode: PlaybackOrderMode) -> LocalizedStringKey {
        switch mode {
        case .sequential: "play_mode_sequential"
        case .repeatAll: "play_mode_repeat_all"
        case .repeatOne: "play_mode_repeat_one"
        case .shuffle: "play_mode_shuffle"
        }
    }

    @ToolbarContentBuilder
    private func playbackModeToolbarItem(titled: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            let mode = playbackMode
            let allowsShuffle = allowsShuffle
            Menu {
                Picker(selection: Binding(
                    get: { mode },
                    set: { applyPlaybackMode($0) }
                )) {
                    ForEach(PlaybackOrderMode.allCases.filter { $0 != .shuffle || allowsShuffle || mode == .shuffle }, id: \.self) { option in
                        Label {
                            Text(Self.titleKey(for: option))
                        } icon: {
                            Image(systemName: option.symbolName)
                        }
                        .tag(option)
                    }
                } label: {
                    Text("queue_play_mode")
                }
            } label: {
                let icon = Image(systemName: mode.symbolName)
                    .foregroundStyle(mode == .sequential ? Color.secondary : Color.accentColor)
                    // 导航栏条目里只用系统修饰符, 不碰任何会读环境的封装。
                    .contentTransition(.symbolEffect(.replace))
                if titled {
                    Label {
                        Text(Self.titleKey(for: mode))
                    } icon: {
                        icon
                    }
                } else {
                    icon
                }
            } primaryAction: {
                applyPlaybackMode(mode.next(allowsShuffle: allowsShuffle))
            }
            .accessibilityLabel(Text("queue_play_mode"))
            .accessibilityValue(Text(Self.titleKey(for: mode)))
            .accessibilityHint(Text("queue_play_mode_hint"))
        }
    }

    @ToolbarContentBuilder
    private func shufflePreferenceToolbarItem(titled: Bool) -> some ToolbarContent {
        // 和播放方式键同在右上角、排在它左边;左上角留给关闭键(#348)。
        ToolbarItem(placement: .primaryAction) {
            // 单曲循环时随机开着也只放这一首,偏好同样不起作用。
            let isEffective = playbackMode == .shuffle
            // 偏好经 `player.playbackSettings` 读写, 同样不碰环境。
            Menu {
                if !isEffective {
                    Text("shuffle_preference_needs_shuffle")
                    if allowsShuffle {
                        Button {
                            applyPlaybackMode(.shuffle)
                        } label: {
                            Label("shuffle_preference_turn_on_shuffle", systemImage: "shuffle")
                        }
                    }
                }
                Picker(selection: Binding(
                    get: { player.playbackSettings.shufflePreference },
                    set: { player.playbackSettings.shufflePreference = $0 }
                )) {
                    ForEach(ShufflePreference.allCases) { preference in
                        Text(verbatim: preference.displayName).tag(preference)
                    }
                } label: {
                    Text("shuffle_preference_title")
                }
                if player.isAppleMusicMode, !player.isPrimuseManagingAppleMusicQueue {
                    Text("shuffle_preference_apple_music_note")
                }
            } label: {
                let icon = Image(systemName: "dice")
                    .foregroundStyle(isEffective ? Color.accentColor : Color.secondary)
                    .opacity(isEffective ? 1 : 0.45)
                if titled {
                    Label {
                        Text("shuffle_preference_title")
                    } icon: {
                        icon
                    }
                } else {
                    icon
                }
            }
            .accessibilityLabel(Text("shuffle_preference_title"))
            .accessibilityValue(Text(verbatim: player.playbackSettings.shufflePreference.displayName))
            .accessibilityHint(Text(
                isEffective
                    ? LocalizedStringKey("shuffle_preference_choose_hint")
                    : LocalizedStringKey("shuffle_preference_needs_shuffle")
            ))
        }
    }

    @ViewBuilder
    private var content: some View {
        let entries = player.queueEntries
        let displayedCount = 1 + player.upcomingQueueEntries.count + player.playedQueueEntries.count
        if entries.isEmpty {
            EmptyStateView(
                titleKey: "queue_empty",
                descriptionKey: "queue_empty_desc",
                systemImage: "music.note.list"
            )
            .pmAppearFade(.contentAppear)
        } else {
            ScrollView {
                // Match the large song list's virtualization strategy. List's
                // edit/reorder bridge registers every queue row up front; a
                // LazyVStack creates only the visible lightweight rows and
                // keeps long queues responsive while preserving one continuous
                // scroll surface.
                LazyVStack(alignment: .leading, spacing: heightClass.value(18, compact: 10)) {
                    let currentIndex = min(max(player.currentIndex, 0), entries.count - 1)
                    let currentEntry = entries[currentIndex]
                    queueSection(title: "now_playing") {
                        queueRow(
                            entry: currentEntry,
                            ordinal: 1,
                            totalCount: displayedCount,
                            displayedSong: player.currentSong ?? currentEntry.song,
                            isPlaying: true
                        )
                    }

                    // 播完后自动续上的相似歌曲单独一段,和自己排的歌分开。
                    let upcoming = QueueContinuationPolicy.splitUpcoming(player.upcomingQueueEntries) {
                        player.isAutoContinuationEntry($0.entry)
                    }
                    if !upcoming.queued.isEmpty {
                        queueSection(title: "up_next") {
                            ForEach(Array(upcoming.queued.enumerated()), id: \.element.id) { @Sendable index, presentation in
                                LazyItemCell {
                                    upcomingRow(presentation, currentEntry: currentEntry, ordinal: index + 2, totalCount: displayedCount)
                                }
                            }
                        }
                    }
                    if !upcoming.autoplay.isEmpty {
                        queueSection(title: "queue_autoplay_section") {
                            ForEach(Array(upcoming.autoplay.enumerated()), id: \.element.id) { @Sendable index, presentation in
                                LazyItemCell {
                                    upcomingRow(presentation, currentEntry: currentEntry, ordinal: upcoming.queued.count + index + 2, totalCount: displayedCount)
                                }
                            }
                        }
                    }

                    let played = player.playedQueueEntries
                    if !played.isEmpty {
                        queueSection(title: "played") {
                            ForEach(Array(played.enumerated()), id: \.element.id) { @Sendable index, presentation in
                                LazyItemCell {
                                    queueRow(entry: presentation.entry, ordinal: upcoming.queued.count + upcoming.autoplay.count + index + 2, totalCount: displayedCount, dimmed: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, heightClass.value(12, compact: 8))
                .padding(.bottom, heightClass.value(28, compact: 12))
            }
            // 半屏队列(iPhone Duo 竖栏)里的行和拖动把手停在竖栏左侧;嵌在播放页右栏时竖栏那一条归播放页自己用。
            .modifier(QueueVerticalBarFill(isEnabled: !isEmbedded))
            // 空态与列表只让新的那块淡入: 两者不重叠, 交叉过渡期间会前后叠排。
            // 行级增删仍然走各自的动画。
            .pmAppearFade(.contentAppear)
        }
    }

    private func upcomingRow(_ presentation: QueuePresentationEntry, currentEntry: QueueEntry, ordinal: Int, totalCount: Int) -> some View {
        queueRow(
            entry: presentation.entry,
            ordinal: ordinal,
            totalCount: totalCount,
            reorderID: QueueReorderOccurrenceID(
                queueEntryID: presentation.id.queueEntryID,
                roundOffset: presentation.id.roundOffset
            ),
            allowsRemoval: player.canRemoveUpcomingQueueEntries
                && presentation.id.queueEntryID != currentEntry.id,
            unreachable: isUnreachable(presentation.entry.song)
        )
    }

    private func queueSection<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    @ViewBuilder
    private func queueRow(
        entry: QueueEntry,
        ordinal: Int,
        totalCount: Int,
        displayedSong: Song? = nil,
        isPlaying: Bool = false,
        dimmed: Bool = false,
        reorderID: QueueReorderOccurrenceID? = nil,
        allowsRemoval: Bool = false,
        unreachable: Bool = false
    ) -> some View {
        let song = displayedSong ?? entry.song
        let isDropTarget = dropTarget == reorderID && reorderID != nil
        let accessibilityLabel = [ordinal.formatted(), song.title, library.artistDisplayName(for: song)]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")

        let row = HStack(alignment: .center, spacing: 10) {
            ZStack {
                CachedArtworkView(
                    coverRef: song.coverArtFileName,
                    songID: song.id,
                    size: 44,
                    cornerRadius: 6,
                    sourceID: song.sourceID,
                    filePath: song.filePath,
                    fileFormat: song.fileFormat
                )
                if isPlaying {
                    Color.black.opacity(0.32)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Image(systemName: player.showsLoadingIndicator ? "ellipsis" : "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        // 换图要有事务驱动才动得起来, 只挂在当前曲这一行上。
                        .pmAnimation(.control, value: player.showsLoadingIndicator)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SongRowTrackNumber(number: ordinal, largestNumber: totalCount)
                    Text(song.title)
                        .font(.subheadline.weight(isPlaying ? .semibold : .regular))
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                }
                if unreachable {
                    // Playback steps over this entry until its source answers.
                    Label("song_row_source_unreachable", systemImage: "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(library.artistDisplayName(for: song) ?? song.albumTitle ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // 时长与删除键放进同一个固定高度的容器, 与 44pt 封面同高居中,
            // 不再各自按内容高度对齐而显得偏上。
            HStack(spacing: 2) {
                if song.duration > 0 {
                    Text(song.duration.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if let reorderID, allowsRemoval {
                    Button {
                        pmWithAnimation(.list) {
                            _ = player.removeUpcomingQueueEntry(reorderID)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            .frame(height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(
            isPlaying || isDropTarget
                ? Color.accentColor.opacity(0.10)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(isDropTarget ? 0.9 : 0), lineWidth: 2)
        }
        .scaleEffect(isDropTarget ? 1.015 : 1)
        .shadow(
            color: Color.accentColor.opacity(isDropTarget ? 0.18 : 0),
            radius: isDropTarget ? 8 : 0,
            y: isDropTarget ? 3 : 0
        )
        .pmAnimation(.list, value: isDropTarget)
        .opacity(dimmed || unreachable ? 0.58 : 1)
        .contentShape(Rectangle())
        .onTapGesture { playEntry(entry) }
        // 拖起这一行时, SwiftUI 会把它渲染进一个独立的预览宿主。那个宿主不继承
        // 按类型注入的可观察对象, 而这一行要读两个: 标题下方的艺术家名走
        // MusicLibrary, 封面 CachedArtworkView 同时读 MusicLibrary 与
        // SourceManager。取不到时 EnvironmentValues 的下标直接触发运行时陷阱,
        // 表现为一碰拖动就闪退。显式带上, 让预览宿主解析得到。
        .environment(library)
        .environment(sourceManager)

        if let reorderID {
            let accessibleRow = row
                // 整行长按即可拖动排序, 不再显示拖动把手。不给 .draggable 传自定义
                // 预览并不会让渲染留在当前宿主 —— 系统仍然把这一行搬进独立的拖拽
                // 预览宿主, 所以环境对象要在 row 上显式带好(见上)。
                .draggable(reorderID.dragPayload)
                .dropDestination(for: String.self) { payloads, _ in
                    defer { dropTarget = nil }
                    guard let payload = payloads.first,
                          let dragged = QueueReorderOccurrenceID(dragPayload: payload) else {
                        return false
                    }
                    return pmWithAnimation(.list) {
                        player.moveUpcomingQueueEntry(dragged, over: reorderID)
                    }
                } isTargeted: { isTargeted in
                    if isTargeted {
                        dropTarget = reorderID
                    } else if dropTarget == reorderID {
                        dropTarget = nil
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityValue(Text(verbatim: song.duration.formattedDuration))
                .accessibilityHint(Text("reorder"))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { playEntry(entry) }
                .accessibilityAdjustableAction { direction in
                    moveEntry(reorderID, direction: direction)
                }
            if allowsRemoval {
                accessibleRow
                    .accessibilityAction(named: Text("remove_from_queue")) {
                        pmWithAnimation(.list) {
                            _ = player.removeUpcomingQueueEntry(reorderID)
                        }
                    }
            } else {
                accessibleRow
            }
        } else {
            row
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(verbatim: accessibilityLabel))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { playEntry(entry) }
        }
    }

    /// Read here, in the list body, and handed to the row as a value: a row
    /// lifted into a drag preview has no environment to read it from.
    private func isUnreachable(_ song: Song) -> Bool {
        sourceManager.unreachablePlaybackSourceIDs.contains(song.sourceID)
            && player.isSongBlockedByUnreachableSource(song)
    }

    private func playEntry(_ entry: QueueEntry) {
        guard let index = player.queueEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        Task { await player.playFromQueue(at: index) }
    }

    private func moveEntry(
        _ entryID: QueueReorderOccurrenceID,
        direction: AccessibilityAdjustmentDirection
    ) {
        let sameRound = player.upcomingQueueEntries.compactMap { entry -> QueueReorderOccurrenceID? in
            guard entry.id.roundOffset == entryID.roundOffset else { return nil }
            return QueueReorderOccurrenceID(
                queueEntryID: entry.id.queueEntryID,
                roundOffset: entry.id.roundOffset
            )
        }
        guard let index = sameRound.firstIndex(of: entryID) else { return }

        let targetIndex: Int
        switch direction {
        case .decrement:
            guard index > sameRound.startIndex else { return }
            targetIndex = sameRound.index(before: index)
        case .increment:
            guard sameRound.index(after: index) < sameRound.endIndex else { return }
            targetIndex = sameRound.index(after: index)
        @unknown default:
            return
        }
        pmWithAnimation(.list) {
            _ = player.moveUpcomingQueueEntry(entryID, over: sameRound[targetIndex])
        }
    }
}

/// 播放队列的弹出页：半屏起手、上拉到全屏；全屏时一拉下来就关掉，不再先退回半屏、要再拉一次才收起
/// （#348）。认的是「从全屏落到半屏」这一步，不管是哪种手势让它落下来的。挂在弹出页的内容上，
/// `dismiss` 关的就是这一页。
struct QueueSheetPresentation: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .medium

    func body(content: Content) -> some View {
        content
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .onChange(of: detent) { previous, current in
                guard previous == .large, current == .medium else { return }
                dismiss()
            }
    }
}

extension View {
    func queueSheetPresentation() -> some View {
        modifier(QueueSheetPresentation())
    }
}

/// 半屏队列在 iPhone Duo 竖栏下的滚动边缘；嵌在播放页右栏时不挂（见 `QueueView.isEmbedded`）。
private struct QueueVerticalBarFill: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.pmExtendsUnderVerticalBar()
        } else {
            content
        }
    }
}
