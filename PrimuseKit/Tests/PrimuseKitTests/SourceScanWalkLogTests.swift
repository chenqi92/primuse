import Foundation
import Testing
@testable import PrimuseKit

/// 可复现的伪随机数(每个用例固定种子)。
struct WalkTestRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum WalkTestFixtures {
    /// 目录源形状的键池:`path:` 小写键、中文路径、同一个键的 NFC/NFD 两种写法、提供方 ID。
    static func keyPool(_ count: Int) -> [String] {
        var keys: [String] = []
        for index in 0..<count {
            switch index % 7 {
            case 0: keys.append("path:/music/周杰伦\(index / 7)/范特西/\(index).flac")
            case 1: keys.append("path:/music/album \(index)/cover.jpg")
            case 2: keys.append("baidu:\(1_000 + index)")
            case 3: keys.append("pc\(index)")
            case 4: keys.append("path:/music/caf\u{E9} \(index)") // NFC
            case 5: keys.append("path:/music/cafe\u{301} \(index - 1)") // 与上一个按 String 相等(NFD)
            default: keys.append("hierarchy-folder:/music/\(index)")
            }
        }
        return keys
    }

    static func item(
        key: String,
        version: Int,
        random: inout WalkTestRandom
    ) -> SourceSyncIndexedItem {
        let directory = Int.random(in: 0..<5, using: &random) == 0
        let parent = "/music/dir \(Int.random(in: 0..<6, using: &random))"
        let songCount = directory ? 0 : Int.random(in: 0..<3, using: &random)
        return SourceSyncIndexedItem(
            stableKey: Int.random(in: 0..<4, using: &random) == 0 ? key + "#stable" : key,
            path: directory ? parent + "/sub \(version % 4)" : parent + "/file \(version).flac",
            displayName: Int.random(in: 0..<3, using: &random) == 0 ? nil : "name \(version)",
            parentPath: Int.random(in: 0..<8, using: &random) == 0 ? nil : parent,
            isDirectory: directory,
            songIDs: (0..<songCount).map { MusicIDs.song(version * 3 + $0) },
            size: Int64(version),
            modifiedDate: Int.random(in: 0..<2, using: &random) == 0
                ? nil : Date(timeIntervalSince1970: 1_700_000_000 + Double(version)),
            revision: Int.random(in: 0..<3, using: &random) == 0 ? nil : "etag-\(version)",
            sidecarFingerprint: Int.random(in: 0..<4, using: &random) == 0 ? "lrc|\(version)" : nil,
            seenEpoch: Int64(version % 5)
        )
    }

    /// 两边逐字节相同的键集合(检查键的写法沿用第一次写入的)。
    static func keyBytes<S: Sequence>(_ keys: S) -> [[UInt8]] where S.Element == String {
        keys.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
    }
}

@Suite("Directory walk log")
struct SourceScanWalkLogTests {
    @Test("Reads exactly like a dictionary plus a set under random writes, seals and merges")
    func matchesDictionaryModel() {
        for seed in 1...6 {
            var random = WalkTestRandom(seed: UInt64(seed))
            let pool = WalkTestFixtures.keyPool(400)
            var log = SourceScanWalkLog()
            var dictionary: [String: SourceSyncIndexedItem] = [:]
            var songs = Set<String>()
            var snapshots: [(log: SourceScanWalkLog, index: [String: SourceSyncIndexedItem], songs: Set<String>)] = []
            for step in 0..<3_000 {
                let key = pool[Int.random(in: 0..<pool.count, using: &random)]
                let item = WalkTestFixtures.item(key: key, version: step, random: &random)
                log.updateValue(item, forKey: key)
                dictionary[key] = item
                if step % 3 == 0 {
                    let id = MusicIDs.song(step % 500)
                    log.insertSongID(id)
                    songs.insert(id)
                }
                if Int.random(in: 0..<25, using: &random) == 0 {
                    log.seal()
                    if snapshots.count < 8 { snapshots.append((log, dictionary, songs)) }
                }
            }
            let segmentCount = log.segments.count
            #expect(segmentCount < 30, "seed \(seed): segments stay logarithmic")
            check(log, dictionary, songs, "seed \(seed)")
            // 封存后交出去的快照不受之后写入的影响。
            for (offset, snapshot) in snapshots.enumerated() {
                check(snapshot.log, snapshot.index, snapshot.songs, "seed \(seed) snapshot \(offset)")
            }
            var consolidated = log
            consolidated.consolidate()
            #expect(consolidated.segments.count == 1)
            check(consolidated, dictionary, songs, "seed \(seed) consolidated")
            check(log, dictionary, songs, "seed \(seed) after consolidating a copy")
        }
    }

    @Test("An unsealed copy is isolated from later writes on either side")
    func unsealedCopiesAreIsolated() {
        var random = WalkTestRandom(seed: 99)
        var log = SourceScanWalkLog()
        var expected: [String: SourceSyncIndexedItem] = [:]
        for step in 0..<50 {
            let item = WalkTestFixtures.item(key: "k\(step)", version: step, random: &random)
            log.updateValue(item, forKey: "k\(step)")
            expected["k\(step)"] = item
        }
        let copy = log
        var other = log
        let changed = WalkTestFixtures.item(key: "k1", version: 999, random: &random)
        log.updateValue(changed, forKey: "k1")
        other.updateValue(changed, forKey: "extra")
        check(copy, expected, [], "copy")
        var afterLog = expected
        afterLog["k1"] = changed
        check(log, afterLog, [], "log")
        var afterOther = expected
        afterOther["extra"] = changed
        check(other, afterOther, [], "other")
    }

    @Test("Equality compares content, not segment layout")
    func equalityIgnoresLayout() {
        var random = WalkTestRandom(seed: 7)
        var first = SourceScanWalkLog()
        var second = SourceScanWalkLog()
        for step in 0..<200 {
            let item = WalkTestFixtures.item(key: "k\(step % 120)", version: step, random: &random)
            first.updateValue(item, forKey: "k\(step % 120)")
            second.updateValue(item, forKey: "k\(step % 120)")
            if step % 7 == 0 { first.seal() }
            first.insertSongID("s\(step % 30)")
            second.insertSongID("s\(step % 30)")
        }
        second.consolidate()
        #expect(first == second)
        second.insertSongID("another")
        #expect(first != second)
    }

    private func check(
        _ log: SourceScanWalkLog,
        _ dictionary: [String: SourceSyncIndexedItem],
        _ songs: Set<String>,
        _ context: String
    ) {
        #expect(log.indexCount == dictionary.count, "\(context)")
        var iterated: [String: SourceSyncIndexedItem] = [:]
        var iteratedKeys: [String] = []
        for (key, item) in log {
            iteratedKeys.append(key)
            iterated[key] = item
        }
        #expect(iteratedKeys.count == dictionary.count, "\(context): every key once")
        #expect(iterated == dictionary, "\(context)")
        let keyBytes = WalkTestFixtures.keyBytes(iteratedKeys)
        let expectedKeyBytes = WalkTestFixtures.keyBytes(dictionary.keys)
        #expect(keyBytes == expectedKeyBytes, "\(context): first spelling of each key is kept")
        for (key, item) in dictionary {
            #expect(log[key] == item, "\(context) \(key)")
        }
        #expect(log["missing-key"] == nil)
        let materialized = log.materializedIndex()
        #expect(materialized == SourceSyncIndex(dictionary), "\(context)")
        let materializedKeyBytes = WalkTestFixtures.keyBytes(materialized.keys)
        #expect(materializedKeyBytes == expectedKeyBytes, "\(context)")
        let expanded = log.indexDictionary
        #expect(expanded == dictionary, "\(context)")
        let songSet = log.songIDSet()
        #expect(songSet == songs, "\(context)")
        var directories: [String] = []
        log.forEachDirectoryItem { directories.append("\($0.stableKey)|\($0.size)") }
        let expectedDirectories = dictionary.values.filter(\.isDirectory).map { "\($0.stableKey)|\($0.size)" }
        #expect(directories.sorted() == expectedDirectories.sorted(), "\(context)")
    }
}

@Suite("Compact index helpers for directory scans")
struct SourceSyncIndexScanHelperTests {
    private func randomIndex(seed: UInt64, count: Int) -> [String: SourceSyncIndexedItem] {
        var random = WalkTestRandom(seed: seed)
        var dictionary: [String: SourceSyncIndexedItem] = [:]
        for (offset, key) in WalkTestFixtures.keyPool(count).enumerated() {
            dictionary[key] = WalkTestFixtures.item(key: key, version: offset, random: &random)
        }
        return dictionary
    }

    @Test("Overlay reads like merging the walk progress into the committed index")
    func overlayMatchesMerging() {
        for seed in 1...4 {
            var random = WalkTestRandom(seed: UInt64(seed) &* 31)
            let lowerDictionary = randomIndex(seed: UInt64(seed), count: 300)
            var upper = SourceScanWalkLog()
            var upperDictionary: [String: SourceSyncIndexedItem] = [:]
            let pool = WalkTestFixtures.keyPool(500)
            for step in 0..<250 {
                let key = pool[Int.random(in: 0..<pool.count, using: &random)]
                let item = WalkTestFixtures.item(key: key, version: 10_000 + step, random: &random)
                upper.updateValue(item, forKey: key)
                upperDictionary[key] = item
                if step % 40 == 0 { upper.seal() }
            }
            let merged = lowerDictionary.merging(upperDictionary) { _, new in new }
            let overlay = SourceSyncIndexOverlay(lower: SourceSyncIndex(lowerDictionary), upper: upper)
            var iterated: [String: SourceSyncIndexedItem] = [:]
            var keys: [String] = []
            for (key, item) in overlay {
                keys.append(key)
                iterated[key] = item
            }
            #expect(keys.count == merged.count)
            #expect(iterated == merged)
            let keyBytes = WalkTestFixtures.keyBytes(keys)
            let mergedKeyBytes = WalkTestFixtures.keyBytes(merged.keys)
            #expect(keyBytes == mergedKeyBytes)
            for key in pool {
                #expect(overlay.item(forKey: key) == merged[key], "seed \(seed) \(key)")
            }
            var directories: [String] = []
            overlay.forEachDirectoryItem { directories.append("\($0.stableKey)|\($0.size)") }
            let expectedDirectories = merged.values.filter(\.isDirectory).map { "\($0.stableKey)|\($0.size)" }
            #expect(directories.sorted() == expectedDirectories.sorted())
            let emptyOverlay = SourceSyncIndexOverlay(lower: SourceSyncIndex(lowerDictionary))
            var plain: [String: SourceSyncIndexedItem] = [:]
            for (key, item) in emptyOverlay { plain[key] = item }
            #expect(plain == lowerDictionary)
        }
    }

    @Test("Grouping by parent and directory views match plain filters")
    func parentGroupingAndDirectoryViews() {
        let dictionary = randomIndex(seed: 5, count: 700)
        let index = SourceSyncIndex(dictionary)
        for parents: Set<String> in [["/music/dir 1", "/music/dir 3"], ["/music/dir 5"], ["/nowhere"], []] {
            var expected: [String: [String: SourceSyncIndexedItem]] = [:]
            for (key, item) in dictionary {
                guard let parent = item.parentPath, parents.contains(parent) else { continue }
                expected[parent, default: [:]][key] = item
            }
            let grouped = index.entries(withParentIn: parents)
            #expect(grouped == expected, "\(parents)")
        }
        let directories = index.directoryItems.map { "\($0.stableKey)|\($0.size)" }
        let expectedDirectories = dictionary.values.filter(\.isDirectory).map { "\($0.stableKey)|\($0.size)" }
        #expect(directories.sorted() == expectedDirectories.sorted())
        var entries: [String: SourceSyncIndexedItem] = [:]
        index.forEachDirectoryEntry { key, item in entries[key] = item }
        let expectedEntries = dictionary.filter { $0.value.isDirectory }
        #expect(entries == expectedEntries)
        #expect(index.hasDirectoryEntries)
        let filesOnly = SourceSyncIndex(dictionary.filter { !$0.value.isDirectory })
        #expect(!filesOnly.hasDirectoryEntries)
    }

    @Test("Concatenating disjoint indexes equals building their union")
    func concatenation() {
        let all = randomIndex(seed: 11, count: 600)
        let keys = all.keys.sorted()
        let first = Dictionary(uniqueKeysWithValues: keys.prefix(200).map { ($0, all[$0]!) })
        let second = Dictionary(uniqueKeysWithValues: keys.dropFirst(200).map { ($0, all[$0]!) })
        let joined = SourceSyncIndex.concatenating([SourceSyncIndex(first), SourceSyncIndex(), SourceSyncIndex(second)])
        #expect(joined == SourceSyncIndex(all))
        #expect(joined.count == all.count)
        let data = try? joined.binaryData().data
        let decoded = data.flatMap { try? SourceSyncIndex.decodeBinary($0) }
        #expect(decoded == SourceSyncIndex(all))
    }

    @Test("Compacting after most rows were removed keeps every live entry and shared directory paths")
    func compactionAfterManyRemovals() {
        var dictionary: [String: SourceSyncIndexedItem] = [:]
        for album in 0..<40 {
            let folder = "/Music/歌手 \(album % 7)/专辑 \(album)"
            dictionary["path:\(folder.lowercased())"] = SourceSyncIndexedItem(
                stableKey: "path:\(folder.lowercased())", path: folder, displayName: "专辑 \(album)",
                parentPath: "/Music/歌手 \(album % 7)", isDirectory: true, size: 0, modifiedDate: nil, revision: nil
            )
            for track in 0..<25 {
                let path = "\(folder)/\(track).flac"
                dictionary["path:\(path.lowercased())"] = SourceSyncIndexedItem(
                    stableKey: "path:\(path.lowercased())", path: path, displayName: "\(track).flac",
                    parentPath: folder, isDirectory: false, songIDs: [MusicIDs.song(album * 100 + track)],
                    size: Int64(track), modifiedDate: nil, revision: track % 2 == 0 ? "e\(track)" : nil
                )
            }
        }
        let original = SourceSyncIndex(dictionary)
        var trimmed = original
        for key in dictionary.keys.sorted().enumerated().filter({ $0.offset % 10 != 0 }).map(\.element) {
            trimmed.removeValue(forKey: key)
            dictionary[key] = nil
        }
        var copy = trimmed
        var random = WalkTestRandom(seed: 3)
        let added = WalkTestFixtures.item(key: "added", version: 1, random: &random)
        copy["added"] = added
        var expected = dictionary
        expected["added"] = added
        #expect(trimmed == SourceSyncIndex(dictionary))
        #expect(copy == SourceSyncIndex(expected))
        #expect(copy.dictionary == expected)
        #expect(original.count == 40 * 26)
        let compactedBytes = copy.storage.arena.count
        let originalBytes = original.storage.arena.count
        #expect(compactedBytes < originalBytes / 4, "the copy dropped the removed rows' bytes")
        let data = try? copy.binaryData().data
        let decoded = data.flatMap { try? SourceSyncIndex.decodeBinary($0) }
        #expect(decoded == SourceSyncIndex(expected))
    }

    @Test("Copying an index with a few removed rows keeps every live entry")
    func copyAfterRemovals() {
        var dictionary = randomIndex(seed: 13, count: 400)
        var removed = SourceSyncIndex(dictionary)
        let keys = dictionary.keys.sorted()
        for key in keys.prefix(20) {
            removed.removeValue(forKey: key)
            dictionary[key] = nil
        }
        let before = removed
        var edited = removed
        var random = WalkTestRandom(seed: 1)
        let item = WalkTestFixtures.item(key: "fresh", version: 1, random: &random)
        edited["fresh"] = item
        edited[keys[30]] = nil
        #expect(before == SourceSyncIndex(dictionary))
        var expected = dictionary
        expected["fresh"] = item
        expected[keys[30]] = nil
        #expect(edited == SourceSyncIndex(expected))
        #expect(edited.dictionary == expected)
        let data = try? edited.binaryData().data
        let decoded = data.flatMap { try? SourceSyncIndex.decodeBinary($0) }
        #expect(decoded == SourceSyncIndex(expected))
    }

    /// 增量对账直接改已提交的紧凑索引再提交:改掉的行留下的字节不能写进文件,
    /// 否则读回来作废行数是零、那些字节再也看不出来,一轮轮同步下去越攒越多。
    @Test("Repeated edit-commit-reload cycles do not accumulate replaced rows' bytes")
    func editCommitCyclesStayBounded() throws {
        var dictionary = randomIndex(seed: 17, count: 1_500)
        var committed = SourceSyncIndex(dictionary)
        let keys = dictionary.keys.sorted()
        var random = WalkTestRandom(seed: 23)
        var arenaSizes: [Int] = []
        for cycle in 0..<8 {
            // 同一份索引被握着(已提交的那份)时改一份:第一次改动时拷贝。
            var edited = committed
            for (offset, key) in keys.enumerated() where (offset + cycle) % 5 == 0 {
                let item = WalkTestFixtures.item(key: key, version: cycle * 10_000 + offset, random: &random)
                edited[key] = item
                dictionary[key] = item
            }
            #expect(edited.storage.deadCount > 0, "cycle \(cycle) replaced rows in place")
            // 握着的那份也带着作废行时再拷一次(下一轮的拷贝走压缩那一支)。
            var second = edited
            second[keys[cycle]] = dictionary[keys[cycle]]
            #expect(second == SourceSyncIndex(dictionary), "cycle \(cycle)")
            let decoded = try SourceSyncIndex.decodeBinary(edited.binaryData().data)
            #expect(decoded == SourceSyncIndex(dictionary), "cycle \(cycle)")
            #expect(decoded.storage.deadCount == 0)
            #expect(decoded.storage.arena.count < edited.storage.arena.count, "cycle \(cycle) wrote no dead bytes")
            // 与按同样内容新建的一份相比只多改过的行各自存的父目录路径(新建时共用一份),
            // 攒着旧字节的话每轮要多出约五分之一。
            let fresh = SourceSyncIndex(dictionary).storage.arena.count
            arenaSizes.append(decoded.storage.arena.count)
            #expect(decoded.storage.arena.count <= fresh + fresh / 4, "cycle \(cycle): \(arenaSizes) vs fresh \(fresh)")
            committed = decoded
        }
    }
}

@Suite("Scan resume state storage")
struct SourceScanResumeStateStorageTests {
    private struct LegacyShape: Codable {
        var schemaVersion: Int
        var pendingDirectories: [String]
        var encounteredSongIDs: Set<String>
        var index: [String: SourceSyncIndexedItem]
    }

    private struct VersionOnly: Decodable {
        var schemaVersion: Int
    }

    private func sampleLog(seed: UInt64, segments: Int) -> (SourceScanWalkLog, [String: SourceSyncIndexedItem], Set<String>) {
        var random = WalkTestRandom(seed: seed)
        var log = SourceScanWalkLog()
        var dictionary: [String: SourceSyncIndexedItem] = [:]
        var songs = Set<String>()
        let pool = WalkTestFixtures.keyPool(120)
        for round in 0..<segments {
            for step in 0..<60 {
                let key = pool[Int.random(in: 0..<pool.count, using: &random)]
                let item = WalkTestFixtures.item(key: key, version: round * 100 + step, random: &random)
                log.updateValue(item, forKey: key)
                dictionary[key] = item
                let id = MusicIDs.song(step)
                log.insertSongID(id)
                songs.insert(id)
            }
            if round < segments - 1 { log.seal() }
        }
        return (log, dictionary, songs)
    }

    @Test("A walk-backed state encodes to the dictionary JSON shape")
    func inlineEncodingKeepsTheShape() throws {
        let (log, dictionary, songs) = sampleLog(seed: 3, segments: 4)
        let state = SourceScanResumeState(pendingDirectories: ["/music/b"], walkLog: log)
        let data = try JSONEncoder().encode(state)
        let legacy = try JSONDecoder().decode(LegacyShape.self, from: data)
        #expect(legacy.schemaVersion == SourceScanResumeState.currentSchemaVersion)
        #expect(legacy.pendingDirectories == ["/music/b"])
        #expect(legacy.index == dictionary)
        #expect(legacy.encounteredSongIDs == songs)
        let decoded = try JSONDecoder().decode(SourceScanResumeState.self, from: data)
        #expect(decoded == state)
        #expect(decoded.isUsable)
        let plain = SourceScanResumeState(pendingDirectories: ["/music/b"], encounteredSongIDs: songs, index: dictionary)
        #expect(plain == state)
        let fromLegacy = try JSONDecoder().decode(
            SourceScanResumeState.self,
            from: JSONEncoder().encode(legacy)
        )
        #expect(fromLegacy == state)
    }

    @Test("Dictionary accessors still read and write in place")
    func dictionaryAccessors() {
        let (log, dictionary, songs) = sampleLog(seed: 4, segments: 3)
        var state = SourceScanResumeState(pendingDirectories: [], walkLog: log)
        #expect(state.index == dictionary)
        #expect(state.encounteredSongIDs == songs)
        var random = WalkTestRandom(seed: 2)
        let item = WalkTestFixtures.item(key: "added", version: 5, random: &random)
        state.index["added"] = item
        state.encounteredSongIDs.insert("added-song")
        var expected = dictionary
        expected["added"] = item
        #expect(state.index == expected)
        #expect(state.encounteredSongIDs == songs.union(["added-song"]))
        #expect(state.walkLog.indexDictionary == expected)
        state.index = [:]
        #expect(state.index.isEmpty)
        #expect(state.encounteredSongIDs == songs.union(["added-song"]))
    }

    @Test("Segment files are written once, read back exactly, and rejected when missing or altered")
    func segmentFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("walk-segments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (log, dictionary, songs) = sampleLog(seed: 8, segments: 5)
        #expect(!log.segments.isEmpty)
        let state = SourceScanResumeState(pendingDirectories: ["/music/c"], walkLog: log)
        let store = ScanResumeSegmentStore(directory: directory)
        let encoder = JSONEncoder()
        encoder.userInfo[.scanResumeSegmentStore] = store
        store.beginPass()
        let data = try encoder.encode(state)
        let referenced = store.endPass()
        #expect(referenced == Set(log.segments.map(\.id)))
        let version = try JSONDecoder().decode(VersionOnly.self, from: data)
        #expect(version.schemaVersion == SourceScanResumeState.segmentedSchemaVersion)

        // 冷启动:新的存储实例按清单读回。
        let decoder = JSONDecoder()
        decoder.userInfo[.scanResumeSegmentStore] = ScanResumeSegmentStore(directory: directory)
        let decoded = try decoder.decode(SourceScanResumeState.self, from: data)
        #expect(decoded.isUsable)
        #expect(decoded == state)
        #expect(decoded.index == dictionary)
        #expect(decoded.encounteredSongIDs == songs)

        // 再编一次:段已在盘上,不重写。
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let dates = try files.map {
            try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.modificationDate] as? Date
        }
        store.beginPass()
        _ = try encoder.encode(decoded)
        _ = store.endPass()
        let filesAgain = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        let datesAgain = try filesAgain.map {
            try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($0).path)[.modificationDate] as? Date
        }
        #expect(filesAgain == files)
        #expect(datesAgain == dates)

        // 没有段存储(旧版本、或别的解码方)就不可用,不会拿半份进度续扫。
        let withoutStore = try JSONDecoder().decode(SourceScanResumeState.self, from: data)
        #expect(!withoutStore.isUsable)

        // 段文件被改过:按不可用处理。
        let victim = store.fileURL(for: log.segments[0].id)
        var bytes = try Data(contentsOf: victim)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: victim)
        let tamperedDecoder = JSONDecoder()
        tamperedDecoder.userInfo[.scanResumeSegmentStore] = ScanResumeSegmentStore(directory: directory)
        let tampered = try tamperedDecoder.decode(SourceScanResumeState.self, from: data)
        #expect(!tampered.isUsable)

        // 不在保留集合里的段被删掉。
        store.removeFiles(keeping: Set(log.segments.dropFirst().map(\.id)))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(remaining.count == log.segments.count - 1)
    }

    @Test("The checkpoint store keeps walk segments beside the JSON and collects stale ones")
    func checkpointStoreSegments() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("checkpoint-segments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("scan-checkpoints.json")
        let segmentDirectory = ScanCheckpointFileStore.segmentDirectory(for: url)
        let store = ScanCheckpointFileStore(checkpointURL: url, initialCheckpoints: [:])
        var (log, dictionary, _) = sampleLog(seed: 21, segments: 6)
        func checkpoint(_ log: SourceScanWalkLog, _ stamp: Double) -> ScanCheckpoint {
            ScanCheckpoint(
                phase: .scanning, intent: .fullScan, directories: ["/music"], songs: [],
                totalCount: 0, currentFile: "", updatedAt: Date(timeIntervalSince1970: stamp),
                directoryState: SourceScanResumeState(pendingDirectories: ["/music/x"], walkLog: log)
            )
        }
        func segmentFiles() throws -> Set<String> {
            Set(try FileManager.default.contentsOfDirectory(atPath: segmentDirectory.path))
        }
        func names(_ log: SourceScanWalkLog) -> Set<String> {
            Set(log.segments.map { $0.id.uuidString.lowercased() + ".pmwalk" })
        }
        let firstLog = log
        let firstBytes = try await store.replace(with: ["source": checkpoint(firstLog, 1)])
        #expect(try segmentFiles() == names(firstLog))
        let jsonSize = try Data(contentsOf: url).count
        #expect(jsonSize < 40_000, "the index lives in segment files, not in the JSON")
        // 写盘量算上段文件,写入间隔才会按真实写盘量放宽;段已在盘上的再写只算 JSON。
        #expect(firstBytes > jsonSize)
        let repeatBytes = try await store.replace(with: ["source": checkpoint(firstLog, 1.5)])
        #expect(repeatBytes == jsonSize)
        let loaded = ScanCheckpointFileStore.load(from: url)
        #expect(loaded["source"]?.directoryState == checkpoint(firstLog, 1).directoryState)
        #expect(loaded["source"]?.directoryState?.index == dictionary)

        var random = WalkTestRandom(seed: 5)
        let item = WalkTestFixtures.item(key: "late", version: 77, random: &random)
        log.updateValue(item, forKey: "late")
        dictionary["late"] = item
        log.consolidate()
        try await store.replace(with: ["source": checkpoint(log, 2)])
        // 上一份写成了备份,它引用的段要留着。
        #expect(try segmentFiles() == names(firstLog).union(names(log)))
        try await store.replace(with: ["source": checkpoint(log, 3)])
        #expect(try segmentFiles() == names(log))
        let reloaded = ScanCheckpointFileStore.load(from: url)
        #expect(reloaded["source"]?.directoryState?.index == dictionary)
        #expect(reloaded["source"]?.directoryState?.isUsable == true)

        // 冷启动读回的状态交给新的存储实例,再写不必重写段文件,旧段照常回收。
        let coldStore = ScanCheckpointFileStore(checkpointURL: url)
        try await coldStore.remove(sourceID: "source")
        #expect(try segmentFiles() == names(log))
        try await coldStore.remove(sourceID: "source")
        #expect(try segmentFiles().isEmpty)
    }
}

@Suite("Directory pruning and snapshot diff match the dictionary implementations")
struct SourceSyncCompactPolicyEquivalenceTests {
    private func tree(seed: UInt64) -> (baseline: [String: SourceSyncIndexedItem], current: [String: SourceSyncIndexedItem], deleted: Set<String>) {
        var random = WalkTestRandom(seed: seed)
        var baseline: [String: SourceSyncIndexedItem] = [:]
        var directoryPaths = ["root"]
        for index in 0..<40 {
            let parent = directoryPaths[Int.random(in: 0..<directoryPaths.count, using: &random)]
            let path = "\(parent)/d\(index)"
            baseline["dir-\(index)"] = SourceSyncIndexedItem(
                stableKey: "dir-\(index)", path: path, parentPath: parent, isDirectory: true,
                size: 0, modifiedDate: nil, revision: nil
            )
            directoryPaths.append(path)
        }
        for index in 0..<200 {
            let parent = directoryPaths[Int.random(in: 0..<directoryPaths.count, using: &random)]
            baseline["file-\(index)"] = SourceSyncIndexedItem(
                stableKey: "file-\(index)", path: "\(parent)/f\(index)", parentPath: parent, isDirectory: false,
                songIDs: ["song-\(index)"], size: 1, modifiedDate: nil, revision: nil
            )
        }
        var current = baseline
        var deleted = Set<String>()
        for key in baseline.keys.sorted() {
            switch Int.random(in: 0..<12, using: &random) {
            case 0:
                current[key] = nil
                deleted.insert(key)
            case 1:
                current[key]?.parentPath = directoryPaths[Int.random(in: 0..<directoryPaths.count, using: &random)]
            case 2:
                deleted.insert(key)
            default:
                break
            }
        }
        return (baseline, current, deleted)
    }

    @Test("Pruning policies match the previous algorithm for dictionaries and compact indexes")
    func pruningMatchesReference() {
        for seed in 1...40 {
            let (baseline, current, deleted) = tree(seed: UInt64(seed))
            let expectedConfirmed = ReferencePruning.confirmedDeletedDirectoryPaths(index: baseline, deletedKeys: deleted)
            let confirmedFromDictionary = SourceSyncDirectoryPruningPolicy.confirmedDeletedDirectoryPaths(
                index: baseline, deletedKeys: deleted
            )
            let confirmedFromIndex = SourceSyncDirectoryPruningPolicy.confirmedDeletedDirectoryPaths(
                index: SourceSyncIndex(baseline), deletedKeys: deleted
            )
            #expect(confirmedFromDictionary == expectedConfirmed, "seed \(seed)")
            #expect(confirmedFromIndex == expectedConfirmed, "seed \(seed)")
            let expectedOrphans = ReferencePruning.orphanedDescendantKeys(baseline: baseline, current: current)
            let orphansFromDictionary = SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
                baseline: baseline, current: current
            )
            let orphansFromIndex = SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
                baseline: SourceSyncIndex(baseline), current: SourceSyncIndex(current)
            )
            #expect(orphansFromDictionary == expectedOrphans, "seed \(seed)")
            #expect(orphansFromIndex == expectedOrphans, "seed \(seed)")
        }
    }

    private func baiduScenario(seed: UInt64) -> (
        previous: [String: SourceSyncIndexedItem],
        current: [SourceSyncIndexedItem],
        live: Set<String>,
        aliases: [String: String],
        missing: [String: Int]
    ) {
        var random = WalkTestRandom(seed: seed)
        var previous: [String: SourceSyncIndexedItem] = [:]
        var current: [SourceSyncIndexedItem] = []
        var live: Set<String> = ["/Music"]
        var aliases: [String: String] = [:]
        var missing: [String: Int] = [:]
        var nextFSID: Int64 = 10_000 + Int64(seed) * 1_000
        func newKey() -> String {
            nextFSID += 1
            return BaiduSnapshotIdentity.stableKey(fsID: nextFSID)
        }
        let folders = (0..<6).map { "/Music/Album \($0)" }
        for folder in folders where Int.random(in: 0..<5, using: &random) > 0 { live.insert(folder) }
        for (offset, folder) in folders.enumerated() {
            let key = newKey()
            let directory = SourceSyncIndexedItem(
                stableKey: key, path: folder, displayName: "Album \(offset)", parentPath: "/Music",
                isDirectory: true, size: 0, modifiedDate: nil, revision: nil, seenEpoch: 2
            )
            previous[key] = directory
            if Int.random(in: 0..<6, using: &random) > 0 {
                var observed = directory
                observed.seenEpoch = 3
                if Int.random(in: 0..<5, using: &random) == 0 { observed.displayName = "Renamed \(offset)" }
                current.append(observed)
            }
        }
        for index in 0..<80 {
            let folder = folders[Int.random(in: 0..<folders.count, using: &random)]
            let path = "\(folder)/Track \(index).flac"
            let legacy = Int.random(in: 0..<4, using: &random) == 0
            let key = legacy ? BaiduSnapshotIdentity.legacyPathKey(path) : newKey()
            let revision = Int.random(in: 0..<5, using: &random) == 0 ? nil : "md5-\(index % 60)"
            let songIDs = Int.random(in: 0..<6, using: &random) == 0 ? [] : ["song-\(index)"]
            let old = SourceSyncIndexedItem(
                stableKey: key, path: path, displayName: "Track \(index).flac", parentPath: folder,
                isDirectory: false, songIDs: songIDs, size: Int64(100 + index % 7), modifiedDate: nil,
                revision: revision, seenEpoch: 2
            )
            previous[key] = old
            if Int.random(in: 0..<5, using: &random) == 0 { missing[key] = 1 }
            switch Int.random(in: 0..<9, using: &random) {
            case 0:
                break // 这轮没出现
            case 1:
                // 原地替换:同路径、新 fs_id。
                var replaced = old
                replaced.stableKey = newKey()
                replaced.songIDs = []
                replaced.seenEpoch = 3
                current.append(replaced)
            case 2:
                // 移到别的目录。
                var moved = old
                if legacy { moved.stableKey = newKey() }
                let target = folders[Int.random(in: 0..<folders.count, using: &random)]
                moved.path = "\(target)/Track \(index).flac"
                moved.parentPath = target
                moved.songIDs = []
                moved.seenEpoch = 3
                current.append(moved)
            case 3:
                // 改过内容。
                var changed = old
                if legacy { changed.stableKey = newKey() }
                changed.revision = "md5-new-\(index)"
                changed.songIDs = []
                changed.seenEpoch = 3
                current.append(changed)
            case 4:
                // 换了身份,别名指过去。
                var renamed = old
                renamed.stableKey = newKey()
                renamed.songIDs = []
                renamed.seenEpoch = 3
                aliases[key] = renamed.stableKey
                current.append(renamed)
            default:
                var same = old
                if legacy { same.stableKey = newKey() }
                same.songIDs = []
                same.seenEpoch = 3
                current.append(same)
            }
        }
        for index in 0..<10 {
            let folder = folders[Int.random(in: 0..<folders.count, using: &random)]
            current.append(SourceSyncIndexedItem(
                stableKey: newKey(), path: "\(folder)/New \(index).flac", displayName: "New \(index).flac",
                parentPath: folder, isDirectory: false, size: 50, modifiedDate: nil,
                revision: "md5-\(index * 6)", seenEpoch: 3
            ))
        }
        return (previous, current, live, aliases, missing)
    }

    @Test("Snapshot diff on the compact index matches the dictionary implementation")
    func baiduPlanMatchesReference() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for seed in 1...60 {
            let scenario = baiduScenario(seed: UInt64(seed))
            let expected = try LegacyBaiduSnapshotDiffReference.plan(
                previousIndex: scenario.previous,
                currentItems: scenario.current,
                liveDirectories: scenario.live,
                identityAliases: scenario.aliases,
                missingStableKeys: scenario.missing,
                now: now
            )
            let actual = try BaiduSnapshotDiffPolicy.plan(
                previousIndex: SourceSyncIndex(scenario.previous),
                currentItems: scenario.current,
                liveDirectories: scenario.live,
                identityAliases: scenario.aliases,
                missingStableKeys: scenario.missing,
                now: now
            )
            #expect(actual.reconciledIndex.dictionary == expected.reconciledIndex, "seed \(seed)")
            #expect(actual.changedParentPaths == expected.changedParentPaths, "seed \(seed)")
            #expect(actual.deletedStableKeys == expected.deletedStableKeys, "seed \(seed)")
            #expect(actual.identityAliases == expected.identityAliases, "seed \(seed)")
            #expect(actual.missingStableKeys == expected.missingStableKeys, "seed \(seed)")
            #expect(actual.reconciliation?.kind == expected.reconciliation?.kind, "seed \(seed)")
            #expect(actual.reconciliation?.detectedAt == expected.reconciliation?.detectedAt, "seed \(seed)")
            let actualUnresolved = Set(actual.reconciliation?.unresolvedStableKeys ?? [])
            let expectedUnresolved = Set(expected.reconciliation?.unresolvedStableKeys ?? [])
            #expect(actualUnresolved == expectedUnresolved, "seed \(seed)")

            for item in scenario.current {
                let compact = BaiduSnapshotDiffPolicy.migrationMatch(for: item, previousIndex: SourceSyncIndex(scenario.previous))
                let reference = LegacyBaiduSnapshotDiffReference.migrationMatch(for: item, previousIndex: scenario.previous)
                #expect(compact?.key == reference?.key, "seed \(seed) \(item.stableKey)")
                #expect(compact?.item == reference?.item, "seed \(seed) \(item.stableKey)")
            }
        }
    }
}

/// 改写之前的两条剪枝规则,原样留作对照。
enum ReferencePruning {
    static func confirmedDeletedDirectoryPaths(
        index: [String: SourceSyncIndexedItem],
        deletedKeys: Set<String>
    ) -> Set<String> {
        var pending = deletedKeys.compactMap { key -> String? in
            guard let item = index[key], item.isDirectory else { return nil }
            return item.path
        }
        var children: [String: [String]] = [:]
        for item in index.values where item.isDirectory {
            if let parent = item.parentPath { children[parent, default: []].append(item.path) }
        }
        var result = Set<String>()
        while let path = pending.popLast() {
            guard result.insert(path).inserted else { continue }
            pending.append(contentsOf: children[path] ?? [])
        }
        return result
    }

    static func orphanedDescendantKeys(
        baseline: [String: SourceSyncIndexedItem],
        current: [String: SourceSyncIndexedItem]
    ) -> Set<String> {
        let survivingDirectoryPaths = Set(current.values.lazy.filter(\.isDirectory).map(\.path))
        var pending = baseline.compactMap { key, item -> String? in
            guard item.isDirectory, current[key] == nil,
                  !survivingDirectoryPaths.contains(item.path) else { return nil }
            return item.path
        }
        var children: [String: [String]] = [:]
        for (key, item) in current {
            if let parent = item.parentPath { children[parent, default: []].append(key) }
        }
        var visited = Set<String>()
        var removed = Set<String>()
        while let path = pending.popLast() {
            guard visited.insert(path).inserted else { continue }
            for key in children[path] ?? [] {
                guard removed.insert(key).inserted, let item = current[key] else { continue }
                if item.isDirectory { pending.append(item.path) }
            }
        }
        return removed
    }
}

// 改写之前(按字典逐条改写)的百度快照差分,原样留作对照:新实现在随机场景下必须与它逐字段相同。
struct LegacyBaiduDiffResult {
    var reconciledIndex: [String: SourceSyncIndexedItem]
    var changedParentPaths: Set<String>
    var deletedStableKeys: Set<String>
    var identityAliases: [String: String]
    var missingStableKeys: [String: Int]
    var reconciliation: SourceSyncReconciliation?
}

enum LegacyBaiduSnapshotDiffReference {
    static let deletionConfirmationCount = 2

    static func plan(
        previousIndex: [String: SourceSyncIndexedItem],
        currentItems: [SourceSyncIndexedItem],
        liveDirectories: Set<String>,
        identityAliases: [String: String] = [:],
        missingStableKeys: [String: Int] = [:],
        now: Date = Date()
    ) throws -> LegacyBaiduDiffResult {
        var currentByKey: [String: SourceSyncIndexedItem] = [:]
        currentByKey.reserveCapacity(currentItems.count)
        for item in currentItems {
            guard BaiduSnapshotIdentity.fsID(from: item.stableKey) != nil else {
                throw BaiduSnapshotDiffError.missingStableIdentity(item.path)
            }
            guard currentByKey.updateValue(item, forKey: item.stableKey) == nil else {
                throw BaiduSnapshotDiffError.duplicateStableKey(item.stableKey)
            }
        }

        var reconciledIndex = previousIndex
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var aliases = identityAliases
        var nextMissing = missingStableKeys
        var claimedPreviousKeys: Set<String> = []

        let legacyEntries = previousIndex.filter { key, _ in
            key.hasPrefix("path:")
        }

        for currentValue in currentByKey.values.sorted(by: { $0.stableKey < $1.stableKey }) {
            let match = migrationMatch(
                for: currentValue,
                previousIndex: previousIndex,
                legacyEntries: legacyEntries,
                aliases: aliases,
                claimedPreviousKeys: claimedPreviousKeys
            ) ?? exactStrongIdentityReplacementMatch(
                for: currentValue,
                previousIndex: previousIndex,
                currentByKey: currentByKey,
                claimedPreviousKeys: claimedPreviousKeys
            )

            var current = currentValue
            if let match {
                claimedPreviousKeys.insert(match.key)
                current.songIDs = match.item.songIDs
                current.seenEpoch = max(current.seenEpoch, match.item.seenEpoch)
                nextMissing[match.key] = nil
                nextMissing[current.stableKey] = nil
                if match.key != current.stableKey {
                    aliases[match.key] = current.stableKey
                    reconciledIndex[match.key] = nil
                    if BaiduSnapshotIdentity.fsID(from: match.key) != nil {
                        insertLiveParent(
                            match.item.parentPath,
                            into: &changedParents,
                            live: liveDirectories
                        )
                        insertLiveParent(
                            current.parentPath,
                            into: &changedParents,
                            live: liveDirectories
                        )
                    }
                }
                if entryChanged(previous: match.item, current: current) {
                    insertLiveParent(match.item.parentPath, into: &changedParents, live: liveDirectories)
                    insertLiveParent(current.parentPath, into: &changedParents, live: liveDirectories)
                    if current.isDirectory, current.path != match.item.path {
                        insertLiveParent(current.path, into: &changedParents, live: liveDirectories)
                    }
                }
            } else {
                insertLiveParent(current.parentPath, into: &changedParents, live: liveDirectories)
                if current.isDirectory {
                    insertLiveParent(current.path, into: &changedParents, live: liveDirectories)
                }
            }
            reconciledIndex[current.stableKey] = current
        }

        var unresolved: Set<String> = []
        for (key, previous) in previousIndex.sorted(by: { $0.key < $1.key }) {
            if claimedPreviousKeys.contains(key) || currentByKey[key] != nil {
                continue
            }

            // Rows without a Song ID — directories (whose children are keyed
            // independently) and the artist-image files indexed for automatic
            // artist artwork — carry no user-owned identity. They are dropped
            // immediately without risking playlists or history, and never
            // held behind the song-deletion confirmation. A vanished image
            // re-lists its parent so the artwork catalogue follows.
            if previous.songIDs.isEmpty {
                reconciledIndex[key] = nil
                nextMissing[key] = nil
                if !previous.isDirectory {
                    insertLiveParent(previous.parentPath, into: &changedParents, live: liveDirectories)
                }
                continue
            }

            let observations = (missingStableKeys[key] ?? 0) + 1
            if observations >= deletionConfirmationCount {
                // Keep the row in the reconciliation baseline until
                // ConnectorScanner consumes its song IDs and removes it.
                deletedKeys.insert(key)
                nextMissing[key] = nil
                insertLiveParent(previous.parentPath, into: &changedParents, live: liveDirectories)
            } else {
                nextMissing[key] = observations
                unresolved.insert(key)
            }
        }

        let reconciliation = unresolved.isEmpty ? nil : SourceSyncReconciliation(
            kind: .baiduIdentityAndDeletionConfirmation,
            unresolvedStableKeys: Array(unresolved),
            detectedAt: now
        )
        return LegacyBaiduDiffResult(
            reconciledIndex: reconciledIndex,
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            identityAliases: aliases,
            missingStableKeys: nextMissing,
            reconciliation: reconciliation
        )
    }

    /// Used by a user-selected deep scan that encounters a path-keyed legacy
    /// index before the first snapshot migration has completed.
    static func migrationMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: [String: SourceSyncIndexedItem],
        claimedPreviousKeys: Set<String> = []
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        migrationMatch(
            for: current,
            previousIndex: previousIndex,
            legacyEntries: previousIndex.filter { $0.key.hasPrefix("path:") },
            aliases: [:],
            claimedPreviousKeys: claimedPreviousKeys
        )
    }

    private static func migrationMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: [String: SourceSyncIndexedItem],
        legacyEntries: @autoclosure () -> [String: SourceSyncIndexedItem],
        aliases: [String: String],
        claimedPreviousKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        if let direct = previousIndex[current.stableKey],
           !claimedPreviousKeys.contains(current.stableKey) {
            return (current.stableKey, direct)
        }

        let exactPathKey = BaiduSnapshotIdentity.legacyPathKey(current.path)
        if let exact = previousIndex[exactPathKey],
           exact.path == current.path,
           !claimedPreviousKeys.contains(exactPathKey) {
            return (exactPathKey, exact)
        }

        if let aliasedKey = aliases.first(where: { $0.value == current.stableKey })?.key,
           let aliased = previousIndex[aliasedKey],
           !claimedPreviousKeys.contains(aliasedKey) {
            return (aliasedKey, aliased)
        }

        guard !current.isDirectory,
              let revision = normalizedRevision(current.revision) else {
            return nil
        }
        let candidates = legacyEntries().filter { key, item in
            !claimedPreviousKeys.contains(key)
                && !item.isDirectory
                && normalizedRevision(item.revision) == revision
                && item.size == current.size
                && !item.songIDs.isEmpty
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        return (candidate.key, candidate.value)
    }

    /// Baidu can replace a file in place and assign it a new fs_id. A complete
    /// snapshot proves that the old identity disappeared globally, so an
    /// otherwise unique file at the exact same path can inherit the existing
    /// Song ID. Ambiguous paths and directories remain fail-closed.
    private static func exactStrongIdentityReplacementMatch(
        for current: SourceSyncIndexedItem,
        previousIndex: [String: SourceSyncIndexedItem],
        currentByKey: [String: SourceSyncIndexedItem],
        claimedPreviousKeys: Set<String>
    ) -> (key: String, item: SourceSyncIndexedItem)? {
        guard !current.isDirectory,
              BaiduSnapshotIdentity.fsID(from: current.stableKey) != nil else {
            return nil
        }

        let livePathMatches = currentByKey.values.filter {
            !$0.isDirectory && $0.path == current.path
        }
        guard livePathMatches.count == 1 else { return nil }

        let candidates = previousIndex.filter { key, item in
            key != current.stableKey
                && BaiduSnapshotIdentity.fsID(from: key) != nil
                && currentByKey[key] == nil
                && !claimedPreviousKeys.contains(key)
                && !item.isDirectory
                && !item.songIDs.isEmpty
                && item.path == current.path
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return nil
        }
        return (candidate.key, candidate.value)
    }

    private static func entryChanged(
        previous: SourceSyncIndexedItem,
        current: SourceSyncIndexedItem
    ) -> Bool {
        previous.path != current.path
            || previous.parentPath != current.parentPath
            || previous.displayName != current.displayName
            || previous.isDirectory != current.isDirectory
            || previous.size != current.size
            || previous.modifiedDate != current.modifiedDate
            || normalizedRevision(previous.revision) != normalizedRevision(current.revision)
            || previous.sidecarFingerprint != current.sidecarFingerprint
    }

    private static func normalizedRevision(_ revision: String?) -> String? {
        guard let value = revision?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value.lowercased()
    }

    private static func insertLiveParent(
        _ path: String?,
        into result: inout Set<String>,
        live: Set<String>
    ) {
        guard let path, live.contains(path) else { return }
        result.insert(path)
    }
}

