import Foundation

/// 歌单里一首「曲库里还没有」的歌：界面上置灰，曲库里出现能对上的歌时原位点亮。
///
/// 它在歌单成员数组里占一个位置，位置上放的是 `id`（带 `pending:` 前缀），
/// 所以顺序天然保留；读成员的地方只认曲库里真有的 `Song.id`，这些占位会被自然跳过。
/// 元数据另存在 `MusicLibrary` 的占位表里，跨设备时编码成只有元数据的 `SongIdentity`。
public struct PlaylistPendingEntry: Codable, Hashable, Sendable, Identifiable {
    public static let idPrefix = "pending:"

    public var id: String
    public var title: String
    public var artists: [String]
    public var album: String?
    /// 秒；nil 表示不知道（文本清单导入通常没有时长）。
    public var duration: Double?
    /// 来自哪里：`ExternalPlaylistPlatform.rawValue`，或者 `removed-source`（音乐源被移除后
    /// 留下的空位）、`text`、`file`。只用于展示与诊断。
    public var origin: String?
    /// 在来源平台上的歌曲 id，便于以后精确对照；可空。
    public var externalID: String?
    public var createdAt: Date
    /// 规则只够得上「可能是」时记下的候选，界面上给用户一键确认。不会自动写入。
    public var suggestedSongID: String?

    public init(
        id: String = PlaylistPendingEntry.makeID(),
        title: String,
        artists: [String],
        album: String? = nil,
        duration: Double? = nil,
        origin: String? = nil,
        externalID: String? = nil,
        createdAt: Date = Date(),
        suggestedSongID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artists = artists
        self.album = album
        self.duration = duration
        self.origin = origin
        self.externalID = externalID
        self.createdAt = createdAt
        self.suggestedSongID = suggestedSongID
    }

    public static func makeID() -> String {
        idPrefix + UUID().uuidString.lowercased()
    }

    public static func isPendingID(_ id: String) -> Bool {
        id.hasPrefix(idPrefix)
    }

    public var artistLine: String {
        artists.joined(separator: " / ")
    }

    public var matchSubject: ExternalTrackMatchPolicy.Subject {
        .init(title: title, artists: artists, duration: duration)
    }

    public var hasPlayableMetadata: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Cross-device

    /// 跨设备同步时的形态：songID 保留占位 id，文件路径为空，其余是元数据。
    /// 旧版本收到它时按普通「暂时解析不到的身份」处理，不会出错。
    public var syncIdentity: SongIdentity {
        SongIdentity(
            songID: id,
            title: title,
            artistName: artists.isEmpty ? nil : artistLine,
            duration: duration ?? 0,
            cloudAccountID: nil,
            filePath: ""
        )
    }

    /// 从同步来的身份还原；不是占位身份时返回 nil。
    public init?(syncIdentity identity: SongIdentity, receivedAt: Date = Date()) {
        guard Self.isPendingID(identity.songID), identity.filePath.isEmpty else { return nil }
        self.init(
            id: identity.songID,
            title: identity.title,
            artists: identity.artistName.map { [$0] } ?? [],
            duration: identity.duration > 0 ? identity.duration : nil,
            origin: "sync",
            createdAt: receivedAt
        )
    }
}
