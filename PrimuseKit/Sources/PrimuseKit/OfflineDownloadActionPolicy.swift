/// Manual Download actions describe a transfer, not the absence of an app cache.
public enum OfflineDownloadActionPolicy {
    public static func allowsDownload(for song: Song, source: MusicSource?) -> Bool {
        guard song.isPlayable,
              song.sourceID != AppleMusicLibraryIdentity.sourceID,
              let source, source.id == song.sourceID,
              source.isEnabled, !source.isDeleted else { return false }
        switch source.type {
        case .local:
            // The descriptor is local, but the audio it points to may not be.
            return song.isStreamDescriptor
        case .appleMusic, .appleMusicLibrary:
            return false
        default:
            return true
        }
    }

    public static func downloadableSongs(in songs: [Song], sources: [MusicSource]) -> [Song] {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.filter { allowsDownload(for: $0, source: sourcesByID[$0.sourceID]) }
    }

    /// 只问有没有: 遇到第一首能下载的就停。菜单与按钮每次重画都要判断, 真正的
    /// 下载列表等点下去再筛。
    public static func containsDownloadableSong(in songs: [Song], sources: [MusicSource]) -> Bool {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.contains { allowsDownload(for: $0, source: sourcesByID[$0.sourceID]) }
    }
}
