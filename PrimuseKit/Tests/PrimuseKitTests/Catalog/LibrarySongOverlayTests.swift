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

/// 覆盖层接在「旧库 → 目录」这条跟写链上:按旧库修订号确认,绑定与镜像谁先到都行。
@Suite("Library pending song writes")
struct LibraryPendingSongWritesTests {
    @Test("A batch is dropped once the catalog mirrors its store revision, whichever arrives first")
    func bindingAndMirroringInEitherOrder() throws {
        let writes = LibraryPendingSongWrites()
        let first = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("a", title: "one")]))
        let second = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("b")]))
        writes.bind(throughSequence: first, storeRevision: 10)
        writes.catalogMirrored(storeRevision: 9)
        #expect(writes.pendingCount == 2)
        writes.catalogMirrored(storeRevision: 10)
        #expect(writes.lookup("a") == .unknown)
        #expect(LibrarySongOverlayTests.present(writes.lookup("b")) == "b/t")

        // 对账先看到了修订号 12,绑定后到:绑定时直接确认。
        writes.catalogMirrored(storeRevision: 12)
        #expect(writes.pendingCount == 1)
        writes.bind(throughSequence: second, storeRevision: 11)
        #expect(writes.pendingCount == 0)
        #expect(writes.answersLikeMemory)

        // 镜像的修订号不往回退。
        let third = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("c")]))
        writes.catalogMirrored(storeRevision: 5)
        writes.bind(throughSequence: third, storeRevision: 12)
        #expect(writes.pendingCount == 0)
    }

    @Test("A whole-store replacement keeps the catalog from answering until it is mirrored")
    func replacementBarrier() throws {
        let writes = LibraryPendingSongWrites()
        let sequence = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("a")]))
        writes.bindReplacement(throughSequence: sequence, storeRevision: 20)
        #expect(!writes.answersLikeMemory)
        writes.catalogMirrored(storeRevision: 19)
        #expect(!writes.answersLikeMemory)
        writes.catalogMirrored(storeRevision: 20)
        #expect(writes.answersLikeMemory)
        #expect(writes.pendingCount == 0)

        writes.catalogMirrored(storeRevision: 25)
        writes.bindReplacement(throughSequence: writes.lastSequence, storeRevision: 24)
        #expect(writes.answersLikeMemory, "already mirrored past the replacement")
    }

    @Test("After following stops nothing is recorded and nothing is answered")
    func suspension() {
        let writes = LibraryPendingSongWrites()
        writes.record(upserts: [LibrarySongOverlayTests.song("a")])
        writes.suspend()
        #expect(writes.pendingCount == 0)
        #expect(!writes.answersLikeMemory)
        #expect(writes.record(upserts: [LibrarySongOverlayTests.song("b")]) == nil)
        writes.bind(throughSequence: 1, storeRevision: 1)
        writes.catalogMirrored(storeRevision: 1)
        #expect(writes.lookup("b") == .unknown)
    }

    @Test("Waiting for the catalog returns once it has acknowledged the batch, false on timeout or when following stops")
    func waitingForAcknowledgement() async throws {
        let writes = LibraryPendingSongWrites()
        #expect(await writes.waitUntilAcknowledged(through: writes.lastSequence, timeout: .milliseconds(10)))

        let first = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("a")]))
        async let waited = writes.waitUntilAcknowledged(through: first, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        writes.catalogMirrored(storeRevision: 3)
        writes.bind(throughSequence: first, storeRevision: 3)
        #expect(await waited)

        // 绑定先到、镜像后到。
        let second = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("b")]))
        writes.bind(throughSequence: second, storeRevision: 4)
        async let later = writes.waitUntilAcknowledged(through: second, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        writes.catalogMirrored(storeRevision: 4)
        #expect(await later)

        // 写旧库失败(没有绑定):等到超时。
        let unbound = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("c")]))
        #expect(await writes.waitUntilAcknowledged(through: unbound, timeout: .milliseconds(50)) == false)

        // 整份替换镜像到之前不算跟上。
        writes.bindReplacement(throughSequence: unbound, storeRevision: 9)
        async let replaced = writes.waitUntilAcknowledged(through: unbound, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        writes.catalogMirrored(storeRevision: 9)
        #expect(await replaced)

        let pending = try #require(writes.record(upserts: [LibrarySongOverlayTests.song("d")]))
        async let stopped = writes.waitUntilAcknowledged(through: pending, timeout: .seconds(5))
        try await Task.sleep(for: .milliseconds(20))
        writes.suspend()
        #expect(await stopped == false)
        #expect(await writes.waitUntilAcknowledged(through: 0, timeout: .seconds(1)) == false)
    }

    @Test("Resolving reads the overlay first, then the catalog, following a rename the catalog has not made yet")
    func resolving() throws {
        let catalog = try TemporaryCatalog()
        try catalog.catalog.apply(upserts: [LibrarySongOverlayTests.song("old", title: "kept"), LibrarySongOverlayTests.song("x")])
        let writes = LibraryPendingSongWrites()
        let sequence = try #require(writes.record(
            upserts: [LibrarySongOverlayTests.song("fresh", title: "new")], deletingIDs: ["x"], renaming: ["old": "moved"]
        ) { (try? catalog.catalog.song(id: $0)) != nil })
        func read(_ id: String) throws -> String? {
            try writes.resolve(id) { try catalog.catalog.song(id: $0) }.map { "\($0.id)/\($0.title)" }
        }
        #expect(try read("moved") == "moved/kept")
        #expect(try read("old") == nil)
        #expect(try read("x") == nil)
        #expect(try read("fresh") == "fresh/new")
        // 一批一起看:与逐个看相同;一条待写的都没有时为 nil(整批直接读目录)。
        let batch = try #require(writes.lookups(["moved", "old", "x", "fresh", "untouched"]))
        #expect(batch[0] == .renamed(from: "old"))
        #expect(batch[1] == .deleted && batch[2] == .deleted)
        #expect(LibrarySongOverlayTests.present(batch[3]) == "fresh/new")
        #expect(batch[4] == .unknown)

        // 目录已经提交、还没确认:改名之后的那一行按新 id 读。
        try catalog.catalog.apply(
            upserts: [LibrarySongOverlayTests.song("fresh", title: "new")], deletingIDs: ["x"], renaming: ["old": "moved"]
        )
        #expect(try read("moved") == "moved/kept")
        writes.bind(throughSequence: sequence, storeRevision: 1)
        writes.catalogMirrored(storeRevision: 1)
        #expect(writes.pendingCount == 0)
        #expect(writes.lookups(["moved", "fresh"]) == nil)
        #expect(try read("moved") == "moved/kept")
        #expect(try read("x") == nil)
    }
}

