import Foundation
import Testing
@testable import PrimuseKit

struct HomeListeningRankingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 9, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func song(_ id: String, artist: String = "Artist", album: String = "Album", path: String? = nil, source: String = "nas") -> Song {
        Song(id: id, title: id, albumTitle: album, artistName: artist, fileFormat: .mp3,
             filePath: path ?? "/Music/Pop/\(id).mp3", sourceID: source)
    }

    private func event(_ song: String, day: Int, month: Int = 9, seconds: Double = 180) -> HomeListeningEvent {
        HomeListeningEvent(songID: song, playedAt: date(day, month: month), listenedSeconds: seconds)
    }

    @Test func periodsUseCalendarBoundariesAndExcludeFutureEvents() {
        let events = [event("a", day: 30, month: 8), event("a", day: 31, month: 8), event("a", day: 1), event("a", day: 6)]
        let songs = ["a": song("a")]
        let week = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .week, category: .songs, now: date(5), calendar: calendar)
        let month = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .month, category: .songs, now: date(5), calendar: calendar)
        #expect(week.first?.playCount == 2)
        #expect(month.first?.playCount == 1)
    }

    @Test func comparisonsUsePreviousPeriodWithoutInventingRankForNewEntries() {
        let events = [event("a", day: 28, month: 8), event("a", day: 29, month: 8), event("b", day: 30, month: 8),
                      event("b", day: 1), event("b", day: 2), event("b", day: 3), event("c", day: 4), event("a", day: 4)]
        let songs = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, song($0)) })
        let ranks = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .week, category: .songs, now: date(5), calendar: calendar)
        #expect(ranks.first?.title == "b")
        #expect(ranks.first?.positionsGained == 1)
        #expect(ranks.first { $0.title == "c" }?.positionsGained == nil)
        let all = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .all, category: .songs, now: date(5), calendar: calendar)
        #expect(all.allSatisfy { $0.positionsGained == nil })
    }

    @Test func trendsSeparateClimbersFallersAndNewEntriesFromAnEmptyPreviousPeriod() {
        // 上周: a×2、b×1；本周: b×3、a×1、c×1。
        let events = [event("a", day: 28, month: 8), event("a", day: 29, month: 8), event("b", day: 30, month: 8),
                      event("b", day: 1), event("b", day: 2), event("b", day: 3), event("c", day: 4), event("a", day: 4)]
        let songs = Dictionary(uniqueKeysWithValues: ["a", "b", "c"].map { ($0, song($0)) })
        let ranks = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .week, category: .songs, now: date(5), calendar: calendar)
        let trends = Dictionary(uniqueKeysWithValues: ranks.map { ($0.title, $0.trend) })
        #expect(trends["b"] == .up(1))
        #expect(trends["a"] == .down(1))
        #expect(trends["c"] == .newEntry)

        // 上一个周期整段空白：谁都不算新上榜。
        let fresh = HomeListeningRanking.ranks(events: [event("a", day: 1), event("b", day: 2)], songs: songs, folders: nil,
                                               period: .week, category: .songs, now: date(5), calendar: calendar)
        #expect(fresh.count == 2)
        #expect(fresh.allSatisfy { $0.trend == nil })

        let all = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .all, category: .songs, now: date(5), calendar: calendar)
        #expect(all.allSatisfy { $0.trend == nil })

        let steady = HomeListeningRanking.ranks(events: [event("a", day: 28, month: 8), event("a", day: 1)], songs: songs, folders: nil,
                                                period: .week, category: .songs, now: date(5), calendar: calendar)
        #expect(steady.first?.trend == .steady)
    }

    @Test func artworkComesFromTheMostPlayedSongOfTheGroupRegardlessOfInputOrder() {
        let songs = Dictionary(uniqueKeysWithValues: ["a", "m", "z"].map { ($0, song($0, artist: "Band")) })
        // z 听得最多；a 与 m 并列，m 更近。
        let events = [event("a", day: 1), event("z", day: 1), event("z", day: 2), event("z", day: 3), event("m", day: 4)]
        for input in [events, Array(events.reversed())] {
            let artists = HomeListeningRanking.ranks(events: input, songs: songs, folders: nil, period: .all, category: .artists, now: date(5), calendar: calendar)
            #expect(artists.count == 1)
            #expect(artists.first?.songIDs == ["a", "m", "z"])
            #expect(artists.first?.artworkSongID == "z")
        }
        let tied = [event("a", day: 1), event("m", day: 4)]
        for input in [tied, Array(tied.reversed())] {
            let artists = HomeListeningRanking.ranks(events: input, songs: songs, folders: nil, period: .all, category: .artists, now: date(5), calendar: calendar)
            #expect(artists.first?.artworkSongID == "m")
        }
        let sameMoment = [event("m", day: 2), event("a", day: 2)]
        let artists = HomeListeningRanking.ranks(events: sameMoment, songs: songs, folders: nil, period: .all, category: .artists, now: date(5), calendar: calendar)
        #expect(artists.first?.artworkSongID == "a")
    }

    @Test func podiumPlacesTheChampionInTheMiddleAndShrinksWithFewerEntries() {
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: 0).isEmpty)
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: 1) == [0])
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: 2) == [1, 0])
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: 3) == [1, 0, 2])
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: 20) == [1, 0, 2])
        #expect(HomeListeningRankBoardPolicy.podiumOrder(count: -1).isEmpty)
        let champion = HomeListeningRankBoardPolicy.stepHeightFraction(place: 0)
        let second = HomeListeningRankBoardPolicy.stepHeightFraction(place: 1)
        let third = HomeListeningRankBoardPolicy.stepHeightFraction(place: 2)
        #expect(champion == 1)
        #expect(champion > second)
        #expect(second > third)
        #expect(third > 0)
    }

    @Test func boardShowsFiveUntilExpandedAndTheShelfNeverDropsBelowFive() {
        typealias Policy = HomeListeningRankBoardPolicy
        #expect(Policy.visibleCount(total: 30, expandedLimit: 20, isExpanded: false) == 5)
        #expect(Policy.visibleCount(total: 30, expandedLimit: 20, isExpanded: true) == 20)
        #expect(Policy.visibleCount(total: 12, expandedLimit: 20, isExpanded: true) == 12)
        #expect(Policy.visibleCount(total: 2, expandedLimit: 20, isExpanded: false) == 2)
        #expect(Policy.visibleCount(total: 0, expandedLimit: 20, isExpanded: true) == 0)
        // 设置调到 5 及以下：不提供展开，残留的展开状态也不能把榜单缩到 5 名以下。
        #expect(!Policy.offersExpansion(total: 30, expandedLimit: 5))
        #expect(!Policy.offersExpansion(total: 30, expandedLimit: 0))
        #expect(!Policy.offersExpansion(total: 5, expandedLimit: 20))
        #expect(Policy.offersExpansion(total: 6, expandedLimit: 6))
        #expect(Policy.visibleCount(total: 30, expandedLimit: 0, isExpanded: true) == 5)
        #expect(Policy.visibleCount(total: 30, expandedLimit: 3, isExpanded: true) == 5)

        #expect(Policy.shelfCount(total: 30, expandedLimit: 20) == 20)
        #expect(Policy.shelfCount(total: 30, expandedLimit: 0) == 5)
        #expect(Policy.shelfCount(total: 3, expandedLimit: 20) == 3)
        #expect(Policy.shelfCount(total: 0, expandedLimit: 20) == 0)
    }

    @Test func playShareIsRelativeToTheLeaderAndStaysInsideTheRow() {
        typealias Policy = HomeListeningRankBoardPolicy
        #expect(Policy.share(playCount: 10, leaderPlayCount: 10) == 1)
        #expect(Policy.share(playCount: 5, leaderPlayCount: 10) == 0.5)
        #expect(Policy.share(playCount: 12, leaderPlayCount: 10) == 1)
        #expect(Policy.share(playCount: 0, leaderPlayCount: 10) == 0)
        #expect(Policy.share(playCount: 3, leaderPlayCount: 0) == 0)
    }

    @Test func rankingOffersTheBoardAndTheShelfButNoStackedShelfRows() {
        #expect(HomeSectionLayoutPolicy.supportedStyles(for: .listeningRanking) == [.list, .carousel])
        #expect(HomeSectionLayoutPolicy.defaultStyle(for: .listeningRanking) == .list)
        #expect(HomeSectionLayoutPolicy.rowsRange(for: .listeningRanking, style: .carousel) == nil)
        #expect(HomeSectionLayoutPolicy.rowsRange(for: .recentlyAdded, style: .carousel) == 1...3)
        var configuration = HomeSectionLayoutConfiguration()
        configuration.advanceStyle(for: .listeningRanking)
        #expect(configuration.style(for: .listeningRanking) == .carousel)
        #expect(configuration.rowCount(for: .listeningRanking) == 1)
        configuration.advanceStyle(for: .listeningRanking)
        #expect(configuration.style(for: .listeningRanking) == .list)
        #expect(configuration.styles.isEmpty)
    }

    @Test func tiesAreStableRegardlessOfInputOrderAndAlbumKeysDoNotCollide() {
        let songs = ["a": song("a", artist: "b|c", album: "a"), "b": song("b", artist: "c", album: "a|b")]
        let events = [event("b", day: 1), event("a", day: 2)]
        let first = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .all, category: .albums, now: date(5), calendar: calendar)
        let reversed = HomeListeningRanking.ranks(events: events.reversed(), songs: songs, folders: nil, period: .all, category: .albums, now: date(5), calendar: calendar)
        #expect(first.count == 2)
        #expect(first.map(\.id) == reversed.map(\.id))
    }

    @Test func unavailableSongsRemainInHistoryAndEmptyArtistMetadataIsExcluded() {
        let songs = ["a": song("a", artist: "", album: "")]
        let events = [event("a", day: 1), event("removed", day: 2)]
        let songsRank = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .week, category: .songs, now: date(5), calendar: calendar)
        let artists = HomeListeningRanking.ranks(events: events, songs: songs, folders: nil, period: .week, category: .artists, now: date(5), calendar: calendar)
        #expect(songsRank.count == 2)
        #expect(artists.isEmpty)
    }

    @Test func historicalMetadataSurvivesLibraryChangesAndUsesLatestRecordedTitle() {
        let events = [
            HomeListeningEvent(songID: "a", playedAt: date(1), listenedSeconds: 90,
                               songTitle: "Old title", artistName: "Original artist", albumTitle: "Original album"),
            HomeListeningEvent(songID: "a", playedAt: date(2), listenedSeconds: 120,
                               songTitle: "Latest title", artistName: "Original artist", albumTitle: "Original album"),
            HomeListeningEvent(songID: "removed", playedAt: date(3), listenedSeconds: 180,
                               songTitle: "Archived song", artistName: "Original artist", albumTitle: "Original album")
        ]
        let currentSongs = ["a": song("a", artist: "Retagged artist", album: "Retagged album")]
        for category in [HomeListeningCategory.artists, .albums] {
            let current = HomeListeningRanking.ranks(events: events, songs: currentSongs, folders: nil,
                                                     period: .week, category: category, now: date(5), calendar: calendar)
            let historyOnly = HomeListeningRanking.ranks(events: events, songs: [:], folders: nil,
                                                         period: .week, category: category, now: date(5), calendar: calendar)
            #expect(current.count == 1)
            #expect(current.first?.playCount == 3)
            #expect(current.first?.listenedSeconds == 390)
            #expect(current.map(\.id) == historyOnly.map(\.id))
        }
        let ranks = HomeListeningRanking.ranks(events: events, songs: currentSongs, folders: nil,
                                               period: .week, category: .songs, now: date(5), calendar: calendar)
        #expect(ranks.first?.title == "Latest title")
        #expect(ranks.first?.playCount == 2)
    }

    @Test func weekBoundariesFollowRegionAndExplicitFirstWeekday() {
        let zone = TimeZone(identifier: "Asia/Shanghai")!
        for (locale, weekday, start) in [("zh_CN", 2, date(31, month: 8, hour: 0)),
                                         ("en_GB", 2, date(31, month: 8, hour: 0)),
                                         ("en_US", 1, date(6, hour: 0)),
                                         ("zh_Hans_US", 1, date(6, hour: 0)),
                                         ("zh_CN@fw=sun", 1, date(6, hour: 0))] {
            let regional = ListeningCalendar.make(locale: Locale(identifier: locale), timeZone: zone)
            #expect(regional.firstWeekday == weekday)
            #expect(HomeListeningPeriod.week.interval(now: date(6), calendar: regional).start == start)
        }
        let preferred = ListeningCalendar.make(locale: Locale(identifier: "zh_CN"), timeZone: zone, firstWeekday: 1)
        #expect(preferred.firstWeekday == 1)
    }

    @Test func directoryCountCanExceedThreeWithoutTruncatingStoredOrder() {
        let sources = (1...6).map {
            LibraryFolderSourceDescriptor(sourceID: "nas\($0)", displayName: "NAS \($0)", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: (1...6).map { song("song\($0)", source: "nas\($0)") })
        #expect(HomeFolderPinStorage.resolvedPins("", index: index, defaultCount: 3).count == 3)
        let six = HomeFolderPinStorage.resolvedPins("", index: index, defaultCount: 6)
        #expect(six.count == 6)
        let reordered = Array(six.reversed())
        let saved = HomeFolderPinStorage.encode(reordered)
        #expect(HomeFolderPinStorage.resolvedPins(saved, index: index, defaultCount: 1) == reordered)
        #expect(HomeFolderPinStorage.resolvedPins("[]", index: index, defaultCount: 6).isEmpty)
        #expect(HomeFolderPinStorage.displayCount(0) == 1)
        #expect(HomeFolderPinStorage.displayCount(100) == 30)
    }

    @Test func nestedFoldersCountEachPlayOnceAndKeepSourcesSeparate() throws {
        let songs = [song("a", path: "/Music/Pop/Live/a.mp3"), song("b", path: "/Music/Pop/Live/b.mp3", source: "other")]
        let sources = ["nas", "other"].map {
            LibraryFolderSourceDescriptor(sourceID: $0, displayName: "NAS", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        let ranks = HomeListeningRanking.ranks(events: [event("a", day: 1), event("b", day: 2)],
                                              songs: Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) }), folders: index,
                                              period: .all, category: .folders, now: date(5), calendar: calendar)
        #expect(ranks.count == 2)
        #expect(ranks.reduce(0) { $0 + $1.playCount } == 2)
        #expect(ranks.allSatisfy { $0.title == "Live" })
        #expect(Set(ranks.compactMap(\.folderID).map(\.sourceID)) == Set(["nas", "other"]))
    }

    @Test func folderPinsResolveLiveMembershipAfterRescanAndSourceRestoration() throws {
        let source = LibraryFolderSourceDescriptor(sourceID: "nas", displayName: "NAS", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        let first = LibraryFolderIndexBuilder.build(sources: [source], songs: [song("a")])
        let id = try #require(first.nodeID(containingSongID: "a"))
        let encoded = HomeFolderPinStorage.encode([id, id])
        let pins = HomeFolderPinStorage.decode(encoded)
        #expect(pins == [id])
        let rescanned = LibraryFolderIndexBuilder.build(sources: [source], songs: [song("a"), song("b")])
        #expect(Set(rescanned.songIDs(in: pins[0], scope: .descendants)) == Set(["a", "b"]))
        let disabled = LibraryFolderSourceDescriptor(sourceID: "nas", displayName: "NAS", scanRoots: ["/Music"], pathSemantics: .hierarchical, isEnabled: false)
        #expect(LibraryFolderIndexBuilder.build(sources: [disabled], songs: [song("a")]).node(withID: pins[0]) == nil)
        #expect(HomeFolderPinStorage.decode(encoded) == pins)
        #expect(rescanned.node(withID: pins[0]) != nil)
    }

    @Test func pinsRoundTripSpecialCharactersAndKeepAnExplicitEmptySelection() {
        let ids = [LibraryFolderNodeID(sourceID: "source:1", kind: .folder, normalizedRelativePath: "/音乐/a|b/\"Live\""),
                   LibraryFolderNodeID(sourceID: "source:2", kind: .folder, normalizedRelativePath: "/音乐/a|b/\"Live\"")]
        #expect(HomeFolderPinStorage.decode(HomeFolderPinStorage.encode(ids)) == ids)
        #expect(HomeFolderPinStorage.encode([]) == "[]")
        #expect(HomeFolderPinStorage.decode("invalid").isEmpty)
    }

    @Test func missingPinnedDirectoriesAreHiddenOnlyAfterAnIndexIsAvailable() throws {
        let source = LibraryFolderSourceDescriptor(sourceID: "nas", displayName: "NAS", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        let existing = LibraryFolderIndexBuilder.build(sources: [source], songs: [song("a", path: "/Music/Removed/a.mp3")])
        let id = try #require(existing.nodeID(containingSongID: "a"))
        let saved = HomeFolderPinStorage.encode([id])
        #expect(HomeFolderPinStorage.resolvedPins(saved, index: nil, defaultCount: 3) == [id])
        #expect(HomeFolderPinStorage.resolvedPins(saved, index: existing, defaultCount: 3) == [id])
        let rescanned = LibraryFolderIndexBuilder.build(sources: [source], songs: [])
        #expect(HomeFolderPinStorage.resolvedPins(saved, index: rescanned, defaultCount: 3).isEmpty)
        #expect(HomeFolderPinStorage.decode(saved) == [id])
    }

    @Test func editingVisiblePinsPreservesDisabledSourcesThroughRestoration() throws {
        let sources = ["a", "b", "c", "d"].map {
            LibraryFolderSourceDescriptor(sourceID: $0, displayName: $0, scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let songs = sources.map { song($0.sourceID, source: $0.sourceID) }
        let full = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        let ids = try sources.map { try #require(full.nodeID(containingSongID: $0.sourceID)) }
        let hidden = full.removingSource("a").removingSource("c")
        let saved = HomeFolderPinStorage.encode([ids[0], ids[1], ids[2]])
        #expect(HomeFolderPinStorage.resolvedPins(saved, index: hidden, defaultCount: 3) == [ids[1]])
        let added = HomeFolderPinStorage.replacingVisiblePins(in: saved, with: [ids[3], ids[1]], index: hidden)
        #expect(HomeFolderPinStorage.decode(added) == [ids[0], ids[3], ids[2], ids[1]])
        let reordered = HomeFolderPinStorage.replacingVisiblePins(in: added, with: [ids[1], ids[3]], index: hidden)
        #expect(HomeFolderPinStorage.decode(reordered) == [ids[0], ids[1], ids[2], ids[3]])
        let removed = HomeFolderPinStorage.replacingVisiblePins(in: reordered, with: [ids[3]], index: hidden)
        #expect(HomeFolderPinStorage.decode(removed) == [ids[0], ids[3], ids[2]])
        #expect(HomeFolderPinStorage.resolvedPins(removed, index: full, defaultCount: 3) == [ids[0], ids[3], ids[2]])
        let clearedVisible = HomeFolderPinStorage.replacingVisiblePins(in: removed, with: [], index: hidden)
        #expect(HomeFolderPinStorage.decode(clearedVisible) == [ids[0], ids[2]])
    }

    @Test func pinEditingKeepsExplicitEmptySelectionAndInitializesAllDefaultPins() {
        let sources = (1...6).map {
            LibraryFolderSourceDescriptor(sourceID: "nas\($0)", displayName: "NAS \($0)", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        }
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: (1...6).map { song("song\($0)", source: "nas\($0)") })
        let defaults = HomeFolderPinStorage.resolvedPins("", index: index, defaultCount: 6)
        #expect(defaults.map(\.kind) == Array(repeating: .source, count: 6))
        let edited = HomeFolderPinStorage.replacingVisiblePins(in: "", with: Array(defaults.reversed()), index: index, defaultCount: 6)
        #expect(HomeFolderPinStorage.decode(edited) == Array(defaults.reversed()))
        #expect(HomeFolderPinStorage.replacingVisiblePins(in: "", with: [], index: index, defaultCount: 6) == "[]")
        #expect(HomeFolderPinStorage.storedPins("[]", index: index, defaultCount: 6).isEmpty)
        #expect(HomeFolderPinStorage.resolvedPins(edited, index: nil, defaultCount: 3) == Array(defaults.reversed()))
    }
}
