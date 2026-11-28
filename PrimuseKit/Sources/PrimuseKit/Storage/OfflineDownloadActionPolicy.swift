import Foundation

/// Identifies local sources backed by cloud storage (iCloud Drive / File Provider)
/// whose files can be evicted by the OS and therefore benefit from Primuse's
/// playback cache and offline downloads without duplicating true local disks.
public enum LocalCloudStoragePathPolicy {
    private static let cloudContainerMarkers = [
        "/Library/Mobile Documents",
        "/Library/CloudStorage",
        "/File Provider Storage",
    ]

    public static func isCloudBackedPath(_ path: String?) -> Bool {
        guard let raw = path?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        let normalized = raw.hasSuffix("/") && raw.count > 1 ? String(raw.dropLast()) : raw
        return cloudContainerMarkers.contains { marker in
            normalized.contains(marker + "/") || normalized.hasSuffix(marker)
        }
    }

    public static func isCloudBackedLocalSource(
        _ source: MusicSource,
        registeredCloudLocalSourceIDs: Set<String> = []
    ) -> Bool {
        guard source.type == .local else { return false }
        return registeredCloudLocalSourceIDs.contains(source.id)
            || isCloudBackedPath(source.basePath)
    }
}

/// Manual Download actions describe a transfer, not the absence of an app cache.
public enum OfflineDownloadActionPolicy {
    public static func allowsDownload(
        for song: Song,
        source: MusicSource?,
        cloudBackedLocalSourceIDs: Set<String> = []
    ) -> Bool {
        guard song.isPlayable,
              song.sourceID != AppleMusicLibraryIdentity.sourceID,
              let source, source.id == song.sourceID,
              source.isEnabled, !source.isDeleted else { return false }
        switch source.type {
        case .local:
            // Local originals on true local storage do not need copying, while
            // stream descriptors and cloud-backed (iCloud Drive / File Provider)
            // local folders can be evicted by the OS and support offline pinning.
            return song.isStreamDescriptor
                || LocalCloudStoragePathPolicy.isCloudBackedLocalSource(
                    source,
                    registeredCloudLocalSourceIDs: cloudBackedLocalSourceIDs
                )
        case .appleMusic, .appleMusicLibrary:
            return false
        default:
            return true
        }
    }

    /// 下载离线之前要不要先确认能上网:本机文件夹里的文件(连同 iCloud 云盘里的,能不能取由系统自己判断)不用;
    /// 本机源里的 `.strm` 指向的是网上的音频,要。
    public static func transferNeedsNetwork(sourceType: MusicSourceType, isStreamDescriptor: Bool) -> Bool {
        sourceType != .local || isStreamDescriptor
    }

    public static func allowsFolderDownload(
        for source: MusicSource?,
        cloudBackedLocalSourceIDs: Set<String> = []
    ) -> Bool {
        guard let source, source.isEnabled, !source.isDeleted else { return false }
        switch source.type {
        case .appleMusic, .appleMusicLibrary:
            return false
        case .local:
            return LocalCloudStoragePathPolicy.isCloudBackedLocalSource(
                source,
                registeredCloudLocalSourceIDs: cloudBackedLocalSourceIDs
            )
        default:
            return true
        }
    }

    public static func downloadableSongs(
        in songs: [Song],
        sources: [MusicSource],
        cloudBackedLocalSourceIDs: Set<String> = []
    ) -> [Song] {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.filter {
            allowsDownload(
                for: $0,
                source: sourcesByID[$0.sourceID],
                cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs
            )
        }
    }

    /// 只问有没有: 遇到第一首能下载的就停。菜单与按钮每次重画都要判断, 真正的
    /// 下载列表等点下去再筛。
    public static func containsDownloadableSong(
        in songs: [Song],
        sources: [MusicSource],
        cloudBackedLocalSourceIDs: Set<String> = []
    ) -> Bool {
        let sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return songs.contains {
            allowsDownload(
                for: $0,
                source: sourcesByID[$0.sourceID],
                cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs
            )
        }
    }
}

public struct FolderOfflineDownloadRequest: Identifiable, Sendable {
    public let id: LibraryFolderNodeID
    public let songs: [Song]

    public var ownerID: String { Self.ownerID(for: id) }

    public static func ownerID(for nodeID: LibraryFolderNodeID) -> String {
        let components = [nodeID.sourceID, nodeID.kind.rawValue, nodeID.normalizedRelativePath]
        return "folder:" + components.map { "\($0.utf8.count):\($0)" }.joined()
    }

    public init?(
        nodeID: LibraryFolderNodeID,
        index: LibraryFolderIndex,
        source: MusicSource?,
        cloudBackedLocalSourceIDs: Set<String> = [],
        songForID: (String) -> Song?
    ) {
        self.init(
            nodeID: nodeID, songIDs: index.songIDs(in: nodeID, scope: .descendants), source: source,
            cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs, songForID: songForID
        )
    }

    /// 同上,文件夹里的歌(整棵子树,索引里的先后)由调用方给:歌曲模型不在内存里时从曲库目录读出来的那份(6c 单元 4 U9a)。
    public init?(
        nodeID: LibraryFolderNodeID,
        songIDs: [String],
        source: MusicSource?,
        cloudBackedLocalSourceIDs: Set<String> = [],
        songForID: (String) -> Song?
    ) {
        var seen = Set<String>()
        let songs = songIDs.compactMap { id -> Song? in
            guard seen.insert(id).inserted,
                  let song = songForID(id), song.sourceID == nodeID.sourceID,
                  OfflineDownloadActionPolicy.allowsDownload(
                    for: song,
                    source: source,
                    cloudBackedLocalSourceIDs: cloudBackedLocalSourceIDs
                  ) else { return nil }
            return song
        }
        guard !songs.isEmpty else { return nil }
        self.id = nodeID
        self.songs = songs
    }
}
