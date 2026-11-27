import Foundation

/// 当前歌的资料库行被替换时，播放器封面要不要强制重载。
///
/// 冷启动时回填、专辑艺术家复查、服务端同步会成批替换歌曲行，正在播的那首常在其中，
/// 但封面根本没变。以前一律 bump `coverRevision`：迷你条、播放页的封面换缓存键、
/// 从盘上重读再淡入，背景也重新取色，于是冷启动那几秒封面一闪一闪。
/// 现在只有决定封面来源的字段变了才重载；同名封面文件被重新刮削（引用字符串不变）
/// 由封面失效通知接住，见 `invalidationTargetsSong`。
public enum NowPlayingArtworkRefreshPolicy {
    public struct ArtworkIdentity: Equatable, Sendable {
        public let songID: String
        public let artworkReference: String?
        public let sourceID: String
        public let filePath: String
        public let fileFormat: String?

        public init(
            songID: String,
            artworkReference: String?,
            sourceID: String,
            filePath: String,
            fileFormat: String?
        ) {
            self.songID = songID
            self.artworkReference = artworkReference
            self.sourceID = sourceID
            self.filePath = filePath
            self.fileFormat = fileFormat
        }
    }

    public static func replacementRequiresReload(
        previous: ArtworkIdentity?,
        updated: ArtworkIdentity
    ) -> Bool {
        guard let previous else { return true }
        return normalized(previous) != normalized(updated)
    }

    /// 失效通知是否点名了这首歌。「全部失效」（删源、清缓存）不算：那是在回收别的歌
    /// 的缓存，正在显示的封面没变，跟着重载只会让播放页闪一下。
    public static func invalidationTargetsSong(
        songID: String,
        artworkReference: String?,
        object: String?,
        tokens: [String],
        isBroadcastToAll: Bool
    ) -> Bool {
        guard !isBroadcastToAll else { return false }
        var local: Set<String> = [songID]
        if let ref = artworkReference?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            local.insert(ref)
        }
        local.remove("")
        guard !local.isEmpty else { return false }
        return ([object].compactMap { $0 } + tokens).contains { local.contains($0) }
    }

    private static func normalized(_ identity: ArtworkIdentity) -> ArtworkIdentity {
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        return ArtworkIdentity(
            songID: identity.songID,
            artworkReference: clean(identity.artworkReference),
            sourceID: identity.sourceID,
            filePath: identity.filePath,
            fileFormat: clean(identity.fileFormat)
        )
    }
}
