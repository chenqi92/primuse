import Foundation
import Testing
@testable import PrimuseKit

struct ListeningRecapTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func event(
        _ songID: String,
        artist: String = "Artist",
        album: String = "Album",
        at playedAt: Date,
        seconds: TimeInterval = 180
    ) -> ListeningRecapEvent {
        ListeningRecapEvent(
            songID: songID, title: "Song \(songID)", artist: artist, album: album,
            playedAt: playedAt, seconds: seconds
        )
    }

    private static func october() -> DateInterval {
        DateInterval(start: date(2026, 10, 1, 0), end: date(2026, 10, 31, 23, 59))
    }

    @Test func totalsCountOnlyTheInterval() {
        let events = [
            Self.event("a", artist: "Faye", album: "Eyes", at: Self.date(2026, 10, 2, 9)),
            Self.event("a", artist: "Faye", album: "Eyes", at: Self.date(2026, 10, 2, 21)),
            Self.event("b", artist: " faye ", album: "eyes", at: Self.date(2026, 10, 3, 10)),
            Self.event("c", artist: "Jay", album: "Fantasy", at: Self.date(2026, 10, 5, 10), seconds: 600),
            Self.event("d", artist: "Old", album: "Before", at: Self.date(2026, 9, 20, 10)),
        ]
        let recap = ListeningRecapBuilder.build(
            events: events,
            interval: Self.october(),
            previousInterval: DateInterval(start: Self.date(2026, 9, 1, 0), end: Self.date(2026, 10, 1, 0)),
            traits: [:],
            calendar: Self.calendar,
            referenceYear: 2026
        )
        #expect(recap.totals.plays == 4)
        #expect(recap.totals.seconds == 1_140)
        #expect(recap.totals.activeDays == 3)
        #expect(recap.totals.uniqueSongs == 3)
        #expect(recap.totals.uniqueArtists == 2)
        #expect(recap.totals.uniqueAlbums == 2)
        #expect(recap.previous == .init(plays: 1, seconds: 180))
        #expect(recap.previous?.secondsChange(to: recap.totals.seconds) == (1_140.0 - 180) / 180)
        #expect(recap.busiestDay?.date == Self.date(2026, 10, 5, 0))
        #expect(recap.personality == nil)
    }

    @Test func compilationCreditsDoNotCountAsArtists() {
        let events = [
            Self.event("a", artist: "群星", album: "Hits", at: Self.date(2026, 10, 2, 9)),
            Self.event("a", artist: "群星", album: "Hits", at: Self.date(2026, 10, 2, 10)),
            Self.event("a", artist: "群星", album: "Hits", at: Self.date(2026, 10, 2, 11)),
            Self.event("b", artist: "Various Artists", album: "Mix", at: Self.date(2026, 10, 3, 9)),
            Self.event("c", artist: "Faye", album: "Eyes", at: Self.date(2026, 10, 4, 9)),
        ]
        let recap = ListeningRecapBuilder.build(
            events: events,
            interval: Self.october(),
            previousInterval: nil,
            traits: [:],
            calendar: Self.calendar,
            referenceYear: 2026
        )
        #expect(recap.totals.uniqueArtists == 1)
        #expect(recap.totals.uniqueAlbums == 3)
        #expect(recap.topFiveArtistShare == 1)
    }

    @Test func emptyIntervalStillReportsThePreviousPeriod() {
        let recap = ListeningRecapBuilder.build(
            events: [Self.event("a", at: Self.date(2026, 9, 3))],
            interval: Self.october(),
            previousInterval: DateInterval(start: Self.date(2026, 9, 1, 0), end: Self.date(2026, 10, 1, 0)),
            traits: [:],
            calendar: Self.calendar,
            referenceYear: 2026
        )
        #expect(recap.isEmpty)
        #expect(recap.previous?.plays == 1)
        #expect(recap.previous?.secondsChange(to: 0) == -1)
        #expect(ListeningRecap.Comparison(plays: 0, seconds: 0).secondsChange(to: 100) == nil)
    }

    @Test func peakHourAndNightShareFollowListenedTime() {
        let events = [
            Self.event("a", at: Self.date(2026, 10, 2, 23, 10), seconds: 1_200),
            Self.event("b", at: Self.date(2026, 10, 3, 1, 0), seconds: 600),
            Self.event("c", at: Self.date(2026, 10, 3, 9, 0), seconds: 300),
            Self.event("d", at: Self.date(2026, 10, 3, 9, 30), seconds: 300),
        ]
        let recap = ListeningRecapBuilder.build(
            events: events, interval: Self.october(), previousInterval: nil,
            traits: [:], calendar: Self.calendar, referenceYear: 2026
        )
        #expect(recap.peakHour == 23)
        #expect(recap.peakDaypart == .lateNight)
        #expect(abs(recap.nightShare - 1_800.0 / 2_400) < 0.0001)
    }

    @Test func daypartBoundaries() {
        #expect(ListeningDaypart.of(hour: 4) == .lateNight)
        #expect(ListeningDaypart.of(hour: 5) == .dawn)
        #expect(ListeningDaypart.of(hour: 9) == .morning)
        #expect(ListeningDaypart.of(hour: 11) == .morning)
        #expect(ListeningDaypart.of(hour: 12) == .afternoon)
        #expect(ListeningDaypart.of(hour: 14) == .afternoon)
        #expect(ListeningDaypart.of(hour: 18) == .evening)
        #expect(ListeningDaypart.of(hour: 23) == .lateNight)
    }

    @Test func sessionsJoinPlaysWithinFiveMinutes() {
        let start = Self.date(2026, 10, 2, 20)
        let events = [
            Self.event("a", at: start, seconds: 200),
            Self.event("b", at: start.addingTimeInterval(200 + 299), seconds: 200),
            Self.event("c", at: start.addingTimeInterval(200 + 299 + 200 + 120), seconds: 200),
            // 间隔超过 5 分钟：另起一段
            Self.event("d", at: start.addingTimeInterval(5_000), seconds: 400),
        ]
        let session = ListeningRecapBuilder.longestSession(events)
        #expect(session?.songs == 3)
        #expect(session?.seconds == 600)
        #expect(session?.start == start)
    }

    @Test func longestStreakPrefersTheMostRecentTie() throws {
        let days: Set<Date> = [
            Self.date(2026, 10, 1, 0), Self.date(2026, 10, 2, 0),
            Self.date(2026, 10, 5, 0), Self.date(2026, 10, 6, 0),
            Self.date(2026, 10, 9, 0),
        ]
        let streak = try #require(ListeningRecapBuilder.longestStreak(days: days, calendar: Self.calendar))
        #expect(streak.days == 2)
        #expect(streak.start == Self.date(2026, 10, 5, 0))
    }

    @Test func discoveriesNeedHistoryBeforeTheInterval() {
        let inside = [
            Self.event("old", at: Self.date(2026, 10, 3)),
            Self.event("new", at: Self.date(2026, 10, 4)),
            Self.event("new", at: Self.date(2026, 10, 5)),
        ]
        let withoutEarlierHistory = ListeningRecapBuilder.build(
            events: inside, interval: Self.october(), previousInterval: nil,
            traits: [:], calendar: Self.calendar, referenceYear: 2026
        )
        #expect(withoutEarlierHistory.discoveries == nil)

        let withHistory = ListeningRecapBuilder.build(
            events: inside + [Self.event("old", at: Self.date(2026, 8, 3))],
            interval: Self.october(), previousInterval: nil,
            traits: [:], calendar: Self.calendar, referenceYear: 2026
        )
        #expect(withHistory.discoveries == 1)

        let allTime = ListeningRecapBuilder.build(
            events: inside, interval: nil, previousInterval: nil,
            traits: [:], calendar: Self.calendar, referenceYear: 2026
        )
        #expect(allTime.discoveries == nil)
    }

    @Test func genresAndPersonalityUseLibraryTraits() throws {
        var events: [ListeningRecapEvent] = []
        var traits: [String: ListeningRecapSongTraits] = [:]
        let genres = ["Rock", "Pop", "Jazz", "Folk", "Blues", "Soul", "rock "]
        for index in 0..<28 {
            let songID = "s\(index)"
            events.append(Self.event(songID, artist: "Artist \(index)", at: Self.date(2026, 10, 2, 22).addingTimeInterval(Double(index) * 600)))
            traits[songID] = .init(genre: genres[index % genres.count], year: 1995)
        }
        let recap = ListeningRecapBuilder.build(
            events: events, interval: Self.october(), previousInterval: nil,
            traits: traits, calendar: Self.calendar, referenceYear: 2026
        )
        #expect(recap.genreCount == 6)
        #expect(recap.topGenres.first?.name == "Rock")
        #expect(abs((recap.topGenres.first?.share ?? 0) - 8.0 / 28) < 0.0001)
        #expect(recap.medianReleaseYear == 1995)
        let personality = try #require(recap.personality)
        #expect(personality.exploration == .explorer)
        #expect(personality.diversity == .omnivore)
        #expect(personality.recency == .vintage)
        #expect(personality.dayCycle == .moon)
        #expect(personality.code == "EOVM")
    }

    @Test func personalityThresholdsMatchTheYearlyReport() {
        let loyal = ListeningPersonalityTraits.classify(
            topFiveArtistShare: 0.35, genreCount: 5, medianReleaseYear: 2021,
            referenceYear: 2026, nightShare: 0.55
        )
        #expect(loyal.code == "LFND")
        let unknownYears = ListeningPersonalityTraits.classify(
            topFiveArtistShare: 0.1, genreCount: 6, medianReleaseYear: nil,
            referenceYear: 2026, nightShare: 0.56
        )
        #expect(unknownYears.code == "EONM")
    }
}

struct ListeningMoodTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private static let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!

    private static func event(_ songID: String, daysAgo: Double, hour: Int = 15, seconds: TimeInterval = 200, artist: String = "A") -> ListeningRecapEvent {
        let day = calendar.startOfDay(for: now.addingTimeInterval(-daysAgo * 86_400))
        return ListeningRecapEvent(
            songID: songID, title: "T\(songID)", artist: artist, album: "Al",
            playedAt: day.addingTimeInterval(Double(hour) * 3_600), seconds: seconds
        )
    }

    @Test func signalsLookAtTheLastThirtyDays() {
        var events: [ListeningRecapEvent] = []
        for index in 0..<20 {
            events.append(Self.event("s\(index % 5)", daysAgo: Double(index), hour: 1, artist: index % 2 == 0 ? "Jay" : "Faye"))
        }
        events.append(Self.event("old", daysAgo: 45))
        let signals = ListeningMoodSignals.make(events: events, traits: [:], now: Self.now, calendar: Self.calendar)
        #expect(signals.plays == 20)
        #expect(signals.uniqueSongs == 5)
        #expect(signals.repeatShare == 0.75)
        #expect(signals.lateNightShare == 1)
        #expect(signals.peakDaypart == .lateNight)
        #expect(signals.changeFromPrevious != nil)
        #expect(signals.discoveryShare == 1)
        #expect(signals.topArtists.count == 2)
        #expect(signals.topSongs.count == 5)
        #expect(ListeningMoodArchetype.classify(signals) == .looping)
    }

    @Test func archetypesFollowTheirOrder() {
        var signals = ListeningMoodSignals()
        signals.plays = 30
        signals.uniqueSongs = 30
        signals.activeDays = 12
        signals.referenceYear = 2026
        #expect(ListeningMoodArchetype.classify(signals) == .steady)

        signals.medianReleaseYear = 2005
        #expect(ListeningMoodArchetype.classify(signals) == .nostalgic)

        signals.changeFromPrevious = -0.6
        #expect(ListeningMoodArchetype.classify(signals) == .quiet)

        signals.changeFromPrevious = 0.8
        #expect(ListeningMoodArchetype.classify(signals) == .surging)

        signals.averageSessionMinutes = 75
        #expect(ListeningMoodArchetype.classify(signals) == .immersed)

        signals.discoveryShare = 0.7
        #expect(ListeningMoodArchetype.classify(signals) == .exploring)

        signals.lateNightShare = 0.5
        #expect(ListeningMoodArchetype.classify(signals) == .nocturnal)

        signals.topSongShare = 0.2
        #expect(ListeningMoodArchetype.classify(signals) == .looping)
    }

    @Test func automaticRefreshIsRare() {
        let reading = ListeningMoodReading(
            title: "t", summary: "s", keywords: [], providerName: "p",
            generatedAt: Self.now.addingTimeInterval(-3 * 86_400), languageCode: "zh-Hans"
        )
        func should(
            _ reading: ListeningMoodReading?, attempt: Date? = nil, plays: Int = 40, newPlays: Int = 40,
            language: String = "zh-Hans", now: Date = Self.now
        ) -> Bool {
            ListeningMoodRefreshPolicy.shouldRefreshAutomatically(
                reading: reading, lastAttemptAt: attempt, windowPlays: plays,
                newPlaysSinceReading: newPlays, languageCode: language, now: now
            )
        }
        #expect(should(nil))
        #expect(!should(nil, plays: 9))
        #expect(!should(nil, attempt: Self.now.addingTimeInterval(-3_600)))
        #expect(should(nil, attempt: Self.now.addingTimeInterval(-7 * 3_600)))
        // 三天前刚解读过：不问
        #expect(!should(reading))
        // 一周以后、又听了足够多：再问
        #expect(should(reading, now: Self.now.addingTimeInterval(5 * 86_400)))
        #expect(!should(reading, newPlays: 14, now: Self.now.addingTimeInterval(5 * 86_400)))
        // 换了语言
        #expect(should(reading, language: "en"))
    }

    @Test func manualRefreshWaitsADay() {
        let generatedAt = Self.now.addingTimeInterval(-3_600)
        let reading = ListeningMoodReading(
            title: "t", summary: "s", keywords: [], providerName: "p",
            generatedAt: generatedAt, languageCode: "en"
        )
        #expect(ListeningMoodRefreshPolicy.nextManualRefresh(reading: nil, lastAttemptAt: nil, now: Self.now) == nil)
        #expect(ListeningMoodRefreshPolicy.nextManualRefresh(reading: reading, lastAttemptAt: nil, now: Self.now)
            == generatedAt.addingTimeInterval(86_400))
        #expect(ListeningMoodRefreshPolicy.nextManualRefresh(
            reading: reading, lastAttemptAt: nil, now: Self.now.addingTimeInterval(86_400)
        ) == nil)
        // 未来的时间（时钟回拨）不拦着
        let future = ListeningMoodReading(
            title: "t", summary: "s", keywords: [], providerName: "p",
            generatedAt: Self.now.addingTimeInterval(86_400), languageCode: "en"
        )
        #expect(ListeningMoodRefreshPolicy.nextManualRefresh(reading: future, lastAttemptAt: nil, now: Self.now) == nil)
    }

    @Test func requestNeedsEnoughPlaysAndClipsNames() throws {
        var signals = ListeningMoodSignals()
        signals.plays = 9
        #expect(ListeningMoodAIExchange.request(for: signals, languageCode: "zh-Hans") == nil)

        signals.plays = 40
        signals.topArtists = ["周杰伦", "周杰伦", " ", "A", "B", "C", "D", "E"]
        signals.topGenres = ["Pop", "pop", "Rock", "Jazz", "Folk"]
        signals.topSongs = [.init(title: String(repeating: "x", count: 300), artist: "Jay"), .init(title: " ", artist: "")]
        signals.peakDaypart = .lateNight
        signals.medianReleaseYear = 3000
        let request = try #require(ListeningMoodAIExchange.request(for: signals, languageCode: "zh-Hans"))
        #expect(request.topArtists == ["周杰伦", "A", "B", "C", "D"])
        #expect(request.topGenres == ["Pop", "Rock", "Jazz"])
        #expect(request.topSongs.count == 1)
        #expect(request.topSongs.first?.title.count == 160)
        #expect(request.medianReleaseYear == nil)
        let json = ListeningMoodAIExchange.payloadJSON(request) ?? ""
        #expect(json.contains("\"language_code\":\"zh-Hans\""))
        #expect(json.contains("\"peak_daypart\":\"late_night\""))
        #expect(json.contains("\"window_days\":30"))
    }

    @Test func answersAreValidated() throws {
        let answer = try ListeningMoodAIExchange.answer(from: """
        好的：{"title":"「深夜循环」","summary":"最近你总在深夜反复听几首歌。\\n\\n像是给一天收个尾。\\n第三段","keywords":["安静","安静","夜晚","专注","多余"]}
        """)
        #expect(answer.title == "深夜循环")
        #expect(answer.summary == "最近你总在深夜反复听几首歌。\n像是给一天收个尾。 第三段")
        #expect(answer.keywords == ["安静", "夜晚", "专注"])

        #expect(throws: ListeningMoodAIExchangeError.malformedResponse) {
            try ListeningMoodAIExchange.answer(from: "no json here")
        }
        #expect(throws: ListeningMoodAIExchangeError.malformedResponse) {
            try ListeningMoodAIExchange.validated(title: " ", summary: "x", keywords: [])
        }
        #expect(throws: ListeningMoodAIExchangeError.containsLink) {
            try ListeningMoodAIExchange.validated(title: "t", summary: "see https://x.y", keywords: [])
        }

        let long = try ListeningMoodAIExchange.validated(
            title: String(repeating: "长", count: 40),
            summary: String(repeating: "一句话。", count: 100),
            keywords: [String(repeating: "k", count: 17)]
        )
        #expect(long.title.count == ListeningMoodAIExchange.maximumTitleLength)
        #expect(long.summary.count <= ListeningMoodAIExchange.maximumSummaryLength)
        #expect(long.summary.hasSuffix("。"))
        #expect(long.keywords.isEmpty)
    }
}
