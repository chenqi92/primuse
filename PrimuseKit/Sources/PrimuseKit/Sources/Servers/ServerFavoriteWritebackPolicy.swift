import Foundation

/// Fail-closed capability and identity rules for favorite mutations.
///
/// Playlist reconciliation can tolerate a best-effort item ID because it is a
/// read-only match. A favorite mutation cannot: sending a directory, album or
/// artist ID to a server would modify the wrong object. Only connector paths
/// emitted for supported song sources are accepted here.
public enum ServerFavoriteWritebackPolicy {
    public static func supports(_ sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .emby, .jellyfin, .plex, .navidrome, .subsonic, .zspace, .songloft, .fnMusic:
            return true
        default:
            return false
        }
    }

    public static func songID(
        fromConnectorPath filePath: String,
        sourceType: MusicSourceType
    ) -> String? {
        if sourceType == .songloft {
            return SongloftAPIProtocol.trackID(from: filePath).map(String.init)
        }
        let directory: String
        switch sourceType {
        case .fnMusic:
            directory = "fnmusic/tracks"
        case .emby, .jellyfin, .plex:
            // 三者的曲目路径都是 /items/<id>.<ext>(见 MediaServerSource 的条目构造);
            // Plex 的 <id> 就是 ratingKey,评分端点认的也是它。
            directory = "items"
        case .navidrome, .subsonic, .zspace:
            directory = "songs"
        default:
            return nil
        }

        let prefix = "/\(directory)/"
        guard filePath.hasPrefix(prefix) else { return nil }
        let fileName = String(filePath.dropFirst(prefix.count))
        guard !fileName.isEmpty,
              !fileName.contains("/"),
              !fileName.hasPrefix("."),
              !fileName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        var itemID = (fileName as NSString).deletingPathExtension
        // 飞牛的曲目 id 和曲库扫描、收藏/歌单清单用同一套认法(去首尾空白):写回后回读确认、
        // 对账比的都是清单里那份,这边多带一个空白就永远对不上(#330)。
        if sourceType == .fnMusic {
            itemID = itemID.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !itemID.isEmpty, itemID != ".", itemID != ".." else { return nil }
        return itemID
    }
}
