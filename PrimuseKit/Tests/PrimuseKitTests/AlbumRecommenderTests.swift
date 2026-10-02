import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album for the moment")
struct AlbumRecommenderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func album(
        _ id: String,
        artist: String,
        genre: String = "Pop",
        tracks: Int = 10,
        minutes: Double = 45,
        added: Date = Date(timeIntervalSince1970: 1_700_000_000),
        cue: Bool = false,
        title: String? = nil
    ) -> [ListeningTestSong] {
        (0..<tracks).map { track in
            ListeningTestSong(
                id: "\(id)-\(track)",
                albumID: id,
                albumTitle: title ?? "Album \(id)",
                artistName: artist,
                albumArtistName: artist,
                genre: genre,
                year: 2001,
                duration: minutes * 60 / Double(tracks),
                dateAdded: added,
                trackNumber: track + 1,
                cueSheetPath: cue ? "/\(id).cue" : nil,
                coverArtFileName: track == 0 ? nil : "\(id).jpg"
            )
        }
    }

    // MARK: Moment

    @Test("The situation follows the clock and the day of the week")
    func situations() {
        // 2026-10-02 is a Friday, 2026-10-03 a Saturday.
        let cases: [(Date, ListeningSituation)] = [
            (date(2026, 10, 2, 3), .lateNight),
            (date(2026, 10, 2, 6), .morning),
            (date(2026, 10, 2, 8), .commute),
            (date(2026, 10, 2, 14), .workday),
            (date(2026, 10, 2, 18), .commute),
            (date(2026, 10, 2, 20), .tonight),
            (date(2026, 10, 2, 23), .bedtime),
            (date(2026, 10, 3, 8), .morning),
            (date(2026, 10, 3, 15), .weekendAfternoon),
            (date(2026, 10, 3, 19), .tonight),
        ]
        for (now, expected) in cases {
            let moment = ListeningMoment.resolve(at: now, calendar: calendar, observesLunarFestivals: false)
            #expect(moment.situation == expected, "\(now)")
            #expect(moment.validUntil > now)
        }
        #expect(ListeningMoment.resolve(at: date(2026, 10, 3, 15), calendar: calendar).isWeekend)
    }

    @Test("A moment lasts until the next situation starts")
    func validity() {
        let moment = ListeningMoment.resolve(at: date(2026, 10, 2, 20, 15), calendar: calendar)
        #expect(moment.validUntil == date(2026, 10, 2, 22))
        let late = ListeningMoment.resolve(at: date(2026, 10, 2, 23, 30), calendar: calendar)
        #expect(late.validUntil == date(2026, 10, 3, 0))
        #expect(moment.dayStamp == 20261002)
        #expect(moment.titleKey == "album_pick_title_tonight")
    }

    @Test("Holidays name the day, lunar ones only when observed")
    func holidays() {
        #expect(ListeningMoment.holiday(on: date(2026, 12, 25, 12), calendar: calendar, observesLunarFestivals: false) == .christmas)
        #expect(ListeningMoment.holiday(on: date(2027, 1, 1, 12), calendar: calendar, observesLunarFestivals: false) == .newYear)
        // Mid-Autumn 2026 falls on 25 September; Spring Festival 2027 on 6 February.
        #expect(ListeningMoment.holiday(on: date(2026, 9, 25, 12), calendar: calendar, observesLunarFestivals: true) == .midAutumn)
        #expect(ListeningMoment.holiday(on: date(2026, 9, 25, 12), calendar: calendar, observesLunarFestivals: false) == nil)
        #expect(ListeningMoment.holiday(on: date(2027, 2, 6, 12), calendar: calendar, observesLunarFestivals: true) == .springFestival)
        #expect(ListeningMoment.holiday(on: date(2027, 2, 5, 12), calendar: calendar, observesLunarFestivals: true) == .springFestival)
        #expect(ListeningMoment.holiday(on: date(2026, 10, 2, 12), calendar: calendar, observesLunarFestivals: true) == nil)
        let christmasNight = ListeningMoment.resolve(at: date(2026, 12, 25, 23), calendar: calendar)
        #expect(christmasNight.titleKey == "album_pick_title_bedtime")
        let christmasDay = ListeningMoment.resolve(at: date(2026, 12, 25, 15), calendar: calendar)
        #expect(christmasDay.titleKey == "album_pick_title_holiday_christmas")
    }

    // MARK: Candidates

    @Test("Only complete albums are candidates; a CUE image counts from two tracks")
    func candidates() throws {
        var songs = album("full", artist: "A", tracks: 8)
        songs += album("short", artist: "B", tracks: 3)
        songs += album("cue", artist: "C", tracks: 2, cue: true)
        songs.append(ListeningTestSong(id: "loose", albumID: nil, albumTitle: nil))
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        #expect(Set(index.candidates.map(\.albumID)) == ["full", "cue"])
        let full = try #require(index.candidates.first { $0.albumID == "full" })
        #expect(full.trackCount == 8)
        #expect(full.artworkSongID == "full-1")
        #expect(abs(full.totalDuration - 45 * 60) < 0.001)
        #expect(full.families == [.pop])
        #expect(index.candidates.first { $0.albumID == "cue" }?.isCueAlbum == true)
    }

    // MARK: Picks

    @Test("Artists the listener plays come first, an album played through lately is skipped")
    func affinity() throws {
        let now = date(2026, 10, 2, 20)
        var songs = album("fav-1", artist: "Faye", genre: "Jazz")
        songs += album("fav-2", artist: "Faye", genre: "Jazz")
        songs += album("other", artist: "Nobody", genre: "Jazz")
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        // fav-1 played through two days ago; fav-2 never.
        var events = (0..<8).map {
            AlbumListeningEvent(songID: "fav-1-\($0)", albumID: "fav-1", artistName: "Faye", playedAt: now.addingTimeInterval(-2 * 86_400))
        }
        events.append(AlbumListeningEvent(songID: "x", albumID: nil, artistName: "Faye", playedAt: now.addingTimeInterval(-86_400)))
        let context = AlbumRecommendationContext(
            moment: ListeningMoment.resolve(at: now, calendar: calendar),
            now: now,
            events: events
        )
        let set = AlbumRecommender.recommend(index: index, context: context)
        #expect(set.picks.first?.albumID == "fav-2")
        #expect(set.picks.last?.albumID == "fav-1")
        #expect(set.picks.first?.reason == .artistPlayedThisWeek(artist: "Faye", count: 9))
    }

    @Test("There is always a pick, even with no history")
    func coldStart() throws {
        let now = date(2026, 10, 2, 23)
        var songs = album("rock", artist: "R", genre: "Metal")
        songs += album("calm", artist: "C", genre: "Ambient")
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let context = AlbumRecommendationContext(
            moment: ListeningMoment.resolve(at: now, calendar: calendar),
            now: now,
            events: []
        )
        let picks = AlbumRecommender.recommend(index: index, context: context).picks
        #expect(picks.count == 2)
        // Bedtime leans to quiet albums.
        #expect(picks.first?.albumID == "calm")
        #expect(picks.first?.reason == .fitsMoment(.bedtime))
    }

    @Test("Dismissed albums never come back; liked ones say so")
    func dismissedAndLiked() throws {
        let now = date(2026, 10, 3, 15)
        var songs = album("a", artist: "A")
        songs += album("b", artist: "B")
        songs += album("c", artist: "C")
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let context = AlbumRecommendationContext(
            moment: ListeningMoment.resolve(at: now, calendar: calendar),
            now: now,
            events: [],
            likedAlbumIDs: ["c"],
            dismissedAlbumIDs: ["a"]
        )
        let picks = AlbumRecommender.recommend(index: index, context: context).picks
        #expect(!picks.contains { $0.albumID == "a" })
        #expect(picks.first?.albumID == "c")
        #expect(picks.first?.reason == .likedAlbum)
    }

    @Test("Picks hold still through a moment and spread across artists")
    func stableAndDiverse() throws {
        var songs: [ListeningTestSong] = []
        for index in 0..<10 { songs += album("same-\(index)", artist: "Same") }
        for index in 0..<10 { songs += album("solo-\(index)", artist: "Artist \(index)") }
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let at8pm = date(2026, 10, 2, 20)
        let at9pm = date(2026, 10, 2, 21, 30)
        func picks(_ now: Date) -> [String] {
            AlbumRecommender.recommend(
                index: index,
                context: AlbumRecommendationContext(
                    moment: ListeningMoment.resolve(at: now, calendar: calendar),
                    now: now,
                    events: []
                )
            ).picks.map(\.albumID)
        }
        let first = picks(at8pm)
        #expect(first.count == AlbumRecommender.pickCount)
        #expect(first == picks(at9pm))
        #expect(first.filter { $0.hasPrefix("same-") }.count <= 1)
    }

    @Test("A holiday album rises on its day")
    func holidayBoost() throws {
        let now = date(2026, 12, 25, 15)
        var songs = album("xmas", artist: "Choir", genre: "Pop", title: "A Very Merry Christmas")
        for index in 0..<8 { songs += album("other-\(index)", artist: "Other \(index)", genre: "Jazz") }
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let context = AlbumRecommendationContext(
            moment: ListeningMoment.resolve(at: now, calendar: calendar),
            now: now,
            events: []
        )
        let picks = AlbumRecommender.recommend(index: index, context: context).picks
        #expect(picks.first?.albumID == "xmas")
        #expect(picks.first?.reason == .holiday(.christmas))
    }

    @Test("What was playing the last few hours tilts the pick")
    func recentVibe() throws {
        let now = date(2026, 10, 2, 14)
        var songs: [ListeningTestSong] = []
        for index in 0..<5 { songs += album("jazz-\(index)", artist: "J\(index)", genre: "Jazz") }
        songs += album("pop", artist: "P", genre: "Pop")
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let events = (0..<4).map { offset in
            AlbumListeningEvent(
                songID: "jazz-\(offset)-0", albumID: "jazz-\(offset)", artistName: nil,
                playedAt: now.addingTimeInterval(-Double(offset + 1) * 600)
            )
        }
        let picks = AlbumRecommender.rankedCandidates(
            index: index,
            context: AlbumRecommendationContext(
                moment: ListeningMoment.resolve(at: now, calendar: calendar),
                now: now,
                events: events
            ),
            limit: 5
        )
        #expect(picks.count == 5)
        // The four just played sit out a few days; the fifth jazz album wins.
        #expect(picks.first?.albumID == "jazz-4")
        #expect(picks.first?.reason == .recentVibe(.jazz))
    }

    @Test("A longer ranked list starts with the moment's picks, so the home row can take the rest")
    func rankedListExtendsPicks() throws {
        let now = date(2026, 10, 2, 20)
        var songs: [ListeningTestSong] = []
        // Fewer artists than picks: the fill-up order must match too.
        for index in 0..<12 { songs += album("al-\(index)", artist: "Artist \(index % 4)") }
        let index = try #require(AlbumCandidateIndex.build(songs: songs, libraryGeneration: 1))
        let context = AlbumRecommendationContext(
            moment: ListeningMoment.resolve(at: now, calendar: calendar),
            now: now,
            events: []
        )
        let picks = AlbumRecommender.recommend(index: index, context: context).picks.map(\.albumID)
        let ranked = AlbumRecommender.rankedCandidates(
            index: index,
            context: context,
            limit: AlbumRecommender.pickCount + 12
        ).map(\.albumID)
        #expect(Array(ranked.prefix(AlbumRecommender.pickCount)) == picks)
        #expect(Set(ranked).count == ranked.count)
        #expect(ranked.count == 12)
    }
}
