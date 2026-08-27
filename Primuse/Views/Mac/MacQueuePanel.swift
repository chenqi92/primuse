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
    @Environment(SourceManager.self) private var sourceManager
    @State private var dropTarget: QueueReorderOccurrenceID?

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
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
        if entries.isEmpty {
            ContentUnavailableView(
                "queue_empty",
                systemImage: "music.note.list",
                description: Text("queue_empty_desc")
            )
        } else {
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
                            ForEach(playedEntries) { entry in
                                queueRow(entry: entry.entry, dimmed: true)
                            }
                        }
                    }

                    if let current = player.currentSong {
                        let currentEntry = entries[cur]
                        queueSection(title: "now_playing", accent: true) {
                            queueRow(entry: currentEntry, displayedSong: current, isPlaying: true)
                                .id(currentEntry.id)
                        }
                    }

                    // Use the player's real traversal order. In shuffle mode
                    // this differs from the raw queue tail.
                    let upNextEntries = player.upcomingQueueEntries
                    if !upNextEntries.isEmpty {
                        queueSection(title: "up_next") {
                            ForEach(upNextEntries) { entry in
                                queueRow(
                                    entry: entry.entry,
                                    reorderID: QueueReorderOccurrenceID(
                                        queueEntryID: entry.id.queueEntryID,
                                        roundOffset: entry.id.roundOffset
                                    ),
                                    allowsRemoval: player.canRemoveUpcomingQueueEntries
                                        && entry.id.queueEntryID != currentEntryID
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("queue_title")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PMColor.text)
            Text(verbatim: queueSummaryText)
                .font(.system(size: 11))
                .foregroundStyle(PMColor.textFaint)
            Spacer(minLength: 0)
            PlayerMoreMenu {
                PMRoundBtnIcon(symbol: "ellipsis")
            }
            .frame(width: 24, height: 24)
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
                          displayedSong: Song? = nil,
                          isPlaying: Bool = false,
                          dimmed: Bool = false,
                          reorderID: QueueReorderOccurrenceID? = nil,
                          allowsRemoval: Bool = false) -> some View {
        let song = displayedSong ?? entry.song
        let isDropTarget = dropTarget == reorderID && reorderID != nil
        let accessibilityLabel = [song.title, library.artistDisplayName(for: song)]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: ", ")
        let row = HStack(spacing: 8) {
            if let reorderID {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(PMColor.textFaint)
                    .frame(width: 14)
                    .contentShape(Rectangle())
                    .draggable(reorderID.dragPayload) {
                        queueDragPreview(song)
                    }
                    .help(Text("reorder"))
                    .accessibilityHidden(true)
            } else {
                Color.clear.frame(width: 14)
            }

            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 32,
                cornerRadius: 4,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: isPlaying ? .semibold : .medium))
                    .foregroundStyle(isPlaying ? PMColor.brand : PMColor.text)
                    .lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(song.duration.formattedDuration)
                .font(.system(size: 10.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(PMColor.textFaint)

            if let reorderID, allowsRemoval {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        _ = player.removeUpcomingQueueEntry(reorderID)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(PMColor.textFaint)
                        .frame(width: 22, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("remove_from_queue"))
                .accessibilityHidden(true)
            }
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
        .animation(.snappy(duration: 0.18), value: isDropTarget)
        .opacity(dimmed ? 0.52 : 1)
        .contentShape(Rectangle())
        .onTapGesture { playEntry(entry) }

        if let reorderID {
            let accessibleRow = row
                // Pointer dragging starts on the visible handle so it cannot
                // compete with the row's tap-to-play gesture. The complete row
                // remains the drop target and exposes keyboard/VoiceOver moves.
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
                        withAnimation(.snappy(duration: 0.2)) {
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

    private func queueDragPreview(_ song: Song) -> some View {
        HStack(spacing: 8) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 34,
                cornerRadius: 5,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(library.artistDisplayName(for: song) ?? song.albumTitle ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(PMColor.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PMColor.textFaint)
        }
        .padding(8)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(PMColor.brand.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        .environment(sourceManager)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("clear_all") { clearPlayed(uptoIndex: player.currentIndex) }
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

    private func saveQueueAsPlaylist() {
        guard !player.queue.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let playlist = library.createPlaylist(name: "\(String(localized: "queue_title")) \(formatter.string(from: Date()))")
        library.replacePlaylistSongs(playlistID: playlist.id, songIDs: player.queue.map(\.id))
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
    }
}
#endif
