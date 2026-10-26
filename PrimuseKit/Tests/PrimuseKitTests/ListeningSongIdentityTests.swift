import Foundation
import Testing
@testable import PrimuseKit

struct ListeningSongIdentityTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func song(_ id: String, title: String, artist: String, duration: TimeInterval, source: String) -> Song {
        Song(id: id, title: title, albumTitle: "Album", artistName: artist, duration: duration, fileFormat: .flac,
             filePath: "/Music/\(id).flac", sourceID: source)
    }

    private func play(_ id: String, _ title: String, _ artist: String, day: Int, month: Int = 9) -> HomeListeningEvent {
        HomeListeningEvent(songID: id, playedAt: date(day, month: month), listenedSeconds: 200,
                           songTitle: title, artistName: artist, albumTitle: "Album")
    }

    private func member(_ id: String, _ title: String, _ artist: String, _ duration: TimeInterval?) -> ListeningSongIdentity.Member {
        .init(songID: id, title: title, artists: [artist], duration: duration)
    }

    @Test func sameSongOnTwoSourcesIsOneRankWithBothCopies() {
        // 网盘那份是繁体标签、带附注，NAS 那份是简体，时长差 1 秒。
        let songs = [
            "cloud": song("cloud", title: "雨季開始了 (電視劇插曲)", artist: "張芯瑜", duration: 245, source: "baidu"),
            "nas": song("nas", title: "雨季开始了", artist: "张芯瑜", duration: 246, source: "nas"),
            "other": song("other", title: "阿诗玛", artist: "朱婧汐", duration: 240, source: "nas"),
        ]
        let events = [
            play("cloud", "雨季開始了 (電視劇插曲)", "張芯瑜", day: 1),
            play("nas", "雨季开始了", "张芯瑜", day: 2), play("nas", "雨季开始了", "张芯瑜", day: 3),
            play("other", "阿诗玛", "朱婧汐", day: 2), play("other", "阿诗玛", "朱婧汐", day: 3),
        ]
        for input in [events, Array(events.reversed())] {
            let ranks = HomeListeningRanking.ranks(events: input, songs: songs, folders: nil, period: .all,
                                                   category: .songs, now: date(5), calendar: calendar)
            #expect(ranks.count == 2)
            #expect(ranks.first?.title == "雨季开始了")
            #expect(ranks.first?.playCount == 3)
            #expect(ranks.first?.listenedSeconds == 600)
            #expect(ranks.first?.songGroups == [["nas", "cloud"]])
            #expect(ranks.first?.songIDs == ["cloud", "nas"])
            #expect(ranks.first?.artworkSongID == "nas")
        }
    }

    @Test func versionsArtistsAndLengthsKeepSongsApart() {
        let keys = ListeningSongIdentity.groupKeys([
            member("studio", "Hello", "Adele", 295),
            member("live", "Hello (Live)", "Adele", 296),
            member("cover", "Hello", "Someone Else", 295),
            member("edit", "Hello", "Adele", 240),
            member("near", "Hello", "Adele", 302),
            member("anonymous", "Hello", "", 295),
        ])
        // 时长差 7 秒算「可能是」，不并；差 55 秒直接否决；没有歌手的只剩歌名，也不并。
        #expect(keys.isEmpty)
    }

    @Test func missingLengthsFallBackToTitleAndArtist() {
        let keys = ListeningSongIdentity.groupKeys([
            member("b", "Hello", "Adele", nil),
            member("a", "Hello", "Adele / Somebody", 295),
        ])
        #expect(keys == ["a": "a", "b": "a"])
    }

    @Test func groupsDoNotChainThroughAMiddleCopy() {
        // a 与 b 差 2.5 秒、b 与 c 差 2.5 秒，但 a 与 c 差 5 秒：c 不能借 b 连进来。
        let keys = ListeningSongIdentity.groupKeys([
            member("c", "Song", "Band", 185),
            member("b", "Song", "Band", 182.5),
            member("a", "Song", "Band", 180),
        ])
        #expect(keys == ["a": "a", "b": "a"])
    }

    @Test func libraryLengthsSeparateVersionsThatHistoryAloneWouldMerge() {
        let events = [play("album", "Song (Extended Mix)", "Band", day: 1), play("single", "Song", "Band", day: 2)]
        let songs = [
            "album": song("album", title: "Song (Extended Mix)", artist: "Band", duration: 420, source: "nas"),
            "single": song("single", title: "Song", artist: "Band", duration: 210, source: "nas"),
        ]
        let withLibrary = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .all,
                                                     category: .songs, now: date(5), calendar: calendar)
        let historyOnly = HomeListeningRanking.ranks(events: events, songs: [:], folders: nil, period: .all,
                                                     category: .songs, now: date(5), calendar: calendar)
        #expect(withLibrary.count == 2)
        #expect(historyOnly.count == 1)
        // 调用方从曲库查到长度带在事件上，与传 `songs` 效果一样。
        let carried = events.map {
            HomeListeningEvent(songID: $0.songID, playedAt: $0.playedAt, listenedSeconds: $0.listenedSeconds,
                               songTitle: $0.songTitle, artistName: $0.artistName, albumTitle: $0.albumTitle,
                               songDuration: songs[$0.songID]?.duration)
        }
        #expect(HomeListeningRanking.ranks(events: carried, songs: [:], folders: nil, period: .all,
                                           category: .songs, now: date(5), calendar: calendar).count == 2)
    }

    @Test func movingToAnotherSourceKeepsTheSongsRankAcrossPeriods() {
        // 上周在网盘听了两次 x、一次 y；本周（8 月 31 日起）换到 NAS 那份听了一次 x，另有两次 y。
        let events = [
            play("x-cloud", "X", "Band", day: 28, month: 8), play("x-cloud", "X", "Band", day: 29, month: 8),
            play("y", "Y", "Band", day: 30, month: 8),
            play("y", "Y", "Band", day: 1), play("y", "Y", "Band", day: 2), play("x-nas", "X", "Band", day: 3),
        ]
        let ranks = HomeListeningRanking.ranks(events: events, songs: [:], folders: nil, period: .week,
                                               category: .songs, now: date(5), calendar: calendar)
        let x = ranks.first { $0.title == "X" }
        #expect(x?.positionsGained == -1)
        #expect(x?.isNewEntry == false)
        #expect(x?.songGroups == [["x-nas"]])
    }

    @Test func artistsListEachSongOncePreferringACopyStillAvailable() {
        let events = [
            play("x-cloud", "X", "Band", day: 1), play("x-cloud", "X", "Band", day: 2),
            play("x-nas", "X", "Band", day: 3), play("y", "Y", "Band", day: 3),
        ]
        let ranks = HomeListeningRanking.ranks(events: events, songs: [:], folders: nil, period: .all,
                                               category: .artists, now: date(5), calendar: calendar)
        #expect(ranks.count == 1)
        #expect(ranks.first?.songGroups == [["x-cloud", "x-nas"], ["y"]])
        let available = ranks.first?.distinctSongIDs(preferring: { $0 != "x-cloud" })
        #expect(available == ["x-nas", "y"])
        // 都不可用时仍给听得最多的那份，个数不变。
        let unavailable = ranks.first?.distinctSongIDs(preferring: { _ in false })
        #expect(unavailable == ["x-cloud", "y"])
    }

    @Test func recapCountsACopyOnAnotherSourceAsTheSameSong() {
        let interval = DateInterval(start: date(1, month: 10), end: date(31, month: 10))
        func event(_ id: String, _ title: String, day: Int, month: Int) -> ListeningRecapEvent {
            ListeningRecapEvent(songID: id, title: title, artist: "Band", album: "Album",
                                playedAt: date(day, month: month), seconds: 200)
        }
        let events = [
            event("x-cloud", "X", day: 20, month: 9),
            event("x-nas", "X", day: 2, month: 10), event("x-cloud", "X", day: 3, month: 10),
            event("y", "Y", day: 4, month: 10),
        ]
        let recap = ListeningRecapBuilder.build(events: events, interval: interval, previousInterval: nil,
                                                traits: [:], calendar: calendar, referenceYear: 2026)
        #expect(recap.totals.uniqueSongs == 2)
        // X 九月就在网盘那份听过，十月换到 NAS 那份不算第一次听到。
        #expect(recap.discoveries == 1)

        let apart = ListeningRecapBuilder.build(
            events: events, interval: interval, previousInterval: nil,
            traits: ["x-cloud": .init(duration: 200), "x-nas": .init(duration: 260)],
            calendar: calendar, referenceYear: 2026
        )
        #expect(apart.totals.uniqueSongs == 3)
    }
}
