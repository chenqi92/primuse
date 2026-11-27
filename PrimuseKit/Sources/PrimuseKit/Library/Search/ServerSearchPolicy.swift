import Foundation

/// 媒体服务器实时搜索的偏好键。默认关闭，由用户手动开启。
public enum ServerSearchFeatureSettings {
    public static let enabledKey = "primuse.search.serverSearchEnabled.v1"

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    public static var isEnabled: Bool {
        isEnabled(defaults: .standard)
    }
}

/// 媒体服务器实时搜索的可用性与节流策略。
///
/// 仅对用户已添加且启用的自托管音乐服务发起标准曲库搜索，不内置任何第三方音源或插件。
public enum ServerSearchAvailabilityPolicy {
    public static let debounce: Duration = .milliseconds(400)
    public static let perSourceLimit = 25
    public static let perSourceTimeout: Duration = .seconds(8)

    public static func supportsServerSearch(_ type: MusicSourceType) -> Bool {
        switch type {
        case .subsonic, .navidrome, .airsonic, .gonic, .zspace,
             .songloft,
             .jellyfin, .emby, .plex,
             .synologyAudioStation,
             .fnMusic,
             .daoliyu:
            return true
        default:
            return false
        }
    }

    public static func searchableSources(
        in sources: [MusicSource],
        disabledSourceIDs: Set<String> = []
    ) -> [MusicSource] {
        sources.filter { source in
            source.isEnabled
                && !disabledSourceIDs.contains(source.id)
                && supportsServerSearch(source.type)
        }
    }

    public static func hasSearchableSource(
        in sources: [MusicSource],
        disabledSourceIDs: Set<String> = []
    ) -> Bool {
        !searchableSources(in: sources, disabledSourceIDs: disabledSourceIDs).isEmpty
    }

    public static func isEnabled(
        featureEnabled: Bool,
        sources: [MusicSource],
        disabledSourceIDs: Set<String> = []
    ) -> Bool {
        featureEnabled && hasSearchableSource(in: sources, disabledSourceIDs: disabledSourceIDs)
    }

    public static func normalizedQuery(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 来自媒体服务器实时搜索的一首未入库候选曲目。
public struct ServerSearchHit: Identifiable, Hashable, Sendable {
    public let song: Song
    public let sourceName: String
    public let sourceType: MusicSourceType

    public var id: String { song.id }

    public init(song: Song, sourceName: String, sourceType: MusicSourceType) {
        self.song = song
        self.sourceName = sourceName
        self.sourceType = sourceType
    }

    public static func == (lhs: ServerSearchHit, rhs: ServerSearchHit) -> Bool {
        lhs.song.id == rhs.song.id
            && lhs.song.sourceID == rhs.song.sourceID
            && lhs.song.filePath == rhs.song.filePath
            && lhs.song.title == rhs.song.title
            && lhs.sourceName == rhs.sourceName
            && lhs.sourceType == rhs.sourceType
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(song.id)
        hasher.combine(song.sourceID)
        hasher.combine(song.filePath)
    }
}

/// 将媒体服务器实时返回的曲目与本机资料库去重，只保留尚未入库的曲目并去除跨源/重复条目。
public enum ServerSearchResultDeduplicator {
    public static func sourcePathKey(sourceID: String, filePath: String) -> String {
        "\(sourceID)\0\(filePath)"
    }

    public static func filterUnindexed(
        _ hits: [ServerSearchHit],
        localSongIDs: Set<String>,
        localSourceFilePaths: Set<String>
    ) -> [ServerSearchHit] {
        var seenIDs = localSongIDs
        var seenSourcePaths = localSourceFilePaths
        var result: [ServerSearchHit] = []
        result.reserveCapacity(hits.count)

        for hit in hits {
            let pathKey = sourcePathKey(sourceID: hit.song.sourceID, filePath: hit.song.filePath)
            guard !seenIDs.contains(hit.song.id),
                  !seenSourcePaths.contains(pathKey) else {
                continue
            }
            seenIDs.insert(hit.song.id)
            seenSourcePaths.insert(pathKey)
            result.append(hit)
        }
        return result
    }
}
