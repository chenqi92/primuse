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

    /// 把音乐源的名字和类别写进数据里，分享图拍快照时不读环境也能显示对。
    @MainActor
    static func resolveSources(in data: inout YearlyReportData, sourcesStore: SourcesStore?) {
        guard let sourcesStore else { return }
        let lookup = Dictionary(
            sourcesStore.allSources.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        data.sources = data.sources.map { share in
            var resolved = share
            if let source = lookup[share.sourceID] {
                resolved.name = source.name
                resolved.kind = YearlyReportData.SourceShare.Kind(source.type)
            }
            return resolved
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
        let plays: Int
        let seconds: TimeInterval
        var name = String(localized: "yearly_unknown_source")
        var kind: Kind = .device

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
