import Foundation

/// 把刚取到的 feed 并进本机已有的那档节目。
public enum PodcastFeedMerge {
    public struct Result: Sendable, Hashable {
        public var show: PodcastShow
        /// 从新到旧(没有日期的排最后,同一时刻保持 feed 里的先后)。
        public var episodes: [PodcastEpisode]
        /// 这次刷新才出现的单集。首次订阅时为空 —— 订阅前就有的不算「新」。
        public var addedEpisodeIDs: [String]
    }

    /// 首次订阅。
    public static func subscribe(
        feed: PodcastFeed,
        feedURL: URL,
        directoryID: Int? = nil,
        now: Date
    ) -> Result {
        let show = PodcastShow(
            id: PodcastIdentity.showID(feedURL: feedURL),
            feedURL: feed.newFeedURL ?? feedURL,
            title: feed.title,
            directoryID: directoryID,
            subscribedAt: now
        )
        return merge(show: show, existing: [], feed: feed, now: now, isFirstFetch: true)
    }

    /// 之后每次刷新。`retaining` 里的单集即使从 feed 里消失了也留着(下载过、听过一半、听完的),
    /// 只保留最近若干集的 feed 不至于把用户听过的东西冲掉。
    public static func refresh(
        show: PodcastShow,
        existing: [PodcastEpisode],
        feed: PodcastFeed,
        retaining: Set<String> = [],
        now: Date
    ) -> Result {
        merge(show: show, existing: existing, feed: feed, retaining: retaining, now: now, isFirstFetch: false)
    }

    private static func merge(
        show original: PodcastShow,
        existing: [PodcastEpisode],
        feed: PodcastFeed,
        retaining: Set<String> = [],
        now: Date,
        isFirstFetch: Bool
    ) -> Result {
        var show = original
        if !feed.title.isEmpty { show.title = feed.title }
        show.author = feed.author ?? show.author
        show.summary = feed.summary ?? show.summary
        show.artworkURL = feed.artworkURL ?? show.artworkURL
        show.websiteURL = feed.websiteURL ?? show.websiteURL
        show.language = feed.language ?? show.language
        if !feed.categories.isEmpty { show.categories = feed.categories }
        show.isSerial = feed.isSerial
        show.isExplicit = feed.isExplicit
        if let moved = feed.newFeedURL,
           PodcastFeedURL.identityKey(for: moved) != PodcastFeedURL.identityKey(for: show.feedURL) {
            show.feedURL = moved
        }
        show.lastRefreshedAt = now

        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var merged: [(episode: PodcastEpisode, order: Int)] = []
        var added: [String] = []

        for (index, item) in feed.items.enumerated() {
            guard let identity = item.identity, let enclosure = item.enclosureURL else { continue }
            let id = PodcastIdentity.episodeID(showID: show.id, guid: identity)
            guard seen.insert(id).inserted else { continue }
            let previous = existingByID[id]
            if previous == nil, !isFirstFetch { added.append(id) }
            let episode = PodcastEpisode(
                id: id,
                showID: show.id,
                guid: identity,
                title: item.title,
                subtitle: item.subtitle,
                showNotes: item.showNotes,
                publishedAt: item.publishedAt ?? previous?.publishedAt,
                duration: item.duration ?? previous?.duration,
                enclosureURL: enclosure,
                enclosureType: item.enclosureType,
                enclosureLength: item.enclosureLength,
                artworkURL: item.artworkURL,
                season: item.season,
                number: item.number,
                kind: item.kind,
                link: item.link,
                chaptersURL: item.chaptersURL,
                chapters: item.chapters.isEmpty ? (previous?.chapters ?? []) : item.chapters,
                transcriptURL: item.transcriptURL,
                transcriptType: item.transcriptType,
                isExplicit: item.isExplicit,
                firstSeenAt: previous?.firstSeenAt ?? now
            )
            merged.append((episode, index))
        }

        var order = merged.count
        for episode in existing where !seen.contains(episode.id) && retaining.contains(episode.id) {
            merged.append((episode, order))
            order += 1
        }

        let episodes = merged.sorted { lhs, rhs in
            switch (lhs.episode.publishedAt, rhs.episode.publishedAt) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.order < rhs.order
            }
        }.map(\.episode)

        show.latestEpisodeAt = episodes.compactMap(\.publishedAt).max() ?? show.latestEpisodeAt
        return Result(show: show, episodes: episodes, addedEpisodeIDs: added)
    }
}

/// 单集在本机的听过状态。进度与听完来自有声内容那份账(`SpokenWordStore`),下载来自播客自己的下载账。
public struct PodcastEpisodeState: Sendable, Hashable {
    public var position: TimeInterval?
    public var isFinished: Bool
    public var isDownloaded: Bool

    public init(position: TimeInterval? = nil, isFinished: Bool = false, isDownloaded: Bool = false) {
        self.position = position
        self.isFinished = isFinished
        self.isDownloaded = isDownloaded
    }

    public var isInProgress: Bool {
        !isFinished && (position ?? 0) > 0
    }

    public static let untouched = PodcastEpisodeState()
}

public enum PodcastEpisodeFilter: String, CaseIterable, Sendable {
    case all
    case unplayed
    case inProgress
    case downloaded

    public func includes(_ state: PodcastEpisodeState) -> Bool {
        switch self {
        case .all: return true
        case .unplayed: return !state.isFinished
        case .inProgress: return state.isInProgress
        case .downloaded: return state.isDownloaded
        }
    }
}

/// 列表排序、分季、跨节目的「最新单集」、播完接着放哪几集。都是纯函数,界面和播放器共用。
public enum PodcastEpisodeListPolicy {
    /// `episodes` 约定是从新到旧(`PodcastFeedMerge` 的输出)。
    public static func ordered(_ episodes: [PodcastEpisode], order: PodcastEpisodeOrder) -> [PodcastEpisode] {
        switch order {
        case .newestFirst: return episodes
        case .oldestFirst: return episodes.reversed()
        }
    }

    public struct SeasonGroup: Sendable, Hashable, Identifiable {
        public var season: Int?
        public var episodes: [PodcastEpisode]
        public var id: Int { season ?? -1 }
    }

    /// 有两季以上才分组;按 `order` 决定季的先后,季内顺序沿用传入的顺序。
    public static func seasonGroups(_ episodes: [PodcastEpisode], order: PodcastEpisodeOrder) -> [SeasonGroup] {
        let seasons = Set(episodes.compactMap(\.season))
        guard seasons.count > 1 else { return [SeasonGroup(season: nil, episodes: episodes)] }
        var groups: [Int?: [PodcastEpisode]] = [:]
        var firstAppearance: [Int?] = []
        for episode in episodes {
            if groups[episode.season] == nil { firstAppearance.append(episode.season) }
            groups[episode.season, default: []].append(episode)
        }
        let sortedSeasons = firstAppearance.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case let (l?, r?): return order == .oldestFirst ? l < r : l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return false
            }
        }
        return sortedSeasons.map { SeasonGroup(season: $0, episodes: groups[$0] ?? []) }
    }

    /// feed 里的集号能不能拿来给人看。有的托管方把集号倒着编(喜马拉雅:最新一集是 1),
    /// 或者每集都写同一个数;集号跟发布先后对不上时就不显示「第 N 集」。`episodes` 从新到旧。
    public static func numbersFollowPublishOrder(_ episodes: [PodcastEpisode]) -> Bool {
        var agree = 0
        var disagree = 0
        var newer: Int?
        var numbered = 0
        for episode in episodes {
            guard let number = episode.number else { continue }
            numbered += 1
            if let newer {
                if newer > number { agree += 1 } else if newer < number { disagree += 1 }
            }
            newer = number
        }
        guard numbered > 1 else { return true }
        return agree > 0 && agree >= disagree
    }

    /// 所有订阅里最近发布的单集,从新到旧。`excludingFinished` 时听完的不列。
    public static func latest(
        episodesByShow: [String: [PodcastEpisode]],
        state: (PodcastEpisode) -> PodcastEpisodeState,
        excludingFinished: Bool = true,
        since: Date? = nil,
        limit: Int
    ) -> [PodcastEpisode] {
        guard limit > 0 else { return [] }
        var candidates: [PodcastEpisode] = []
        for episodes in episodesByShow.values {
            // 每档节目已经是从新到旧,取前 limit 个就够。
            var taken = 0
            for episode in episodes {
                guard taken < limit else { break }
                if let since, let published = episode.publishedAt, published < since { break }
                if excludingFinished, state(episode).isFinished { continue }
                candidates.append(episode)
                taken += 1
            }
        }
        return Array(candidates.sorted { lhs, rhs in
            let l = lhs.publishedAt ?? .distantPast
            let r = rhs.publishedAt ?? .distantPast
            return l != r ? l > r : lhs.id < rhs.id
        }.prefix(limit))
    }

    /// 订阅之后才出现、还没听完的单集数,节目封面上的角标。
    public static func newEpisodeCount(
        show: PodcastShow,
        episodes: [PodcastEpisode],
        state: (PodcastEpisode) -> PodcastEpisodeState
    ) -> Int {
        episodes.reduce(0) { count, episode in
            guard episode.firstSeenAt > show.subscribedAt, episode.kind != .trailer else { return count }
            return count + (state(episode).isFinished || state(episode).isInProgress ? 0 : 1)
        }
    }

    /// 在节目页点了某一集:播完接着往「更新」的方向放还没听完的,预告不放。
    /// 返回值第一项就是点的那一集。
    public static func continuation(
        from episodeID: String,
        in episodes: [PodcastEpisode],
        state: (PodcastEpisode) -> PodcastEpisodeState,
        limit: Int = 50
    ) -> [PodcastEpisode] {
        // episodes 从新到旧;往「更新」的方向 = 往数组前面走。
        guard let index = episodes.firstIndex(where: { $0.id == episodeID }) else { return [] }
        var queue = [episodes[index]]
        var cursor = index - 1
        while cursor >= 0, queue.count < limit {
            let candidate = episodes[cursor]
            if candidate.kind != .trailer, !state(candidate).isFinished { queue.append(candidate) }
            cursor -= 1
        }
        return queue
    }

    /// 连载节目「从头听」/「接着听」:最早一集还没听完的,优先正在听的那集。
    public static func resumeTarget(
        in episodes: [PodcastEpisode],
        isSerial: Bool,
        state: (PodcastEpisode) -> PodcastEpisodeState
    ) -> PodcastEpisode? {
        if let inProgress = episodes.first(where: { state($0).isInProgress }) { return inProgress }
        let playable = episodes.filter { $0.kind != .trailer }
        if isSerial {
            return playable.last(where: { !state($0).isFinished }) ?? playable.last
        }
        return playable.first(where: { !state($0).isFinished }) ?? playable.first
    }
}

/// 什么时候该刷新一档节目。
public enum PodcastRefreshSchedule {
    /// 前台进入、打开播客页时,距上次刷新超过这么久才去取。
    public static let minimumInterval: TimeInterval = 30 * 60

    public static func isDue(lastRefreshedAt: Date?, failureCount: Int = 0, now: Date) -> Bool {
        guard let last = lastRefreshedAt else { return true }
        // 连续失败就拉长间隔,最长一天一次,别对坏掉的 feed 一直敲。
        let backoff = min(24 * 3600, minimumInterval * pow(2, Double(min(failureCount, 6))))
        return now.timeIntervalSince(last) >= (failureCount > 0 ? backoff : minimumInterval)
    }
}
