import Foundation
import PrimuseKit

/// 重复检测走曲库目录(P2c):两趟流式遍历,内存不随曲库长成整库的歌。
///
/// 第一趟只记每首歌重复键(`DuplicateDetector` 的标题 + 艺人 + 2 秒时长桶)的哈希出现过几次;
/// 第二趟把键出现过不止一次的歌取出来,交给原来的 `DuplicateDetector.detect`。分组只看同键的成员,
/// 成员仍按库内顺序进来,所以分组、组内次序和整库跑一遍完全相同。哈希撞车只会多取几首候选,
/// `detect` 按真正的键再分一次,不影响结果。
///
/// 键的算法抄自 `DuplicateDetector.swift` 里的私有 `DuplicateKey`(那个文件不归 P2c);
/// 两边要一起改。更好的做法是目录存一列规范化的重复键,用 SQL `GROUP BY … HAVING count > 1`。
enum DuplicateCatalogScan {
    static func detect(reader: LibraryCatalogReader, scope: LibrarySongScope = .visible) async throws -> [DuplicateGroup] {
        let candidates = try await reader.readCancellable { (catalog, cancellation) -> [Song] in
            var seenOnce = Set<Int>()
            var repeated = Set<Int>()
            var visited = 0
            try catalog.forEachSong(scope) { _, song in
                visited += 1
                if visited.isMultiple(of: 512), cancellation.isCancelled { return false }
                guard let hash = keyHash(song) else { return true }
                if !seenOnce.insert(hash).inserted { repeated.insert(hash) }
                return true
            }
            try cancellation.check()
            seenOnce = []
            guard !repeated.isEmpty else { return [] }
            var candidates: [Song] = []
            visited = 0
            try catalog.forEachSong(scope) { _, song in
                visited += 1
                if visited.isMultiple(of: 512), cancellation.isCancelled { return false }
                if let hash = keyHash(song), repeated.contains(hash) { candidates.append(song) }
                return true
            }
            try cancellation.check()
            return candidates
        }
        return DuplicateDetector.detect(in: candidates)
    }

    /// 与 `DuplicateKey.init?(_:)` 同一规则;没有键(缺标题、艺人或有效时长)时 nil。
    private static func keyHash(_ song: Song) -> Int? {
        let title = normalize(song.title)
        let trackArtist = normalize(song.artistName ?? "")
        let artist = trackArtist.isEmpty ? normalize(song.albumArtistName ?? "") : trackArtist
        guard !title.isEmpty, !artist.isEmpty, song.duration.isFinite, song.duration > 0 else { return nil }
        var hasher = Hasher()
        hasher.combine(title)
        hasher.combine(artist)
        hasher.combine(song.duration.finiteInt() / 2)
        return hasher.finalize()
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
