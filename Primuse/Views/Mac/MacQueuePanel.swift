#if os(macOS)
import SwiftUI
import PrimuseKit

/// 右侧 slide-in 队列面板,模仿 Apple Music 的「正在播放」队列。跟 sheet
/// 版 (`QueueView`) 唯一的区别是布局——侧栏紧贴 detail 右边,不劫持
/// 整个窗口。内部 list / 拖拽逻辑跟 sheet 版保持一致,源数据来自同一个
/// AudioPlayerService。
struct MacQueuePanel: View {
    var onClose: () -> Void

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    // 同 iOS 的 QueueView: 拖拽预览宿主要用, 行里的 CachedArtworkView 同时读
    // MusicLibrary 与 SourceManager。
    @Environment(SourceManager.self) private var sourceManager
    @State private var dropTarget: QueueReorderOccurrenceID?

    var body: some View {
        let isEmpty = player.queueEntries.isEmpty
        VStack(spacing: 0) {
            header(isEmpty: isEmpty)
            list
            // 空队列时「清除已播放 / 保存为歌单」都无事可做, 整条底栏不画。
            if !isEmpty {
                footer
            }
        }
        // 面板永远占满右侧整列: 空态只有一小块内容, 不撑满的话会缩成一个灰块
        // 悬在窗口中间, 上下露出正文的底色。
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                NSVisualEffectBackdrop(material: .sidebar, blending: .behindWindow)
                Rectangle().fill(PMColor.sidebarGlass.opacity(0.6))
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .leading) {
            Rectangle().fill(PMColor.divider).frame(width: 0.5).ignoresSafeArea(edges: .vertical)
        }
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        let entries = player.queueEntries
        let displayedCount = 1 + player.upcomingQueueEntries.count + player.playedQueueEntries.count
        if entries.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    // A large library can put thousands of songs in the queue.
                    // Eager stacks instantiate every row (including its artwork)
                    // as soon as the panel opens, which made a 2K-song queue add
                    // roughly 600 MB of resident memory. Keep both the section
                    // list and each section's rows lazy so only visible artwork is
                    // decoded and retained.
                    LazyVStack(alignment: .leading, spacing: 12) {
                        // currentIndex 在切歌/换队列瞬间可能越界, 钳到合法区间,
                        // 否则下面构造 Range 时 lowerBound > upperBound 会 trap。
                        let cur = min(max(player.currentIndex, 0), entries.count - 1)
                        let currentEntryID = entries[cur].id

                        // In shuffle mode raw queue offsets are not playback history.
                        // Use the player's current-round traversal prefix so Played
                        // cannot overlap the current-round Up Next section.
                        let playedEntries = player.playedQueueEntries
                        if !playedEntries.isEmpty {
                            queueSection(title: "played") {
                                ForEach(Array(playedEntries.enumerated()), id: \.element.id) { index, entry in
                                    queueRow(entry: entry.entry, ordinal: index + 1, totalCount: displayedCount, dimmed: true)
                                }
                            }
                        }

                        if let current = player.currentSong {
                            let currentEntry = entries[cur]
                            queueSection(title: "now_playing", accent: true) {
                                queueRow(entry: currentEntry, ordinal: playedEntries.count + 1, totalCount: displayedCount, displayedSong: current, isPlaying: true)
                                    .id(currentEntry.id)
                            }
                            .id(Self.nowPlayingAnchor)
                        }

                        // Use the player's real traversal order. In shuffle mode
                        // this differs from the raw queue tail.
                        // 播完后自动续上的相似歌曲单独一段,和自己排的歌分开。
                        let upNext = QueueContinuationPolicy.splitUpcoming(player.upcomingQueueEntries) {
                            player.isAutoContinuationEntry($0.entry)
                        }
                        if !upNext.queued.isEmpty {
                            queueSection(title: "up_next") {
                                ForEach(Array(upNext.queued.enumerated()), id: \.element.id) { index, entry in
                                    upcomingRow(entry, currentEntryID: currentEntryID, ordinal: playedEntries.count + index + 2, totalCount: displayedCount)
                                }
                            }
                        }
                        if !upNext.autoplay.isEmpty {
                            queueSection(title: "queue_autoplay_section") {
                                ForEach(Array(upNext.autoplay.enumerated()), id: \.element.id) { index, entry in
                                    upcomingRow(entry, currentEntryID: currentEntryID, ordinal: playedEntries.count + upNext.queued.count + index + 2, totalCount: displayedCount)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
                // 「已播放」排在最上面, 听了一阵再打开面板, 看到的是一屏旧歌。
                // 打开时直接停在正在播放这一段, 往上翻才是历史, 和 Apple Music 一样。
                // 只在出现时定一次位, 面板开着时切歌不去抢用户正在看的位置。
                .onAppear {
                    guard player.currentSong != nil, !player.playedQueueEntries.isEmpty else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(Self.nowPlayingAnchor, anchor: .top)
                    }
                }
            }
        }
    }

    private static let nowPlayingAnchor = "queue.nowPlaying"

    /// 空队列: 说清楚队列从哪来, 再给一个马上能听的入口。
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(PMColor.textFaint)
                .frame(width: 56, height: 56)
                .background(PMColor.glassBtn, in: .circle)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("queue_empty")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(PMColor.text)
                Text(verbatim: String(
                    format: String(localized: "queue_empty_mac_hint_format"),
                    String(localized: "insert_next")
                ))
                .font(.system(size: 11.5))
                .foregroundStyle(PMColor.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            }

            // 资料库里一首歌都没有时, 这个按钮按下去什么也不会发生, 不给。
            if !library.musicSongs.isEmpty {
                QueueEmptyShuffleButton(action: shuffleLibrary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 36)
        // 视觉重心略高于几何中心, 底下还压着播放条。
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pmAppearFade(.contentAppear)
    }

    private func upcomingRow(_ entry: QueuePresentationEntry, currentEntryID: UUID, ordinal: Int, totalCount: Int) -> some View {
        queueRow(
            entry: entry.entry,
            ordinal: ordinal,
            totalCount: totalCount,
            reorderID: QueueReorderOccurrenceID(
                queueEntryID: entry.id.queueEntryID,
                roundOffset: entry.id.roundOffset
            ),
            allowsRemoval: player.canRemoveUpcomingQueueEntries
                && entry.id.queueEntryID != currentEntryID,
            unreachable: isUnreachable(entry.entry.song)
        )
    }

    private func header(isEmpty: Bool) -> some View {
        HStack(spacing: 8) {
            Text("queue_title")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            // 空队列时「0 首歌曲 · 0:00」没有意义; 更多菜单针对当前歌曲, 没歌在播也不给。
            if !isEmpty {
                Text(verbatim: queueSummaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(PMColor.textFaint)
            }
            Spacer(minLength: 0)
            if !isEmpty || player.currentSong != nil {
                PlayerMoreMenu {
                    PMRoundBtnIcon(symbol: "ellipsis")
                }
                .frame(width: 24, height: 24)
            }
            Button(action: onClose) {
                PMRoundBtnIcon(symbol: "xmark")
            }
            .buttonStyle(.plain)
            .help(Text("close"))
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private func queueSection<Content: View>(
        title: LocalizedStringKey,
        accent: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(accent ? PMColor.brand : PMColor.textFaint)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            content()
        }
    }

    @ViewBuilder
    private func queueRow(entry: QueueEntry,
                          ordinal: Int,
                          totalCount: Int,
                          displayedSong: Song? = nil,
                          isPlaying: Bool = false,
                          dimmed: Bool = false,
                          reorderID: QueueReorderOccurrenceID? = nil,
                          allowsRemoval: Bool = false,
                          unreachable: Bool = false) -> some View {
        let song = displayedSong ?? entry.song
        let isDropTarget = dropTarget == reorderID && reorderID != nil
        let accessibilityLabel = [ordinal.formatted(), song.title, library.artistDisplayName(for: song)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        let row = HStack(alignment: .center, spacing: 8) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 32,
                cornerRadius: 4,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            SongRowTrackNumber(number: ordinal, largestNumber: totalCount)
                .font(.system(size: 11)).foregroundStyle(PMColor.textFaint)

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                if unreachable {
                    // Playback steps over this entry until its source answers.
                    Label("song_row_source_unreachable", systemImage: "wifi.slash")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                } else {
                    Text(library.artistDisplayName(for: song) ?? "")
                        .font(.system(size: 10.5))
                        .foregroundStyle(PMColor.textFaint)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                Text(song.duration.formattedDuration)
                    .font(.system(size: 10.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(PMColor.textFaint)

                if let reorderID, allowsRemoval {
                    Button {
                        pmWithAnimation(.list) {
                            _ = player.removeUpcomingQueueEntry(reorderID)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(PMColor.textFaint)
                            .frame(width: 22, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Text("remove_from_queue"))
                    .accessibilityHidden(true)
                }
            }
            .frame(height: 32)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isPlaying || isDropTarget ? PMColor.rowHover : Color.clear,
            in: .rect(cornerRadius: 6)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(PMColor.brand.opacity(isDropTarget ? 0.9 : 0), lineWidth: 1.5)
        }
        .scaleEffect(isDropTarget ? 1.012 : 1)
        .shadow(
            color: PMColor.brand.opacity(isDropTarget ? 0.16 : 0),
            radius: isDropTarget ? 7 : 0,
            y: isDropTarget ? 2 : 0
        )
        .pmAnimation(.list, value: isDropTarget)
        .opacity(dimmed || unreachable ? 0.52 : 1)
        .contentShape(Rectangle())
        .onTapGesture { playEntry(entry) }
        // 拖起这一行时渲染进独立的拖拽预览宿主, 那里不继承按类型注入的可观察
        // 对象。行内的艺术家名与封面都要读 MusicLibrary / SourceManager, 取不到
        // 就会触发运行时陷阱。显式带上。
        .environment(library)
        .environment(sourceManager)

        if let reorderID {
            let accessibleRow = row
                // 整行按住拖动即可排序, 不再显示拖动把手。不传自定义预览并不能让
                // 渲染留在当前宿主, 系统仍会搬进独立的预览宿主, 所以环境对象在
                // row 上显式带好(见上)。整行仍是放置目标, 并保留键盘 / VoiceOver
                // 的移动操作。
                .draggable(reorderID.dragPayload)
                .dropDestination(for: String.self) { payloads, _ in
                    defer { dropTarget = nil }
                    guard let payload = payloads.first,
                          let dragged = QueueReorderOccurrenceID(dragPayload: payload) else {
                        return false
                    }
                    return player.moveUpcomingQueueEntry(dragged, over: reorderID)
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
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            // 只删「已播放」那一段, 当前和接下来的歌都留着; 原来写「清除全部」名不副实。
            Button("queue_clear_played") { clearPlayed(uptoIndex: player.currentIndex) }
                // Prefix removal only matches the visible Played partition in
                // non-shuffle order. Never delete unrelated raw slots in shuffle.
                .disabled(player.shuffleEnabled || player.currentIndex <= 0)
            Button("save_as_playlist") { saveQueueAsPlaylist() }
                .disabled(player.queue.isEmpty)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 11))
        .foregroundStyle(PMColor.textMuted)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Rectangle().fill(PMColor.divider).frame(height: 0.5)
        }
    }

    private var queueSummaryText: String {
        "\(player.queue.count) \(String(localized: "songs_count")) · \(queueDuration.formattedDuration)"
    }

    private var queueDuration: TimeInterval {
        player.queue.reduce(0) { $0 + max(0, $1.duration) }
    }

    // MARK: - Actions

    /// Read here, in the list body, and handed to the row as a value: a row
    /// lifted into a drag preview has no environment to read it from.
    private func isUnreachable(_ song: Song) -> Bool {
        sourceManager.unreachablePlaybackSourceIDs.contains(song.sourceID)
            && player.isSongBlockedByUnreachableSource(song)
    }

    private func playEntry(_ entry: QueueEntry) {
        guard let index = player.queueEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        // Resolve the stable queue occurrence back to its current raw offset.
        // The queue may be reordered between rendering and tapping, and the
        // same Song may legitimately appear in more than one slot.
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
        player.moveUpcomingQueueEntry(entryID, over: sameRound[targetIndex])
    }

    private func clearPlayed(uptoIndex: Int) {
        guard uptoIndex > 0, uptoIndex <= player.queue.count else { return }
        player.removeQueuePrefix(count: uptoIndex)
    }

    private func shuffleLibrary() {
        // 和首页「随机播放全部」同一套: 整库不含不喜欢的歌(#193)。
        let ids = library.musicSongIDsExcludingDisliked
        guard !ids.isEmpty else { return }
        player.shuffleEnabled = false
        Task { await player.play(queueIDs: ids, order: .shuffled) }
    }

    private func saveQueueAsPlaylist() {
        guard !player.queue.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let playlist = library.createPlaylist(name: "\(String(localized: "queue_title")) \(formatter.string(from: Date()))")
        library.replacePlaylistSongs(playlistID: playlist.id, songIDs: player.queue.map(\.id))
    }
}

private struct QueueEmptyShuffleButton: View {
    let action: () -> Void

    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "shuffle")
                    .font(.system(size: 11, weight: .semibold))
                Text("shuffle_all")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background(PMColor.brand.opacity(hover ? 0.86 : 1), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .pmAnimation(.hover, value: hover)
    }
}

private struct PMRoundBtnIcon: View {
    let symbol: String

    @State private var hover = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(PMColor.textMuted)
            .frame(width: 24, height: 24)
            .background(hover ? PMColor.glassBtnHover : PMColor.glassBtn, in: .circle)
            .contentShape(Circle())
            .onHover { hover = $0 }
            .pmAnimation(.hover, value: hover)
    }
}
#endif
