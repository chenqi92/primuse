import PrimuseKit
import SwiftUI

/// 一档本地节目(自己的文件标成播客):和订阅节目页同一套排法 —— 头部、筛选与排序、单集行。
///
/// 单集默认按日期新的在上(新放进来的文件不用滚到底去找),也能按旧到新、文件顺序或自己拖的顺序;
/// 可只看未播放或已播放。排法与筛选按节目记在本机(`LocalPodcastShowSettingsStore`)。
/// 点一集从这一集放起,播完按收听先后接着放还没听完的,和订阅节目一样。
struct LocalPodcastShowDetailView: View {
    let entry: SpokenWordLibrarySnapshot.Entry
    /// Mac 详情栈给的返回;没给时(播客页里点进来)退回上一页。
    var onMacInlineBack: (() -> Void)? = nil

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showsReorder = false

    private var spokenWordStore: SpokenWordStore { SpokenWordStore.shared }
    private var settingsStore: LocalPodcastShowSettingsStore { LocalPodcastShowSettingsStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }
    private var book: SpokenWordBook { entry.book }

    var body: some View {
        let settings = settingsStore.settings(for: book.id)
        let ordered = LocalPodcastEpisodeListPolicy.ordered(book.items, settings: settings)
        let visible = ordered.filter { settings.filter.includes($0) }
        let songsByID = Dictionary(entry.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        List {
            Section {
                #if os(macOS)
                macBackButton
                    .listRowSeparator(.hidden)
                #endif
                header(ordered: ordered, settings: settings)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                controls(settings: settings)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            Section {
                if visible.isEmpty {
                    Text("podcast_no_matching_episodes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .listRowSeparator(.hidden)
                }
                ForEach(visible, id: \.id) { item in
                    row(item, song: songsByID[item.id], ordered: ordered, settings: settings)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(book.title)
        .accessibilityIdentifier("podcast.localShow.detail")
        .sheet(isPresented: $showsReorder) {
            PlaylistReorderSheet(
                name: book.title,
                countLabel: String(format: String(localized: "podcast_episode_count %lld"), ordered.count),
                hintKey: "podcast_reorder_hint",
                songs: ordered.compactMap { songsByID[$0.id] }
            ) { songs in
                settingsStore.saveCustomOrder(songs.map(\.id), for: book.id)
            }
        }
    }

    #if os(macOS)
    private var macBackButton: some View {
        Button {
            if let onMacInlineBack {
                onMacInlineBack()
            } else {
                dismiss()
            }
        } label: {
            Label("back", systemImage: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("podcast.back")
    }
    #endif

    // MARK: - Header

    private func header(ordered: [SpokenWordBookItem], settings: LocalPodcastShowSettings) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                let cover = entry.songs.first
                CachedArtworkView(
                    coverRef: cover?.coverArtFileName,
                    songID: cover?.id,
                    size: 128,
                    cornerRadius: 14,
                    sourceID: cover?.sourceID,
                    filePath: cover?.filePath,
                    fileFormat: cover?.fileFormat,
                    placeholderIcon: "antenna.radiowaves.left.and.right"
                )
                .frame(width: 128, height: 128)
                .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(book.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                    if let author = book.author {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(tint)
                            .lineLimit(2)
                    }
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if book.isInProgress {
                        SpokenWordProgressBar(value: book.fractionComplete, tint: tint)
                            .frame(maxWidth: 220)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            actionRow(ordered: ordered, settings: settings)
        }
    }

    /// 「12 集 · 3 集未播放 · 昨天更新」。
    private var metaLine: String {
        var parts = [String(format: String(localized: "podcast_episode_count %lld"), book.items.count)]
        let unplayed = book.items.count - book.finishedCount
        if unplayed > 0, unplayed < book.items.count {
            parts.append(String(format: String(localized: "podcast_local_unplayed_count %lld"), unplayed))
        } else if unplayed == 0 {
            parts.append(String(localized: "podcast_local_all_played"))
        }
        if let latest = PodcastFormat.date(book.items.compactMap(\.addedAt).max()) {
            parts.append(String(format: String(localized: "podcast_updated_format"), latest))
        }
        return parts.joined(separator: " · ")
    }

    private func actionRow(ordered: [SpokenWordBookItem], settings: LocalPodcastShowSettings) -> some View {
        let startID = LocalPodcastEpisodeListPolicy.startItemID(
            in: ordered,
            resumeItemID: book.resumeItemID,
            canContinue: book.canContinue
        )
        return HStack(spacing: 10) {
            if let startID {
                Button {
                    play(from: startID, settings: settings)
                } label: {
                    playLabel(startID: startID, settings: settings)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .accessibilityIdentifier("podcast.localShow.play")
            }
            SpokenWordBookSpeedMenu(bookID: book.id)
                #if os(iOS)
                .controlSize(.large)
                #endif
            Menu {
                moreMenu(ordered: ordered)
            } label: {
                PodcastCircleKey(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("more"))
            .accessibilityIdentifier("podcast.localShow.more")
        }
    }

    @ViewBuilder
    private func playLabel(startID: String, settings: LocalPodcastShowSettings) -> some View {
        if player.currentSong?.id == startID && player.isPlaying {
            PodcastPrimaryKeyLabel(titleKey: "pause", systemImage: "pause.fill")
        } else if book.canContinue {
            PodcastPrimaryKeyLabel(titleKey: "podcast_continue", systemImage: "play.fill")
        } else if settings.order == .newestFirst {
            PodcastPrimaryKeyLabel(titleKey: "podcast_play_latest", systemImage: "play.fill")
        } else {
            PodcastPrimaryKeyLabel(titleKey: "play", systemImage: "play.fill")
        }
    }

    @ViewBuilder
    private func moreMenu(ordered: [SpokenWordBookItem]) -> some View {
        let unfinished = ordered.filter { !$0.isFinished }.map(\.id)
        let finished = ordered.filter(\.isFinished).map(\.id)
        Button {
            spokenWordStore.markFinished(true, songIDs: unfinished)
        } label: {
            Label("podcast_mark_all_played", systemImage: "checkmark.circle")
        }
        .disabled(unfinished.isEmpty)
        Button {
            spokenWordStore.markFinished(false, songIDs: finished)
        } label: {
            Label("podcast_mark_all_unplayed", systemImage: "circle")
        }
        .disabled(finished.isEmpty)
        Divider()
        Button {
            showsReorder = true
        } label: {
            Label("podcast_reorder_episodes", systemImage: "arrow.up.arrow.down")
        }
        .disabled(ordered.count < 2)
    }

    // MARK: - Filter and order

    private func controls(settings: LocalPodcastShowSettings) -> some View {
        HStack(spacing: 10) {
            Picker("podcast_filter", selection: Binding(
                get: { settings.filter },
                set: { filter in settingsStore.update(book.id) { $0.filter = filter } }
            )) {
                Text("podcast_filter_all").tag(LocalPodcastEpisodeFilter.all)
                Text("podcast_filter_unplayed").tag(LocalPodcastEpisodeFilter.unplayed)
                Text("podcast_played").tag(LocalPodcastEpisodeFilter.played)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .accessibilityIdentifier("podcast.localShow.filter")
            Spacer(minLength: 0)
            Menu {
                Picker("podcast_episode_order", selection: Binding(
                    get: { settings.order },
                    set: { order in settingsStore.update(book.id) { $0.order = order } }
                )) {
                    Text("podcast_order_newest").tag(LocalPodcastEpisodeOrder.newestFirst)
                    Text("podcast_order_oldest").tag(LocalPodcastEpisodeOrder.oldestFirst)
                    Text("podcast_order_file").tag(LocalPodcastEpisodeOrder.fileOrder)
                    // 拖过一次才有「自定义顺序」可选;没拖过就从下面那一项进去拖。
                    if settings.order == .custom || !settings.customOrder.isEmpty {
                        Text("podcast_order_custom").tag(LocalPodcastEpisodeOrder.custom)
                    }
                }
                .pickerStyle(.inline)
                Button {
                    showsReorder = true
                } label: {
                    Label("podcast_reorder_episodes", systemImage: "hand.draw")
                }
                .disabled(book.items.count < 2)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                    Text(orderTitle(settings.order))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(tint)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("podcast_episode_order"))
            .accessibilityValue(Text(orderTitle(settings.order)))
            .accessibilityIdentifier("podcast.localShow.order")
        }
    }

    private func orderTitle(_ order: LocalPodcastEpisodeOrder) -> LocalizedStringKey {
        switch order {
        case .newestFirst: "podcast_order_newest"
        case .oldestFirst: "podcast_order_oldest"
        case .fileOrder: "podcast_order_file"
        case .custom: "podcast_order_custom"
        }
    }

    // MARK: - Rows

    private func row(
        _ item: SpokenWordBookItem,
        song: Song?,
        ordered: [SpokenWordBookItem],
        settings: LocalPodcastShowSettings
    ) -> some View {
        Button {
            if player.currentSong?.id == item.id {
                player.togglePlayPause()
            } else {
                play(from: item.id, settings: settings)
            }
        } label: {
            LocalPodcastEpisodeRow(item: item)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityIdentifier("podcast.localShow.episode")
        .contextMenu {
            episodeMenu(item, song: song, ordered: ordered, settings: settings)
        }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                spokenWordStore.markFinished(!item.isFinished, songIDs: [item.id])
            } label: {
                if item.isFinished {
                    Label("podcast_mark_unplayed", systemImage: "circle")
                } else {
                    Label("podcast_mark_played", systemImage: "checkmark.circle")
                }
            }
            .tint(tint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let song {
                Button {
                    _ = player.insertNextInQueue([song])
                } label: {
                    Label("insert_next_short", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.orange)
            }
        }
        #endif
    }

    @ViewBuilder
    private func episodeMenu(
        _ item: SpokenWordBookItem,
        song: Song?,
        ordered: [SpokenWordBookItem],
        settings: LocalPodcastShowSettings
    ) -> some View {
        Button {
            spokenWordStore.markFinished(!item.isFinished, songIDs: [item.id])
        } label: {
            if item.isFinished {
                Label("podcast_mark_unplayed", systemImage: "circle")
            } else {
                Label("podcast_mark_played", systemImage: "checkmark.circle")
            }
        }
        let earlier = LocalPodcastEpisodeListPolicy.earlierUnfinishedIDs(
            than: item.id, in: ordered, order: settings.order
        )
        Button {
            spokenWordStore.markFinished(true, songIDs: earlier)
        } label: {
            Label("podcast_mark_older_played", systemImage: "checkmark.circle.badge.questionmark")
        }
        .disabled(earlier.isEmpty)
        if let song {
            Button {
                _ = player.insertNextInQueue([song])
            } label: {
                Label("insert_next_short", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
        }
        if item.position != nil {
            Button(role: .destructive) {
                spokenWordStore.clearPosition(forSongID: item.id)
            } label: {
                Label("spoken_word_clear_progress", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func play(from itemID: String, settings: LocalPodcastShowSettings) {
        if player.currentSong?.id == itemID {
            player.togglePlayPause()
            return
        }
        let queue = LocalPodcastPlayback.queue(for: book, songs: entry.songs, from: itemID, settings: settings)
        guard !queue.isEmpty else { return }
        Task { await player.play(queue: queue, startingAt: 0) }
    }
}

/// 本地节目的一集:日期(没听过的前面一个点)、标题、播放键与时长或剩余,听完的标「已播放」。
/// 排法和订阅节目的单集行一样。
private struct LocalPodcastEpisodeRow: View {
    let item: SpokenWordBookItem

    @Environment(AudioPlayerService.self) private var player

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        let isCurrent = player.currentSong?.id == item.id
        VStack(alignment: .leading, spacing: 4) {
            metaLine(isCurrent: isCurrent)
            Text(item.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(isCurrent ? tint : (item.isFinished ? .secondary : .primary))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            HStack(spacing: 10) {
                playKey(isCurrent: isCurrent)
                statusText(isCurrent: isCurrent)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// 没听过的一集前面一个点,和「未播放」筛选是同一个意思的一半:听到一半的有进度圈,听完的标「已播放」。
    private func metaLine(isCurrent: Bool) -> some View {
        HStack(spacing: 6) {
            if !isCurrent, !item.isFinished, item.position == nil {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(Text("podcast_filter_unplayed"))
            }
            if let date = PodcastFormat.date(item.addedAt) {
                Text(date)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func playKey(isCurrent: Bool) -> some View {
        let isPlaying = isCurrent && player.isPlaying
        let fraction = progressFraction(isCurrent: isCurrent)
        let size: CGFloat = 30
        return ZStack {
            Circle()
                .stroke(tint.opacity(0.18), lineWidth: 2.5)
            if fraction > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if isCurrent, player.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(tint)
                    .offset(x: isPlaying ? 0 : size * 0.03)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func progressFraction(isCurrent: Bool) -> CGFloat {
        let total = (isCurrent && player.duration > 0) ? player.duration : item.duration
        guard total > 0 else { return 0 }
        if item.isFinished, !isCurrent { return 1 }
        let position = isCurrent ? player.currentTime : (item.position ?? 0)
        return CGFloat(min(1, max(0, position / total)))
    }

    @ViewBuilder
    private func statusText(isCurrent: Bool) -> some View {
        let total = item.duration > 0 ? item.duration : (isCurrent ? player.duration : 0)
        Group {
            if item.isFinished, !isCurrent {
                Label("podcast_played", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else if let position = isCurrent ? player.currentTime : item.position, position > 0, total > position {
                Text(PodcastFormat.remaining(total - position))
            } else if let duration = PodcastFormat.duration(total) {
                Text(duration)
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(isCurrent ? tint : .secondary)
    }
}
