import Foundation
import Testing
@testable import PrimuseKit

@Suite("Start listening shelf")
struct ListeningIntentShelfTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    /// 200 songs added yesterday: 80 jazz from the nineties, 60 pop, 40 rock, 20 untagged.
    private var library: [ListeningTestSong] {
        let added = now.addingTimeInterval(-86_400)
        var songs: [ListeningTestSong] = []
        for index in 0..<80 { songs.append(ListeningTestSong(id: "j\(index)", genre: "Jazz", year: 1994, dateAdded: added)) }
        for index in 0..<60 { songs.append(ListeningTestSong(id: "p\(index)", genre: "Pop", year: 2015, dateAdded: added)) }
        for index in 0..<40 { songs.append(ListeningTestSong(id: "r\(index)", genre: "Rock", year: 2003, dateAdded: added)) }
        for index in 0..<20 { songs.append(ListeningTestSong(id: "u\(index)", dateAdded: added)) }
        return songs
    }

    private func availability(_ songs: [ListeningTestSong]? = nil) throws -> ListeningIntentAvailability {
        try #require(ListeningIntentEngine.availability(
            songs: songs ?? library,
            intents: ListeningIntentShelfPolicy.builtInCatalog,
            history: .empty(now: now),
            libraryGeneration: 1
        ))
    }

    @Test("The first card resumes the music queue when there is one, otherwise plays anything")
    func leadCard() throws {
        let availability = try availability()
        let fresh = ListeningIntentShelfPolicy.row(
            availability: availability, configuration: .init(), resumeSongCount: nil
        )
        #expect(fresh.first?.intent == .builtIn(.anything))
        #expect(fresh.first?.role == .lead)
        #expect(fresh.first?.songCount == 200)

        let resuming = ListeningIntentShelfPolicy.row(
            availability: availability, configuration: .init(), resumeSongCount: 37
        )
        #expect(resuming.first?.intent == .builtIn(.resume))
        #expect(resuming.first?.songCount == 37)
        // "Anything" is still on the shelf, as the strongest suggestion.
        #expect(resuming.dropFirst().first?.intent == .builtIn(.anything))
        #expect(!fresh.dropFirst().contains { $0.intent == .builtIn(.anything) })
    }

    @Test("Suggestions follow lighting strength, skip dark and whole-library intents, and stop at ten")
    func suggestions() throws {
        let row = ListeningIntentShelfPolicy.row(
            availability: try availability(), configuration: .init(), resumeSongCount: nil
        )
        let ids = row.map(\.id)
        #expect(ids.count <= ListeningIntentShelfPolicy.rowLimit)
        // Jazz (80) before the nineties (80, later in the catalog) before pop (60) before rock (40).
        let jazz = try #require(ids.firstIndex(of: "builtin:jazz"))
        let nineties = try #require(ids.firstIndex(of: "builtin:nineties"))
        let pop = try #require(ids.firstIndex(of: "builtin:pop"))
        let rock = try #require(ids.firstIndex(of: "builtin:rock"))
        #expect(jazz < nineties && nineties < pop && pop < rock)
        // Everything was added at once: "newly added" is the whole library again.
        #expect(!ids.contains("builtin:newlyAdded"))
        // No history yet: "long unplayed" stays dark; no eighties songs at all.
        #expect(!ids.contains("builtin:longUnplayed"))
        #expect(!ids.contains("builtin:eighties"))
        #expect(!ids.contains("builtin:resume"))
        #expect(Set(ids).count == ids.count)

        var big: [ListeningTestSong] = []
        for (offset, genre) in ["Jazz", "Pop", "Rock", "Electronic", "Classical", "Folk", "Rap", "Ambient", "Soundtrack"].enumerated() {
            for index in 0..<30 {
                big.append(ListeningTestSong(id: "\(genre)\(index)", genre: genre, year: 1980 + offset * 4, duration: 200))
            }
        }
        let crowded = ListeningIntentShelfPolicy.row(
            availability: try availability(big), configuration: .init(), resumeSongCount: 5
        )
        #expect(crowded.count == ListeningIntentShelfPolicy.rowLimit)
    }

    @Test("Pins come right after the first card in the listener's order; hidden intents never show")
    func pinsAndHidden() throws {
        var configuration = ListeningIntentShelfConfiguration()
        configuration.setPinned(true, intentID: "builtin:rock")
        configuration.setPinned(true, intentID: "builtin:pop")
        configuration.setPinned(true, intentID: ListeningIntent.smartPlaylistIntentID("road"))
        configuration.setPinned(true, intentID: ListeningIntent.smartPlaylistIntentID("deleted"))
        configuration.setHidden(true, intentID: "builtin:jazz")
        let row = ListeningIntentShelfPolicy.row(
            availability: try availability(),
            configuration: configuration,
            resumeSongCount: nil,
            smartPlaylists: [ListeningIntent.smartPlaylistIntentID("road"): 14]
        )
        #expect(Array(row.map(\.id).prefix(4)) == ["builtin:anything", "builtin:rock", "builtin:pop", "smart:road"])
        #expect(row[1].role == .pinned && row[1].isPinned)
        #expect(row[3].intent.source == .smartPlaylist(id: "road"))
        #expect(row[3].songCount == 14)
        #expect(!row.contains { $0.id == "builtin:jazz" })
        #expect(!row.contains { $0.id == "smart:deleted" })
        #expect(Set(row.map(\.id)).count == row.count)
    }

    @Test("A pinned intent with no songs is left out; a pinned one below the lighting threshold still shows")
    func pinnedThreshold() throws {
        var songs = library
        for index in 0..<3 { songs.append(ListeningTestSong(id: "c\(index)", genre: "Classical")) }
        var configuration = ListeningIntentShelfConfiguration()
        configuration.setPinned(true, intentID: "builtin:classical")
        configuration.setPinned(true, intentID: "builtin:eighties")
        let row = ListeningIntentShelfPolicy.row(
            availability: try availability(songs), configuration: configuration, resumeSongCount: nil
        )
        #expect(row.contains { $0.id == "builtin:classical" && $0.songCount == 3 })
        #expect(!row.contains { $0.id == "builtin:eighties" })
    }

    @Test("No shelf without enough music or something to resume")
    func emptyShelf() throws {
        let tiny = (0..<5).map { ListeningTestSong(id: "s\($0)", genre: "Pop") }
        #expect(ListeningIntentShelfPolicy.row(
            availability: try availability(tiny), configuration: .init(), resumeSongCount: nil
        ).isEmpty)
        #expect(ListeningIntentShelfPolicy.row(
            availability: nil, configuration: .init(), resumeSongCount: nil
        ).isEmpty)
        // Before lighting is computed, a resumable queue still gets its card.
        let resumeOnly = ListeningIntentShelfPolicy.row(
            availability: nil, configuration: .init(), resumeSongCount: 8
        )
        #expect(resumeOnly.map(\.id) == ["builtin:resume"])
    }

    @Test("The page groups every built-in, pins first, and marks hidden and dark ones")
    func page() throws {
        var configuration = ListeningIntentShelfConfiguration()
        configuration.setPinned(true, intentID: "builtin:pop")
        configuration.setPinned(true, intentID: ListeningIntent.smartPlaylistIntentID("road"))
        configuration.setHidden(true, intentID: "builtin:rock")
        let sections = ListeningIntentShelfPolicy.page(
            availability: try availability(),
            configuration: configuration,
            smartPlaylists: [ListeningIntent.smartPlaylistIntentID("road"): 0]
        )
        #expect(sections.map(\.kind) == [.pinned, .genre, .era, .mood, .habit])
        #expect(sections[0].items.map(\.id) == ["builtin:pop", "smart:road"])
        #expect(sections[0].items[1].isLit == false)
        let genres = sections[1].items
        #expect(!genres.contains { $0.id == "builtin:pop" })
        #expect(genres.first { $0.id == "builtin:rock" }?.isHidden == true)
        #expect(genres.first { $0.id == "builtin:classical" }?.isLit == false)
        #expect(genres.first { $0.id == "builtin:jazz" }?.isLit == true)
        let all = sections.flatMap(\.items).map(\.id)
        #expect(Set(all).count == all.count)
        #expect(!all.contains("builtin:resume"))
        #expect(all.count == ListeningIntentShelfPolicy.builtInCatalog.count + 1)
        #expect(sections[1].titleKey == "listening_intent_group_genre")
    }

    @Test("Pinning, hiding and reordering keep the configuration consistent and survive a round trip")
    func configuration() {
        var configuration = ListeningIntentShelfConfiguration()
        configuration.setHidden(true, intentID: "builtin:jazz")
        configuration.setPinned(true, intentID: "builtin:jazz")
        #expect(configuration.isPinned("builtin:jazz") && !configuration.isHidden("builtin:jazz"))
        configuration.setPinned(true, intentID: "builtin:pop")
        configuration.setPinned(true, intentID: "builtin:rock")
        configuration.movePinned("builtin:rock", by: -5)
        #expect(configuration.pinnedIDs == ["builtin:rock", "builtin:jazz", "builtin:pop"])
        configuration.movePinned("builtin:rock", onto: "builtin:pop")
        #expect(configuration.pinnedIDs == ["builtin:jazz", "builtin:pop", "builtin:rock"])
        configuration.setHidden(true, intentID: "builtin:pop")
        #expect(configuration.pinnedIDs == ["builtin:jazz", "builtin:rock"])
        #expect(configuration.hiddenIDs == ["builtin:pop"])

        // A smart playlist only exists as a pin: hiding it removes it, nothing is remembered.
        let road = ListeningIntent.smartPlaylistIntentID("road")
        configuration.setPinned(true, intentID: road)
        #expect(configuration.pinnedSmartPlaylistIDs == ["road"])
        configuration.setHidden(true, intentID: road)
        #expect(!configuration.isPinned(road) && !configuration.isHidden(road))

        configuration.setPinned(true, intentID: road)
        configuration.setPinned(true, intentID: ListeningIntent.smartPlaylistIntentID("gone"))
        let pruned = configuration.pruneSmartPlaylists(keeping: ["road"])
        let prunedAgain = configuration.pruneSmartPlaylists(keeping: ["road"])
        #expect(pruned && !prunedAgain)
        #expect(configuration.pinnedSmartPlaylistIDs == ["road"])

        let decoded = ListeningIntentShelfConfiguration.decode(configuration.encoded())
        #expect(decoded == configuration)
        #expect(ListeningIntentShelfConfiguration.decode("") == ListeningIntentShelfConfiguration())
        #expect(ListeningIntentShelfConfiguration.decode("{not json") == ListeningIntentShelfConfiguration())
        let duplicated = ListeningIntentShelfConfiguration.decode(
            #"{"pinnedIDs":["a","a","b"],"hiddenIDs":["b","c","c"]}"#
        )
        #expect(duplicated.pinnedIDs == ["a", "b"])
        #expect(duplicated.hiddenIDs == ["c"])
        #expect(ListeningIntent.smartPlaylistID(fromIntentID: "smart:") == nil)
        #expect(ListeningIntent.smartPlaylistID(fromIntentID: "builtin:pop") == nil)
    }

    @Test("Smart playlist samples are bounded, unique and seed-stable")
    func sample() {
        let ids = (0..<300).map { "s\($0)" }
        let first = ListeningIntentShelfPolicy.sample(ids, limit: 50, seed: 7)
        #expect(first.count == 50)
        #expect(Set(first).count == 50)
        #expect(first == ListeningIntentShelfPolicy.sample(ids, limit: 50, seed: 7))
        #expect(first != ListeningIntentShelfPolicy.sample(ids, limit: 50, seed: 8))
        #expect(Set(ListeningIntentShelfPolicy.sample(Array(ids.prefix(10)), limit: 50, seed: 1)) == Set(ids.prefix(10)))
        #expect(ListeningIntentShelfPolicy.sample([], limit: 50, seed: 1).isEmpty)
    }

    @Test("Show songs lists matches in library order, bounded, with the full count")
    func matchingSongs() throws {
        let result = try #require(ListeningIntentEngine.matchingSongIDs(
            for: .builtIn(.rock), songs: library, history: .empty(now: now), limit: 10
        ))
        #expect(result.total == 40)
        #expect(result.ids == (0..<10).map { "r\($0)" })
        let resume = try #require(ListeningIntentEngine.matchingSongIDs(
            for: .builtIn(.resume), songs: library, history: .empty(now: now), limit: 10
        ))
        #expect(resume.total == 0)
        #expect(ListeningIntentEngine.matchingSongIDs(
            for: .builtIn(.pop), songs: library, history: .empty(now: now), limit: 10, isCancelled: { true }
        ) == nil)
    }

    @Test("The spread-out grid lists every lit intent once, the ten-card row included")
    func unboundedRow() throws {
        var big: [ListeningTestSong] = []
        for (offset, genre) in ["Jazz", "Pop", "Rock", "Electronic", "Classical", "Folk", "Rap", "Ambient", "Soundtrack"].enumerated() {
            for index in 0..<30 {
                big.append(ListeningTestSong(id: "\(genre)\(index)", genre: genre, year: 1980 + offset * 4, duration: 200))
            }
        }
        let lit = try availability(big)
        var configuration = ListeningIntentShelfConfiguration()
        configuration.setHidden(true, intentID: "builtin:jazz")
        let row = ListeningIntentShelfPolicy.row(availability: lit, configuration: configuration, resumeSongCount: 5)
        let all = ListeningIntentShelfPolicy.row(
            availability: lit, configuration: configuration, resumeSongCount: 5, limit: .max
        )
        #expect(row.count == ListeningIntentShelfPolicy.rowLimit)
        #expect(all.count > row.count)
        #expect(Array(all.prefix(row.count)) == row)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(!all.contains { $0.id == "builtin:jazz" })
        #expect(all.dropFirst().allSatisfy { lit.isLit($0.intent) })
    }

    @Test("Grid columns follow the width: two on a phone, more on wider screens, within bounds")
    func gridColumns() {
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 350, spacing: 8) == 2)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 390, spacing: 8) == 2)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 728, spacing: 8) == 4)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 804, spacing: 8) == 5)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 1_400, spacing: 8) == 6)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 200, spacing: 8) == 2)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: 0, spacing: 8) == 2)
        #expect(ListeningIntentShelfPolicy.gridColumns(width: .nan, spacing: 8) == 2)
    }

    @Test("The collapsed grid rounds the chosen count up to whole rows and never invents tiles")
    func collapsedGrid() {
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 6, columns: 2, available: 21) == 6)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 5, columns: 2, available: 21) == 6)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 6, columns: 4, available: 21) == 8)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 6, columns: 4, available: 7) == 7)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 0, columns: 2, available: 21) == 2)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 6, columns: 0, available: 21) == 6)
        #expect(ListeningIntentShelfPolicy.collapsedGridCount(limit: 6, columns: 2, available: 0) == 0)
    }
}
