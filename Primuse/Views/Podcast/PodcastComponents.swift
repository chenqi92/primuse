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
    /// `onCancel` 给调用方清掉为这次放行记下的东西(比如要跳到的时间点)。
    func podcastInsecureHTTPAlert(
        host: Binding<String?>,
        onCancel: @escaping () -> Void = {},
        onAllow: @escaping () -> Void
    ) -> some View {
        alert("insecure_http_warning_title", isPresented: Binding(
            get: { host.wrappedValue != nil },
            set: { if !$0 { host.wrappedValue = nil } }
        )) {
            Button("cancel", role: .cancel) {
                host.wrappedValue = nil
                onCancel()
            }
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
    /// 行底下画一条分隔线,从文字左缘画起(封面多大就让开多少)。
    var showsDivider = false
    var onOpen: (() -> Void)?

    @Environment(AudioPlayerService.self) private var player
    /// 封面跟文字一样高时实际量出来的边长,下面那一排键和分隔线按它让开。
    @State private var matchedArtworkSide: CGFloat?

    private var store: PodcastStore { PodcastStore.shared }
    private var tint: Color { ListeningSpace.podcast.tint }
    private static let artworkSize: CGFloat = 60
    private static let artworkSpacing: CGFloat = 12
    private static let controlsHeight: CGFloat = 32

    /// 跨节目、不带简介的列表(首页与播客页的「最新单集」「喜欢的单集」):封面放大到和右边一栏一样高,
    /// 顶边对齐第一行字、底边对齐播放键(#320)。标题始终占两行,每一行封面一样大。
    private var matchesArtworkToText: Bool { showsArtwork && !showsSummary }

    private var textLeading: CGFloat {
        guard showsArtwork else { return 0 }
        let side = matchesArtworkToText ? (matchedArtworkSide ?? Self.artworkSize) : Self.artworkSize
        return side + Self.artworkSpacing
    }

    var body: some View {
        let state = store.state(for: episode)
        let isCurrent = player.currentSong?.id == episode.id
        Button {
            onOpen?()
        } label: {
            Group {
                if matchesArtworkToText {
                    SpokenWordHeaderRowLayout(
                        spacing: Self.artworkSpacing,
                        preferredSide: Self.artworkSize,
                        maximumSide: 124,
                        maximumWidthFraction: 0.32
                    ) {
                        SpokenWordHeaderArtworkSlot { side in
                            PodcastArtwork(episode: episode, show: show, size: side, cornerRadius: 10)
                        }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { side in
                            matchedArtworkSide = side
                        }
                        textColumn(state: state, isCurrent: isCurrent, reservesTitleLines: true)
                    }
                } else {
                    HStack(alignment: .top, spacing: Self.artworkSpacing) {
                        if showsArtwork {
                            PodcastArtwork(episode: episode, show: show, size: Self.artworkSize, cornerRadius: 8)
                        }
                        textColumn(state: state, isCurrent: isCurrent, reservesTitleLines: false)
                        Spacer(minLength: 0)
                    }
                }
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
            .padding(.leading, textLeading)
            .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().padding(.leading, textLeading)
            }
        }
    }

    private func textColumn(state: PodcastEpisodeState, isCurrent: Bool, reservesTitleLines: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metaLine(state: state)
            Text(episode.title)
                .font(.body.weight(.semibold))
                .foregroundStyle(state.isFinished && !isCurrent ? .secondary : .primary)
                .lineLimit(2, reservesSpace: reservesTitleLines)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
///
/// 菜单内容里挂不了放行确认的 alert:明文 http 的单集由挂菜单的那个视图弹
/// (`needsInsecureConsent`),长按菜单直接用 `podcastEpisodeContextMenu`。
struct PodcastEpisodeMenu: View {
    let episode: PodcastEpisode
    var continuing: [PodcastEpisode] = []
    /// 给了就多一项「前往节目」(单集页、跨节目的列表里用)。
    var openShow: ((String) -> Void)?
    var needsInsecureConsent: (@MainActor (String) -> Void)?
    /// 给了就多一项「生成文稿」:没有文字稿的单集,或生成过的(重新生成)(#314)。
    var generateTranscript: (@MainActor (PodcastEpisode) -> Void)?

    @Environment(AudioPlayerService.self) private var player

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let state = store.state(for: episode)
        Button {
            PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { host in
                needsInsecureConsent?(host)
            }
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
        // 喜欢的单集列在「我喜欢」页底下和播客页里,不进歌单本身。
        let isLiked = store.isLiked(episodeID: episode.id)
        Button {
            PMHaptics.likeToggled(isLiked: !isLiked)
            store.setLiked(!isLiked, episode: episode)
        } label: {
            Label(isLiked ? "a11y_unlike" : "a11y_like", systemImage: isLiked ? "heart.slash" : "heart")
        }
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
        if let generateTranscript {
            let generated = SpokenTranscriptGenerator.shared.records[episode.id] != nil
            if episode.transcriptURL == nil || generated {
                Button {
                    generateTranscript(episode)
                } label: {
                    Label(
                        generated ? "transcript_generation_regenerate" : "transcript_generation_action",
                        systemImage: "waveform.and.mic"
                    )
                }
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
        // 单集没有自己的网页时分享节目。
        if let link = episode.link ?? store.show(id: episode.showID).flatMap(PodcastShare.url(for:)) {
            ShareLink(item: link) {
                Label("share", systemImage: "square.and.arrow.up")
            }
        }
    }
}

/// 单集行的长按菜单,连同菜单里「播放」碰到明文 http 时的放行确认。
private struct PodcastEpisodeContextMenu: ViewModifier {
    let episode: PodcastEpisode
    let continuing: [PodcastEpisode]
    let openShow: ((String) -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @State private var pendingInsecureHost: String?
    @State private var transcriptGenerationSong: Song?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                PodcastEpisodeMenu(
                    episode: episode,
                    continuing: continuing,
                    openShow: openShow,
                    needsInsecureConsent: { pendingInsecureHost = $0 },
                    generateTranscript: { episode in
                        transcriptGenerationSong = PodcastPlaybackSong.song(
                            for: episode,
                            show: PodcastStore.shared.show(id: episode.showID)
                        )
                    }
                )
            }
            .podcastInsecureHTTPAlert(host: $pendingInsecureHost) {
                PodcastPlaybackLauncher.play(episode, continuing: continuing, player: player) { _ in }
            }
            .sheet(item: $transcriptGenerationSong) { song in
                SpokenTranscriptGenerationSheet(song: song)
                    .environment(AppServices.shared.musicIntelligence)
            }
    }
}

/// 喜欢的单集,最近喜欢的在前。播客页一段、整页列表、「我喜欢」页底下都用它。
/// 放完一集接着放列表里的下一集;feed 里已经没有的那几集点了不进单集页,播放键照样能放。
/// 喜欢的本地节目单集(自己的文件标成播客)接在订阅单集后面:它们只记着点心先后,没有喜欢的时间。
struct PodcastLikedEpisodeRows: View {
    let items: [PodcastLikedEpisodeItem]
    var localSongs: [Song] = []
    var limit: Int?
    var onOpen: ((String) -> Void)?
    var openShow: ((String) -> Void)?
    var openLocalShow: ((String) -> Void)?

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let episodes = items.map(\.episode)
        let shownCount = limit ?? (items.count + localSongs.count)
        let shown = Array(items.prefix(shownCount))
        let shownLocal = Array(localSongs.prefix(max(0, shownCount - shown.count)))
        ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
            let continuing = Array(episodes.dropFirst(index + 1).prefix(30))
            let canOpen = onOpen != nil && store.episode(id: item.episode.id) != nil
            PodcastEpisodeRow(
                episode: item.episode,
                show: item.show,
                showsArtwork: true,
                showsSummary: false,
                continuing: continuing,
                showsDivider: index < shown.count - 1 || !shownLocal.isEmpty,
                onOpen: canOpen ? { onOpen?(item.episode.id) } : nil
            )
            .podcastEpisodeContextMenu(item.episode, continuing: continuing, openShow: openShow)
        }
        ForEach(Array(shownLocal.enumerated()), id: \.element.id) { index, song in
            LikedLocalPodcastEpisodeRow(
                song: song,
                continuing: Array(localSongs.dropFirst(index + 1).prefix(30)),
                showsDivider: index < shownLocal.count - 1,
                openShow: openLocalShow
            )
        }
    }
}

/// 「我喜欢」页底下那一段:喜欢的播客单集不进歌单本身,在这里列出来;喜欢的本地节目单集
/// 照旧记在「我喜欢」里,但不混进上面的歌曲,也排在这里。
/// Mac 的详情区不是导航栈,点一行不进单集页(行里的播放键照样能放)。
struct PodcastLikedEpisodesFooter: View {
    var opensEpisodes = true

    @Environment(MusicLibrary.self) private var library
    @State private var pushedEpisodeID: String?
    @State private var pushedLocalShowID: String?

    private var store: PodcastStore { PodcastStore.shared }

    var body: some View {
        let items = store.likedEpisodes()
        let localSongs = library.likedLocalPodcastSongs()
        if !items.isEmpty || !localSongs.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                PodcastSectionHeader(titleKey: "podcast_liked_episodes")
                if opensEpisodes {
                    PodcastLikedEpisodeRows(
                        items: items,
                        localSongs: localSongs,
                        onOpen: { pushedEpisodeID = $0 },
                        openLocalShow: { pushedLocalShowID = $0 }
                    )
                } else {
                    PodcastLikedEpisodeRows(items: items, localSongs: localSongs)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .navigationDestination(item: $pushedEpisodeID) { episodeID in
                PodcastEpisodeDetailView(episodeID: episodeID)
            }
            .navigationDestination(item: $pushedLocalShowID) { showID in
                SpokenWordBookDetailView(bookID: showID, collection: .localPodcasts)
            }
        }
    }
}

/// 「喜欢的单集」里的一集本地节目(自己的文件标成播客)。排法同订阅单集行:封面跟文字一样高、
/// 节目名在日期前。没有单集详情页,整行点一下就放(正在放的这一集是暂停),放完接着放列表里后面几集。
struct LikedLocalPodcastEpisodeRow: View {
    let song: Song
    var continuing: [Song] = []
    var showsDivider = false
    var openShow: ((String) -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @Environment(MusicLibrary.self) private var library
    /// 封面跟文字一样高时实际量出来的边长,下面那一排键和分隔线按它让开。
    @State private var matchedArtworkSide: CGFloat?

    private static let artworkSize: CGFloat = 60
    private static let artworkSpacing: CGFloat = 12
    private static let controlsHeight: CGFloat = 32

    private var textLeading: CGFloat {
        (matchedArtworkSide ?? Self.artworkSize) + Self.artworkSpacing
    }

    /// 本地节目按专辑(节目名)成组;没写专辑的退回艺人。
    private var showTitle: String? {
        let album = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !album.isEmpty { return album }
        let artist = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return artist.isEmpty ? nil : artist
    }

    var body: some View {
        let item = SpokenWordBookSupport.item(for: song, store: SpokenWordStore.shared)
        let isCurrent = player.currentSong?.id == song.id
        Button {
            play()
        } label: {
            SpokenWordHeaderRowLayout(
                spacing: Self.artworkSpacing,
                preferredSide: Self.artworkSize,
                maximumSide: 124,
                maximumWidthFraction: 0.32
            ) {
                SpokenWordHeaderArtworkSlot { side in
                    CachedArtworkView(
                        coverRef: song.coverArtFileName,
                        songID: song.id,
                        size: side,
                        cornerRadius: 10,
                        sourceID: song.sourceID,
                        filePath: song.filePath,
                        fileFormat: song.fileFormat
                    )
                    .frame(width: side, height: side)
                }
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { side in
                    matchedArtworkSide = side
                }
                VStack(alignment: .leading, spacing: 4) {
                    metaLine(item: item)
                    Text(library.displayTitle(for: song))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(item.isFinished && !isCurrent ? .secondary : .primary)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    // 下面那一排键盖在这里(见 overlay),这里只占位置。
                    Color.clear
                        .frame(height: Self.controlsHeight)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottomLeading) {
            LocalPodcastEpisodeControls(item: item)
                .frame(height: Self.controlsHeight)
                .padding(.leading, textLeading)
                .padding(.bottom, 10)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().padding(.leading, textLeading)
            }
        }
        .contextMenu { menu(item: item) }
        .accessibilityIdentifier("podcast.liked.localEpisode")
    }

    private func metaLine(item: SpokenWordBookItem) -> some View {
        HStack(spacing: 6) {
            if let showTitle {
                Text(showTitle)
                    .lineLimit(1)
                Text(verbatim: "·")
            }
            if let date = PodcastFormat.date(item.addedAt) {
                Text(date)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func menu(item: SpokenWordBookItem) -> some View {
        Button {
            play()
        } label: {
            Label(item.position != nil && !item.isFinished ? "podcast_continue" : "podcast_play", systemImage: "play.fill")
        }
        Button {
            _ = player.insertNextInQueue([song])
        } label: {
            Label("insert_next_short", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Divider()
        Button {
            PMHaptics.likeToggled(isLiked: false)
            library.toggleLiked(songID: song.id)
        } label: {
            Label("a11y_unlike", systemImage: "heart.slash")
        }
        Button {
            SpokenWordStore.shared.markFinished(!item.isFinished, songIDs: [song.id])
        } label: {
            if item.isFinished {
                Label("podcast_mark_unplayed", systemImage: "circle")
            } else {
                Label("podcast_mark_played", systemImage: "checkmark.circle")
            }
        }
        if let openShow, let showID = library.localPodcastShowID(forSongID: song.id) {
            Button {
                openShow(showID)
            } label: {
                Label("podcast_go_to_show", systemImage: "rectangle.stack")
            }
        }
    }

    private func play() {
        if player.currentSong?.id == song.id {
            player.togglePlayPause()
            return
        }
        let queue = [song] + continuing
        Task { await player.play(queue: queue, startingAt: 0) }
    }
}

extension View {
    func podcastEpisodeContextMenu(
        _ episode: PodcastEpisode,
        continuing: [PodcastEpisode] = [],
        openShow: ((String) -> Void)? = nil
    ) -> some View {
        modifier(PodcastEpisodeContextMenu(episode: episode, continuing: continuing, openShow: openShow))
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
/// 节目页的键挤在封面右边那一栏,窄屏、大字号下放不下整句时先去掉图标,再不行只留图标。
struct PodcastPrimaryKeyLabel: View {
    let titleKey: LocalizedStringKey
    let systemImage: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(titleKey)
                    .lineLimit(1)
            }
            Text(titleKey)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Image(systemName: systemImage)
                .accessibilityLabel(Text(titleKey))
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Header row

/// 详情页顶上「封面 + 右边一栏」那一行(书籍详情、播客节目页、本地节目页、单集行):
/// 封面是正方形,顶边对齐右栏第一行字、底边对齐右栏最后一样东西(通常是按钮)。
///
/// 只放两个子视图:先封面、后右栏。封面边长先取 `preferredSide`;右栏在剩下的宽度里排出来
/// 比它高时,封面跟着长到右栏那么高(不超过 `maximumSide`,也不超过整行宽度的
/// `maximumWidthFraction`),右栏变窄可能又多折一行,所以多量几次。右栏比封面矮时,
/// 把右栏撑到封面那么高 —— 右栏里在按钮上面垫一个 `Spacer`,按钮就落到封面底边。
struct SpokenWordHeaderRowLayout: Layout {
    var spacing: CGFloat = 16
    var preferredSide: CGFloat
    var maximumSide: CGFloat
    var maximumWidthFraction: CGFloat = 0.42

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? (preferredSide + spacing + 260)
        let metrics = metrics(width: width, column: subviews[1])
        return CGSize(width: width, height: max(metrics.side, metrics.columnHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let metrics = metrics(width: bounds.width, column: subviews[1])
        let rowHeight = max(metrics.side, metrics.columnHeight)
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: metrics.side, height: metrics.side)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX + metrics.side + spacing, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: columnWidth(bounds.width, side: metrics.side), height: rowHeight)
        )
    }

    private func columnWidth(_ width: CGFloat, side: CGFloat) -> CGFloat {
        max(width - side - spacing, 0)
    }

    private func metrics(width: CGFloat, column: LayoutSubview) -> (side: CGFloat, columnHeight: CGFloat) {
        let cap = max(min(maximumSide, width * maximumWidthFraction), min(preferredSide, width * 0.5))
        var side = min(preferredSide, cap)
        var height = column.sizeThatFits(ProposedViewSize(width: columnWidth(width, side: side), height: nil)).height
        // 封面只会变大:每长一次右栏就窄一点、可能更高,最多追三次。
        for _ in 0..<3 where height > side + 0.5 && side < cap {
            side = min(height.rounded(.up), cap)
            height = column.sizeThatFits(ProposedViewSize(width: columnWidth(width, side: side), height: nil)).height
        }
        return (side, height)
    }
}

/// `SpokenWordHeaderRowLayout` 里的封面格:封面视图都只收固定边长,这里按版面实际给的边长画。
struct SpokenWordHeaderArtworkSlot<Artwork: View>: View {
    @ViewBuilder var artwork: (CGFloat) -> Artwork

    var body: some View {
        Color.clear
            .overlay {
                GeometryReader { proxy in
                    let side = min(proxy.size.width, proxy.size.height)
                    if side > 1 {
                        artwork(side)
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                    }
                }
            }
    }
}

/// 订阅节目页与本地节目页头部共用的尺寸。
enum PodcastHeaderMetrics {
    static let preferredSide: CGFloat = 128
    static let maximumSide: CGFloat = 176
    /// 宽屏(iPad、Mac)上按钮不跟着右栏拉成一长条。
    static let actionRowMaxWidth: CGFloat = 420
}

/// 节目页单集列表上方的排序键:图标后面写着现在按什么排,订阅节目与本地节目一样。
struct PodcastOrderMenuLabel: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 13, weight: .semibold))
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(ListeningSpace.podcast.tint)
        .frame(height: 32)
        .contentShape(Rectangle())
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

/// 「…」菜单里的几项:刷新、按地址添加、导入导出、设置。页内的操作条和 Mac 播客页共用。
struct PodcastActionsMenuItems: View {
    let navigation: PodcastNavigationModel

    private var store: PodcastStore { PodcastStore.shared }
    private var availability: PodcastAvailabilityService { PodcastAvailabilityService.shared }

    var body: some View {
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
        PodcastSectionsEditorButton(navigation: navigation)
        Button {
            navigation.showsSettings = true
        } label: {
            Label("podcast_settings", systemImage: "gearshape")
        }
    }
}

