import Foundation
import PrimuseKit

/// 播客单集的播放。单集是带虚拟来源的 `Song`(`PodcastPlaybackSong`),流派是 Podcast,
/// 所以续播、跳转键、变速、睡眠定时都走有声内容那一套;这里只补单集自己的几件事:
///
/// - 起播前探一次音频文件:很多节目动态插播广告,feed 里写的长度和真实文件对不上,
///   分段请求又要求长度一分不差;顺带记下跳转后的 CDN 地址,之后的分段请求不再每段都经一次下载统计;
/// - 有本机下载就放本机文件;
/// - 片头跳过、片尾提前结束(每档节目自己设);
/// - feed 里带的章节(Podlove 内联、Podcasting 2.0 章节文件)。
extension AudioPlayerService {
    /// DLNA 投放和播客单集:都是一个外部地址,不属于任何音乐源 —— 不写源的音频缓存、
    /// 元数据直接按地址取、拿不到长度时用渐进解码。
    func isExternalURLItem(_ song: Song?) -> Bool {
        isDLNACast(song) || PodcastPlaybackSong.isEpisode(song)
    }

    // MARK: - Starting

    /// 播一集。`continuing` 是播完接着放的单集(已按收听顺序排好,不含这一集);
    /// 「连续播放」关着时只放这一集。`position` 给了就从那里开始(节目说明里的时间点)。
    func playPodcast(
        _ episode: PodcastEpisode,
        continuing: [PodcastEpisode] = [],
        from position: TimeInterval? = nil
    ) async {
        let store = PodcastStore.shared
        let continuous = UserDefaults.standard.object(forKey: PodcastPlaybackSettings.continuousPlaybackKey) as? Bool ?? true
        let queue = [episode] + (continuous ? continuing.filter { $0.id != episode.id } : [])
        let songs = queue.map { item in
            PodcastPlaybackSong.song(for: item, show: store.show(id: item.showID))
        }
        // 听完的重放从头开始,和书架重放一本听完的书一样。
        if store.state(for: episode).isFinished {
            store.setPlayed(false, episode: episode)
        }
        if let position {
            pendingSpokenWordSeekOverride = (episode.id, position)
        }
        // 已经是这一集(在放或停着):只是继续,不重新加载,也不换掉连续播放排好的后续单集。
        if currentSong?.id == episode.id, position == nil {
            if !isPlaying { togglePlayPause() }
            return
        }
        PodcastPlaybackMemory.shared.remember(songs)
        await play(queue: songs, startingAt: 0)
    }

    /// 起播前的准备(`play(song:)` 里、取地址之前调)。探到的长度写回 `currentSong`
    /// 和队列里的那一项,拖动进度、断流恢复都按它来。
    func preparePodcastEpisodeForPlayback(_ song: Song) async -> Song {
        guard PodcastPlaybackSong.isEpisode(song) else { return song }
        if let local = PodcastDownloadStore.shared.localURL(for: song.id) {
            let size = (try? FileManager.default.attributesOfItem(atPath: local.path)[.size] as? Int64) ?? song.fileSize
            return replacingPodcastFileSize(song, with: size)
        }
        let cache = PodcastEnclosureProbeCache.shared
        var probe = cache.probe(forEpisodeID: song.id)
        if probe == nil, let enclosure = URL(string: song.filePath) {
            probe = await PodcastNetwork.probeEnclosure(enclosure)
            if let probe { cache.store(probe, forEpisodeID: song.id) }
        }
        guard let probe else {
            // 探不到(服务器不认、超时):长度当未知,走渐进解码,别按 feed 里可能不准的长度分段读。
            plog("🎙️ '\(song.title)': enclosure probe failed, playing without ranges")
            return replacingPodcastFileSize(song, with: 0)
        }
        plog("🎙️ '\(song.title)': range=\(probe.supportsRange) size=\(probe.totalLength / 1024)KB host=\(probe.finalURL.host ?? "?")")
        return replacingPodcastFileSize(song, with: probe.supportsRange ? probe.totalLength : 0)
    }

    private func replacingPodcastFileSize(_ song: Song, with size: Int64) -> Song {
        guard song.fileSize != size else { return song }
        var updated = song
        updated.fileSize = size
        if currentSong?.id == song.id { currentSong = updated }
        for index in queueEntries.indices where queueEntries[index].song.id == song.id {
            queueEntries[index].song = updated
        }
        return updated
    }

    /// 播客单集实际去哪儿取:本机下载 → 探到的最终地址 → feed 里的原地址。
    func resolvedPodcastURL(for song: Song) -> URL? {
        guard PodcastPlaybackSong.isEpisode(song) else { return nil }
        if let local = PodcastDownloadStore.shared.localURL(for: song.id) { return local }
        if let probe = PodcastEnclosureProbeCache.shared.probe(forEpisodeID: song.id) { return probe.finalURL }
        return URL(string: song.filePath)
    }

    /// 下一集提前探好,换集时少等一个来回。
    func prefetchUpcomingPodcastEpisode() {
        guard let next = nextQueueEntryInQueue()?.song,
              PodcastPlaybackSong.isEpisode(next),
              PodcastDownloadStore.shared.localURL(for: next.id) == nil,
              PodcastEnclosureProbeCache.shared.probe(forEpisodeID: next.id) == nil,
              let enclosure = URL(string: next.filePath) else { return }
        let id = next.id
        Task { @MainActor in
            if let probe = await PodcastNetwork.probeEnclosure(enclosure) {
                PodcastEnclosureProbeCache.shared.store(probe, forEpisodeID: id)
            }
        }
    }

    // MARK: - Player page

    /// 播放页两侧小键这一下走的是章还是集(旁白据此说「下一章」还是「下一集」)。
    var podcastForwardUnit: PodcastQueueNavigationPolicy.Unit {
        PodcastQueueNavigationPolicy.forwardUnit(
            chapterCount: spokenWordChapters.count,
            currentChapterIndex: currentChapterIndex
        )
    }

    var podcastBackwardUnit: PodcastQueueNavigationPolicy.Unit {
        PodcastQueueNavigationPolicy.backwardUnit(chapterCount: spokenWordChapters.count)
    }

    /// 播放页「标为已播放」:队列里还有下一集就接着放,没有就停下。
    ///
    /// 记位置会把听完的单集重新打开,所以先让这一集最后记一次(换集或暂停时),再标听完。
    func markCurrentPodcastEpisodePlayed() {
        guard let song = currentSong, PodcastPlaybackSong.isEpisode(song),
              let found = PodcastStore.shared.episode(id: song.id) else { return }
        let store = PodcastStore.shared
        if hasNextBookItem {
            // 换集时起播会先给上一集记一次位置,那会把刚标的「听完」又打开。
            PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = song.id
            store.setPlayed(true, episode: found.episode)
            skipToNextBookItem()
        } else {
            // 先停(停的时候照常记位置),再标听完。之后又接着听,自动存档会照常把它重新打开。
            pause()
            store.setPlayed(true, episode: found.episode)
        }
    }

    // MARK: - Per-item setup

    /// 换到一集时(`handleSpokenWordItemChange` 里调):没有续播位置就按节目设置跳过片头;
    /// 带上 feed 里的章节。
    func preparePodcastItem(_ song: Song) {
        guard PodcastPlaybackSong.isEpisode(song),
              let found = PodcastStore.shared.episode(id: song.id) else { return }
        PodcastPlaybackState.shared.outroHandledEpisodeID = nil
        PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = nil
        let intro = found.show.settings.skipIntroSeconds
        if intro > 0,
           pendingSpokenWordSeekOverride == nil,
           SpokenWordStore.shared.resumePosition(for: song) == nil {
            pendingSpokenWordSeekOverride = (song.id, TimeInterval(intro))
        }
        if !found.episode.chapters.isEmpty {
            spokenWordChapters = found.episode.chapters.map { MediaChapter(startTime: $0.start, title: $0.title) }
            refreshCurrentChapter()
        } else if let chaptersURL = found.episode.chaptersURL {
            let songID = song.id
            Task { @MainActor [weak self] in
                let chapters = await PodcastNetwork.chapters(from: chaptersURL)
                guard let self, self.currentSong?.id == songID, self.spokenWordChapters.isEmpty, !chapters.isEmpty else { return }
                self.spokenWordChapters = chapters.map { MediaChapter(startTime: $0.start, title: $0.title) }
                self.refreshCurrentChapter()
                plog("🎙️ Chapters: \(chapters.count) marks from the feed for '\(song.title)'")
            }
        }
    }

    /// 播放时钟每拍调:离结尾不到节目设的片尾秒数,就当这集听完,接着放下一集。
    func applyPodcastOutroSkipIfNeeded() {
        guard isPlaying, let song = currentSong, PodcastPlaybackSong.isEpisode(song),
              PodcastPlaybackState.shared.outroHandledEpisodeID != song.id,
              let found = PodcastStore.shared.episode(id: song.id) else { return }
        let outro = TimeInterval(found.show.settings.skipOutroSeconds)
        let total = duration > 0 ? duration : song.duration
        guard outro > 0, total > outro + 30, currentTime > 10, total - currentTime <= outro else { return }
        PodcastPlaybackState.shared.outroHandledEpisodeID = song.id
        PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = song.id
        plog("🎙️ Skipping the last \(Int(outro))s of '\(song.title)'")
        SpokenWordStore.shared.markFinished(true, songIDs: [song.id])
        Task { @MainActor [weak self] in
            guard let self else { return }
            let advanced = await self.next(isAutomaticAdvance: true)
            if !advanced { self.pause() }
        }
    }
}

/// 播放相关的全局开关。
/// 播放器扩展里存不了的几样状态。
@MainActor
final class PodcastPlaybackState {
    static let shared = PodcastPlaybackState()
    /// 这一集的片尾已经处理过,别每拍再触发一次。
    var outroHandledEpisodeID: String?
    /// 这一集刚标成听完、正在换下一集:换集时别再给它记位置(记位置会把听完重新打开)。换到下一集时清掉。
    var positionSaveSuppressedEpisodeID: String?
}

/// 最近一次播客队列里的那几集,冷启动恢复播放会话时用。
///
/// 恢复只认曲库里的歌;播客的单集不在曲库,整个播客库又得在后台读完才知道,
/// 所以把起播时的队列原样存一份小文件,恢复时同步读回来。
@MainActor
final class PodcastPlaybackMemory {
    static let shared = PodcastPlaybackMemory()

    private let url: URL = {
        #if os(tvOS)
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let base = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return base.appendingPathComponent("Primuse/Podcasts/now-playing-queue.json")
    }()

    func remember(_ songs: [Song]) {
        let url = url
        let snapshot = Array(songs.prefix(100))
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// 同步读:文件只有几十集的元数据。
    func songs() -> [Song] {
        guard let data = try? Data(contentsOf: url),
              let songs = try? JSONDecoder().decode([Song].self, from: data) else { return [] }
        return songs
    }
}
