import Foundation
import PrimuseKit

/// 检测 library 内同首歌的多个版本 (NAS 上同时存放 mp3 + flac, 或者
/// 不同目录里相同文件)。按 (title, artist, duration±2s) 作为 fingerprint
/// 分组, 每组超过 1 首即视为重复。
///
/// 用法:
/// ```
/// let groups = DuplicateDetector.detect(in: library.songs)
/// for group in groups {
///     // group.bestSong 按质量排序的第一名 (推荐保留)
///     // group.redundantSongs 推荐删除的其他版本
/// }
/// ```
@MainActor
enum DuplicateDetector {
    /// duration ±2s 容差: 同一首歌不同 encoder 转出来 duration 可能差几百
    /// 毫秒, 取 2s bucket (实际 ±1s) 容错。
    private static let durationBucketSec: Int = 2

    /// 扫描 library 找重复歌曲分组。
    /// - Parameter songs: 整个 library 的 songs
    /// - Returns: 重复分组数组 (每组 size >= 2), 按标题字母序。
    static func detect(in songs: [Song]) -> [DuplicateGroup] {
        let grouped = Dictionary(grouping: songs) { song -> DuplicateKey in
            DuplicateKey(
                title: normalize(song.title),
                artist: normalize(song.artistName ?? ""),
                durationBucket: Int(song.duration) / durationBucketSec
            )
        }

        return grouped
            .compactMap { (key, members) -> DuplicateGroup? in
                guard members.count > 1 else { return nil }
                // 标题或艺术家是空的 group 没意义 (会把所有 "未知" 归为一组)
                guard !key.title.isEmpty else { return nil }
                let sorted = members.sorted { qualityScore(of: $0) > qualityScore(of: $1) }
                let displaySong = sorted.first!
                return DuplicateGroup(
                    id: "\(key.title)|\(key.artist)|\(key.durationBucket)",
                    title: displaySong.title,
                    artist: displaySong.artistName ?? "",
                    duration: displaySong.duration,
                    songs: sorted
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// 质量评分 — 高 = 推荐保留。维度优先级:
    /// 1. lossless > lossy (无损上 +10000)
    /// 2. bitDepth (24bit > 16bit) (×500)
    /// 3. sampleRate (96k > 44.1k) (×0.01 转 kHz)
    /// 4. bitRate (有损歌的关键, kbps)
    /// 5. fileSize 作为最后 tiebreaker (MB)
    static func qualityScore(of song: Song) -> Int {
        var score = 0
        if isLossless(song.fileFormat) { score += 10000 }
        if let bd = song.bitDepth { score += bd * 500 }
        if let sr = song.sampleRate { score += sr / 1000 }
        if let br = song.bitRate { score += br / 1000 }
        score += Int(song.fileSize / (1024 * 1024))
        return score
    }

    private static func isLossless(_ format: AudioFormat) -> Bool {
        switch format {
        case .flac, .alac, .wav, .aiff, .aif, .ape, .wv, .dsf, .dff:
            return true
        case .mp3, .aac, .m4a, .mp4, .ogg, .opus, .wma:
            return false
        }
    }

    /// 标题 / 艺术家 normalize: 去 diacritic + 大小写 + 首尾空白, 但保留
    /// 内部空白 + 标点 (太激进 normalize 会把"Hello (Live)"和"Hello"
    /// 误归到同组, 这种其实是不同版本要保留, 不是重复)。
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}

/// 重复分组 — 多个 Song 共享 title+artist+duration 桶。
struct DuplicateGroup: Identifiable {
    let id: String
    let title: String
    let artist: String
    let duration: TimeInterval
    /// 按质量评分降序排列, 第一个是推荐保留的。
    let songs: [Song]

    var bestSong: Song { songs.first! }
    var redundantSongs: [Song] { Array(songs.dropFirst()) }
    var count: Int { songs.count }
}

private struct DuplicateKey: Hashable {
    let title: String
    let artist: String
    let durationBucket: Int
}
