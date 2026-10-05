import Foundation

/// 播放记录里的音乐源 ID 认不出来时（源删了，或者删了又重建），把它找回到现在的某个源上。
///
/// 歌曲 ID 是源 ID 加路径哈希出来的，源一重建，旧记录里的歌一首都对不上，只剩两条线索：
/// 1. 删除时留下的源信息（类型、地址与共享路径、网盘账号、服务器标识）—— 和现存的源比；
/// 2. 那个源上播过的歌名与歌手 —— 去曲库里看这些歌现在在哪个源上，多数落在同一个才认。
/// 两条都认不出：知道名字的算「已删除」，连名字都没有的归到一起。
public enum ListeningSourceAttribution {
    public enum Resolution: Equatable, Sendable {
        /// 记到这个现存的源上（可能就是删了又重建的那个）。
        case live(String)
        /// 源已删除，还记得它叫什么、是什么类型。
        case deleted(name: String, type: MusicSourceType)
        /// 什么都没留下。
        case unknown
    }

    /// 按歌投票至少要比上几首、其中多少落在同一个源上才算数。
    public static let minimumVotingSongs = 3
    public static let minimumVoteShare = 0.6

    /// 认定「同一个源」的线索：网盘账号、Plex 服务器、厂商给的设备标识，以及每个地址加共享
    /// 路径。只在同一类源之间比，任一条相同即可。
    public static func connectionKeys(of source: MusicSource) -> Set<String> {
        var keys = Set<String>()
        if let account = nonEmpty(source.cloudAccountID) { keys.insert("account:" + account) }
        if let server = nonEmpty(source.plexServerIdentifier) { keys.insert("plex:" + server) }
        if let vendor = nonEmpty(source.connectionConfiguration?.vendorIdentifier) { keys.insert("vendor:" + vendor) }

        let location = [source.shareName, source.exportPath, source.basePath]
            .compactMap { $0.map(normalizedPath) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        var endpoints: [(host: String, port: Int?)] = []
        if let host = nonEmpty(source.host) { endpoints.append((host, source.port)) }
        for endpoint in [source.connectionConfiguration?.localEndpoint, source.connectionConfiguration?.publicEndpoint] {
            if let endpoint, let host = nonEmpty(endpoint.host) { endpoints.append((host, endpoint.port)) }
        }
        for endpoint in endpoints {
            keys.insert("address:\(endpoint.host.lowercased()):\(endpoint.port.map(String.init) ?? ""):\(location)")
        }
        // 没有地址的源（本机文件夹、系统音乐库）：同一类里路径相同就是同一个。
        if endpoints.isEmpty, keys.isEmpty {
            keys.insert("path:" + location)
        }
        return keys
    }

    /// 已删除的源在现存的同类源里只有一个线索相同，就认作它；有两个以上说不清，不认。
    public static func connectionMatch(for deleted: MusicSource, among live: [MusicSource]) -> String? {
        let keys = connectionKeys(of: deleted)
        guard !keys.isEmpty else { return nil }
        let candidates = live.filter {
            $0.id != deleted.id && $0.type == deleted.type && !connectionKeys(of: $0).isDisjoint(with: keys)
        }
        return candidates.count == 1 ? candidates[0].id : nil
    }

    /// 歌名加歌手的比对键：去掉首尾空白、不分大小写。没有歌名的不参与。
    public static func songKey(title: String, artist: String?) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return nil }
        let artist = (artist ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return title + "\u{1F}" + artist
    }

    /// 按歌投票。`played` 是这个源上播过的歌（比对键），`librarySources[键]` 是这首歌现在
    /// 在曲库里哪些源上。一首歌在几个源上都有时，每个源各记一票。
    public static func songVote(played: Set<String>, librarySources: [String: Set<String>]) -> String? {
        var matched = 0
        var votes: [String: Int] = [:]
        for key in played {
            guard let sources = librarySources[key], !sources.isEmpty else { continue }
            matched += 1
            for source in sources { votes[source, default: 0] += 1 }
        }
        guard matched >= minimumVotingSongs else { return nil }
        let ranked = votes.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        guard let best = ranked.first,
              Double(best.value) / Double(matched) >= minimumVoteShare,
              // 两个源并列第一说不清是哪个。
              ranked.dropFirst().first?.value != best.value else { return nil }
        return best.key
    }

    /// 每个出现在播放记录里的源 ID 该记到哪里。
    /// - Parameters:
    ///   - deleted: 删除留下的源信息（「最近删除」里的，以及删除台账里的墓碑）。
    ///   - songVotes: 对认不出的源按歌投出来的现存源 ID，见 `songVote`。
    public static func resolve(
        playedSourceIDs: Set<String>,
        live: [MusicSource],
        deleted: [MusicSource],
        songVotes: [String: String]
    ) -> [String: Resolution] {
        let liveIDs = Set(live.map(\.id))
        let tombstones = Dictionary(deleted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Resolution] = [:]
        for sourceID in playedSourceIDs {
            if liveIDs.contains(sourceID) {
                result[sourceID] = .live(sourceID)
            } else if let tombstone = tombstones[sourceID], let match = connectionMatch(for: tombstone, among: live) {
                result[sourceID] = .live(match)
            } else if let vote = songVotes[sourceID], liveIDs.contains(vote) {
                result[sourceID] = .live(vote)
            } else if let tombstone = tombstones[sourceID] {
                result[sourceID] = .deleted(name: tombstone.name, type: tombstone.type)
            } else {
                result[sourceID] = .unknown
            }
        }
        return result
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
            .lowercased()
    }
}
