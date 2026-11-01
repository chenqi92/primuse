import Foundation
import Testing
@testable import PrimuseKit

@Suite("Short song title shortcuts")
struct SiriSongCatalogTests {
    @Test func keepsDistinctRecordingsAndPrioritizesRecentSelections() {
        let songs = [song("a", "晨光"), song("b", "晨光"), song("c", "山海间"), song("long", "听见微风")]
        let selected = SiriSongCatalog.shortcuts(from: songs, priorityIDs: ["b", "b", "missing"], limit: 3)
        #expect(selected.map(\.id) == ["b", "a", "c"])
        #expect(SiriSongCatalog.shortcuts(from: songs, priorityIDs: ["b"], limit: 1).map(\.id) == ["b"])
    }

    @Test func reflectsRenamesAndRemovalInsteadOfRememberingTitles() {
        let before = SiriSongCatalog.shortcuts(from: [song("a", "晨光"), song("b", "山海间")], priorityIDs: [], limit: 10)
        let after = SiriSongCatalog.shortcuts(from: [song("a", "初晴")], priorityIDs: ["b"], limit: 10)
        #expect(before.count == 2)
        #expect(after.map(\.id) == ["a"])
        #expect(after.map(\.title) == ["初晴"])
    }

    @Test func excludesUnplayableEmptyAndUnsafeEntries() {
        var unplayable = song("empty", "晴天")
        unplayable.filePath = ""
        let selected = SiriSongCatalog.shortcuts(
            from: [song("blank", "  "), song("file:///private/song", "山海"), unplayable, song("good", " 山海 ")],
            priorityIDs: [], limit: 10
        )
        #expect(selected.map(\.id) == ["good"])
    }

    @Test func boundsLargeLibrariesAndUsesStableOrdering() {
        let songs = (0..<1_200).map { song(String(format: "%04d", $0), "初晴") }
        let selected = SiriSongCatalog.shortcuts(from: songs.reversed(), priorityIDs: ["1199"], limit: 80)
        #expect(selected.count == 80)
        #expect(selected.first?.id == "1199")
        #expect(selected.last?.id == "0078")
        #expect(SiriSongCatalog.shortcuts(from: songs, priorityIDs: [], limit: 0).isEmpty)
    }

    @Test func protectsTheSharedLocalizedPhraseBudget() {
        for names in 1...4 {
            for stations in [0, 10, 50] {
                let slots = SiriSongCatalog.shortcutLimit(appNameCount: names, settingsCount: 36, stationCount: stations, bookCount: 8, podcastCount: 8)
                let reserved = 5 + 18 + 32 + 36 + stations * 4 + 24 + 24
                #expect(slots >= 0)
                if reserved * names <= 1_000 {
                    #expect((slots + reserved) * names <= 1_000)
                    #expect((slots + reserved + 1) * names > 1_000)
                } else {
                    #expect(slots == 0)
                }
            }
        }
    }

    private func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, fileFormat: .mp3, filePath: "\(id).mp3", sourceID: "fixture", dateAdded: Date(timeIntervalSince1970: 0))
    }
}
