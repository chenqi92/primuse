import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playing book cache")
struct SpokenWordCurrentBookCacheTests {
    private func item(_ number: Int, duration: TimeInterval = 600) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: "c\(number)",
            title: "第\(number)集",
            albumTitle: "长书",
            albumArtist: "讲述者",
            trackNumber: number,
            duration: duration,
            fileName: "/长书/\(String(format: "%03d", number)).mp3",
            sourceID: "src"
        )
    }

    private var items: [SpokenWordBookItem] { (1...6).map { item($0) } }

    /// What grouping the items afresh with this progress gives.
    private func regrouped(
        _ items: [SpokenWordBookItem],
        progress: [String: SpokenWordItemProgress],
        untimed: Set<String> = []
    ) -> SpokenWordBook? {
        let updated = items.map {
            $0.replacingProgress(progress[$0.id] ?? .init(), songHasDuration: !untimed.contains($0.id))
        }
        return SpokenWordBookGrouping.books(from: updated).first
    }

    @Test("A saved position updates the book without grouping it again")
    func progressDoesNotRegroup() {
        var cache = SpokenWordCurrentBookCache()
        var groupCount = 0
        var progress: [String: SpokenWordItemProgress] = [:]
        let source = items
        func read(_ progressKey: String, item: String = "c2") -> SpokenWordBook? {
            cache.book(
                groupingKey: "book|1|1",
                progressKey: progressKey,
                itemID: item,
                group: {
                    groupCount += 1
                    return .init(book: regrouped(source, progress: progress))
                },
                progress: { progress[$0] ?? .init() }
            )
        }

        #expect(read("1")?.chapterCount == 6)
        #expect(read("1") != nil)
        #expect(groupCount == 1)

        let saved = Date(timeIntervalSince1970: 2_000)
        progress["c1"] = .init(finishedAt: Date(timeIntervalSince1970: 1_000))
        progress["c2"] = .init(knownDuration: 600, position: 240, positionUpdatedAt: saved)
        let updated = read("2")
        #expect(groupCount == 1)
        #expect(updated == regrouped(source, progress: progress))
        #expect(updated?.resumeItemID == "c2")
        #expect(updated?.lastListenedAt == saved)
        #expect(updated?.finishedCount == 1)

        // The next chapter of the same book keeps the grouping too.
        #expect(read("2", item: "c3") == updated)
        #expect(groupCount == 1)
    }

    @Test("A change to the book's members or their classification groups again")
    func groupingKeyRegroups() {
        var cache = SpokenWordCurrentBookCache()
        var groupCount = 0
        let source = items
        for groupingKey in ["book|1|1", "book|2|1", "book|2|2"] {
            _ = cache.book(
                groupingKey: groupingKey,
                progressKey: "1",
                itemID: "c1",
                group: {
                    groupCount += 1
                    return .init(book: regrouped(source, progress: [:]))
                },
                progress: { _ in .init() }
            )
        }
        #expect(groupCount == 3)
    }

    @Test("An item the kept book does not hold groups again")
    func outsideItemRegroups() {
        var cache = SpokenWordCurrentBookCache()
        var groupCount = 0
        let source = items
        for itemID in ["c1", "elsewhere"] {
            _ = cache.book(
                groupingKey: "book|1|1",
                progressKey: "1",
                itemID: itemID,
                group: {
                    groupCount += 1
                    return .init(book: regrouped(source, progress: [:]))
                },
                progress: { _ in .init() }
            )
        }
        #expect(groupCount == 2)
    }

    @Test("A book not found is not looked for again until something changes")
    func missingBookIsCached() {
        var cache = SpokenWordCurrentBookCache()
        var groupCount = 0
        for progressKey in ["1", "2"] {
            let book = cache.book(
                groupingKey: "book|1|1",
                progressKey: progressKey,
                itemID: "c1",
                group: {
                    groupCount += 1
                    return .init(book: nil)
                },
                progress: { _ in .init() }
            )
            #expect(book == nil)
        }
        #expect(groupCount == 1)
    }

    @Test("A file without a duration of its own takes the stored one")
    func untimedItemFollowsStoredDuration() {
        var cache = SpokenWordCurrentBookCache()
        let source = [item(1), item(2, duration: 0), item(3)]
        var progress: [String: SpokenWordItemProgress] = [:]
        let untimed: Set<String> = ["c2"]
        func read(_ progressKey: String) -> SpokenWordBook? {
            cache.book(
                groupingKey: "book|1|1",
                progressKey: progressKey,
                itemID: "c2",
                group: { .init(book: regrouped(source, progress: progress, untimed: untimed), untimedItemIDs: untimed) },
                progress: { progress[$0] ?? .init() }
            )
        }
        #expect(read("1")?.items[1].duration == 0)
        progress["c2"] = .init(knownDuration: 900, position: 30, positionUpdatedAt: Date(timeIntervalSince1970: 50))
        // A timed item keeps its own duration whatever the store heard.
        progress["c1"] = .init(knownDuration: 1, finishedAt: Date(timeIntervalSince1970: 40))
        let book = read("2")
        #expect(book?.items.map(\.duration) == [600, 900, 600])
        #expect(book == regrouped(source, progress: progress, untimed: untimed))
    }

    @Test("The key names the playing item and the progress it was read at")
    func keyFollowsItemAndProgress() {
        var cache = SpokenWordCurrentBookCache()
        let source = items
        var keys: [String?] = []
        for (progressKey, itemID) in [("1", "c1"), ("1", "c2"), ("2", "c2")] {
            _ = cache.book(
                groupingKey: "book|1|1",
                progressKey: progressKey,
                itemID: itemID,
                group: { .init(book: regrouped(source, progress: [:])) },
                progress: { _ in .init() }
            )
            keys.append(cache.key)
        }
        #expect(Set(keys.compactMap { $0 }).count == 3)
    }
}
