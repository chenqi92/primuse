import PrimuseKit
import SwiftUI

/// 一档节目:头部(封面、名字、主播、订阅与播放)、简介、单集列表。
///
/// 没订阅也能进来先看、先听(从发现或 RSS 地址进来的预览);订阅只是一个按钮。
/// 单集列表按节目类型默认排序(连载从第一集起,其余最新在前),可筛未播/已下载,多季时按季分组。
struct PodcastShowDetailView: View {
    enum Source: Hashable {
        case show(String)
        case directory(PodcastDirectoryShow)
        case feed(URL)
    }

    let source: Source

    @Environment(AudioPlayerService.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var showID: String?
    @State private var loadError: String?
    @State private var pendingInsecureHost: String?
    @State private var filter: PodcastEpisodeFilter = .all
    @State private var expandsSummary = false
    @State private var showsSettings = false
    @State private var confirmsUnsubscribe = false
    @State private var pushedEpisodeID: String?
    @State private var isSubscribing = false

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        Group {
            if let showID, let show = store.show(id: showID) {
                content(show)
            } else if let loadError {
                ContentUnavailableView {
                    Label("podcast_load_failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("podcast_retry") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost) { Task { await load() } }
        .navigationDestination(item: $pushedEpisodeID) { id in
            PodcastEpisodeDetailView(episodeID: id, opensShow: false)
        }
    }

    private func load() async {
        loadError = nil
        do {
            switch source {
            case .show(let id):
                store.loadIfNeeded()
                showID = id
            case .directory(let directoryShow):
                showID = try await store.preview(directoryShow: directoryShow).id
            case .feed(let url):
                showID = try await store.preview(feedURL: url).id
            }
        } catch PodcastNetwork.Failure.insecureHTTP(let host) {
            pendingInsecureHost = host
        } catch is PodcastFeedError {
            loadError = String(localized: "podcast_error_not_a_feed")
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Content

    private func content(_ show: PodcastShow) -> some View {
        let all = store.episodes(forShowID: show.id)
        let ordered = PodcastEpisodeListPolicy.ordered(all, order: show.effectiveEpisodeOrder)
        let visible = ordered.filter { filter.includes(store.state(for: $0)) }
        let groups = PodcastEpisodeListPolicy.seasonGroups(visible, order: show.effectiveEpisodeOrder)
        return List {
            Section {
                #if os(macOS)
                PodcastInlineBackButton()
                    .listRowSeparator(.hidden)
                #endif
                header(show, episodes: all)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
                controls(show, total: all.count, visible: visible.count)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            if visible.isEmpty {
                Section {
                    Text(all.isEmpty ? "podcast_no_episodes" : "podcast_no_matching_episodes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                        .listRowSeparator(.hidden)
                }
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        row(episode, show: show, in: all)
                    }
                } header: {
                    if let season = group.season, groups.count > 1 {
                        Text(String(format: String(localized: "podcast_season_format"), season))
                            .font(.headline)
                    } else if groups.count > 1 {
                        Text("podcast_season_other").font(.headline)
                    }
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(show.title)
        .refreshable {
            if store.isSubscribed(show.id) { await store.refresh(showID: show.id) }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack { PodcastShowSettingsView(showID: show.id) }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 460)
            #endif
        }
        .confirmationDialog(
            "podcast_unsubscribe_confirm_title",
            isPresented: $confirmsUnsubscribe,
            titleVisibility: .visible
        ) {
            Button("podcast_unsubscribe", role: .destructive) {
                store.unsubscribe(show.id)
                dismiss()
            }
        } message: {
            Text("podcast_unsubscribe_confirm_message")
        }
    }

    private func row(_ episode: PodcastEpisode, show: PodcastShow, in all: [PodcastEpisode]) -> some View {
        let continuing = Array(PodcastEpisodeListPolicy.continuation(from: episode.id, in: all, state: store.state(for:)).dropFirst())
        let state = store.state(for: episode)
        return PodcastEpisodeRow(episode: episode, show: show, continuing: continuing) {
            pushedEpisodeID = episode.id
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .podcastEpisodeContextMenu(episode, continuing: continuing)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                store.setPlayed(!state.isFinished, episode: episode)
            } label: {
                if state.isFinished {
                    Label("podcast_mark_unplayed", systemImage: "circle")
                } else {
                    Label("podcast_mark_played", systemImage: "checkmark.circle")
                }
            }
            .tint(tint)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if PodcastDownloadStore.shared.isDownloaded(episode.id) {
                Button(role: .destructive) {
                    PodcastDownloadStore.shared.delete(episode.id)
                } label: {
                    Label("podcast_remove_download", systemImage: "trash")
                }
            } else {
                Button {
                    PodcastDownloadStore.shared.download(episode)
                } label: {
                    Label("podcast_download", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
            Button {
                let song = PodcastPlaybackSong.song(for: episode, show: show)
                _ = player.insertNextInQueue([song])
            } label: {
                Label("insert_next_short", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .tint(.orange)
        }
    }

    // MARK: - Header

    private func header(_ show: PodcastShow, episodes: [PodcastEpisode]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                PodcastArtwork(show: show, size: 128, cornerRadius: 14)
                    .shadow(color: .black.opacity(0.14), radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 5) {
                    Text(show.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                    if let author = show.author, !author.isEmpty {
                        Text(author)
                            .font(.subheadline)
                            .foregroundStyle(tint)
                            .lineLimit(2)
                    }
                    if let meta = metaLine(show, episodes: episodes) {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }

            actionRow(show, episodes: episodes)

            if let summary = PodcastShowNotes.plainSummary(show.summary, limit: 2_000) {
                PodcastShowSummary(text: summary, isExpanded: $expandsSummary)
            }
            if let failure = store.refreshFailures[show.id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func metaLine(_ show: PodcastShow, episodes: [PodcastEpisode]) -> String? {
        var parts: [String] = []
        if let category = show.categories.first { parts.append(PodcastFormat.category(category)) }
        if !episodes.isEmpty {
            parts.append(String(format: String(localized: "podcast_episode_count %lld"), episodes.count))
        }
        if let latest = PodcastFormat.date(show.latestEpisodeAt) {
            parts.append(String(format: String(localized: "podcast_updated_format"), latest))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 订了:主键是播放(最新一集/继续/从第一集),旁边一个对勾(节目设置、退订)和「…」。
    /// 没订:主键是订阅,播放退成旁边的圆键。和单集页同一套尺寸。
    private func actionRow(_ show: PodcastShow, episodes: [PodcastEpisode]) -> some View {
        let subscribed = store.isSubscribed(show.id)
        let target = PodcastEpisodeListPolicy.resumeTarget(in: episodes, isSerial: show.isSerial, state: store.state(for:))
        return HStack(spacing: 10) {
            if subscribed {
                if let target {
                    Button {
                        play(target, episodes: episodes)
                    } label: {
                        playLabel(target, show: show)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(tint)
                    .accessibilityIdentifier("podcast.show.play")
                }
                Menu {
                    Button {
                        showsSettings = true
                    } label: {
                        Label("podcast_show_settings", systemImage: "slider.horizontal.3")
                    }
                    Button(role: .destructive) {
                        confirmsUnsubscribe = true
                    } label: {
                        Label("podcast_unsubscribe", systemImage: "minus.circle")
                    }
                } label: {
                    PodcastCircleKey(systemName: "checkmark", foreground: tint)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(Text("podcast_subscribed"))
                .accessibilityIdentifier("podcast.show.subscribed")
            } else {
                Button {
                    isSubscribing = true
                    if let adopted = store.adopt(previewID: show.id) {
                        showID = adopted.id
                    }
                    isSubscribing = false
                } label: {
                    PodcastPrimaryKeyLabel(titleKey: "podcast_subscribe", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(tint)
                .disabled(isSubscribing)
                .accessibilityIdentifier("podcast.show.subscribe")
                if let target {
                    Button {
                        play(target, episodes: episodes)
                    } label: {
                        PodcastCircleKey(
                            systemName: player.currentSong?.id == target.id && player.isPlaying ? "pause.fill" : "play.fill",
                            foreground: tint
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("podcast_play_latest"))
                }
            }
            Menu {
                moreMenu(show)
            } label: {
                PodcastCircleKey(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel(Text("more"))
            .accessibilityIdentifier("podcast.show.more")
        }
    }

    private func play(_ target: PodcastEpisode, episodes: [PodcastEpisode]) {
        if player.currentSong?.id == target.id {
            player.togglePlayPause()
        } else {
            let continuing = Array(PodcastEpisodeListPolicy.continuation(from: target.id, in: episodes, state: store.state(for:)).dropFirst())
            PodcastPlaybackLauncher.play(target, continuing: continuing, player: player) { pendingInsecureHost = $0 }
        }
    }

    @ViewBuilder
    private func playLabel(_ target: PodcastEpisode, show: PodcastShow) -> some View {
        if player.currentSong?.id == target.id && player.isPlaying {
            PodcastPrimaryKeyLabel(titleKey: "pause", systemImage: "pause.fill")
        } else if store.state(for: target).isInProgress {
            PodcastPrimaryKeyLabel(titleKey: "podcast_continue", systemImage: "play.fill")
        } else if show.isSerial {
            PodcastPrimaryKeyLabel(titleKey: "podcast_play_from_start", systemImage: "play.fill")
        } else {
            PodcastPrimaryKeyLabel(titleKey: "podcast_play_latest", systemImage: "play.fill")
        }
    }

    private func controls(_ show: PodcastShow, total: Int, visible: Int) -> some View {
        HStack(spacing: 10) {
            Picker("podcast_filter", selection: $filter) {
                Text("podcast_filter_all").tag(PodcastEpisodeFilter.all)
                Text("podcast_filter_unplayed").tag(PodcastEpisodeFilter.unplayed)
                Text("podcast_filter_downloaded").tag(PodcastEpisodeFilter.downloaded)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            Spacer(minLength: 0)
            if store.isSubscribed(show.id) {
                Menu {
                    Picker("podcast_episode_order", selection: Binding(
                        get: { show.effectiveEpisodeOrder },
                        set: { order in
                            store.updateDefinition(show.id) { $0.settings.episodeOrder = order }
                        }
                    )) {
                        Text("podcast_order_newest").tag(PodcastEpisodeOrder.newestFirst)
                        Text("podcast_order_oldest").tag(PodcastEpisodeOrder.oldestFirst)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ListeningSpace.podcast.tint)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .accessibilityLabel(Text("podcast_episode_order"))
            }
        }
    }

    @ViewBuilder
    private func moreMenu(_ show: PodcastShow) -> some View {
        if store.isSubscribed(show.id) {
            Button {
                Task { await store.refresh(showID: show.id) }
            } label: {
                Label("refresh", systemImage: "arrow.clockwise")
            }
            Button {
                store.markAllPlayed(showID: show.id)
            } label: {
                Label("podcast_mark_all_played", systemImage: "checkmark.circle")
            }
            Button {
                showsSettings = true
            } label: {
                Label("podcast_show_settings", systemImage: "slider.horizontal.3")
            }
        }
        if let url = PodcastShare.url(for: show) {
            ShareLink(item: url) {
                Label("share", systemImage: "square.and.arrow.up")
            }
        }
        if let website = show.websiteURL {
            Link(destination: website) {
                Label("podcast_open_website", systemImage: "safari")
            }
        }
        if PodcastAvailabilityService.shared.allowsCustomFeeds {
            Button {
                PodcastClipboard.copy(show.feedURL.absoluteString)
            } label: {
                Label("podcast_copy_feed_url", systemImage: "doc.on.doc")
            }
        }
        if store.isSubscribed(show.id) {
            Divider()
            Button(role: .destructive) {
                confirmsUnsubscribe = true
            } label: {
                Label("podcast_unsubscribe", systemImage: "minus.circle")
            }
        }
    }
}

/// 节目简介:排出来超过三行才给「展开」。按真实排版量,不按字数猜 ——
/// 中文七十来字就满三行,英文一百多字在宽屏上可能还不到。
private struct PodcastShowSummary: View {
    let text: String
    @Binding var isExpanded: Bool
    @State private var collapsedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private static let collapsedLineLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { measurements }
            if isExpanded || fullHeight > collapsedHeight + 1 {
                Button(isExpanded ? "podcast_show_less" : "podcast_show_more") {
                    pmWithAnimation(.panel) { isExpanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(ListeningSpace.podcast.tint)
            }
        }
    }

    /// 同宽排两份看不见的:限三行的和不限行的,一样高就是没被截。展开收起都不影响它们。
    private var measurements: some View {
        ZStack(alignment: .topLeading) {
            Text(text)
                .font(.subheadline)
                .lineLimit(Self.collapsedLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { collapsedHeight = $0 }
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
        }
        .hidden()
        .accessibilityHidden(true)
    }
}

enum PodcastClipboard {
    @MainActor
    static func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

/// 一档节目自己的设置:单集顺序、新单集自动下载、跳过片头片尾、这档的下载。
struct PodcastShowSettingsView: View {
    let showID: String

    @Environment(\.dismiss) private var dismiss
    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        Form {
            if let show = store.show(id: showID) {
                Section {
                    Picker("podcast_episode_order", selection: binding(\.episodeOrder, show: show)) {
                        Text(show.isSerial ? "podcast_order_auto_serial" : "podcast_order_auto_episodic").tag(PodcastEpisodeOrder?.none)
                        Text("podcast_order_newest").tag(PodcastEpisodeOrder?.some(.newestFirst))
                        Text("podcast_order_oldest").tag(PodcastEpisodeOrder?.some(.oldestFirst))
                    }
                    Toggle("podcast_auto_download", isOn: binding(\.autoDownloadsNewEpisodes, show: show))
                } footer: {
                    Text("podcast_auto_download_footer")
                }
                Section {
                    Picker("podcast_skip_intro", selection: binding(\.skipIntroSeconds, show: show)) {
                        ForEach(PodcastShowSettings.skipChoices, id: \.self) { seconds in
                            Text(secondsLabel(seconds)).tag(seconds)
                        }
                    }
                    Picker("podcast_skip_outro", selection: binding(\.skipOutroSeconds, show: show)) {
                        ForEach(PodcastShowSettings.skipChoices, id: \.self) { seconds in
                            Text(secondsLabel(seconds)).tag(seconds)
                        }
                    }
                } footer: {
                    Text("podcast_skip_footer")
                }
                let bytes = PodcastDownloadStore.shared.bytes(forShowID: show.id)
                if bytes > 0 {
                    Section {
                        LabeledContent("podcast_downloads_size", value: PodcastFormat.bytes(bytes))
                        Button("podcast_remove_show_downloads", role: .destructive) {
                            PodcastDownloadStore.shared.deleteAll(showID: show.id)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("podcast_show_settings")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("done") { dismiss() }
            }
        }
    }

    private func secondsLabel(_ seconds: Int) -> String {
        seconds == 0
            ? String(localized: "podcast_skip_off")
            : String(format: String(localized: "podcast_seconds_format %lld"), seconds)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PodcastShowSettings, Value>, show: PodcastShow) -> Binding<Value> {
        Binding(
            get: { store.show(id: showID)?.settings[keyPath: keyPath] ?? show.settings[keyPath: keyPath] },
            set: { value in store.updateDefinition(showID) { $0.settings[keyPath: keyPath] = value } }
        )
    }
}
