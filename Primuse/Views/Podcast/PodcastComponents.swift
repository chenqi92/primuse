import PrimuseKit
import SwiftUI

// MARK: - Artwork

/// 节目或单集的封面。单集没有自己的封面时用节目的,缓存键也跟着用节目的,同一张图只存一份。
struct PodcastArtwork: View {
    let url: URL?
    let cacheKey: String
    var size: CGFloat
    var cornerRadius: CGFloat = 10

    init(show: PodcastShow?, size: CGFloat, cornerRadius: CGFloat = 10) {
        url = show?.artworkURL
        cacheKey = show?.id ?? "podcast-placeholder"
        self.size = size
        self.cornerRadius = cornerRadius
    }

    init(episode: PodcastEpisode, show: PodcastShow?, size: CGFloat, cornerRadius: CGFloat = 10) {
        if let own = episode.artworkURL {
            url = own
            cacheKey = episode.id
        } else {
            url = show?.artworkURL
            cacheKey = show?.id ?? episode.showID
        }
        self.size = size
        self.cornerRadius = cornerRadius
    }

    init(directoryShow: PodcastDirectoryShow, size: CGFloat, cornerRadius: CGFloat = 10) {
        url = directoryShow.artworkURL
        cacheKey = "podcast-directory:\(directoryShow.id)"
        self.size = size
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        CachedArtworkView(
            coverRef: url?.absoluteString,
            songID: cacheKey,
            size: size,
            cornerRadius: cornerRadius,
            sourceID: PodcastPlaybackSong.sourceID,
            placeholderIcon: ListeningSpace.podcast.systemImage
        )
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Play button

/// 单集行尾的播放键:外圈是这一集听到哪,正在放时变成暂停,加载时转圈。
struct PodcastPlayButton: View {
    let episode: PodcastEpisode
    var continuing: [PodcastEpisode] = []
    var size: CGFloat = 34

    @Environment(AudioPlayerService.self) private var player
    @State private var pendingInsecureHost: String?

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        let state = store.state(for: episode)
        let isCurrent = player.currentSong?.id == episode.id
        let isPlaying = isCurrent && player.isPlaying
        let fraction = progressFraction(state: state, isCurrent: isCurrent)
        Button {
            if isCurrent {
                player.togglePlayPause()
            } else {
                PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { pendingInsecureHost = $0 }
            }
        } label: {
            ZStack {
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
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(isPlaying ? "pause" : "play"))
        .accessibilityIdentifier("podcast.play." + episode.id)
        .podcastInsecureHTTPAlert(host: $pendingInsecureHost) {
            PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { _ in }
        }
    }

    private func progressFraction(state: PodcastEpisodeState, isCurrent: Bool) -> CGFloat {
        let total = (isCurrent && player.duration > 0) ? player.duration : (episode.duration ?? 0)
        guard total > 0 else { return 0 }
        if state.isFinished { return 1 }
        let position = isCurrent ? player.currentTime : (state.position ?? 0)
        return CGFloat(min(1, max(0, position / total)))
    }
}

/// 起播前的那一步:明文 http 的音频地址先问用户要不要放行,其余直接交给播放器。
enum PodcastPlaybackLauncher {
    @MainActor
    static func play(
        _ episode: PodcastEpisode,
        continuing: [PodcastEpisode] = [],
        from position: TimeInterval? = nil,
        player: AudioPlayerService,
        needsInsecureConsent: @escaping @MainActor (String) -> Void
    ) {
        Task { @MainActor in
            if !PodcastDownloadStore.shared.isDownloaded(episode.id) {
                do {
                    _ = try await PodcastNetwork.reachableURL(for: episode.enclosureURL)
                } catch PodcastNetwork.Failure.insecureHTTP(let host) {
                    needsInsecureConsent(host)
                    return
                } catch {}
            }
            await player.playPodcast(episode, continuing: continuing, from: position)
        }
    }
}

extension View {
    /// 明文 http 主机的放行确认。和电台、音乐源用同一套文案与信任记录。
    func podcastInsecureHTTPAlert(host: Binding<String?>, onAllow: @escaping () -> Void) -> some View {
        alert("insecure_http_warning_title", isPresented: Binding(
            get: { host.wrappedValue != nil },
            set: { if !$0 { host.wrappedValue = nil } }
        )) {
            Button("cancel", role: .cancel) { host.wrappedValue = nil }
            Button("insecure_http_continue", role: .destructive) {
                if let target = host.wrappedValue {
                    SSLTrustStore.shared.allowInsecureHTTP(domain: target)
                }
                host.wrappedValue = nil
                onAllow()
            }
        } message: {
            Text(String(format: String(localized: "insecure_http_warning_message %@"), host.wrappedValue ?? ""))
        }
    }
}

// MARK: - Download button

struct PodcastDownloadButton: View {
    let episode: PodcastEpisode
    var compact = false

    private var downloads: PodcastDownloadStore { PodcastDownloadStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        Group {
            if downloads.isDownloaded(episode.id) {
                Menu {
                    Button(role: .destructive) {
                        downloads.delete(episode.id)
                    } label: {
                        Label("podcast_remove_download", systemImage: "trash")
                    }
                } label: {
                    icon("arrow.down.circle.fill", color: tint)
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(Text("podcast_downloaded"))
            } else {
                switch downloads.states[episode.id] {
                case .downloading(let fraction):
                    Button {
                        downloads.cancel(episode.id)
                    } label: {
                        ZStack {
                            Circle().stroke(tint.opacity(0.2), lineWidth: 2)
                            Circle()
                                .trim(from: 0, to: max(0.03, fraction))
                                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: "stop.fill")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(tint)
                        }
                        .frame(width: 18, height: 18)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("podcast_cancel_download"))
                case .queued:
                    Button {
                        downloads.cancel(episode.id)
                    } label: {
                        ProgressView().controlSize(.small).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("podcast_cancel_download"))
                case .failed:
                    Button {
                        downloads.download(episode)
                    } label: {
                        icon("exclamationmark.arrow.circlepath", color: .orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("podcast_retry_download"))
                case nil:
                    Button {
                        downloads.download(episode)
                    } label: {
                        icon("arrow.down.circle", color: .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("podcast_download"))
                }
            }
        }
        .accessibilityIdentifier("podcast.download." + episode.id)
    }

    private func icon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: compact ? 17 : 19, weight: .regular))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
    }
}

// MARK: - Episode row

/// 单集列表的一行。节目页里不显示节目封面(整页都是这一档),跨节目的列表里显示。
///
/// 整行是一个按钮(进单集页),播放键和下载键压在它上面、不在它里面 ——
/// 按钮套按钮时点哪个算哪个说不准,列表里还会一下触发两个。
struct PodcastEpisodeRow: View {
    let episode: PodcastEpisode
    var show: PodcastShow?
    var showsArtwork = false
    var showsSummary = true
    var continuing: [PodcastEpisode] = []
    var onOpen: (() -> Void)?

    @Environment(AudioPlayerService.self) private var player

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }
    private static let artworkSize: CGFloat = 60
    private static let controlsHeight: CGFloat = 32

    var body: some View {
        let state = store.state(for: episode)
        let isCurrent = player.currentSong?.id == episode.id
        Button {
            onOpen?()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if showsArtwork {
                    PodcastArtwork(episode: episode, show: show, size: Self.artworkSize, cornerRadius: 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    metaLine(state: state)
                    Text(episode.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(state.isFinished && !isCurrent ? .secondary : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if showsSummary, let summary = PodcastEpisodeSummaryCache.shared.summary(for: episode) {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    // 下面那一排键盖在这里(见 overlay),这里只占位置。
                    Color.clear
                        .frame(height: Self.controlsHeight)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                PodcastPlayButton(episode: episode, continuing: continuing, size: 30)
                statusText(state: state, isCurrent: isCurrent)
                Spacer(minLength: 0)
                PodcastDownloadButton(episode: episode, compact: true)
            }
            .frame(height: Self.controlsHeight)
            .padding(.leading, showsArtwork ? Self.artworkSize + 12 : 0)
            .padding(.bottom, 10)
        }
    }

    private func metaLine(state: PodcastEpisodeState) -> some View {
        HStack(spacing: 6) {
            if showsArtwork, let show {
                Text(show.title)
                    .lineLimit(1)
                Text(verbatim: "·")
            }
            if let date = PodcastFormat.date(episode.publishedAt) {
                Text(date)
            }
            if let label = kindLabel {
                Text(label)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)
            }
            if episode.isVideo {
                Image(systemName: "video")
                    .accessibilityLabel(Text("podcast_video_episode"))
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var kindLabel: String? {
        switch episode.kind {
        case .trailer: return String(localized: "podcast_kind_trailer")
        case .bonus: return String(localized: "podcast_kind_bonus")
        case .full:
            if let number = episode.number, store.showsEpisodeNumbers(forShowID: episode.showID) {
                if let season = episode.season {
                    return String(format: String(localized: "podcast_season_episode_format"), season, number)
                }
                return String(format: String(localized: "podcast_episode_number_format"), number)
            }
            return nil
        }
    }

    @ViewBuilder
    private func statusText(state: PodcastEpisodeState, isCurrent: Bool) -> some View {
        let total = episode.duration ?? (isCurrent ? player.duration : 0)
        Group {
            if state.isFinished, !isCurrent {
                Label("podcast_played", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
            } else if let position = isCurrent ? player.currentTime : state.position, position > 0, total > position {
                Text(PodcastFormat.remaining(total - position))
            } else if let duration = PodcastFormat.duration(total) {
                Text(duration)
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(isCurrent ? tint : .secondary)
    }
}

/// 列表行的摘要按单集缓存:几百行滚动时不必每次重新扫一遍说明。
@MainActor
final class PodcastEpisodeSummaryCache {
    static let shared = PodcastEpisodeSummaryCache()
    private var cache: [String: String] = [:]

    func summary(for episode: PodcastEpisode) -> String? {
        let key = episode.id + "|" + String(episode.showNotes?.count ?? 0)
        if let hit = cache[key] { return hit.isEmpty ? nil : hit }
        let value = episode.subtitle.flatMap { PodcastShowNotes.plainSummary($0, limit: 160) }
            ?? PodcastShowNotes.plainSummary(episode.showNotes, limit: 160)
            ?? ""
        if cache.count > 3000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value.isEmpty ? nil : value
    }
}

// MARK: - Episode actions

/// 单集的长按/行尾菜单。节目页、最新单集、首页共用。
struct PodcastEpisodeMenu: View {
    let episode: PodcastEpisode
    var continuing: [PodcastEpisode] = []
    /// 给了就多一项「前往节目」(单集页、跨节目的列表里用)。
    var openShow: ((String) -> Void)?

    @Environment(AudioPlayerService.self) private var player

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let state = store.state(for: episode)
        Button {
            PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { _ in }
        } label: {
            Label(state.isInProgress ? "podcast_continue" : "podcast_play", systemImage: "play.fill")
        }
        Button {
            let song = PodcastPlaybackSong.song(for: episode, show: store.show(id: episode.showID))
            _ = player.insertNextInQueue([song])
        } label: {
            Label("insert_next_short", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            let song = PodcastPlaybackSong.song(for: episode, show: store.show(id: episode.showID))
            player.appendToQueue([song])
        } label: {
            Label("add_to_queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        Divider()
        Button {
            store.setPlayed(!state.isFinished, episode: episode)
        } label: {
            if state.isFinished {
                Label("podcast_mark_unplayed", systemImage: "circle")
            } else {
                Label("podcast_mark_played", systemImage: "checkmark.circle")
            }
        }
        if store.isSubscribed(episode.showID), episode.publishedAt != nil {
            Button {
                store.markOlderPlayed(than: episode)
            } label: {
                Label("podcast_mark_older_played", systemImage: "checkmark.circle.badge.questionmark")
            }
        }
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
        }
        if let openShow {
            Divider()
            Button {
                openShow(episode.showID)
            } label: {
                Label("podcast_go_to_show", systemImage: "rectangle.stack")
            }
        }
        if let link = episode.link {
            ShareLink(item: link) {
                Label("share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - Show notes

/// 节目说明。时间点点了跳过去(这一集正在放就直接跳,否则从那里开始放),链接用系统浏览器打开。
struct PodcastShowNotesView: View {
    let blocks: [PodcastShowNotes.Block]
    var onSeek: (TimeInterval) -> Void

    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let seconds = PodcastShowNotes.seekSeconds(from: url) {
                onSeek(seconds)
                return .handled
            }
            return .systemAction
        })
    }

    @ViewBuilder
    private func blockView(_ block: PodcastShowNotes.Block) -> some View {
        switch block {
        case .paragraph(let runs):
            Text(attributed(runs))
                .font(.body)
        case .heading(let runs):
            Text(attributed(runs))
                .font(.headline)
                .padding(.top, 4)
        case .quote(let runs):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(attributed(runs))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        case .listItem(let runs, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: marker)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 14, alignment: .trailing)
                Text(attributed(runs))
                    .font(.body)
            }
        }
    }

    private func attributed(_ runs: [PodcastShowNotes.Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            switch run {
            case .text(let text, let bold, let italic):
                var piece = AttributedString(text)
                if bold && italic {
                    piece.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
                } else if bold {
                    piece.inlinePresentationIntent = .stronglyEmphasized
                } else if italic {
                    piece.inlinePresentationIntent = .emphasized
                }
                result += piece
            case .link(let text, let url):
                var piece = AttributedString(text)
                piece.link = url
                piece.foregroundColor = tint
                result += piece
            case .timestamp(let text, let seconds):
                var piece = AttributedString(text)
                piece.link = PodcastShowNotes.seekURL(seconds)
                piece.foregroundColor = tint
                piece.inlinePresentationIntent = .stronglyEmphasized
                result += piece
            }
        }
        return result
    }
}

// MARK: - Action keys

/// 节目页、单集页主键旁边的圆形小键:同一个尺寸、同一种底色,图标默认次要色。
struct PodcastCircleKey: View {
    let systemName: String
    var foreground: Color?
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foreground.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            .frame(width: size, height: size)
            .background(.quaternary.opacity(0.6), in: Circle())
            .contentShape(Circle())
    }
}

/// 页面顶上的主键:实心、撑满剩下的宽度,字不折行。
/// 不用 `Label`:放在 List 行里时它的图标会被染成行的强调色,和白字对不上。
struct PodcastPrimaryKeyLabel: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            Text(titleKey)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Section header

struct PodcastSectionHeader<Trailing: View>: View {
    let titleKey: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(titleKey)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension PodcastSectionHeader where Trailing == EmptyView {
    init(titleKey: LocalizedStringKey) {
        self.titleKey = titleKey
        self.trailing = { EmptyView() }
    }
}

// MARK: - Mac chrome

/// Mac 的详情区藏了窗口工具栏,推进来的页面自己画返回键;iOS 用系统导航栏的,这里什么都不画。
struct PodcastInlineBackButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(macOS)
        Button {
            dismiss()
        } label: {
            Label("back", systemImage: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("podcast.back")
        #endif
    }
}

/// 发现键 + 「…」菜单(刷新、按地址添加、导入导出、设置)。首页「播客」那一面和 Mac 的播客页用;
/// iOS 播客页这些在导航栏上。
struct PodcastInlineActionsBar: View {
    let navigation: PodcastNavigationModel

    private var store: PodcastStore { PodcastStore.shared }
    private var availability: PodcastAvailabilityService { PodcastAvailabilityService.shared }
    private var tint: Color { ListeningSpace.podcast.tint }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                navigation.showsDiscover = true
            } label: {
                Label("podcast_discover", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .accessibilityIdentifier("podcast.inline.discover")
            if store.isRefreshingAll {
                ProgressView().controlSize(.small)
            }
            Spacer(minLength: 0)
            Menu {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Label("podcast_refresh_all", systemImage: "arrow.clockwise")
                }
                .disabled(store.shows.isEmpty || store.isRefreshingAll)
                if availability.allowsCustomFeeds {
                    Button {
                        navigation.showsAddFeed = true
                    } label: {
                        Label("podcast_add_by_url", systemImage: "link")
                    }
                    Button {
                        navigation.showsOPMLImporter = true
                    } label: {
                        Label("podcast_import_opml", systemImage: "square.and.arrow.down")
                    }
                }
                if !store.shows.isEmpty {
                    ShareLink(item: PodcastOPMLDocument(), preview: SharePreview(String(localized: "podcast_export_opml"))) {
                        Label("podcast_export_opml", systemImage: "square.and.arrow.up")
                    }
                }
                Divider()
                Button {
                    navigation.showsSettings = true
                } label: {
                    Label("podcast_settings", systemImage: "gearshape")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 36, height: 28)
                    .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
            .tint(tint)
            .accessibilityLabel(Text("more"))
            .accessibilityIdentifier("podcast.inline.more")
        }
    }
}
