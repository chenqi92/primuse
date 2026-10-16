import Foundation
import Observation
import PrimuseKit

/// 本地节目(自己的文件标成的播客)每档各自的单集排法、筛选与拖出来的顺序。
///
/// 只记在本机,和书架的拖动顺序一样不进 iCloud:节目 id 由各台设备自己的曲库分组得出,
/// 各端扫的目录也可能不同。
@MainActor
@Observable
final class LocalPodcastShowSettingsStore {
    static let shared = LocalPodcastShowSettingsStore()

    private static let defaultsKey = "primuse.podcast.localShowSettings.v1"

    private(set) var settingsByShowID: [String: LocalPodcastShowSettings]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: LocalPodcastShowSettings].self, from: data) {
            settingsByShowID = decoded
        } else {
            settingsByShowID = [:]
        }
    }

    func settings(for showID: String) -> LocalPodcastShowSettings {
        settingsByShowID[showID] ?? .default
    }

    func update(_ showID: String, _ change: (inout LocalPodcastShowSettings) -> Void) {
        var settings = settings(for: showID)
        change(&settings)
        guard settings != self.settings(for: showID) else { return }
        settingsByShowID[showID] = settings == .default ? nil : settings
        persist()
    }

    /// 存下拖出来的顺序,并换成「自定义顺序」。
    func saveCustomOrder(_ ids: [String], for showID: String) {
        update(showID) {
            $0.customOrder = ids
            $0.order = .custom
        }
    }

    /// 节目换了 id(读出标签后分组变了,old → new):排法跟到新 id 上。新 id 已经有自己的
    /// 排法时那是之后才设的,留着它。只在本机,旧 id 不必留给别的设备。
    func carryShows(renames: [String: String]) {
        var next = settingsByShowID
        for oldID in renames.keys.sorted() {
            guard let newID = renames[oldID], let settings = next.removeValue(forKey: oldID) else { continue }
            if next[newID] == nil { next[newID] = settings }
        }
        guard next != settingsByShowID else { return }
        settingsByShowID = next
        persist()
    }

    private func persist() {
        if settingsByShowID.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(settingsByShowID) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// 按一档本地节目自己的排法起播:从点的那一集(没点就是「播放」键该放的那集)开始,
/// 播完按收听先后接着放还没听完的。节目页、CarPlay、电视共用。
enum LocalPodcastPlayback {
    @MainActor
    static func queue(
        for book: SpokenWordBook,
        songs: [Song],
        from itemID: String? = nil,
        settings: LocalPodcastShowSettings
    ) -> [Song] {
        let ordered = LocalPodcastEpisodeListPolicy.ordered(book.items, settings: settings)
        guard let startID = itemID ?? LocalPodcastEpisodeListPolicy.startItemID(
            in: ordered,
            resumeItemID: book.resumeItemID,
            canContinue: book.canContinue
        ) else { return [] }
        let songsByID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return LocalPodcastEpisodeListPolicy
            .continuation(from: startID, in: ordered, order: settings.order)
            .compactMap { songsByID[$0.id] }
    }
}
