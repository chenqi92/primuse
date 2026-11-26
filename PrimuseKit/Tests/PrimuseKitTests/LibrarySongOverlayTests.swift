import Foundation
import Testing
@testable import PrimuseKit

/// 目录成为权威后的待写覆盖层:按 id 读「覆盖层 → 目录」与把所有批都写进目录后读的结果相同,
/// 不论目录此刻提交到第几批;确认之后条目按批丢掉。
@Suite("Library song overlay", .serialized)
struct LibrarySongOverlayTests {
    static func song(_ id: String, title: String = "t") -> Song {
        Song(id: id, title: title, duration: 100, fileFormat: .flac, filePath: "Music/\(id).flac", sourceID: "src")
    }

    /// 覆盖层里那一首的「id/标题」(不是那一首时为 nil)。
    static func present(_ lookup: LibrarySongOverlay.Lookup) -> String? {
        if case .present(let song) = lookup { return "\(song.id)/\(song.title)" }
        return nil
    }

    @Test("Reads see the newest batch; acknowledging drops only what later batches did not rewrite")
    func sequencingAndAcknowledgement() {
        var overlay = LibrarySongOverlay()
        #expect(overlay.lookup("a") == .unknown)
        let first = overlay.record(upserts: [Self.song("a", title: "one"), Self.song("b")])
        let second = overlay.record(upserts: [Self.song("a", title: "two")], deletingIDs: ["b"])
        #expect(Self.present(overlay.lookup("a")) == "a/two")
        #expect(overlay.lookup("b") == .deleted)
        overlay.acknowledge(through: first)
        #expect(Self.present(overlay.lookup("a")) == "a/two", "rewritten by the second batch")
        #expect(overlay.count == 2)
        overlay.acknowledge(through: second)
        #expect(overlay.isEmpty)
        #expect(overlay.lookup("a") == .unknown)
        overlay.acknowledge(through: first)
        #expect(overlay.acknowledgedSequence == second, "acknowledgement never goes back")
    }

    @Test("Within a batch renames come first, then deletions, then upserts")
    func batchOrder() {
        var overlay = LibrarySongOverlay()
        overlay.record(upserts: [Self.song("x", title: "kept")], deletingIDs: ["x"])
        #expect(Self.present(overlay.lookup("x")) == "x/kept")
        let inCatalog: Set<String> = ["old", "taken", "other"]
        overlay.record(upserts: [], renaming: ["old": "new", "other": "taken", "ghost": "spirit"]) { inCatalog.contains($0) }
        #expect(overlay.lookup("old") == .deleted)
        #expect(overlay.lookup("new") == .renamed(from: "old"))
        #expect(overlay.lookup("other") == .unknown, "the new id is already in the catalog: the catalog keeps the old name")
        #expect(overlay.lookup("spirit") == .unknown, "the old id is nowhere: nothing to rename")
        overlay.record(upserts: [], renaming: ["x": "y"])
        #expect(Self.present(overlay.lookup("y")) == "y/kept")
        overlay.removeAll()
        #expect(overlay.isEmpty)
        #expect(overlay.acknowledgedSequence == overlay.lastSequence)
    }

    private struct Generator {
        var state: UInt64
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upperBound))
        }
    }

    private struct Batch {
        var upserts: [Song] = []
        var deletes: [String] = []
        var renames: [String: String] = [:]
    }

    @Test("Overlay over a partly committed catalog reads like the fully written catalog", arguments: [1, 2, 3, 4] as [UInt64])
    func overlayMatchesTheFullyWrittenCatalog(seed: UInt64) throws {
        var random = Generator(state: seed)
        let ids = (0..<10).map { "id\($0)" }
        for round in 0..<12 {
            let full = try TemporaryCatalog()
            let partial = try TemporaryCatalog()
            var batches: [Batch] = []
            for _ in 0..<(3 + random.next(6)) {
                var batch = Batch()
                for _ in 0..<random.next(4) {
                    batch.upserts.append(Self.song(ids[random.next(ids.count)], title: "r\(round)-\(random.next(1000))"))
                }
                for _ in 0..<random.next(3) { batch.deletes.append(ids[random.next(ids.count)]) }
                for _ in 0..<random.next(3) {
                    let from = ids[random.next(ids.count)]
                    batch.renames[from] = ids[random.next(ids.count)]
                }
                // 同一批里同一首只写一次(同 `persistSongChanges` 合并过的批)。
                var seen = Set<String>()
                batch.upserts = batch.upserts.reversed().filter { seen.insert($0.id).inserted }.reversed()
                batches.append(batch)
            }

            var overlay = LibrarySongOverlay()
            var committed = 0
            func commitPartial(upTo target: Int) throws {
                while committed < target {
                    let batch = batches[committed]
                    try partial.catalog.apply(upserts: batch.upserts, deletingIDs: batch.deletes, renaming: batch.renames)
                    committed += 1
                    overlay.acknowledge(through: UInt64(committed))
                }
            }
            for (index, batch) in batches.enumerated() {
                // 目录在后台随机地追上一部分,再记下这一批。
                try commitPartial(upTo: committed + random.next(index - committed + 1))
                overlay.record(upserts: batch.upserts, deletingIDs: batch.deletes, renaming: batch.renames) { id in
                    (try? partial.catalog.song(id: id)) != nil
                }
                try full.catalog.apply(upserts: batch.upserts, deletingIDs: batch.deletes, renaming: batch.renames)
            }
            try commitPartial(upTo: committed + random.next(batches.count - committed + 1))

            for id in ids {
                let expected = try full.catalog.song(id: id)
                let resolved: Song?
                switch overlay.lookup(id) {
                case .unknown: resolved = try partial.catalog.song(id: id)
                case .present(let song): resolved = song
                case .deleted: resolved = nil
                case .renamed(let from):
                    var moved = try partial.catalog.song(id: from)
                    moved?.id = id
                    resolved = moved
                }
                #expect(resolved?.id == expected?.id && resolved?.title == expected?.title
                            && resolved?.filePath == expected?.filePath,
                        "seed \(seed) round \(round) id \(id) committed \(committed)/\(batches.count)")
            }
            try commitPartial(upTo: batches.count)
            #expect(overlay.isEmpty)
        }
    }
}
