import SwiftUI
import PrimuseKit

struct QueueView: View {
    let player: AudioPlayerService
    @State private var dropTarget: QueueReorderOccurrenceID?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("queue_title")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        let entries = player.queueEntries
        if entries.isEmpty {
            EmptyStateView(
                titleKey: "queue_empty",
                descriptionKey: "queue_empty_desc",
                systemImage: "music.note.list"
            )
        } else {
            ScrollView {
                // Match the large song list's virtualization strategy. List's
                // edit/reorder bridge registers every queue row up front; a
                // LazyVStack creates only the visible lightweight rows and
                // keeps long queues responsive while preserving one continuous
                // scroll surface.
                LazyVStack(alignment: .leading, spacing: 18) {
                    let currentIndex = min(max(player.currentIndex, 0), entries.count - 1)
                    let currentEntry = entries[currentIndex]
                    queueSection(title: "now_playing") {
                        queueRow(
                            entry: currentEntry,
                            displayedSong: player.currentSong ?? currentEntry.song,
                            isPlaying: true
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
                                        && presentation.id.queueEntryID != currentEntry.id
                                )
                            }
                        }
                    }

                    let played = player.playedQueueEntries
                    if !played.isEmpty {
                        queueSection(title: "played") {
                            ForEach(played) { presentation in
                                queueRow(entry: presentation.entry, dimmed: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .padding(.bottom, 28)
            }
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
        allowsRemoval: Bool = false
    ) -> some View {
        let song = displayedSong ?? entry.song
        let isDropTarget = dropTarget == reorderID && reorderID != nil
        let accessibilityLabel = [song.title, song.artistName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")

        let row = HStack(spacing: 10) {
            if let reorderID {
                Image(systemName: "line.3.horizontal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
                    .draggable(reorderID.dragPayload) {
                        queueDragPreview(song)
                    }
                    .accessibilityHidden(true)
            }

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
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(isPlaying ? .semibold : .regular))
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                Text(song.artistName ?? song.albumTitle ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if song.duration > 0 {
                Text(song.duration.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let reorderID, allowsRemoval {
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        _ = player.removeUpcomingQueueEntry(reorderID)
                    }
                } label: {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }
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
        .animation(.snappy(duration: 0.2), value: isDropTarget)
        .opacity(dimmed ? 0.58 : 1)
        .contentShape(Rectangle())
        .onTapGesture { playEntry(entry) }

        if let reorderID {
            let accessibleRow = row
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
                        withAnimation(.snappy(duration: 0.22)) {
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

    private func queueDragPreview(_ song: Song) -> some View {
        HStack(spacing: 10) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 42,
                cornerRadius: 6,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(song.artistName ?? song.albumTitle ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(width: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
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
        player.moveUpcomingQueueEntry(entryID, over: sameRound[targetIndex])
    }
}
