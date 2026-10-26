import Foundation

public enum ListeningCalendar {
    public static var current: Calendar {
        let system = Calendar.autoupdatingCurrent
        let locale = Locale.autoupdatingCurrent
        let regional = Locale(identifier: locale.identifier).calendar
        let preferred = system.firstWeekday != regional.firstWeekday ? system.firstWeekday : nil
        return make(locale: locale, timeZone: system.timeZone, identifier: system.identifier, firstWeekday: preferred)
    }

    public static func make(
        locale: Locale, timeZone: TimeZone, identifier: Calendar.Identifier = .gregorian,
        firstWeekday: Int? = nil
    ) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.locale = locale
        calendar.timeZone = timeZone
        if let firstWeekday {
            calendar.firstWeekday = firstWeekday
        } else if locale.region?.identifier == "CN",
                  Locale.Components(identifier: locale.identifier).firstDayOfWeek == nil {
            // CLDR uses Monday for mainland China; some Foundation releases
            // still carry the older Sunday default. Keep explicit overrides.
            calendar.firstWeekday = 2
        }
        return calendar
    }

    public static func interval(component: Calendar.Component?, now: Date, calendar: Calendar) -> DateInterval {
        let start = component.flatMap { calendar.dateInterval(of: $0, for: now)?.start } ?? .distantPast
        return DateInterval(start: start, end: now)
    }
}

public enum HomeListeningPeriod: String, CaseIterable, Sendable {
    case week, month, all

    public func interval(now: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component? = self == .all ? nil : (self == .week ? .weekOfYear : .month)
        return ListeningCalendar.interval(component: component, now: now, calendar: calendar)
    }

    public func previousInterval(now: Date, calendar: Calendar) -> DateInterval? {
        guard self != .all else { return nil }
        let component: Calendar.Component = self == .week ? .weekOfYear : .month
        guard let current = calendar.dateInterval(of: component, for: now),
              let previous = calendar.date(byAdding: component, value: -1, to: current.start)
        else { return nil }
        return DateInterval(start: previous, end: current.start)
    }
}

public enum HomeListeningCategory: String, CaseIterable, Sendable {
    case songs, artists, albums, folders
}

public struct HomeListeningEvent: Sendable {
    public let songID: String
    public let playedAt: Date
    public let listenedSeconds: TimeInterval
    public let songTitle: String?
    public let artistName: String?
    public let albumTitle: String?
    /// 这首歌的长度（不是这次听了多久）。认「同一首歌」时用来防误并；播放记录里没有，
    /// 调用方从曲库查到了才填，`ranks` 的 `songs` 里有这首歌时也不必填。
    public let songDuration: TimeInterval?

    public init(
        songID: String, playedAt: Date, listenedSeconds: TimeInterval,
        songTitle: String? = nil, artistName: String? = nil, albumTitle: String? = nil,
        songDuration: TimeInterval? = nil
    ) {
        self.songID = songID
        self.playedAt = playedAt
        self.listenedSeconds = listenedSeconds
        self.songTitle = songTitle
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.songDuration = songDuration
    }
}

public struct HomeListeningRank: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let songIDs: [String]
    /// 这一项里的不同歌曲。同一首歌在几个音乐源里各有一份（或者源删了重建、ID 变了）算一首，
    /// 见 `ListeningSongIdentity`：每组是同一首歌的几份，听得多的在前；组按播放次数从多到少。
    /// 歌曲榜每一项正好一组。
    public let songGroups: [[String]]
    /// 这一组里听得最多的那首，封面取它的。`songIDs` 按 ID 排序，第一首只是
    /// 字典序靠前，拿来当艺人或专辑的门面没有道理。
    public let artworkSongID: String?
    public let folderID: LibraryFolderNodeID?
    public let playCount: Int
    public let listenedSeconds: TimeInterval
    public var positionsGained: Int?
    /// 上一个周期有榜单，而这一项不在其中。上一个周期整段空白时不算 ——
    /// 否则刚开始用的人会看到满屏「新上榜」。
    public var isNewEntry = false

    /// 每首歌挑一份：同一首的几份里第一份 `isAvailable` 的；都不可用时取听得最多的那份。
    public func distinctSongIDs(preferring isAvailable: (String) -> Bool) -> [String] {
        songGroups.compactMap { copies in copies.first(where: isAvailable) ?? copies.first }
    }

    public var trend: HomeListeningRankTrend? {
        if let positionsGained {
            if positionsGained > 0 { return .up(positionsGained) }
            if positionsGained < 0 { return .down(-positionsGained) }
            return .steady
        }
        return isNewEntry ? .newEntry : nil
    }
}

/// 与上一个周期相比的名次变化。「全部」没有上一个周期，整榜都没有变化可言。
public enum HomeListeningRankTrend: Equatable, Sendable {
    case up(Int)
    case down(Int)
    case steady
    case newEntry
}

/// 榜单怎么摆：前三名站领奖台，其余列成名次榜；横排则是一条封面货架。
public enum HomeListeningRankBoardPolicy {
    public static let podiumSize = 3
    /// 收起时一共露出几名（含领奖台）。
    public static let collapsedCount = 5

    /// 领奖台从左到右依次站谁（下标即名次 - 1）：亚军、冠军、季军。
    /// 不足三名时按人数收拢，不给缺席的名次留空台阶。
    public static func podiumOrder(count: Int) -> [Int] {
        switch max(0, min(count, podiumSize)) {
        case 0: return []
        case 1: return [0]
        case 2: return [1, 0]
        default: return [1, 0, 2]
        }
    }

    /// 台阶相对冠军台阶的高度。固定三级而不是按播放次数算 —— 前三名次数
    /// 接近时按比例画出来是一排齐平的柱子，看不出是领奖台。
    public static func stepHeightFraction(place: Int) -> Double {
        switch place {
        case 0: return 1
        case 1: return 0.68
        default: return 0.46
        }
    }

    public static func offersExpansion(total: Int, expandedLimit: Int) -> Bool {
        total > collapsedCount && expandedLimit > collapsedCount
    }

    public static func visibleCount(total: Int, expandedLimit: Int, isExpanded: Bool) -> Int {
        let limit = isExpanded && offersExpansion(total: total, expandedLimit: expandedLimit)
            ? expandedLimit
            : collapsedCount
        return max(0, min(total, limit))
    }

    /// 横排没有展开这一说，直接铺到设置里的名次；设置调到 5 以下也至少铺 5 名。
    public static func shelfCount(total: Int, expandedLimit: Int) -> Int {
        max(0, min(total, max(expandedLimit, collapsedCount)))
    }

    /// 相对榜首的播放占比，给名次行的底色条用。
    public static func share(playCount: Int, leaderPlayCount: Int) -> Double {
        guard leaderPlayCount > 0, playCount > 0 else { return 0 }
        return min(1, Double(playCount) / Double(leaderPlayCount))
    }
}

public enum HomeListeningRanking {
    private struct GroupKey: Hashable {
        let category: HomeListeningCategory
        let components: [String]

        var id: String {
            let data = (try? JSONEncoder().encode([category.rawValue] + components)) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct Accumulator {
        var title: String
        var subtitle: String
        var folderID: LibraryFolderNodeID?
        var songPlays: [String: SongPlays] = [:]
        var count = 0
        var seconds: TimeInterval = 0
        var latestDate = Date.distantPast

        /// 次数最多的那首；并列时取最近听过的，再并列按 ID，保证与输入顺序无关。
        var artworkSongID: String? {
            songPlays.max { SongPlays.ranksAbove($1, $0) }?.key
        }

        /// 同一首歌的几份归成一组，组内与组间都是听得多的在前，次序与输入顺序无关。
        func songGroups(keys: [String: String]) -> [[String]] {
            var groups: [String: (plays: SongPlays, copies: [(id: String, plays: SongPlays)])] = [:]
            for (id, plays) in songPlays {
                let key = keys[id] ?? id
                var group = groups[key] ?? (SongPlays(), [])
                group.plays.count += plays.count
                group.plays.latestDate = max(group.plays.latestDate, plays.latestDate)
                group.copies.append((id, plays))
                groups[key] = group
            }
            return groups
                .map { key, group in
                    (key: key, plays: group.plays,
                     copies: group.copies.sorted { SongPlays.ranksAbove(($0.id, $0.plays), ($1.id, $1.plays)) }.map(\.id))
                }
                .sorted { SongPlays.ranksAbove(($0.key, $0.plays), ($1.key, $1.plays)) }
                .map(\.copies)
        }
    }

    private struct SongPlays {
        var count = 0
        var latestDate = Date.distantPast

        /// 次数多的在前；并列时最近听过的在前，再并列按 ID。
        static func ranksAbove(_ lhs: (key: String, value: SongPlays), _ rhs: (key: String, value: SongPlays)) -> Bool {
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.value.latestDate != rhs.value.latestDate { return lhs.value.latestDate > rhs.value.latestDate }
            return lhs.key < rhs.key
        }
    }

    /// Listening history remains valid after library changes. Only directory
    /// membership depends on the current library index.
    /// - Parameter songKeys: 调用方已经按 `ListeningSongIdentity.groupKeys(events:songs:)` 算好的
    ///   同一首歌分组（同一份记录要排好几张榜时只算一次）；nil 时这里自己算。
    public static func ranks(
        events: [HomeListeningEvent],
        songs: [String: Song],
        folders: LibraryFolderIndex?,
        period: HomeListeningPeriod,
        category: HomeListeningCategory,
        now: Date = Date(),
        calendar: Calendar = ListeningCalendar.current,
        songKeys: [String: String]? = nil
    ) -> [HomeListeningRank] {
        // 整段记录一起认，本期和上期用的是同一套分组，名次升降才对得上。
        let songKeys = category == .folders
            ? [:]
            : songKeys ?? ListeningSongIdentity.groupKeys(events: events, songs: songs)
        let current = aggregate(
            events: events, songs: songs, songKeys: songKeys, folders: folders, category: category,
            interval: period.interval(now: now, calendar: calendar), includesEnd: true
        )
        guard let interval = period.previousInterval(now: now, calendar: calendar) else {
            return current
        }
        let previous = aggregate(
            events: events, songs: songs, songKeys: songKeys, folders: folders, category: category,
            interval: interval, includesEnd: false
        )
        let positions = Dictionary(uniqueKeysWithValues: previous.enumerated().map { ($1.id, $0) })
        return current.enumerated().map { position, value in
            var value = value
            if let oldPosition = positions[value.id] {
                value.positionsGained = oldPosition - position
            } else {
                value.isNewEntry = !previous.isEmpty
            }
            return value
        }
    }

    private static func aggregate(
        events: [HomeListeningEvent], songs: [String: Song], songKeys: [String: String],
        folders: LibraryFolderIndex?, category: HomeListeningCategory, interval: DateInterval, includesEnd: Bool
    ) -> [HomeListeningRank] {
        var groups: [GroupKey: Accumulator] = [:]
        // 同一个名字会出现成百上千次,判一次就记下。
        var placeholderArtists: [String: Bool] = [:]
        for event in events {
            guard event.playedAt >= interval.start,
                  includesEnd ? event.playedAt <= interval.end : event.playedAt < interval.end else { continue }
            let song = songs[event.songID]
            let artist = event.artistName ?? song?.artistName ?? ""
            let album = event.albumTitle ?? song?.albumTitle ?? ""
            let components: [String]
            let title: String
            let subtitle: String
            var folderID: LibraryFolderNodeID?
            switch category {
            case .songs:
                components = [songKeys[event.songID] ?? event.songID]
                title = event.songTitle ?? song?.title ?? event.songID
                subtitle = artist
            case .artists:
                guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let isPlaceholder = placeholderArtists[artist] ?? PlaceholderArtistPolicy.isPlaceholder(artist)
                placeholderArtists[artist] = isPlaceholder
                guard !isPlaceholder else { continue }
                components = [artist]
                title = artist
                subtitle = ""
            case .albums:
                guard !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                components = [album, artist]
                title = album
                subtitle = artist
            case .folders:
                // One play belongs to its containing directory, not every
                // ancestor. This keeps nested-folder totals comparable.
                guard let folders, let id = folders.nodeID(containingSongID: event.songID),
                      let node = folders.node(withID: id),
                      node.kind == .folder || node.kind == .scanRoot else { continue }
                components = [id.sourceID, id.kind.rawValue, id.normalizedRelativePath]
                title = node.displayName ?? ""
                subtitle = folders.sourceNode(for: id.sourceID)?.displayName ?? ""
                folderID = id
            }
            let key = GroupKey(category: category, components: components)
            var group = groups[key] ?? Accumulator(title: title, subtitle: subtitle, folderID: folderID)
            if event.playedAt > group.latestDate {
                group.title = title
                group.subtitle = subtitle
                group.latestDate = event.playedAt
            }
            var plays = group.songPlays[event.songID] ?? SongPlays()
            plays.count += 1
            plays.latestDate = max(plays.latestDate, event.playedAt)
            group.songPlays[event.songID] = plays
            group.count += 1
            if event.listenedSeconds.isFinite { group.seconds += max(0, event.listenedSeconds) }
            groups[key] = group
        }
        return groups.map { key, value in
            HomeListeningRank(
                id: key.id, title: value.title, subtitle: value.subtitle,
                songIDs: value.songPlays.keys.sorted(), songGroups: value.songGroups(keys: songKeys),
                artworkSongID: value.artworkSongID,
                folderID: value.folderID,
                playCount: value.count, listenedSeconds: value.seconds, positionsGained: nil
            )
        }.sorted {
            if $0.playCount != $1.playCount { return $0.playCount > $1.playCount }
            if $0.listenedSeconds != $1.listenedSeconds { return $0.listenedSeconds > $1.listenedSeconds }
            return $0.id < $1.id
        }
    }
}

public enum HomeFolderPinStorage {
    public static let key = "primuse.home.folders.v1"
    public static let displayCountKey = "primuse.home.folderDisplayCount"
    public static let defaultDisplayCount = 3
    public static let displayCountRange = 1...30

    public static func displayCount(_ value: Int) -> Int {
        min(displayCountRange.upperBound, max(displayCountRange.lowerBound, value))
    }

    public static func resolvedPins(
        _ value: String, index: LibraryFolderIndex?, defaultCount: Int
    ) -> [LibraryFolderNodeID] {
        let saved = storedPins(value, index: index, defaultCount: defaultCount)
        guard let index else { return saved }
        return saved.filter { index.node(withID: $0) != nil }
    }

    public static func storedPins(
        _ value: String, index: LibraryFolderIndex?, defaultCount: Int
    ) -> [LibraryFolderNodeID] {
        guard value.isEmpty else { return decode(value) }
        guard let index else { return [] }
        var result: [LibraryFolderNodeID] = []
        for source in index.sourceNodes {
            let candidates = LibraryFolderBrowsePolicy.collapsedScanRoot(in: index, for: source.id) != nil
                ? [source]
                : index.children(of: source.id).filter { $0.kind == .scanRoot || $0.kind == .folder }
            for node in candidates {
                guard node.descendantSongCount > 0 else { continue }
                result.append(node.id)
                if result.count == displayCount(defaultCount) { return result }
            }
        }
        return result
    }

    /// Edits the visible slots while keeping unavailable directories in their
    /// saved positions, so disabling a source never erases its pins.
    public static func replacingVisiblePins(
        in value: String,
        with updatedPins: [LibraryFolderNodeID],
        index: LibraryFolderIndex?,
        defaultCount: Int = defaultDisplayCount
    ) -> String {
        let saved = storedPins(value, index: index, defaultCount: defaultCount)
        let visible = Set(resolvedPins(value, index: index, defaultCount: defaultCount))
        var seen = Set<LibraryFolderNodeID>()
        let updated = updatedPins.filter { seen.insert($0).inserted }
        var remaining = updated.makeIterator()
        var result = saved.compactMap { id in
            visible.contains(id) ? remaining.next() : id
        }
        result.append(contentsOf: remaining)
        return encode(result)
    }

    private struct Record: Codable {
        let sourceID: String
        let kind: String
        let path: String
    }

    public static func decode(_ value: String) -> [LibraryFolderNodeID] {
        guard let data = value.data(using: .utf8),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        var seen = Set<LibraryFolderNodeID>()
        return records.compactMap { record in
            guard let kind = LibraryFolderNodeKind(rawValue: record.kind) else { return nil }
            let id = LibraryFolderNodeID(sourceID: record.sourceID, kind: kind, normalizedRelativePath: record.path)
            return seen.insert(id).inserted ? id : nil
        }
    }

    public static func encode(_ ids: [LibraryFolderNodeID]) -> String {
        let records = ids.map { Record(sourceID: $0.sourceID, kind: $0.kind.rawValue, path: $0.normalizedRelativePath) }
        guard let data = try? JSONEncoder().encode(records) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// 播放记录里的「同一首歌」。
///
/// 歌曲 ID 是音乐源 ID 加文件路径的哈希：同一首歌放在两个源里，或者源删了重建，就是两个 ID，
/// 听歌排行会把它排成两名，「听过多少首」也算成两首。这里在统计时把它们归成一组，播放记录本身不改。
///
/// 认法与播放时「源连不上就换别的源里的同一首」（`MusicLibrary.otherCopies`）是同一条：
/// `ExternalTrackMatchPolicy` 判为 confident —— 歌名主体一致、版本标记（现场、伴奏、混音…）一致、
/// 歌手有交集、两边都知道时长时相差不超过 3 秒。只有歌名对得上、缺歌手或时长差得多的都不并。
public enum ListeningSongIdentity {
    public struct Member: Sendable, Hashable {
        public let songID: String
        public let title: String
        public let artists: [String]
        /// 秒；不知道时为 nil（歌已经不在曲库里，或者调用方没查曲库）。
        public let duration: TimeInterval?

        public init(songID: String, title: String, artists: [String], duration: TimeInterval?) {
            self.songID = songID
            self.title = title
            self.artists = artists
            self.duration = duration
        }
    }

    /// 并进了组的每首歌 → 组键（组里字典序最小的歌曲 ID）。没和别的歌并到一起的不在结果里，
    /// 调用方照旧用它自己的 ID：`keys[id] ?? id`。同一首歌出现多次时只认第一次。
    public static func groupKeys(_ members: [Member]) -> [String: String] {
        var seen = Set<String>()
        var buckets: [String: [(id: String, key: ExternalTrackMatchPolicy.Key)]] = [:]
        for member in members where seen.insert(member.songID).inserted {
            let key = NormalizationCache.shared.key(for: member)
            // 没有歌手的判不到 confident，不必进桶。
            guard key.isMatchable, !key.artistTokens.isEmpty else { continue }
            buckets[key.coreTitle, default: []].append((member.songID, key))
        }
        var result: [String: String] = [:]
        for bucket in buckets.values where bucket.count > 1 {
            // 按 ID 排，结果与输入顺序无关。要和组里已有的每一首都对得上才进组：不做传递，
            // 免得 3:00 并 3:02、3:02 并 3:05，把差 5 秒的两首也连到一起。
            var clusters: [[(id: String, key: ExternalTrackMatchPolicy.Key)]] = []
            for entry in bucket.sorted(by: { $0.id < $1.id }) {
                if let index = clusters.firstIndex(where: { cluster in
                    cluster.allSatisfy { ExternalTrackMatchPolicy.verdict(entry.key, $0.key) == .confident }
                }) {
                    clusters[index].append(entry)
                } else {
                    clusters.append([entry])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                for entry in cluster { result[entry.id] = cluster[0].id }
            }
        }
        return result
    }

    /// 首页排行用的播放记录。歌名、歌手按记录里最近一次的写法（与榜单上显示的一致），记录里没写的
    /// 用曲库里的；时长记录里没有，用事件带的或曲库里的。
    public static func groupKeys(events: [HomeListeningEvent], songs: [String: Song]) -> [String: String] {
        groupKeys(plays: events.map {
            Play(songID: $0.songID, playedAt: $0.playedAt, title: $0.songTitle, artist: $0.artistName, duration: $0.songDuration)
        }, songs: songs)
    }

    /// 听歌回顾用的播放记录；时长从 `traits` 查。
    public static func groupKeys(
        events: [ListeningRecapEvent], traits: [String: ListeningRecapSongTraits]
    ) -> [String: String] {
        groupKeys(plays: events.map {
            Play(songID: $0.songID, playedAt: $0.playedAt, title: $0.title, artist: $0.artist,
                 duration: traits[$0.songID]?.duration)
        }, songs: [:])
    }

    struct Play {
        let songID: String
        let playedAt: Date
        let title: String?
        let artist: String?
        let duration: TimeInterval?
    }

    static func groupKeys(plays: [Play], songs: [String: Song]) -> [String: String] {
        var latest: [String: Play] = [:]
        for play in plays {
            if let known = latest[play.songID], known.playedAt >= play.playedAt { continue }
            latest[play.songID] = play
        }
        let members = latest.values.map { play -> Member in
            let song = songs[play.songID]
            let artists = nonEmpty(play.artist).map { [$0] } ?? song.map(ExternalTrackMatchPolicy.artists(of:)) ?? []
            return Member(
                songID: play.songID,
                title: nonEmpty(play.title) ?? song?.title ?? "",
                artists: artists,
                duration: play.duration ?? song?.duration
            )
        }
        return groupKeys(members)
    }

    /// 每首歌都要判两次，不走 Foundation 的 `trimmingCharacters`（几千首时它比分组本身还慢）。
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, value.contains(where: { !$0.isWhitespace }) else { return nil }
        return value
    }

    /// 歌名拆成主体与版本标记、歌手拆成名字，都只看字符串本身，拆一次却要几十微秒（繁简转换、
    /// 逐个版本词比对）。排行每次刷新都要对听过的几千首歌各做一遍，按字符串记下来，下次只算新出现的。
    private final class NormalizationCache: @unchecked Sendable {
        static let shared = NormalizationCache()
        private static let capacity = 20_000

        private struct TitleParts {
            let core: String
            let markers: Set<ExternalTrackMatchPolicy.VersionMarker>
        }

        private let lock = NSLock()
        private var titles: [String: TitleParts] = [:]
        private var artists: [String: [String]] = [:]

        func key(for member: Member) -> ExternalTrackMatchPolicy.Key {
            let title = titleParts(member.title)
            var tokens = Set<String>()
            for artist in member.artists { tokens.formUnion(artistTokens(artist)) }
            return ExternalTrackMatchPolicy.Key(
                coreTitle: title.core, versionMarkers: title.markers,
                artistTokens: tokens, duration: member.duration
            )
        }

        private func titleParts(_ title: String) -> TitleParts {
            lock.lock()
            let cached = titles[title]
            lock.unlock()
            if let cached { return cached }
            let (core, markers) = ExternalTrackMatchPolicy.splitTitle(title)
            let parts = TitleParts(core: core, markers: markers)
            lock.lock()
            if titles.count >= Self.capacity { titles.removeAll(keepingCapacity: true) }
            titles[title] = parts
            lock.unlock()
            return parts
        }

        private func artistTokens(_ artist: String) -> [String] {
            lock.lock()
            let cached = artists[artist]
            lock.unlock()
            if let cached { return cached }
            let tokens = ExternalTrackMatchPolicy.artistTokens(artist)
            lock.lock()
            if artists.count >= Self.capacity { artists.removeAll(keepingCapacity: true) }
            artists[artist] = tokens
            lock.unlock()
            return tokens
        }
    }
}

extension ExternalTrackMatchPolicy {
    /// 一首曲库里的歌拿哪些歌手去比：源给了多值歌手字段就用它，否则用歌手文本；都没有才退到专辑艺术家。
    public static func artists(of song: Song) -> [String] {
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
