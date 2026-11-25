import Foundation

/// 一轮扫描累积的歌曲表(原来是 `var allSongs = existingSongs` 加一份 `[id: 下标]`)。
///
/// 开头那份已有的歌原样共用,不复制:改过的行按下标记在旁边,新歌另起一段,只在交出终态快照
/// (`songs`)或删去这轮没见到的行(`removeAll(where:)`)时才拼成一整份。原来第一次改一行就会
/// 写时复制出整个源的歌曲数组,扫描期间一直两份并存。
///
/// 下标、计数、遍历顺序、按 id 找下标(同一 id 出现多次时指向最后一次)与原来的 `[Song]` 加字典完全一致;
/// 终态快照的内容与顺序也一样。删过之后不再按 id 找下标(原来那份字典此时已经过期,之后也没人用)。
public struct ScanSongAccumulator: Sendable {
    // crash-pattern: allow library-array-property 一轮扫描里的局部值,与调用方传进来的已有歌曲共用同一份数组,扫描结束即放掉
    private var base: [Song]
    private var replacements: [Int: Song] = [:]
    // crash-pattern: allow library-array-property 只有这一轮新发现的歌,以这一轮扫描为界
    private var appended: [Song] = []
    private var indexByID: [String: Int]

    public init(_ songs: [Song]) {
        base = songs
        var index: [String: Int] = [:]
        index.reserveCapacity(songs.count)
        for (offset, song) in songs.enumerated() { index[song.id] = offset }
        indexByID = index
    }

    public var count: Int { base.count + appended.count }
    public var isEmpty: Bool { count == 0 }
    public var indices: Range<Int> { 0..<count }

    public subscript(position: Int) -> Song {
        get {
            if position < base.count { return replacements[position] ?? base[position] }
            return appended[position - base.count]
        }
        set {
            if position < base.count {
                replacements[position] = newValue
            } else {
                appended[position - base.count] = newValue
            }
        }
    }

    /// 这个 id 最后一次出现的下标。
    public func index(ofID id: String) -> Int? { indexByID[id] }

    public mutating func append(_ song: Song) {
        appended.append(song)
        indexByID[song.id] = count - 1
    }

    /// 删掉满足条件的行,其余保持先后。之后按 id 找下标一律返回 nil。
    public mutating func removeAll(where shouldBeRemoved: (Song) throws -> Bool) rethrows {
        var kept: [Song] = []
        kept.reserveCapacity(count)
        for position in indices {
            let song = self[position]
            if try !shouldBeRemoved(song) { kept.append(song) }
        }
        base = kept
        replacements = [:]
        appended = []
        indexByID = [:]
    }

    /// 整份歌曲表(终态快照)。一行没改、没有新歌时就是开头那份本身,不复制。
    public var songs: [Song] {
        guard !replacements.isEmpty || !appended.isEmpty else { return base }
        var result = base
        for (position, song) in replacements { result[position] = song }
        result.append(contentsOf: appended)
        return result
    }

    /// 改过的行数加新歌数(测试与诊断)。
    public var overlayCount: Int { replacements.count + appended.count }
}
