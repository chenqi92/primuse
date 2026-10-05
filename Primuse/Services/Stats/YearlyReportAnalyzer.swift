import Foundation
import PrimuseKit

/// 年度报告的数据：一年（今年就是一月一日到现在）的听歌回顾，加上报告自己的几个时刻和音乐源。
///
/// 总量、高峰时段、连听、风格、人格都走 Kit 里的 `ListeningRecapBuilder`，榜单走首页排行
/// 那一套，同一首歌、同一位艺人在哪里看到的数字都一样。
enum YearlyReportAnalyzer {
    /// 排行露出多少名（收起时更少）。
    static let rankingLimit = 20

    /// 播放记录里没有风格和年份，按 id 去曲库查（O(1)），只查记录里出现过的歌 ——
    /// 几十万首的库不必为了一份报告整库过一遍。
    @MainActor
    static func songTraits(for entries: [PlayHistoryStore.Entry], library: MusicLibrary) -> [String: ListeningRecapSongTraits] {
        var traits: [String: ListeningRecapSongTraits] = [:]
        for songID in Set(entries.map(\.songID)) {
            guard let song = library.song(id: songID) else { continue }
            traits[songID] = ListeningRecapSongTraits(genre: song.genre, year: song.year)
        }
        return traits
    }

    /// - Parameter music: 全部音乐播放记录，不只这一年：「这一年第一次听到」要往前看，
    ///   和去年同期比也要用到去年的记录。
    /// - Returns: 这一年还没开始时为 nil。
    nonisolated static func compute(
        year: Int,
        music: [PlayHistoryStore.Entry],
        traits: [String: ListeningRecapSongTraits],
        now: Date,
        calendar: Calendar
    ) -> YearlyReportData? {
        guard let interval = ListeningYearReportPolicy.interval(year: year, now: now, calendar: calendar) else { return nil }
        let events = music.map {
            ListeningRecapEvent(
                songID: $0.songID,
                title: $0.songTitle,
                artist: $0.artistName,
                album: $0.albumTitle,
                playedAt: $0.playedAt,
                seconds: $0.listenedSec.isFinite ? max(0, $0.listenedSec) : 0
            )
        }
        let recap = ListeningRecapBuilder.build(
            events: events,
            interval: interval,
            previousInterval: ListeningYearReportPolicy.comparisonInterval(for: interval, calendar: calendar),
            traits: traits,
            calendar: calendar,
            referenceYear: year
        )
        let scoped = music.filter { interval.contains($0.playedAt) }

        var sources: [String: (plays: Int, seconds: TimeInterval)] = [:]
        for entry in scoped {
            sources[entry.sourceID, default: (0, 0)].plays += 1
            sources[entry.sourceID, default: (0, 0)].seconds += entry.listenedSec.isFinite ? max(0, entry.listenedSec) : 0
        }

        return YearlyReportData(
            year: year,
            interval: interval,
            isInProgress: ListeningYearReportPolicy.isInProgress(interval, year: year, calendar: calendar),
            recap: recap,
            highlights: ListeningYearHighlights.build(events: events, interval: interval, calendar: calendar),
            songs: PlayHistoryStore.rankedItems(from: scoped, category: .songs, limit: rankingLimit),
            artists: PlayHistoryStore.rankedItems(from: scoped, category: .artists, limit: rankingLimit),
            albums: PlayHistoryStore.rankedItems(from: scoped, category: .albums, limit: rankingLimit),
            sources: sources
                .map { .init(sourceID: $0.key, plays: $0.value.plays, seconds: $0.value.seconds) }
                .sorted { $0.seconds > $1.seconds }
        )
    }

    /// 播放记录里每个音乐源 ID 该记到哪里（见 `ListeningSourceAttribution`）。删了又重建的源
    /// 按地址或账号认回去；没留下源信息的，拿它播过的歌名与歌手去曲库投票，要扫一遍曲库，
    /// 所以只在有这种源时才扫，放在后台跑。
    nonisolated static func attributeSources(
        music: [PlayHistoryStore.Entry],
        live: [MusicSource],
        deleted: [MusicSource],
        librarySongs: [Song]
    ) -> [String: ListeningSourceAttribution.Resolution] {
        let played = Set(music.map(\.sourceID))
        let liveIDs = Set(live.map(\.id))
        let tombstones = Dictionary(deleted.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let needsVote = played.filter { sourceID in
            !liveIDs.contains(sourceID)
                && tombstones[sourceID].flatMap { ListeningSourceAttribution.connectionMatch(for: $0, among: live) } == nil
        }
        var votes: [String: String] = [:]
        if !needsVote.isEmpty {
            // 每个要投票的源：播过的歌（歌曲 ID → 歌名加歌手的比对键）。
            var playedSongs: [String: [String: String]] = [:]
            for entry in music where needsVote.contains(entry.sourceID) {
                playedSongs[entry.sourceID, default: [:]][entry.songID] =
                    ListeningSourceAttribution.songKey(title: entry.songTitle, artist: entry.artistName) ?? ""
            }
            let wantedIDs = playedSongs.values.reduce(into: Set<String>()) { $0.formUnion($1.keys) }
            let wantedKeys = playedSongs.values.reduce(into: Set<String>()) { $0.formUnion($1.values) }
            // 歌还在曲库里（只是记录上的源 ID 变了）按歌曲 ID 认；源重建过、ID 全换了的按歌名加歌手认。
            var sourceBySongID: [String: String] = [:]
            var sourcesBySongKey: [String: Set<String>] = [:]
            for song in librarySongs where liveIDs.contains(song.sourceID) {
                if wantedIDs.contains(song.id) { sourceBySongID[song.id] = song.sourceID }
                if let key = ListeningSourceAttribution.songKey(title: song.title, artist: song.artistName),
                   wantedKeys.contains(key) {
                    sourcesBySongKey[key, default: []].insert(song.sourceID)
                }
            }
            for (sourceID, songs) in playedSongs {
                var librarySources: [String: Set<String>] = [:]
                for (songID, key) in songs {
                    if let source = sourceBySongID[songID] {
                        librarySources[songID] = [source]
                    } else if let sources = sourcesBySongKey[key] {
                        librarySources[songID] = sources
                    }
                }
                if let vote = ListeningSourceAttribution.songVote(played: Set(songs.keys), librarySources: librarySources) {
                    votes[sourceID] = vote
                }
            }
        }
        return ListeningSourceAttribution.resolve(
            playedSourceIDs: played,
            live: live,
            deleted: deleted,
            songVotes: votes
        )
    }

    /// 删除留下的源信息：「最近删除」里的，以及永久删除后删除台账里的墓碑。
    @MainActor
    static func deletedSources(in sourcesStore: SourcesStore) -> [MusicSource] {
        sourcesStore.recentlyDeletedSources + sourcesStore.sourceDeletionRecords.compactMap(\.tombstone)
    }

    /// 按归属把音乐源合并，写上名字和类别（分享图拍快照时不读环境也能显示对）。认回到现存源的
    /// 并进那个源；删了的写原来的名字并标上已删除，同名的并成一行；什么都没留下的并成一行
    /// 「已删除的音乐源」。
    @MainActor
    static func resolveSources(
        in data: inout YearlyReportData,
        attribution: [String: ListeningSourceAttribution.Resolution],
        sourcesStore: SourcesStore?
    ) {
        guard let sourcesStore else { return }
        let live = Dictionary(sourcesStore.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [String: YearlyReportData.SourceShare] = [:]
        for share in data.sources {
            let resolution = attribution[share.sourceID]
                ?? (live[share.sourceID] == nil ? .unknown : .live(share.sourceID))
            var resolved: YearlyReportData.SourceShare
            switch resolution {
            case .live(let sourceID):
                resolved = .init(sourceID: sourceID, plays: share.plays, seconds: share.seconds)
                if let source = live[sourceID] {
                    resolved.name = source.name
                    resolved.kind = .init(source.type)
                    resolved.isDeleted = false
                }
            case .deleted(let name, let type):
                resolved = .init(sourceID: "deleted:\(type.rawValue):\(name)", plays: share.plays, seconds: share.seconds)
                resolved.name = name
                resolved.kind = .init(type)
            case .unknown:
                resolved = .init(sourceID: "deleted", plays: share.plays, seconds: share.seconds)
            }
            if var existing = merged[resolved.sourceID] {
                existing.plays += resolved.plays
                existing.seconds += resolved.seconds
                merged[resolved.sourceID] = existing
            } else {
                merged[resolved.sourceID] = resolved
            }
        }
        data.sources = merged.values.sorted {
            $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.sourceID < $1.sourceID
        }
    }
}

// MARK: - Data model

struct YearlyReportData: Sendable, Identifiable {
    var id: Int { year }
    let year: Int
    /// 今年是一月一日到现在。
    let interval: DateInterval
    let isInProgress: Bool
    let recap: ListeningRecap
    let highlights: ListeningYearHighlights
    let songs: [PlayHistoryStore.RankedItem]
    let artists: [PlayHistoryStore.RankedItem]
    let albums: [PlayHistoryStore.RankedItem]
    var sources: [SourceShare]

    var isEmpty: Bool { recap.isEmpty }

    var personality: MusicPersonality? { recap.personality.map(MusicPersonality.init) }

    /// 听歌时长和去年比：今年还没过完时只比到去年的同一天。
    var growth: Double? {
        recap.previous?.secondsChange(to: recap.totals.seconds).flatMap { $0.isFinite ? $0 : nil }
    }

    struct SourceShare: Sendable, Identifiable {
        var id: String { sourceID }
        let sourceID: String
        var plays: Int
        var seconds: TimeInterval
        var name = String(localized: "yearly_source_deleted_unknown")
        var kind: Kind = .server
        /// 源已经不在了（认不回现存的源）。
        var isDeleted = true

        /// 报告里的三种来源插画。
        enum Kind: Sendable {
            case device, server, cloud

            init(_ type: MusicSourceType) {
                switch type {
                case .local, .appleMusicLibrary:
                    self = .device
                case .synology, .qnap, .ugreen, .fnos, .fnMusic, .daoliyu, .songloft, .synologyAudioStation,
                     .audiobookshelf, .smb, .webdav, .ftp, .sftp, .nfs, .upnp,
                     .jellyfin, .emby, .plex, .subsonic, .navidrome, .airsonic, .gonic:
                    self = .server
                case .baiduPan, .aliyunDrive, .oneDrive, .dropbox, .googleDrive, .drime, .pan115, .pan123,
                     .guangya, .s3, .appleMusic:
                    self = .cloud
                }
            }

            var artworkName: String {
                switch self {
                case .device: "decor_source_local"
                case .server: "decor_source_nas"
                case .cloud: "decor_source_cloud"
                }
            }

            var fallbackSymbol: String {
                switch self {
                case .device: "iphone"
                case .server: "externaldrive.fill"
                case .cloud: "icloud.fill"
                }
            }
        }
    }
}
