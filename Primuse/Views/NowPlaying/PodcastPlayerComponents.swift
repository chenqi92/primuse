import SwiftUI
import PrimuseKit

// MARK: - Sheets

/// 播放页上打开的播客页面:这一集的详情,或者这档节目。
/// 单集不在曲库里,「转到这本书」对它是空页,iPhone、iPad、Mac 都换成这两页。
enum PodcastPlayerSheetTarget: Identifiable, Hashable {
    case episode(String)
    case show(String)

    var id: String {
        switch self {
        case .episode(let id): "episode:\(id)"
        case .show(let id): "show:\(id)"
        }
    }
}

struct NowPlayingPodcastSheet: View {
    let target: PodcastPlayerSheetTarget

    var body: some View {
        NavigationStack {
            switch target {
            case .episode(let id):
                PodcastEpisodeDetailView(episodeID: id)
            case .show(let id):
                PodcastShowDetailView(source: .show(id))
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}

// MARK: - Episode actions

/// 播放页菜单里对正在播的这一集能做的事。iPhone 的更多菜单和 Mac 的菜单共用。
@MainActor
enum PodcastPlayerEpisodeActions {
    enum Download: Equatable {
        /// 已经下好了。正在播它,不给删除:删掉解码器正在读的文件只会卡住。
        case downloaded
        case available
        case inProgress
    }

    static func episode(_ player: AudioPlayerService) -> (episode: PodcastEpisode, show: PodcastShow)? {
        guard let song = player.currentSong, PodcastPlaybackSong.isEpisode(song) else { return nil }
        return PodcastStore.shared.episode(id: song.id)
    }

    /// 节目还订着(或开着预览)才有节目页可去。
    static func showID(_ player: AudioPlayerService) -> String? {
        episode(player)?.show.id
    }

    static func download(_ player: AudioPlayerService) -> Download? {
        guard let found = episode(player) else { return nil }
        let downloads = PodcastDownloadStore.shared
        if downloads.isDownloaded(found.episode.id) { return .downloaded }
        switch downloads.states[found.episode.id] {
        case .queued, .downloading: return .inProgress
        case .failed, nil: return .available
        }
    }

    static func toggleDownload(_ player: AudioPlayerService) {
        guard let found = episode(player) else { return }
        switch download(player) {
        case .available: PodcastDownloadStore.shared.download(found.episode)
        case .inProgress: PodcastDownloadStore.shared.cancel(found.episode.id)
        case .downloaded, nil: break
        }
    }
}

// MARK: - Up next

/// 播客播放页的「接下来」:队列里这一集之后的单集,和音乐的「接下来播放」是同一份队列。
/// 点一行放那一集(后面的不动),左滑或长按删掉一行,右上角清空。
/// iPhone 上在目录面板的 sheet 里,iPad、折叠屏与 Mac 在播放页右栏里。
struct PodcastUpNextList: View {
    /// 嵌在播放页里时按播放页的颜色画;sheet 里用系统颜色。
    var palette: SpokenWordPlayerPalette?
    /// 点了一行之后(sheet 借此关掉)。
    var onOpen: (() -> Void)?

    @Environment(AudioPlayerService.self) private var player
    @AppStorage(PodcastPlaybackSettings.continuousPlaybackKey) private var continuousPlayback = true

    /// 队列里插进整张专辑也只列前面这些:这里是给听播客的人看后面几集的。
    private static let visibleLimit = 100

    private var primary: Color { palette?.primary ?? .primary }
    private var secondary: Color { palette?.secondary ?? .secondary }
    private var accent: Color { palette?.accent ?? .accentColor }

    var body: some View {
        // 读这两样让列表跟着收听进度与听完标记刷新。
        let _ = SpokenWordStore.shared.positions.count
        let _ = SpokenWordStore.shared.finishedAt.count
        let upcoming = Array(
            player.upcomingQueueEntries
                .lazy
                .filter { $0.id.roundOffset == 0 }
                .prefix(Self.visibleLimit)
        )
        List {
            if upcoming.isEmpty {
                emptyState
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                Section {
                    ForEach(upcoming) { item in
                        row(item)
                    }
                } header: {
                    header(upcoming)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(palette == nil ? .automatic : .hidden)
    }

    private func header(_ upcoming: [QueuePresentationEntry]) -> some View {
        HStack {
            Text("up_next")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(secondary)
            Spacer()
            if player.canRemoveUpcomingQueueEntries {
                Button("clear") {
                    pmWithAnimation(.list) {
                        // 从后往前删,每删一项队列里前面的位置都不变。
                        for item in upcoming.reversed() {
                            _ = player.removeUpcomingQueueEntry(occurrence(item))
                        }
                    }
                }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(accent)
            }
        }
        .textCase(nil)
    }

    private func row(_ item: QueuePresentationEntry) -> some View {
        Button {
            guard let index = player.queueEntries.firstIndex(where: { $0.id == item.entry.id }) else { return }
            Task { await player.playFromQueue(at: index) }
            onOpen?()
        } label: {
            PodcastUpNextRow(song: item.entry.song, palette: palette)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .contextMenu {
            if player.canRemoveUpcomingQueueEntries {
                Button(role: .destructive) {
                    remove(item)
                } label: {
                    Label("podcast_player_remove_from_up_next", systemImage: "minus.circle")
                }
            }
        }
        #if os(iOS)
        .swipeActions {
            if player.canRemoveUpcomingQueueEntries {
                Button(role: .destructive) {
                    remove(item)
                } label: {
                    Label("podcast_player_remove_from_up_next", systemImage: "minus.circle")
                }
            }
        }
        #endif
    }

    private func remove(_ item: QueuePresentationEntry) {
        pmWithAnimation(.list) {
            _ = player.removeUpcomingQueueEntry(occurrence(item))
        }
    }

    private func occurrence(_ item: QueuePresentationEntry) -> QueueReorderOccurrenceID {
        QueueReorderOccurrenceID(queueEntryID: item.id.queueEntryID, roundOffset: item.id.roundOffset)
    }

    /// 后面没排东西:这一集放完就停。「连续播放」关着时顺手给出开关,开了以后
    /// 从节目页或单集列表起播,后面的单集会一起排进来。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("podcast_player_up_next_empty")
                .font(.body)
                .foregroundStyle(primary)
            if !continuousPlayback {
                Toggle("podcast_continuous_playback", isOn: $continuousPlayback)
                    .tint(accent)
                    .foregroundStyle(primary)
                Text("podcast_continuous_playback_footer")
                    .font(.footnote)
                    .foregroundStyle(secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

/// 「接下来」里的一行:方形封面、单集名、节目名与还剩多少。
private struct PodcastUpNextRow: View {
    let song: Song
    var palette: SpokenWordPlayerPalette?

    private var primary: Color { palette?.primary ?? .primary }
    private var secondary: Color { palette?.secondary ?? .secondary }

    var body: some View {
        let isEpisode = PodcastPlaybackSong.isEpisode(song)
        HStack(spacing: 12) {
            CachedArtworkView(
                coverRef: song.coverArtFileName,
                songID: song.id,
                size: 48,
                cornerRadius: 8,
                sourceID: song.sourceID,
                filePath: song.filePath,
                fileFormat: song.fileFormat,
                placeholderIcon: isEpisode ? "antenna.radiowaves.left.and.right" : "music.note"
            )
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: song.title)
                    .font(.body)
                    .foregroundStyle(primary)
                    .lineLimit(2)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String? {
        let owner = (song.albumTitle?.isEmpty == false ? song.albumTitle : nil) ?? song.artistName
        // 时长在前:节目名常常很长,放后面会把时长截掉。
        let parts = [progress, owner].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 听完的说「已播放」,听到一半的说还剩多久,没听过的说多长。
    private var progress: String? {
        let store = SpokenWordStore.shared
        if store.isFinished(songID: song.id) { return String(localized: "podcast_played") }
        if let stored = store.position(forSongID: song.id), stored.duration > stored.position {
            return PodcastFormat.remaining(stored.duration - stored.position)
        }
        return PodcastFormat.duration(song.duration)
    }
}

// MARK: - Menu items

/// 更多菜单里「下载 / 取消下载」这一项。单独一个视图:下载进度一变只重画它,不惊动整个播放页。
/// 已经下好的不给「删除下载」:正在播的就是这个文件。
struct PodcastPlayerDownloadMenuItem: View {
    @Environment(AudioPlayerService.self) private var player

    var body: some View {
        switch PodcastPlayerEpisodeActions.download(player) {
        case .available:
            Button {
                PodcastPlayerEpisodeActions.toggleDownload(player)
            } label: {
                Label("podcast_download", systemImage: "arrow.down.circle")
            }
        case .inProgress:
            Button {
                PodcastPlayerEpisodeActions.toggleDownload(player)
            } label: {
                Label("podcast_cancel_download", systemImage: "xmark.circle")
            }
        case .downloaded, nil:
            EmptyView()
        }
    }
}
