import Foundation

public enum ScrapeApplyPolicy {
    /// 把刮削结果里没被选中的部分换回原来的值。从结果出发、只还原没选的字段,
    /// 刮削顺带带回的其他字段(CUE 边界、ReplayGain)原样保留。
    public static func restricted(_ updated: Song, to parts: ScrapeParts, original: Song) -> Song {
        var result = updated
        if !parts.contains(.metadata) {
            result.title = original.title
            result.albumID = original.albumID
            result.artistID = original.artistID
            result.albumTitle = original.albumTitle
            result.artistName = original.artistName
            result.sourceArtistNames = original.sourceArtistNames
            result.albumArtistName = original.albumArtistName
            result.trackNumber = original.trackNumber
            result.discNumber = original.discNumber
            result.genre = original.genre
            result.year = original.year
            result.titlePinyin = original.titlePinyin
            result.artistPinyin = original.artistPinyin
            result.albumPinyin = original.albumPinyin
            result.duration = original.duration
            result.bitRate = original.bitRate
            result.sampleRate = original.sampleRate
            result.bitDepth = original.bitDepth
            result.effectiveBitDepth = original.effectiveBitDepth
            result.mvPath = original.referencedMusicVideoPath
        }
        if !parts.contains(.cover) {
            result.coverArtFileName = original.coverArtFileName
        }
        if !parts.contains(.lyrics) {
            result.lyricsFileName = original.lyricsFileName
        }
        return result
    }
}
