import Foundation
import PrimuseKit

/// 文稿显示偏移(#320):全局一层(输出设备的延迟),加上这一集 / 这本书自己的一层(插播广告)。
/// 只在本机记:车载、蓝牙这类延迟跟着设备走,换一台设备不一样。
@MainActor
@Observable
final class SpokenWordTranscriptOffsetStore {
    static let shared = SpokenWordTranscriptOffsetStore()

    private static let globalKey = "primuse.transcriptOffset.global"
    private static let itemsKey = "primuse.transcriptOffset.items.v1"
    /// 单集 / 书各自的偏移最多记这么多条,超了丢最早改的。
    private static let itemLimit = 400

    private struct ItemRecord: Codable {
        var delay: TimeInterval
        var updatedAt: Date
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// 所有文稿统一挪的秒数,正数是往后挪。
    private(set) var globalDelay: TimeInterval
    private var items: [String: ItemRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        globalDelay = SpokenWordTranscriptOffsetPolicy.normalized(defaults.double(forKey: Self.globalKey))
        if let data = defaults.data(forKey: Self.itemsKey),
           let decoded = try? JSONDecoder().decode([String: ItemRecord].self, from: data) {
            items = decoded
        } else {
            items = [:]
        }
    }

    func itemDelay(forKey key: String) -> TimeInterval? {
        items[key]?.delay
    }

    func effectiveDelay(forKey key: String) -> TimeInterval {
        SpokenWordTranscriptOffsetPolicy.effectiveDelay(global: globalDelay, item: items[key]?.delay)
    }

    func setGlobalDelay(_ delay: TimeInterval) {
        let normalized = SpokenWordTranscriptOffsetPolicy.normalized(delay)
        guard normalized != globalDelay else { return }
        globalDelay = normalized
        defaults.set(normalized, forKey: Self.globalKey)
        Self.notifyChanged()
    }

    func setItemDelay(_ delay: TimeInterval, forKey key: String) {
        let normalized = SpokenWordTranscriptOffsetPolicy.normalized(delay)
        guard normalized != (items[key]?.delay ?? 0) else { return }
        if normalized == 0 {
            items[key] = nil
        } else {
            items[key] = ItemRecord(delay: normalized, updatedAt: Date())
            if items.count > Self.itemLimit {
                let overflow = items.sorted { $0.value.updatedAt < $1.value.updatedAt }
                    .prefix(items.count - Self.itemLimit)
                for (staleKey, _) in overflow { items[staleKey] = nil }
            }
        }
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: Self.itemsKey)
        }
        Self.notifyChanged()
    }

    // MARK: - Songs

    /// 这首歌在播放器里按哪一层记。音乐没有文稿偏移。
    func itemKey(for song: Song) -> String? {
        let isPodcast = PodcastPlaybackSong.isEpisode(song) || SpokenWordStore.shared.isPodcast(song)
        guard isPodcast || SpokenWordStore.shared.isSpokenWord(song) else { return nil }
        return SpokenWordTranscriptOffsetPolicy.itemKey(
            songID: song.id,
            bookID: isPodcast ? nil : AppServices.shared.playerService.spokenWordBookID(for: song),
            isPodcastEpisode: isPodcast
        )
    }

    func effectiveDelay(for song: Song) -> TimeInterval {
        guard let key = itemKey(for: song) else { return 0 }
        return effectiveDelay(forKey: key)
    }

    /// 显示用的文稿:按这首的偏移平移时间轴。音乐原样返回。
    func presenting(_ lines: [LyricLine], for song: Song?) -> [LyricLine] {
        guard let song, !lines.isEmpty else { return lines }
        return SpokenWordTranscriptOffsetPolicy.applying(delay: effectiveDelay(for: song), to: lines)
    }

    /// 偏移变了:播放页重排一遍;锁屏、小组件、Mac 桌面歌词这些按「歌词变了」重新取一遍。
    private static func notifyChanged() {
        NotificationCenter.default.post(name: .primuseTranscriptOffsetDidChange, object: nil)
        if let songID = AppServices.shared.playerService.currentSong?.id {
            NotificationCenter.default.post(name: .primuseLyricsDidChange, object: songID)
        }
    }
}

extension Notification.Name {
    static let primuseTranscriptOffsetDidChange = Notification.Name("primuse.transcriptOffsetDidChange")
}
