import Foundation
import PrimuseKit

/// 曲库一侧的匹配器：导入别处的歌单、以及歌单里置灰条目的自动点亮，都用它把
/// 「一首外来的歌」对到曲库里。规则本身在 `ExternalTrackMatchPolicy`（Kit，可在 Linux 测），
/// 这里只负责把 `Song` 喂进去、在多份候选里挑一份。
///
/// 建索引要对整库做一次繁简/全半角归一化，必须在后台跑。`keyCache` 让同一首歌
/// 在元数据没变之前只归一化一次，扫描期间反复重建索引也不会整库重算。
struct PlaylistEntryMatcher: Sendable {
    struct Match: Sendable {
        /// 规则判为「就是它」的歌，按音质从高到低。
        var confident: [Song] = []
        /// 只够得上「可能是」的歌，按曲库顺序。
        var probable: [Song] = []

        var best: Song? { confident.first }
        var suggestion: Song? { confident.first ?? probable.first }
    }

    private let songs: [Song]
    private let index: ExternalTrackMatchIndex<Int>

    init(songs: [Song], keyCache: PlaylistEntryMatchKeyCache? = nil) {
        self.songs = songs
        var keyed: [(id: Int, key: ExternalTrackMatchPolicy.Key)] = []
        keyed.reserveCapacity(songs.count)
        for (offset, song) in songs.enumerated() {
            let key = keyCache?.key(for: song) ?? ExternalTrackMatchPolicy.Key(Self.subject(of: song))
            keyed.append((offset, key))
        }
        index = ExternalTrackMatchIndex(keyed: keyed)
    }

    var isEmpty: Bool { songs.isEmpty }

    func match(_ subject: ExternalTrackMatchPolicy.Subject) -> Match {
        var result = Match()
        for hit in index.matches(for: subject) {
            let song = songs[hit.id]
            if hit.verdict == .confident {
                result.confident.append(song)
            } else {
                result.probable.append(song)
            }
        }
        result.confident.sort {
            DuplicateDetector.qualityScore(of: $0) > DuplicateDetector.qualityScore(of: $1)
        }
        return result
    }

    /// 同一条的几种读法（视频标题「A - B」的两种顺序等）：有一种够得上「就是它」就用那种，
    /// 否则取第一种有「可能是」候选的。
    func match(anyOf subjects: [ExternalTrackMatchPolicy.Subject]) -> Match {
        var fallback = Match()
        for subject in subjects {
            let result = match(subject)
            if !result.confident.isEmpty { return result }
            if fallback.probable.isEmpty, !result.probable.isEmpty { fallback = result }
        }
        return fallback
    }

    static func subject(of song: Song) -> ExternalTrackMatchPolicy.Subject {
        .init(title: song.title, artists: artists(of: song), duration: song.duration)
    }

    /// 源给了多值歌手字段就用它，否则用歌手文本；都没有才退到专辑艺术家。
    static func artists(of song: Song) -> [String] {
        if let names = song.sourceArtistNames, !names.isEmpty { return names }
        if let artist = song.artistName?.trimmingCharacters(in: .whitespacesAndNewlines), !artist.isEmpty {
            return [artist]
        }
        if let albumArtist = song.albumArtistName?.trimmingCharacters(in: .whitespacesAndNewlines), !albumArtist.isEmpty {
            return [albumArtist]
        }
        return []
    }
}

/// 每首歌归一化后的匹配键缓存。键随标题/歌手/时长变化失效。
final class PlaylistEntryMatchKeyCache: @unchecked Sendable {
    private struct Entry {
        let fingerprint: Fingerprint
        let key: ExternalTrackMatchPolicy.Key
    }

    private struct Fingerprint: Equatable {
        let title: String
        let artists: [String]
        let duration: Double
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func key(for song: Song) -> ExternalTrackMatchPolicy.Key {
        let subject = PlaylistEntryMatcher.subject(of: song)
        let fingerprint = Fingerprint(title: subject.title, artists: subject.artists, duration: song.duration)
        lock.lock()
        if let cached = entries[song.id], cached.fingerprint == fingerprint {
            lock.unlock()
            return cached.key
        }
        lock.unlock()
        let key = ExternalTrackMatchPolicy.Key(subject)
        lock.lock()
        entries[song.id] = Entry(fingerprint: fingerprint, key: key)
        lock.unlock()
        return key
    }

    /// 只留下仍在曲库里的歌，免得删掉的源一直占着内存。
    func retain(songIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        guard entries.count > songIDs.count else { return }
        entries = entries.filter { songIDs.contains($0.key) }
    }
}
