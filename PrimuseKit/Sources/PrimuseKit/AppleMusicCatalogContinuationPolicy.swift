import Foundation

/// 目录曲(搜索结果里点播的 Apple Music 歌)播完后续播相似歌曲(#166 的目录版)。
///
/// 曲库续播只能从曲库里挑,而在 Apple Music 里搜的歌往往不在曲库里。这里的
/// 候选全部来自 Apple Music 目录:先拿 Last.fm 的相似单曲到目录里逐首对上,
/// 不够再轮流放相似艺人(连同本人)的热门曲。
public enum AppleMusicCatalogContinuationPolicy {
    /// 一次续多少首。每首都要联网对上,比曲库那批小。
    public static let batchSize = 12
    /// Last.fm 的相似单曲最多拿去目录里对几首,每首一次目录搜索。
    public static let lastFmLookupLimit = 18
    /// 同时发几个目录搜索。
    public static let lookupConcurrency = 4
    /// 取几位相似艺人的热门曲。
    public static let similarArtistLimit = 8
    /// 每位艺人的热门曲拿前几首进候选。
    public static let topSongsPerArtist = 4
    /// 一批里同一位歌手最多几首,免得续成某位歌手的专场。
    public static let perArtistLimit = 3

    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let title: String
        public let artist: String

        public init(id: String, title: String, artist: String) {
            self.id = id
            self.title = title
            self.artist = artist
        }
    }

    /// 同一首歌的比较键:歌名去掉括号里的版本说明,与歌手一起忽略大小写、全半角和变音符号。
    public static func songKey(title: String, artist: String) -> String {
        "\(titleKey(title))|\(artistKey(artist))"
    }

    public static func titleKey(_ title: String) -> String {
        let stripped = folded(removingBracketedText(from: title))
        return stripped.isEmpty ? folded(title) : stripped
    }

    public static func artistKey(_ artist: String) -> String {
        folded(artist)
    }

    /// 目录搜索结果里哪一条就是要找的那首:歌名一致,歌手一致或一方包含另一方
    /// (目录写「A & B」、Last.fm 只写「A」)。对不上就不要,宁缺毋错。
    public static func matchIndex(title: String, artist: String, in results: [Candidate]) -> Int? {
        let wantedTitle = titleKey(title)
        let wantedArtist = artistKey(artist)
        guard !wantedTitle.isEmpty, !wantedArtist.isEmpty else { return nil }
        return results.firstIndex { result in
            titleKey(result.title) == wantedTitle && artistsMatch(artistKey(result.artist), wantedArtist)
        }
    }

    /// 曲库艺人在目录艺人搜索结果里是哪一位:名字(忽略大小写、全半角、变音符号与标点)
    /// 完全一样、且只有一位这样的。艺人照片配错人比没有照片难看得多,所以不认包含关系;
    /// 同名的有好几位时也分不清是谁,不要。
    public static func uniqueArtistMatchIndex(name: String, in results: [String]) -> Int? {
        let wanted = artistKey(name)
        guard !wanted.isEmpty else { return nil }
        let matches = results.indices.filter { artistKey(results[$0]) == wanted }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 拼一批续播:先放 Last.fm 那一路(已按相似度排好),再轮流取各位艺人的热门曲。
    /// 同一首(按 `songKey`)只出现一次,`isExcluded` 为真的(已在队列里、刚播过、
    /// 不喜欢的)不要,同一位歌手不超过 `perArtistLimit` 首。
    public static func assemble(
        similarTracks: [Candidate],
        artistTopSongs: [[Candidate]],
        isExcluded: (Candidate) -> Bool,
        limit: Int = batchSize,
        perArtistLimit: Int = perArtistLimit
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        var picked: [Candidate] = []
        var seenIDs = Set<String>()
        var seenKeys = Set<String>()
        var perArtist: [String: Int] = [:]

        func take(_ candidate: Candidate) {
            guard picked.count < limit else { return }
            let key = songKey(title: candidate.title, artist: candidate.artist)
            // 排除掉的歌也记下比较键:队列里已有的那首换个版本(现场版、重制版)再来也不要。
            guard !isExcluded(candidate) else {
                seenKeys.insert(key)
                return
            }
            let artist = artistKey(candidate.artist)
            guard perArtist[artist, default: 0] < perArtistLimit,
                  !seenKeys.contains(key),
                  seenIDs.insert(candidate.id).inserted else { return }
            seenKeys.insert(key)
            perArtist[artist, default: 0] += 1
            picked.append(candidate)
        }

        for candidate in similarTracks { take(candidate) }
        let longest = artistTopSongs.map(\.count).max() ?? 0
        for round in 0..<longest {
            for songs in artistTopSongs where songs.indices.contains(round) {
                take(songs[round])
            }
        }
        return picked
    }

    private static func artistsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        // 太短的名字互相包含说明不了什么。
        guard min(lhs.count, rhs.count) >= 2 else { return false }
        return lhs.contains(rhs) || rhs.contains(lhs)
    }

    static func removingBracketedText(from value: String) -> String {
        let pairs: [Character: Character] = ["(": ")", "[": "]", "（": "）", "【": "】", "{": "}"]
        var result = ""
        var closers: [Character] = []
        for character in value {
            if let closer = pairs[character] {
                closers.append(closer)
            } else if let expected = closers.last, character == expected {
                closers.removeLast()
            } else if closers.isEmpty {
                result.append(character)
            }
        }
        return result
    }

    static func folded(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
