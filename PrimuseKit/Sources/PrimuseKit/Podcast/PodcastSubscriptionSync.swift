import Foundation

/// 经 iCloud 键值存储同步的那一份订阅定义。只有用户的决定(订了哪些、每档的设置、
/// 已播水位线),不含刷新状态 —— 别的设备的 ETag 同步过来会让这台拿到 304 却一集都没有。
public struct PodcastSubscriptionRecord: Codable, Hashable, Sendable {
    public var id: String
    public var feedURL: URL
    public var title: String
    public var author: String?
    public var artworkURL: URL?
    public var directoryID: Int?
    public var subscribedAt: Date
    public var settings: PodcastShowSettings
    public var playedThrough: Date?
    public var reopenedEpisodeIDs: [String]
    public var modifiedAt: Date

    public init(show: PodcastShow) {
        id = show.id
        feedURL = show.feedURL
        title = show.title
        author = show.author
        artworkURL = show.artworkURL
        directoryID = show.directoryID
        subscribedAt = show.subscribedAt
        settings = show.settings
        playedThrough = show.playedThrough
        reopenedEpisodeIDs = show.reopenedEpisodeIDs.sorted()
        modifiedAt = show.definitionModifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, feedURL, title, author, artworkURL, directoryID, subscribedAt, settings
        case playedThrough, reopenedEpisodeIDs, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        feedURL = try c.decode(URL.self, forKey: .feedURL)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        author = try c.decodeIfPresent(String.self, forKey: .author)
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        directoryID = try c.decodeIfPresent(Int.self, forKey: .directoryID)
        subscribedAt = try c.decodeIfPresent(Date.self, forKey: .subscribedAt) ?? .distantPast
        settings = try c.decodeIfPresent(PodcastShowSettings.self, forKey: .settings) ?? PodcastShowSettings()
        playedThrough = try c.decodeIfPresent(Date.self, forKey: .playedThrough)
        reopenedEpisodeIDs = try c.decodeIfPresent([String].self, forKey: .reopenedEpisodeIDs) ?? []
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? subscribedAt
    }

    /// 别的设备订的、本机还没取过 feed 的节目:先用记录里的名字和封面占位,刷新后补全。
    public func makeShow() -> PodcastShow {
        PodcastShow(
            id: id,
            feedURL: feedURL,
            title: title,
            author: author,
            artworkURL: artworkURL,
            directoryID: directoryID,
            subscribedAt: subscribedAt,
            settings: settings,
            playedThrough: playedThrough,
            reopenedEpisodeIDs: Set(reopenedEpisodeIDs),
            definitionModifiedAt: modifiedAt
        )
    }

    /// 把记录里的用户决定写到已有的节目上,节目自己的信息和刷新状态不动。
    public func apply(to show: inout PodcastShow) {
        show.settings = settings
        show.playedThrough = playedThrough
        show.reopenedEpisodeIDs = Set(reopenedEpisodeIDs)
        show.definitionModifiedAt = modifiedAt
        if show.directoryID == nil { show.directoryID = directoryID }
    }
}

public struct PodcastSubscriptionDocument: Codable, Hashable, Sendable {
    public var subscriptions: [PodcastSubscriptionRecord]
    /// 退订过的节目 id → 退订时间。另一台设备还没收到退订时,靠它判断谁更新。
    public var removed: [String: Date]

    public init(subscriptions: [PodcastSubscriptionRecord] = [], removed: [String: Date] = [:]) {
        self.subscriptions = subscriptions
        self.removed = removed
    }

    private enum CodingKeys: String, CodingKey { case subscriptions, removed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subscriptions = try c.decodeIfPresent([PodcastSubscriptionRecord].self, forKey: .subscriptions) ?? []
        removed = try c.decodeIfPresent([String: Date].self, forKey: .removed) ?? [:]
    }

    public static func decode(_ raw: String?) -> PodcastSubscriptionDocument? {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        return try? Self.decoder.decode(PodcastSubscriptionDocument.self, from: data)
    }

    public func encoded() -> String {
        guard let data = try? Self.encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        // 两台设备合出同一份内容时编码也要一字不差,键值存储才认得出「没变」。
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

public enum PodcastSubscriptionSync {
    /// 退订记录留多久。超过这么久还没同步到的设备,再订回来也不算冲突。
    public static let tombstoneLifetime: TimeInterval = 180 * 24 * 3600

    public static func document(shows: [PodcastShow], removed: [String: Date], now: Date) -> PodcastSubscriptionDocument {
        let live = Set(shows.map(\.id))
        let tombstones = removed.filter { !live.contains($0.key) && now.timeIntervalSince($0.value) < tombstoneLifetime }
        return PodcastSubscriptionDocument(
            subscriptions: shows.map(PodcastSubscriptionRecord.init(show:)).sorted { $0.id < $1.id },
            removed: tombstones
        )
    }

    public struct Outcome: Sendable, Hashable {
        /// 合并后本机应有的节目(保持本机原有顺序,新来的接在后面)。
        public var shows: [PodcastShow]
        public var removed: [String: Date]
        /// 别的设备新订的:本机还没有单集,要去取 feed。
        public var addedShowIDs: [String]
        /// 别的设备退订的。
        public var removedShowIDs: [String]
        /// 本机有云端没有的改动(新订阅、更新的设置):合并结果要推回去。
        public var needsPush: Bool
    }

    /// 云端那份和本机合并。每档节目按「订阅/改设置的时间」与「退订时间」谁新谁算。
    public static func merge(
        local shows: [PodcastShow],
        localRemoved: [String: Date],
        remote: PodcastSubscriptionDocument,
        now: Date
    ) -> Outcome {
        var removed = localRemoved
        for (id, date) in remote.removed where (removed[id] ?? .distantPast) < date {
            removed[id] = date
        }
        let remoteByID = Dictionary(remote.subscriptions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in
            lhs.modifiedAt >= rhs.modifiedAt ? lhs : rhs
        })

        var result: [PodcastShow] = []
        var removedIDs: [String] = []
        var needsPush = false
        var seen = Set<String>()

        for var show in shows {
            seen.insert(show.id)
            if let record = remoteByID[show.id] {
                if record.modifiedAt > show.definitionModifiedAt {
                    record.apply(to: &show)
                } else if record.modifiedAt < show.definitionModifiedAt {
                    needsPush = true
                }
                // 时间相同时不比节目名和封面:那是各自刷新 feed 得来的,两台设备一时不一致很正常,
                // 拿它判断「要推」会让两边轮流把自己的版本推上去。
                result.append(show)
            } else if let removedAt = removed[show.id], removedAt >= show.definitionModifiedAt {
                removedIDs.append(show.id)
            } else {
                // 本机订了、云端还没有。
                needsPush = true
                result.append(show)
            }
        }

        var added: [String] = []
        for record in remote.subscriptions.sorted(by: { $0.subscribedAt < $1.subscribedAt }) where !seen.contains(record.id) {
            seen.insert(record.id)
            if let removedAt = removed[record.id], removedAt >= record.modifiedAt {
                // 本机后来退订了,云端那条是旧的。
                needsPush = true
                continue
            }
            result.append(record.makeShow())
            added.append(record.id)
        }

        let live = Set(result.map(\.id))
        removed = removed.filter { !live.contains($0.key) && now.timeIntervalSince($0.value) < tombstoneLifetime }
        if removed != remote.removed.filter({ !live.contains($0.key) && now.timeIntervalSince($0.value) < tombstoneLifetime }) {
            needsPush = true
        }
        return Outcome(shows: result, removed: removed, addedShowIDs: added, removedShowIDs: removedIDs, needsPush: needsPush)
    }
}
