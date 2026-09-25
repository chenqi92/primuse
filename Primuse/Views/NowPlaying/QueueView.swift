import SwiftUI
import PrimuseKit

struct QueueView: View {
    let player: AudioPlayerService
    @Environment(MusicLibrary.self) private var library
    // 拖拽预览宿主要用: 行里的 CachedArtworkView 同时读 MusicLibrary 与
    // SourceManager, 两个都得显式带过去。见 queueRow 里的说明。
    @Environment(SourceManager.self) private var sourceManager
    /// 队列以半屏 sheet 呈现, 手机横屏下可视高度只够两行出头, 行距与底部留白收一档。
    @Environment(\.pmHeightClass) private var heightClass
    @State private var dropTarget: QueueReorderOccurrenceID?
    /// `Queue.nowPlayingCard` 下已播放默认收起:队列页要看的是
    /// 接下来放什么,听过的列表越放越长会把它挤下去。
    @State private var showsPlayed = false
    @Environment(\.skin) private var skin

    var body: some View {
        // 在这里取值再传给工具栏:导航栏条目由独立宿主渲染,不在那里读环境。
        let extendedQueue = skin.usesNowPlayingCardQueue
        NavigationStack {
            content(extended: extendedQueue)
                .navigationTitle("queue_title")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { shuffleToolbarContent(showsRepeat: extendedQueue) }
        }
    }

    /// 队列页自己的随机播放开关。在这之前, 想把手上这份队列打乱, 只能先点开
    /// 播放页、再去底部那排控件里找随机播放 —— 队列就摊在眼前, 却没有入口。
    /// 只读 `player` 这个存储属性, 不碰 @Environment: 导航栏条目会在转场期间
    /// 由独立的宿主渲染, 在那里读必需的环境值会直接崩。
    @ToolbarContentBuilder
    private func shuffleToolbarContent(showsRepeat: Bool) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            let isOn = player.shuffleEnabled
            Button {
                player.shuffleEnabled.toggle()
            } label: {
                Label {
                    Text("a11y_shuffle")
                } icon: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                        // 导航栏条目里只用系统修饰符, 不碰任何会读环境的封装。
                        .symbolEffect(.bounce, value: isOn)
                }
            }
            .disabled(player.queueCount < 2)
            .accessibilityLabel(Text("a11y_shuffle"))
            .accessibilityValue(Text(isOn ? "a11y_value_on" : "a11y_value_off"))
        }
        // 循环也放在这里:关 → 全部 → 单曲,和播放页的循环键同一个顺序。
        if showsRepeat {
            ToolbarItem(placement: .primaryAction) {
                let mode = player.repeatMode
                Button {
                    switch mode {
                    case .off: player.repeatMode = .all
                    case .all: player.repeatMode = .one
                    case .one: player.repeatMode = .off
                    }
                } label: {
                    Label {
                        Text("a11y_repeat")
                    } icon: {
                        Image(systemName: mode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(mode == .off ? Color.secondary : Color.accentColor)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .accessibilityLabel(Text("a11y_repeat"))
                .accessibilityValue(Text(mode == .off ? "a11y_value_off" : "a11y_value_on"))
            }
        }
    }

    @ViewBuilder
    private func content(extended: Bool) -> some View {
        let entries = player.queueEntries
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
                        // 分组面板那一套下,正在播放单独成一张卡片,和下面的列表分开。
                        queueRow(
                            entry: currentEntry,
                            displayedSong: player.currentSong ?? currentEntry.song,
                            isPlaying: true
                        )
                        .padding(.vertical, extended ? 4 : 0)
                        .background(
                            extended ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }

                    let upcoming = player.upcomingQueueEntries
                    if !upcoming.isEmpty {
                        queueSection(title: "up_next") {
                            ForEach(upcoming) { presentation in
                                queueRow(
                                    entry: presentation.entry,
                                    reorderID: QueueReorderOccurrenceID(
                                        queueEntryID: presentation.id.queueEntryID,
                                        roundOffset: presentation.id.roundOffset
                                    ),
                                    allowsRemoval: player.canRemoveUpcomingQueueEntries
                                        && presentation.id.queueEntryID != currentEntry.id,
                                    unreachable: isUnreachable(presentation.entry.song)
                                )
                            }
                        }
                    }

                    let played = player.playedQueueEntries
                    if !played.isEmpty, !extended {
                        queueSection(title: "played") {
                            ForEach(played) { presentation in
                                queueRow(entry: presentation.entry, dimmed: true)
                            }
                        }
                    } else if !played.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Button {
                                pmWithAnimation(.list) { showsPlayed.toggle() }
                            } label: {
                                HStack {
                                    Text("played")
                                        .font(.caption.weight(.semibold))
                                        .textCase(.uppercase)
                                    Text(verbatim: "\(played.count)")
                                        .font(.caption.monospacedDigit())
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.caption.weight(.bold))
                                        .rotationEffect(.degrees(showsPlayed ? 180 : 0))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityValue(Text(showsPlayed ? "a11y_value_on" : "a11y_value_off"))

                            if showsPlayed {
                                ForEach(played) { presentation in
                                    queueRow(entry: presentation.entry, dimmed: true)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, heightClass.value(12, compact: 8))
                .padding(.bottom, heightClass.value(28, compact: 12))
            }
            // 空态与列表只让新的那块淡入: 两者不重叠, 交叉过渡期间会前后叠排。
            // 行级增删仍然走各自的动画。
            .pmAppearFade(.contentAppear)
        }
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
        displayedSong: Song? = nil,
        isPlaying: Bool = false,
        dimmed: Bool = false,
        reorderID: QueueReorderOccurrenceID? = nil,
        allowsRemoval: Bool = false,
        unreachable: Bool = false
    ) -> some View {
        let song = displayedSong ?? entry.song
        let isDropTarget = dropTarget == reorderID && reorderID != nil
        let accessibilityLabel = [song.title, library.artistDisplayName(for: song)]
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
                    Image(systemName: player.isLoading ? "ellipsis" : "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                        // 换图要有事务驱动才动得起来, 只挂在当前曲这一行上。
                        .pmAnimation(.control, value: player.isLoading)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(isPlaying ? .semibold : .regular))
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .lineLimit(1)
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
