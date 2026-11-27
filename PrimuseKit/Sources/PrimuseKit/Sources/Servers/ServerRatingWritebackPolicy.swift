import Foundation

/// Which sources accept a song rating written back from Primuse, and how the
/// server song id is recovered from `Song.filePath`. Like favorites, a rating
/// mutation must never be sent to an id that is not a catalogue song.
public enum ServerRatingWritebackPolicy {
    public static func supports(_ sourceType: MusicSourceType) -> Bool {
        sourceType == .navidrome || sourceType == .synologyAudioStation
    }

    /// 专辑也有服务端评分的源(`setRating` 收专辑 id)。Audio Station 只有歌曲评分。
    public static func supportsAlbumRatings(_ sourceType: MusicSourceType) -> Bool {
        sourceType == .navidrome
    }

    public static func songID(
        fromConnectorPath filePath: String,
        sourceType: MusicSourceType
    ) -> String? {
        switch sourceType {
        case .navidrome:
            return ServerFavoriteWritebackPolicy.songID(
                fromConnectorPath: filePath,
                sourceType: sourceType
            )
        case .synologyAudioStation:
            // 只认连接器写出的 `/songs/<目录曲目 id>.<扩展名>`。
            return SynologyAudioStationAPI.songID(fromTrackPath: filePath)
        default:
            return nil
        }
    }
}
