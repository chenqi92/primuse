import Foundation

/// 单集交给播放器时的样子:一首带虚拟来源的 `Song`,和电台、DLNA 投放同一种做法。
///
/// - 流派写 Podcast:有声内容的分类认这个词,续播、跳转键、变速、睡眠到本集结束都跟着有声那一套走;
/// - 专辑写节目名、专辑艺术家写主播:有声那边按专辑归「书」,每档节目因此有自己的倍速;
/// - `filePath` 是 enclosure 原地址,真正去哪儿取(已下载的本机文件、跳转后的 CDN 地址)由播放器现查。
public enum PodcastPlaybackSong {
    public static let sourceID = "primuse.podcast"
    public static let genre = "Podcast"

    public static func song(for episode: PodcastEpisode, show: PodcastShow?, fileSize: Int64 = 0) -> Song {
        let format = AudioFormat.from(fileExtension: episode.audioFileExtension) ?? .mp3
        let author = show?.author ?? show?.title
        return Song(
            id: episode.id,
            title: episode.title.isEmpty ? (show?.title ?? episode.guid) : episode.title,
            albumTitle: show?.title,
            artistName: author,
            albumArtistName: author,
            trackNumber: episode.number,
            discNumber: episode.season,
            duration: episode.duration ?? 0,
            fileFormat: format,
            filePath: episode.enclosureURL.absoluteString,
            sourceID: sourceID,
            fileSize: fileSize,
            genre: genre,
            dateAdded: episode.publishedAt ?? episode.firstSeenAt,
            coverArtFileName: (episode.artworkURL ?? show?.artworkURL)?.absoluteString
        )
    }

    public static func isEpisode(_ song: Song?) -> Bool {
        guard let song else { return false }
        return song.sourceID == sourceID || PodcastIdentity.isEpisodeID(song.id)
    }
}
