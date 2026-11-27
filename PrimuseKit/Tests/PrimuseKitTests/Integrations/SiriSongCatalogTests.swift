import Foundation
import Testing
@testable import PrimuseKit

@Suite("Short song title shortcuts")
struct SiriSongCatalogTests {
    @Test func cancelledCatalogDoesNotReturnPartialSuggestions() async {
        let input = (0..<1_200).map { song("cancelled-\($0)", "初晴") }
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return SiriSongCatalog.shortcuts(from: input, priorityIDs: [], limit: 80)
        }.value
        #expect(result.isEmpty)
    }

    @Test func boundedSelectionPreservesNewestDuplicateAndPriorityOrder() {
        var newest = song("duplicate", "清晨")
        newest.dateAdded = Date(timeIntervalSince1970: 30)
        var older = song("older", "晚霞")
        older.dateAdded = Date(timeIntervalSince1970: 20)
        let input = [song("duplicate", "山海"), older, song("priority", " 微风\n"), newest]
        let selected = SiriSongCatalog.shortcuts(from: input, priorityIDs: ["priority", "priority"], limit: 2)
        #expect(selected.map(\.id) == ["priority", "duplicate"])
        #expect(selected.last?.title == "清晨")
    }

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

    /// 流式那一版(只留够格的优先歌和最新的 `limit` 首)与原来先建整库 id 表、再有界挑选的结果相同。
    @Test(arguments: [1, 2, 3, 4, 5] as [UInt64])
    func streamingSelectionMatchesTheWholeLibraryAlgorithm(seed: UInt64) {
        var state = seed
        func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upperBound))
        }
        let titles = ["初晴", "晴天", "海", "山海间", "不能再作为短歌名", "Hi", "Love Story", "  ", "夜曲"]
        for round in 0..<40 {
            let songs: [Song] = (0..<(20 + next(300))).map { index in
                var value = song("s\(seed)-\(round)-\(index)", titles[next(titles.count)])
                value.dateAdded = Date(timeIntervalSince1970: TimeInterval(next(12)))
                if next(10) == 0 { value.filePath = "" }
                return value
            }
            var priority: [String] = (0..<next(8)).map { _ in songs[next(songs.count)].id }
            if next(3) == 0 { priority.append("missing") }
            if let first = priority.first, next(2) == 0 { priority.append(first) }
            let limit = next(30)
            let streamed = SiriSongCatalog.shortcuts(priorityIDs: priority, limit: limit) { body in
                for song in songs where !body(song) { return }
            }
            #expect(streamed.map(\.id) == Self.reference(songs, priorityIDs: priority, limit: limit).map(\.id),
                    "seed \(seed) round \(round) limit \(limit)")
        }
    }

    /// 原来的整库算法(改成流式之前的 `shortcuts(from:priorityIDs:limit:)`),作对照。
    private static func reference(_ songs: [Song], priorityIDs: [String], limit: Int) -> [Song] {
        guard limit > 0 else { return [] }
        var byID: [String: Int] = [:]
        for index in songs.indices {
            let song = songs[index]
            guard song.isPlayable else { continue }
            let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty && title.count <= 3
                && SiriRadioStationCatalog.safeDisplayName(title) != nil
                && SiriRadioStationCatalog.isSafeIdentifier(song.id) {
                byID[song.id] = index
            }
        }
        var selected: [Song] = []
        for id in priorityIDs {
            if let index = byID.removeValue(forKey: id) {
                selected.append(songs[index])
                if selected.count == limit { return selected }
            }
        }
        let remaining = byID.values.sorted {
            songs[$0].dateAdded != songs[$1].dateAdded ? songs[$0].dateAdded > songs[$1].dateAdded : songs[$0].id < songs[$1].id
        }.prefix(limit - selected.count)
        return selected + remaining.map { songs[$0] }
    }

    private func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, fileFormat: .mp3, filePath: "\(id).mp3", sourceID: "fixture", dateAdded: Date(timeIntervalSince1970: 0))
    }
}
