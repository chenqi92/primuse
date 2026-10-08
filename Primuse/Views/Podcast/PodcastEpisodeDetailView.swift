import PrimuseKit
import SwiftUI

/// 一集:封面、节目、标题、日期时长,大播放键,下载与标记;有章节列章节;下面是节目说明。
/// 说明里的时间点点了就跳过去 —— 正在放这一集就直接跳,没在放就从那里开始放。
struct PodcastEpisodeDetailView: View {
    let episodeID: String
    /// 从节目页进来时不再给「去节目页」的入口,免得来回套娃。
    var opensShow = true

    @Environment(AudioPlayerService.self) private var player
    @State private var pendingInsecureHost: String?
    @State private var pendingSeek: TimeInterval?
    @State private var pushedShowID: String?
    @State private var feedChapters: [PodcastChapter] = []
    /// 节目说明排好的版。在后台排一次,别跟着播放进度每拍重排。
    @State private var notesBlocks: [PodcastShowNotes.Block] = []

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        Group {
            if let found = store.episode(id: episodeID) {
                content(found.episode, show: found.show)
            } else if !store.isLoaded {
                ProgressView()
            } else {
                ContentUnavailableView("podcast_episode_missing", systemImage: ListeningSpace.podcast.systemImage)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { store.loadIfNeeded() }
        .navigationDestination(item: $pushedShowID) { id in
            PodcastShowDetailView(source: .show(id))
        }
    }

    private func content(_ episode: PodcastEpisode, show: PodcastShow) -> some View {
        let isCurrent = player.currentSong?.id == episode.id
        let chapters = chapters(for: episode, isCurrent: isCurrent)
        // 从这一集放起,和节目页的列表一样按收听顺序接着放(连续播放开着时)。
        let continuing = Array(PodcastEpisodeListPolicy.continuation(
            from: episode.id,
            in: store.episodes(forShowID: show.id),
            state: store.state(for:)
        ).dropFirst())
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(macOS)
                PodcastInlineBackButton()
                #endif
                header(episode, show: show)
                PodcastEpisodeActions(
                    episode: episode,
                    continuing: continuing,
                    openShow: opensShow ? { pushedShowID = $0 } : nil,
                    needsInsecureConsent: {
                        pendingSeek = nil
                        pendingInsecureHost = $0
                    }
                )
                if !chapters.isEmpty {
                    chapterList(chapters, episode: episode, isCurrent: isCurrent, continuing: continuing)
                }
                if !notesBlocks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("podcast_show_notes")
                            .font(.title3.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        PodcastShowNotesView(blocks: notesBlocks) { seconds in
                            seek(episode, to: seconds, continuing: continuing)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(episode.title)
        .task(id: episode.id) {
            let notes = episode.showNotes ?? ""
            notesBlocks = await Task.detached(priority: .userInitiated) {
                PodcastShowNotes.blocks(from: notes)
            }.value
            guard episode.chapters.isEmpty, let url = episode.chaptersURL else { return }
            feedChapters = await PodcastNetwork.chapters(from: url)
        }
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost, onCancel: { pendingSeek = nil }) {
            PodcastPlaybackLauncher.play(episode, continuing: continuing, from: pendingSeek, player: player) { _ in }
            pendingSeek = nil
        }
    }

    // MARK: - Header

    private func header(_ episode: PodcastEpisode, show: PodcastShow) -> some View {
        HStack(alignment: .top, spacing: 16) {
            PodcastArtwork(episode: episode, show: show, size: 112, cornerRadius: 12)
                .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 6) {
                if opensShow {
                    Button {
                        pushedShowID = show.id
                    } label: {
                        HStack(spacing: 3) {
                            Text(show.title).lineLimit(1)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(show.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(episode.title)
                    .font(.title3.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine(episode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func metaLine(_ episode: PodcastEpisode) -> String {
        var parts: [String] = []
        if let date = PodcastFormat.date(episode.publishedAt) { parts.append(date) }
        if let duration = PodcastFormat.duration(episode.duration) { parts.append(duration) }
        if episode.kind == .trailer { parts.append(String(localized: "podcast_kind_trailer")) }
        if episode.kind == .bonus { parts.append(String(localized: "podcast_kind_bonus")) }
        if episode.isVideo { parts.append(String(localized: "podcast_video_episode")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Chapters

    private func chapters(for episode: PodcastEpisode, isCurrent: Bool) -> [PodcastChapter] {
        if !episode.chapters.isEmpty { return episode.chapters }
        if !feedChapters.isEmpty { return feedChapters }
        // 正在放、从文件里读出了章节(下载好的 m4a)。
        if isCurrent, !player.spokenWordChapters.isEmpty {
            return player.spokenWordChapters.map { PodcastChapter(start: $0.startTime, title: $0.title) }
        }
        return []
    }

    private func chapterList(
        _ chapters: [PodcastChapter],
        episode: PodcastEpisode,
        isCurrent: Bool,
        continuing: [PodcastEpisode]
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("podcast_chapters")
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 6)
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                let isActive = isCurrent && player.currentChapterIndex == index
                Button {
                    seek(episode, to: chapter.start, continuing: continuing)
                } label: {
                    HStack(spacing: 12) {
                        Text(ChapterTimeFormatter.string(from: chapter.start))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(isActive ? tint : .secondary)
                            .frame(minWidth: 52, alignment: .leading)
                        Text(chapter.title.isEmpty
                             ? String(format: String(localized: "podcast_chapter_number_format"), index + 1)
                             : chapter.title)
                            .font(.subheadline.weight(isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? tint : .primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if isActive {
                            Image(systemName: "waveform")
                                .font(.caption)
                                .foregroundStyle(tint)
                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        }
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < chapters.count - 1 {
                    Divider()
                }
            }
        }
    }

    private func seek(_ episode: PodcastEpisode, to seconds: TimeInterval, continuing: [PodcastEpisode]) {
        if player.currentSong?.id == episode.id {
            player.seek(to: seconds, startPlaying: true)
        } else {
            pendingSeek = seconds
            PodcastPlaybackLauncher.play(episode, continuing: continuing, from: seconds, player: player) {
                pendingInsecureHost = $0
            }
        }
    }
}

/// 单集页的播放键、下载、标记和进度条。单独一个视图:只有它跟着播放进度刷新。
private struct PodcastEpisodeActions: View {
    let episode: PodcastEpisode
    var continuing: [PodcastEpisode] = []
    var openShow: ((String) -> Void)?
    var needsInsecureConsent: @MainActor (String) -> Void

    @Environment(AudioPlayerService.self) private var player
    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        let state = store.state(for: episode)
        let isCurrent = player.currentSong?.id == episode.id
        let total = isCurrent && player.duration > 0 ? player.duration : (episode.duration ?? 0)
        let position = isCurrent ? player.currentTime : (state.position ?? 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    if isCurrent {
                        player.togglePlayPause()
                    } else {
                        PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) {
                            needsInsecureConsent($0)
                        }
                    }
                } label: {
                    if isCurrent && player.isPlaying {
                        PodcastPrimaryKeyLabel(titleKey: "pause", systemImage: "pause.fill")
                    } else if state.isInProgress || (isCurrent && position > 0) {
                        PodcastPrimaryKeyLabel(titleKey: "podcast_continue", systemImage: "play.fill")
                    } else {
                        PodcastPrimaryKeyLabel(titleKey: "podcast_play", systemImage: "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .accessibilityIdentifier("podcast.episode.play")

                PodcastDownloadButton(episode: episode)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.6), in: Circle())

                Button {
                    store.setPlayed(!state.isFinished, episode: episode)
                } label: {
                    PodcastCircleKey(
                        systemName: state.isFinished ? "checkmark.circle.fill" : "checkmark.circle",
                        foreground: state.isFinished ? tint : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(state.isFinished ? "podcast_mark_unplayed" : "podcast_mark_played"))

                let isLiked = store.isLiked(episodeID: episode.id)
                Button {
                    store.setLiked(!isLiked, episode: episode)
                } label: {
                    PodcastCircleKey(
                        systemName: isLiked ? "heart.fill" : "heart",
                        foreground: isLiked ? .red : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(isLiked ? "a11y_unlike" : "a11y_like"))

                Menu {
                    PodcastEpisodeMenu(
                        episode: episode,
                        continuing: continuing,
                        openShow: openShow,
                        needsInsecureConsent: needsInsecureConsent
                    )
                } label: {
                    PodcastCircleKey(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(Text("more"))
                .accessibilityIdentifier("podcast.episode.more")
            }
            if total > 0, position > 0, !state.isFinished {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(1, position / total))
                        .progressViewStyle(.linear)
                        .tint(tint)
                    Text(PodcastFormat.remaining(max(0, total - position)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else if state.isFinished {
                Label("podcast_played", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 所有订阅的单集按发布时间排:主页「最新单集」的「全部」。可筛未播、听到一半、已下载。
struct PodcastEpisodeFeedView: View {
    @AppStorage("primuse.podcast.feed.filter") private var filterRawValue = PodcastEpisodeFilter.unplayed.rawValue
    @State private var pushedEpisodeID: String?
    @State private var pushedShowID: String?

    private var store: PodcastStore { PodcastStore.shared }
    private var filter: PodcastEpisodeFilter { PodcastEpisodeFilter(rawValue: filterRawValue) ?? .unplayed }

    var body: some View {
        let episodes = store.latestEpisodes(limit: 300, includeFinished: true)
            .filter { filter.includes(store.state(for: $0)) }
        List {
            #if os(macOS)
            PodcastInlineBackButton()
                .listRowSeparator(.hidden)
            #endif
            Section {
                Picker("podcast_filter", selection: $filterRawValue) {
                    Text("podcast_filter_unplayed").tag(PodcastEpisodeFilter.unplayed.rawValue)
                    Text("podcast_filter_in_progress").tag(PodcastEpisodeFilter.inProgress.rawValue)
                    Text("podcast_filter_downloaded").tag(PodcastEpisodeFilter.downloaded.rawValue)
                    Text("podcast_filter_all").tag(PodcastEpisodeFilter.all.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowSeparator(.hidden)
            }
            if episodes.isEmpty {
                Text("podcast_no_matching_episodes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowSeparator(.hidden)
            }
            ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                let continuing = Array(episodes.dropFirst(index + 1).prefix(30))
                PodcastEpisodeRow(
                    episode: episode,
                    show: store.show(id: episode.showID),
                    showsArtwork: true,
                    continuing: continuing
                ) {
                    pushedEpisodeID = episode.id
                }
                .podcastEpisodeContextMenu(episode, continuing: continuing, openShow: { pushedShowID = $0 })
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    let finished = store.state(for: episode).isFinished
                    Button {
                        store.setPlayed(!finished, episode: episode)
                    } label: {
                        Label(finished ? "podcast_mark_unplayed" : "podcast_mark_played",
                              systemImage: finished ? "circle" : "checkmark.circle")
                    }
                    .tint(ListeningSpace.podcast.tint)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("podcast_latest_episodes")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .refreshable { await store.refreshAll() }
        .navigationDestination(item: $pushedEpisodeID) { id in
            PodcastEpisodeDetailView(episodeID: id)
        }
        .navigationDestination(item: $pushedShowID) { id in
            PodcastShowDetailView(source: .show(id))
        }
    }
}

/// 播客的全局设置:连续播放、自动下载只用 Wi-Fi、听完删下载、下载占用。
struct PodcastSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PodcastPlaybackSettings.continuousPlaybackKey) private var continuousPlayback = true
    @AppStorage(PodcastDownloadStore.wifiOnlyKey) private var wifiOnly = true
    @AppStorage(PodcastDownloadStore.deletePlayedKey) private var deletePlayed = true
    @State private var confirmsDeleteAll = false

    private var downloads: PodcastDownloadStore { PodcastDownloadStore.shared }

    var body: some View {
        Form {
            Section {
                Toggle("podcast_continuous_playback", isOn: $continuousPlayback)
            } footer: {
                Text("podcast_continuous_playback_footer")
            }
            Section("podcast_settings_downloads") {
                Toggle("podcast_auto_download_wifi_only", isOn: $wifiOnly)
                Toggle("podcast_delete_played_downloads", isOn: $deletePlayed)
                LabeledContent("podcast_downloads_size", value: PodcastFormat.bytes(downloads.totalBytes))
                Button("podcast_remove_all_downloads", role: .destructive) {
                    confirmsDeleteAll = true
                }
                .disabled(downloads.records.isEmpty)
                // 挂在触发按钮上，弹框从按钮长出来而不是贴在整页边缘。
                .confirmationDialog("podcast_remove_all_downloads", isPresented: $confirmsDeleteAll, titleVisibility: .visible) {
                    Button("podcast_remove_all_downloads", role: .destructive) {
                        downloads.deleteAll()
                    }
                }
            }
            Section {
                Text("podcast_skip_interval_note")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("podcast_settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
            }
        }
        .onChange(of: deletePlayed) { _, enabled in
            if enabled { PodcastStore.shared.purgePlayedDownloads() }
        }
    }
}
