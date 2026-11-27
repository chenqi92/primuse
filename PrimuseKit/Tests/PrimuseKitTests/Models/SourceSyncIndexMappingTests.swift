import CryptoKit
import Foundation
import Testing
@testable import PrimuseKit

/// 可复现的随机数(SplitMix64)。
struct SyncIndexSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// SMB 一类目录源的随机索引:深层中文/日文/越南文路径、NFD 写法的名字、目录行、
/// 多首歌一行(CUE)、没有歌的旁挂文件、各种可选字段。
enum RandomSyncIndexFixture {
    static let words = ["周杰伦", "范特西", "七里香", "晴天", "Les Mise\u{301}rables", "Tiến Lên", "ジャズ",
                        "가요", "Live 2024", "Disc 1", "精选 [FLAC]", "A–Z “best”", "Ελληνικά", "Кино"]

    static func make(entries: Int, seed: UInt64) -> [String: SourceSyncIndexedItem] {
        var random = SyncIndexSeededGenerator(seed: seed)
        var index: [String: SourceSyncIndexedItem] = [:]
        var directories: [String] = ["/Music"]
        index["path:/music"] = SourceSyncIndexedItem(
            stableKey: "path:/music", path: "/Music", displayName: "Music", parentPath: "/",
            isDirectory: true, size: 0, modifiedDate: nil, revision: nil
        )
        var serial = 0
        while index.count < entries {
            serial += 1
            let parent = directories[Int.random(in: 0..<directories.count, using: &random)]
            let word = words[Int.random(in: 0..<words.count, using: &random)]
            if directories.count < max(4, entries / 12), Int.random(in: 0..<10, using: &random) == 0 {
                let path = "\(parent)/\(word) \(serial)"
                directories.append(path)
                index["path:" + path.lowercased()] = SourceSyncIndexedItem(
                    stableKey: "path:" + path.lowercased(), path: path, displayName: "\(word) \(serial)",
                    parentPath: parent, isDirectory: true, size: 0,
                    modifiedDate: Bool.random(using: &random) ? Date(timeIntervalSince1970: Double(serial)) : nil,
                    revision: nil, seenEpoch: Int64.random(in: 0...5, using: &random)
                )
                continue
            }
            let name = "\(String(format: "%02d", serial % 100)) \(word) \(serial).flac"
            let path = "\(parent)/\(name)"
            let key = "path:" + path.lowercased()
            let songCount = [1, 1, 1, 1, 0, 3][Int.random(in: 0..<6, using: &random)]
            let songs = (0..<songCount).map { offset in
                String(format: "%016llx%016llx", UInt64(serial) &* 0x9E37_79B9_7F4A_7C15, UInt64(offset + 1))
            }
            index[key] = SourceSyncIndexedItem(
                stableKey: Int.random(in: 0..<50, using: &random) == 0 ? "provider:\(serial)" : key,
                path: path,
                displayName: Int.random(in: 0..<20, using: &random) == 0 ? nil : name,
                parentPath: parent,
                isDirectory: false,
                songIDs: songs,
                size: Int64.random(in: 0...2_000_000_000, using: &random),
                modifiedDate: Bool.random(using: &random)
                    ? Date(timeIntervalSinceReferenceDate: Double.random(in: 0...1e9, using: &random)) : nil,
                revision: Int.random(in: 0..<4, using: &random) == 0 ? "etag-\(serial)" : nil,
                sidecarFingerprint: Int.random(in: 0..<3, using: &random) == 0 ? "lrc:\(serial)|cover" : nil,
                seenEpoch: Int64.random(in: 0...9, using: &random)
            )
        }
        return index
    }

    /// 条目所有字段的字节(字符串按 UTF-8 原样),用来比「逐字节相同」。
    static func bytes(_ key: String, _ item: SourceSyncIndexedItem) -> [UInt8] {
        var result: [UInt8] = []
        func add(_ value: String?) {
            guard let value else { result.append(0xFF); return }
            result.append(contentsOf: Array(value.utf8))
            result.append(0)
        }
        add(key)
        add(item.stableKey)
        add(item.path)
        add(item.displayName)
        add(item.parentPath)
        result.append(item.isDirectory ? 1 : 0)
        for id in item.songIDs { add(id) }
        withUnsafeBytes(of: item.size) { result.append(contentsOf: $0) }
        withUnsafeBytes(of: item.modifiedDate?.timeIntervalSinceReferenceDate.bitPattern ?? 0) {
            result.append(contentsOf: $0)
        }
        add(item.revision)
        add(item.sidecarFingerprint)
        withUnsafeBytes(of: item.seenEpoch) { result.append(contentsOf: $0) }
        return result
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("primuse-sync-mapping-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeMappable(_ index: SourceSyncIndex, to url: URL) throws -> SourceSyncIndex.BinarySummary {
    let encoded = try index.binaryData(mappable: true)
    try encoded.data.write(to: url)
    return encoded.summary
}

/// 改一份文件里的几个字节,再把末尾的 SHA-256 重新算好(模拟写入方的错误,而不是磁盘损坏)。
private func rewrite(_ url: URL, _ edit: (inout Data) -> Void) throws {
    var data = try Data(contentsOf: url)
    edit(&data)
    let payload = data.count - 32
    let digest = Data(SHA256.hash(data: data.prefix(payload)))
    data.replaceSubrange(payload..<data.count, with: digest)
    try data.write(to: url)
}

private func header(_ data: Data, _ offset: Int) -> UInt64 {
    data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
}

@Suite("Memory-mapped source sync index")
struct SourceSyncIndexMappingTests {
    @Test("The stable key hash is fixed and agrees with canonical equivalence")
    func stableHashIsFixedAndCanonical() {
        // 算法写进了文件:这些值变了说明算法变了,要加 `SourceSyncKeyHash.algorithm`。
        #expect(SourceSyncKeyHash.hash(of: "") == 0xA4AB_2EEA)
        #expect(SourceSyncKeyHash.hash(of: "a") == 0x57DB_4C68)
        #expect(SourceSyncKeyHash.hash(of: "12345678") == 0xDB71_9FB1)
        #expect(SourceSyncKeyHash.hash(of: "path:/music/周杰伦/晴天.flac") == 0x39F7_0B21)
        #expect(SourceSyncKeyHash.hash(of: "hierarchy-song:0123456789abcdef0123456789abcdef") == 0x99D4_42A9)
        #expect(SourceSyncKeyHash.hash(of: "Tiến Lên") == 0x3A16_B544)
        let equivalent: [(String, String)] = [
            ("/Books/Les Mise\u{301}rables", "/Books/Les Mis\u{E9}rables"),
            ("\u{212A}elvin", "Kelvin"),
            ("か\u{3099}", "が"),
            ("\u{1100}\u{1161}", "가"),
            ("Tie\u{302}\u{301}n", "Tiến"),
            ("A\u{30A}", "\u{212B}"),
        ]
        for (left, right) in equivalent {
            #expect(left == right)
            #expect(SourceSyncKeyHash.hash(of: left) == SourceSyncKeyHash.hash(of: right), "\(left)")
        }
        #expect(SourceSyncKeyHash.hash(of: "/Books/Les Mis\u{E9}rables") == 0xF22F_7712)
        // 前缀 + 后缀两段算的与整串算的相同。
        let suffix = Array("/music/周杰伦/晴天.flac".utf8)
        suffix.withUnsafeBufferPointer { bytes in
            #expect(SourceSyncKeyHash.hash(prefix: Array("path:".utf8), suffix: bytes) == 0x39F7_0B21)
        }
    }

    @Test("A mapped index answers byte-for-byte like the heap index", arguments: [1 as UInt64, 7, 2_026])
    func mappedMatchesHeap(seed: UInt64) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var dictionary = RandomSyncIndexFixture.make(entries: 3_000, seed: seed)
        // 改过、删过的索引(带作废行)也写得出能映射的文件。
        var heap = SourceSyncIndex(dictionary)
        var random = SyncIndexSeededGenerator(seed: seed ^ 0xABCDEF)
        for key in dictionary.keys.sorted().shuffled(using: &random).prefix(200) {
            if Bool.random(using: &random) {
                dictionary.removeValue(forKey: key)
                heap.removeValue(forKey: key)
            } else {
                var item = dictionary[key]!
                item.revision = "edited-\(Int.random(in: 0...99, using: &random))"
                dictionary[key] = item
                heap[key] = item
            }
        }
        let url = directory.appendingPathComponent("index.index")
        let summary = try writeMappable(heap, to: url)
        let mapped = try SourceSyncIndex.mapFile(at: url, expectedSHA256: summary.sha256)
        #expect(mapped.isMemoryMapped)
        #expect(!heap.isMemoryMapped)
        #expect(mapped.heapByteCount == 0)
        #expect(mapped.count == heap.count)
        #expect(mapped == heap)
        #expect(heap == mapped)
        #expect(mapped.dictionary == dictionary)

        // 遍历顺序与每个字段的字节都相同。
        let heapRows = heap.map { RandomSyncIndexFixture.bytes($0.key, $0.value) }
        let mappedRows = mapped.map { RandomSyncIndexFixture.bytes($0.key, $0.value) }
        #expect(heapRows == mappedRows)
        #expect(Array(heap.keys).map { Array($0.utf8) } == Array(mapped.keys).map { Array($0.utf8) })
        #expect(Array(heap.values) == Array(mapped.values))
        #expect(Array(heap.directoryItems) == Array(mapped.directoryItems))
        #expect(heap.hasDirectoryEntries == mapped.hasDirectoryEntries)

        // 存在的、规范等价写法的、不存在的键,查到的都一样。
        for (key, item) in dictionary {
            let found = mapped[key]
            #expect(found == item)
            #expect(found.map { RandomSyncIndexFixture.bytes(key, $0) } == heap[key].map {
                RandomSyncIndexFixture.bytes(key, $0)
            })
            let decomposed = key.decomposedStringWithCanonicalMapping
            #expect(mapped[decomposed] == heap[decomposed])
            #expect(mapped.contains(key: key))
        }
        for probe in 0..<500 {
            let missing = "path:/music/missing \(probe) \(RandomSyncIndexFixture.words[probe % 14])"
            #expect(mapped[missing] == nil)
            #expect(heap[missing] == nil)
        }
        let parents = Set(dictionary.values.compactMap(\.parentPath).shuffled(using: &random).prefix(20))
        #expect(mapped.entries(withParentIn: parents) == heap.entries(withParentIn: parents))
        #expect(AlbumArtistFolderIndex.parents(fromSyncIndex: mapped)
            == AlbumArtistFolderIndex.parents(fromSyncIndex: dictionary))
        #expect(SpokenWordFolderTopology.directoryParents(fromSyncIndex: mapped)
            == SpokenWordFolderTopology.directoryParents(fromSyncIndex: dictionary))

        // 映射的那份再写一遍(两种格式)仍是同一份内容。
        let rewritten = try mapped.binaryData(mappable: true)
        #expect(rewritten.data == (try heap.binaryData(mappable: true).data))
        #expect(try SourceSyncIndex.decodeBinary(rewritten.data) == heap)
        #expect(try SourceSyncIndex.decodeBinary(mapped.binaryData().data) == heap)
    }

    @Test("Every real source shape maps and reads back exactly")
    func everyShapeMaps() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, dictionary) in SourceSyncIndexFixtures.allShapes {
            let index = SourceSyncIndex(dictionary)
            let url = directory.appendingPathComponent("\(UUID().uuidString).index")
            let summary = try writeMappable(index, to: url)
            let mapped = try SourceSyncIndex.mapFile(at: url, expectedSHA256: summary.sha256)
            #expect(mapped.dictionary == dictionary, "\(name)")
            #expect(mapped.count == dictionary.count, "\(name)")
            for (key, item) in dictionary { #expect(mapped[key] == item, "\(name) \(key)") }
        }
        // 规范等价的查找在映射的那份上照样成立。
        let url = directory.appendingPathComponent("equivalence.index")
        _ = try writeMappable(SourceSyncIndex(SourceSyncIndexFixtures.spokenWord()), to: url)
        let mapped = try SourceSyncIndex.mapFile(at: url)
        #expect(mapped["/Books/Les Mis\u{E9}rables"]?.displayName == "Les Mise\u{301}rables")
        let precomposedKey = "/Books/Les Mis\u{E9}rables/Chapitre 3.m4b"
        #expect(mapped[precomposedKey]?.songIDs == [MusicIDs.song(903)])
    }

    @Test("Mutating a mapped index copies it to the heap and leaves the mapping untouched")
    func mutationCopiesToHeap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = SourceSyncIndexFixtures.server(songs: 400)
        let url = directory.appendingPathComponent("server.index")
        _ = try writeMappable(SourceSyncIndex(dictionary), to: url)
        let mapped = try SourceSyncIndex.mapFile(at: url)
        var edited = mapped
        let key = "hierarchy-song:\(MusicIDs.song(3))"
        var item = try #require(edited[key])
        item.displayName = "改名"
        edited[key] = item
        edited.removeValue(forKey: "hierarchy-song:\(MusicIDs.song(4))")
        edited["new"] = item
        #expect(!edited.isMemoryMapped)
        #expect(mapped.isMemoryMapped)
        #expect(mapped.dictionary == dictionary)
        var expected = dictionary
        expected[key] = item
        expected.removeValue(forKey: "hierarchy-song:\(MusicIDs.song(4))")
        expected["new"] = item
        #expect(edited.dictionary == expected)
        #expect(edited != mapped)

        // 目录走查拿映射的那份当第一段,照常读写、合并。
        var walk = SourceScanWalkLog(index: mapped)
        #expect(walk[key] == dictionary[key])
        walk.updateValue(item, forKey: key)
        walk.updateValue(item, forKey: "walk-new")
        #expect(walk[key] == item)
        var walked = dictionary
        walked[key] = item
        walked["walk-new"] = item
        #expect(walk.materializedIndex().dictionary == walked)
        let overlay = SourceSyncIndexOverlay(lower: mapped, upper: SourceScanWalkLog())
        #expect(overlay.item(forKey: key) == dictionary[key])
        #expect(mapped.dictionary == dictionary)
    }

    @Test("Damaged, truncated and inconsistent files are rejected without crashing")
    func damagedFilesAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index = SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 300))
        let good = directory.appendingPathComponent("good.index")
        let summary = try writeMappable(index, to: good)
        let data = try Data(contentsOf: good)

        func attempt(_ name: String, _ bytes: Data) -> Error? {
            let url = directory.appendingPathComponent(name)
            try? bytes.write(to: url)
            do {
                _ = try SourceSyncIndex.mapFile(at: url)
                return nil
            } catch {
                return error
            }
        }
        #expect(attempt("truncated", data.prefix(data.count - 1)) as? SourceSyncIndexFileError == .truncated)
        #expect(attempt("tiny", data.prefix(40)) as? SourceSyncIndexFileError == .truncated)
        #expect(attempt("empty", Data()) as? SourceSyncIndexFileError == .truncated)
        var flipped = data
        flipped[data.count / 2] ^= 0x10
        #expect(attempt("flipped", flipped) as? SourceSyncIndexFileError == .digestMismatch)
        var appended = data
        appended.append(0)
        #expect(attempt("appended", appended) as? SourceSyncIndexFileError == .truncated)
        #expect(throws: SourceSyncIndexFileError.digestMismatch) {
            try SourceSyncIndex.mapFile(at: good, expectedSHA256: String(repeating: "0", count: 64))
        }
        #expect(throws: SourceSyncIndexFileError.mappingFailed(ENOENT)) {
            try SourceSyncIndex.mapFile(at: directory.appendingPathComponent("missing.index"))
        }
        // 第 1 版的文件映射不了,报版本(调用方改走读进堆里的路)。
        let legacy = directory.appendingPathComponent("legacy.index")
        try index.binaryData().data.write(to: legacy)
        #expect(throws: SourceSyncIndexFileError.unsupportedVersion(1)) {
            try SourceSyncIndex.mapFile(at: legacy)
        }

        let rowCount = Int(header(data, 16))
        let spanCount = Int(header(data, 24))
        let slotCount = Int(header(data, 40))
        let hashesOffset = 64 + rowCount * 96 + spanCount * 8
        let slotsOffset = hashesOffset + rowCount * 4
        // 校验和对得上、内容却是写坏的:哈希表少了一行。
        let missingSlot = directory.appendingPathComponent("missing-slot.index")
        try data.write(to: missingSlot)
        try rewrite(missingSlot) { bytes in
            for slot in 0..<slotCount {
                let offset = slotsOffset + slot * 4
                let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
                if value >= 0 {
                    withUnsafeBytes(of: Int32(-1)) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
                    break
                }
            }
        }
        #expect(throws: SourceSyncIndexFileError.hashTableMismatch) { try SourceSyncIndex.mapFile(at: missingSlot) }
        // 哈希表里的行号越界。
        let outOfRange = directory.appendingPathComponent("out-of-range.index")
        try data.write(to: outOfRange)
        try rewrite(outOfRange) { bytes in
            for slot in 0..<slotCount {
                let offset = slotsOffset + slot * 4
                let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
                if value >= 0 {
                    withUnsafeBytes(of: Int32(rowCount + 5)) { bytes.replaceSubrange(offset..<offset + 4, with: $0) }
                    break
                }
            }
        }
        #expect(throws: SourceSyncIndexFileError.hashTableMismatch) { try SourceSyncIndex.mapFile(at: outOfRange) }
        // 存着的哈希与键对不上(算法或 NFC 规则变了)。
        let wrongHash = directory.appendingPathComponent("wrong-hash.index")
        try data.write(to: wrongHash)
        try rewrite(wrongHash) { bytes in bytes[hashesOffset] ^= 0x01 }
        #expect(throws: SourceSyncIndexFileError.hashTableMismatch) { try SourceSyncIndex.mapFile(at: wrongHash) }
        // 哈希算法版本不同。
        let otherAlgorithm = directory.appendingPathComponent("other-algorithm.index")
        try data.write(to: otherAlgorithm)
        try rewrite(otherAlgorithm) { bytes in bytes[48] = 99 }
        #expect(throws: SourceSyncIndexFileError.hashTableMismatch) { try SourceSyncIndex.mapFile(at: otherAlgorithm) }
        // 行引用的字节越界。
        let badRow = directory.appendingPathComponent("bad-row.index")
        try data.write(to: badRow)
        try rewrite(badRow) { bytes in
            withUnsafeBytes(of: UInt32.max) { bytes.replaceSubrange(64..<68, with: $0) }
        }
        #expect(throws: SourceSyncIndexFileError.corruptRow(0)) { try SourceSyncIndex.mapFile(at: badRow) }
        // 槽数不比行数多(探测停不下来)。
        let fullTable = directory.appendingPathComponent("full-table.index")
        try data.write(to: fullTable)
        try rewrite(fullTable) { bytes in
            withUnsafeBytes(of: UInt64(rowCount).littleEndian) { bytes.replaceSubrange(40..<48, with: $0) }
        }
        #expect(throws: SourceSyncIndexFileError.truncated) { try SourceSyncIndex.mapFile(at: fullTable) }

        // 好的那份照常映射;坏的那些都没有影响它。
        let mapped = try SourceSyncIndex.mapFile(at: good, expectedSHA256: summary.sha256)
        #expect(mapped == index)
    }

    /// 一个服务器源的已提交状态:有删歌证词、正在确认的大批消失、要求完整走查。
    private static func smbStateWithEvidence(sourceID: String) -> SourceSyncState {
        SourceSyncState(
            sourceID: sourceID, scopeFingerprint: "scope", identityScopeFingerprint: "identity",
            cursors: ["/Music": "cursor"],
            index: SourceSyncIndex(RandomSyncIndexFixture.make(entries: 1_200, seed: 31)),
            scanEpoch: 9, requiresDeepScan: true,
            lastFullScanAt: SourceSyncIndexFixtures.date,
            reconciliation: SourceSyncReconciliation(
                kind: .serverCatalogMassDisappearance, unresolvedStableKeys: ["song-1", "song-2"],
                detectedAt: SourceSyncIndexFixtures.date
            ),
            missingCatalogSongIDs: ["song-1": 1, "song-2": 1],
            deletionEvidenceRevision: "walk-1"
        )
    }

    @Test("An unreadable index keeps the rest of the state, so a partially visible share is not pruned at once",
          arguments: ["corrupt", "unknown-version"])
    func unreadableIndexKeepsBaselineMetadata(damage: String) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = Self.smbStateWithEvidence(sourceID: "smb")
        let record = try SourceSyncStateDirectory.writeSource(state, previous: nil, previousIndex: nil, in: directory)
        let reference = try #require(record.index)
        let indexURL = directory.appendingPathComponent(reference.file)
        switch damage {
        case "corrupt":
            var bytes = try Data(contentsOf: indexURL)
            bytes[bytes.count / 3] ^= 0x80
            try bytes.write(to: indexURL)
        default:
            // 更新的版本写的格式(这一版不认识),校验和对得上。
            try rewrite(indexURL) { bytes in bytes[8] = 99 }
            let sha = try Data(contentsOf: indexURL).suffix(32).map { String(format: "%02x", $0) }.joined()
            let stateURL = directory.appendingPathComponent("\(SourceSyncStateDirectory.fileStem(for: "smb")).state.json")
            let envelope = try String(contentsOf: stateURL, encoding: .utf8)
                .replacingOccurrences(of: reference.sha256, with: sha)
            try envelope.write(to: stateURL, atomically: true, encoding: .utf8)
        }

        let loaded = SourceSyncStateDirectory.loadDirectory(directory, now: Date().addingTimeInterval(3_600))
        let kept = try #require(loaded.states["smb"])
        #expect(loaded.problems.count == 1)
        #expect(kept.indexBaselineLost)
        #expect(kept.index.isEmpty)
        // 删歌证词、确认中的大批消失、要求完整走查都还在。
        var expected = state
        expected.index = SourceSyncIndex()
        expected.indexBaselineLost = true
        #expect(kept == expected)
        // 不能拿来做增量对账:下一次是完整走查。
        #expect(!kept.isUsable(sourceID: "smb", scopeFingerprint: "scope"))
        #expect(kept.matchesScope(sourceID: "smb", scopeFingerprint: "scope"))
        // 读不回来的文件留到下次提交时再换掉,过了孤儿宽限期也不删。
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(loaded.records["smb"]?.index == nil)

        // 共享文件夹只挂上了一部分:完整走查只看到 300 首里的 120 首。扫描服务拿同一扫描范围的
        // 上一份状态(就是这份)走删除确认:这一轮不删,等更多次完整走查。
        let existing = Set((0..<300).map { "song-\($0)" })
        let visible = Set((0..<120).map { "song-\($0)" })
        let plan = ServerCatalogDeletionConfirmationPolicy.plan(
            existingSongIDs: existing, authoritativeSongIDs: visible,
            previousMissingCounts: kept.missingCatalogSongIDs, previousEvidenceRevision: kept.deletionEvidenceRevision,
            currentRevision: "walk-2", authority: .authoritative
        )
        #expect(plan.holdsMassDisappearance)
        #expect(plan.confirmedDeletionSongIDs.isEmpty)
        #expect(ServerCatalogDeletionConfirmationPolicy.retainedAuthoritativeSongIDs(
            existingSongIDs: existing, authoritativeSongIDs: visible,
            confirmedDeletionSongIDs: plan.confirmedDeletionSongIDs
        ) == existing)

        // 走查提交的新状态重建了索引、去掉了标记,读不回来的旧文件随之换掉。
        let store = SourceSyncStateFileStore(
            directory: directory, initialStates: loaded.states, persistedRecords: loaded.records
        )
        var rebuilt = state
        rebuilt.scanEpoch += 1
        rebuilt.index = SourceSyncIndex(RandomSyncIndexFixture.make(entries: 500, seed: 32))
        _ = try #require(try await store.upsert(rebuilt, expectedMutationEpoch: 0))
        let reloaded = SourceSyncStateDirectory.loadDirectory(directory)
        #expect(reloaded.problems.isEmpty)
        #expect(reloaded.states["smb"] == rebuilt)
        #expect(reloaded.states["smb"]?.indexBaselineLost == false)
        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
    }

    /// 写一个旧版本(第 1 版索引文件)的源进目录。
    private static func writeLegacyFormatSource(_ state: SourceSyncState, in directory: URL) throws {
        let record = try SourceSyncStateDirectory.writeSource(state, previous: nil, previousIndex: nil, in: directory)
        let reference = try #require(record.index)
        let legacy = try state.index.binaryData()
        try legacy.data.write(to: directory.appendingPathComponent(reference.file))
        let stem = SourceSyncStateDirectory.fileStem(for: state.sourceID)
        let stateURL = directory.appendingPathComponent("\(stem).state.json")
        let envelope = try String(contentsOf: stateURL, encoding: .utf8)
            .replacingOccurrences(of: reference.sha256, with: legacy.summary.sha256)
        try envelope.write(to: stateURL, atomically: true, encoding: .utf8)
    }

    @Test("An index written by an older build loads into the heap at once and is rewritten later in the background")
    func legacyIndexFileIsUpgradedInTheBackground() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = SourceSyncState(sourceID: "smb", scopeFingerprint: "scope",
                                    index: SourceSyncIndex(SourceSyncIndexFixtures.fileSystem()), scanEpoch: 3)
        try Self.writeLegacyFormatSource(state, in: directory)
        let legacyFile = try #require(SourceSyncStateDirectory.loadDirectory(directory).records["smb"]?.index?.file)

        // 读的时候不写盘:直接给出堆上的那份,记下要改写。
        let loaded = SourceSyncStateDirectory.loadDirectory(directory)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.pendingFormatUpgrades == ["smb"])
        #expect(loaded.states["smb"] == state)
        #expect(loaded.states["smb"]?.index.isMemoryMapped == false)
        #expect(loaded.records["smb"]?.index?.file == legacyFile)

        let store = SourceSyncStateFileStore(
            directory: directory, initialStates: loaded.states, persistedRecords: loaded.records
        )
        let upgraded = await store.upgradeIndexFormats(loaded.pendingFormatUpgrades)
        let mapped = try #require(upgraded["smb"])
        #expect(mapped.isMemoryMapped)
        #expect(mapped == state.index)
        #expect(await store.snapshot()["smb"]?.index.isIdentical(to: mapped) == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".index") }
        #expect(files.count == 1 && files.first != legacyFile)
        let upgradedData = try Data(contentsOf: directory.appendingPathComponent(try #require(files.first)))
        #expect(upgradedData[8] == UInt8(SourceSyncIndex.mappableFormatVersion))

        // 下次启动直接映射,不再改写。
        let again = SourceSyncStateDirectory.loadDirectory(directory)
        #expect(again.pendingFormatUpgrades.isEmpty)
        #expect(again.states["smb"] == state)
        #expect(again.states["smb"]?.index.isMemoryMapped == true)
    }

    @Test("A failed background rewrite backs off instead of rewriting on every launch, and keeps a consistent record")
    func failedFormatUpgradeBacksOff() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = SourceSyncState(sourceID: "smb", scopeFingerprint: "scope",
                                    index: SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 80)), scanEpoch: 3)
        try Self.writeLegacyFormatSource(state, in: directory)
        let loaded = SourceSyncStateDirectory.loadDirectory(directory)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        // 写索引文件失败:这次不改写,记下退避。
        let failing = IndexWriteFailingWriter(mode: .fail)
        let failingStore = SourceSyncStateFileStore(
            directory: directory, initialStates: loaded.states, persistedRecords: loaded.records,
            atomicWriter: failing.write
        )
        #expect(await failingStore.upgradeIndexFormats(["smb"], now: now).isEmpty)
        #expect(failing.indexWrites == 1)
        let backoff = SourceSyncStateDirectory.FormatUpgradeBackoff.load(from: directory)
        let stem = SourceSyncStateDirectory.fileStem(for: "smb")
        #expect(backoff.attempts[stem]?.failures == 1)
        #expect(!backoff.allowsAttempt(stem: stem, now: now.addingTimeInterval(3_600)))
        #expect(backoff.allowsAttempt(stem: stem, now: now.addingTimeInterval(SourceSyncStateDirectory.FormatUpgradeBackoff.initialDelay)))
        // 磁盘上仍是原来那一份,照常读得回来。
        #expect(SourceSyncStateDirectory.loadDirectory(directory).states["smb"] == state)

        // 退避期内的下一次启动不再整份重写。
        let relaunched = SourceSyncStateDirectory.loadDirectory(directory)
        let waiting = IndexWriteFailingWriter(mode: .pass)
        let waitingStore = SourceSyncStateFileStore(
            directory: directory, initialStates: relaunched.states, persistedRecords: relaunched.records,
            atomicWriter: waiting.write
        )
        #expect(await waitingStore.upgradeIndexFormats(relaunched.pendingFormatUpgrades, now: now.addingTimeInterval(60)).isEmpty)
        #expect(waiting.indexWrites == 0)

        // 写成了却映射不了(写出来的文件坏了):记录指向新写的那个文件,手里留着堆上那份。
        let corrupting = IndexWriteFailingWriter(mode: .corrupt)
        let corruptingStore = SourceSyncStateFileStore(
            directory: directory, initialStates: relaunched.states, persistedRecords: relaunched.records,
            atomicWriter: corrupting.write
        )
        let later = now.addingTimeInterval(2 * SourceSyncStateDirectory.FormatUpgradeBackoff.initialDelay)
        #expect(await corruptingStore.upgradeIndexFormats(["smb"], now: later).isEmpty)
        #expect(corrupting.indexWrites == 1)
        #expect(await corruptingStore.snapshot()["smb"] == state)
        #expect(SourceSyncStateDirectory.FormatUpgradeBackoff.load(from: directory).attempts[stem]?.failures == 2)
        let afterCorrupt = SourceSyncStateDirectory.loadDirectory(directory, removesOrphans: false)
        let file = try #require(afterCorrupt.states["smb"].flatMap { _ in
            try? String(contentsOf: directory.appendingPathComponent("\(stem).state.json"), encoding: .utf8)
        })
        #expect(!file.isEmpty)
        let indexFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".index") }
        #expect(indexFiles.count == 1)
        #expect(file.contains(try #require(indexFiles.first)))
    }

    /// 稳定哈希在 `slotCount` 个槽的表里落在 `0..<window` 的键。
    private static func collidingKeys(count: Int, slotCount: Int, window: Int) -> [String] {
        var keys: [String] = []
        var candidate = 0
        while keys.count < count {
            let key = "path:/collide/\(candidate)"
            candidate += 1
            let home = Int((UInt64(SourceSyncKeyHash.hash(of: key)) &* UInt64(slotCount)) >> 32)
            if home < window { keys.append(key) }
        }
        return keys
    }

    @Test("Keys whose hashes pile up past the probe limit are read into the heap instead of being mapped")
    func excessiveProbingFallsBackToHeap() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rowCount = 1_100
        let keys = Self.collidingKeys(
            count: rowCount, slotCount: SourceSyncIndex.Storage.slotCount(for: rowCount), window: 8
        )
        var dictionary: [String: SourceSyncIndexedItem] = [:]
        for key in keys {
            dictionary[key] = SourceSyncIndexFixtures.item(key, path: String(key.dropFirst(5)), parent: "/collide",
                                                           songs: [key])
        }
        let state = SourceSyncState(sourceID: "smb", scopeFingerprint: "scope",
                                    index: SourceSyncIndex(dictionary), scanEpoch: 1)
        let record = try SourceSyncStateDirectory.writeSource(state, previous: nil, previousIndex: nil, in: directory)
        let url = directory.appendingPathComponent(try #require(record.index?.file))
        #expect(throws: SourceSyncIndexFileError.excessiveProbing) { try SourceSyncIndex.mapFile(at: url) }
        // 同一份文件按小上限也是:校验一遍走完,不会因为挤在一起变成平方级。
        let normal = directory.appendingPathComponent("normal.index")
        _ = try writeMappable(SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 300)), to: normal)
        #expect(throws: SourceSyncIndexFileError.excessiveProbing) {
            try SourceSyncIndex.mapFile(at: normal, maximumProbeRun: 1)
        }
        #expect(try SourceSyncIndex.mapFile(at: normal).count == SourceSyncIndexFixtures.server(songs: 300).count)
        // 目录读的时候改成读进堆里,内容照旧,不当成要改写的旧格式。
        let loaded = SourceSyncStateDirectory.loadDirectory(directory)
        #expect(loaded.problems.isEmpty)
        #expect(loaded.pendingFormatUpgrades.isEmpty)
        #expect(loaded.states["smb"] == state)
        #expect(loaded.states["smb"]?.index.isMemoryMapped == false)
    }

    @Test("Every row whose key goes through NFC normalisation has its stored hash checked, not just a sample")
    func everyNormalisedKeyHashIsVerified() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 2000 行里混着 NFD 写法(要规范化)的键,抽查每隔几行才看一行。
        var dictionary = SourceSyncIndexFixtures.server(songs: 2_000)
        for book in 0..<40 {
            let key = "/Books/Les Mise\u{301}rables \(book)"
            dictionary[key] = SourceSyncIndexFixtures.item(key, parent: "/Books", directory: true)
        }
        let url = directory.appendingPathComponent("mixed.index")
        let summary = try writeMappable(SourceSyncIndex(dictionary), to: url)
        let (target, rowCount, hashesOffset) = try { () throws -> (Int, Int, Int) in
            let mapped = try SourceSyncIndex.mapFile(at: url, expectedSHA256: summary.sha256)
            let storage = mapped.storage
            let rows = storage.rowCount
            let stride = Swift.max(1, rows / 512)
            let target = try #require((0..<rows).first { row in
                row % stride != 0 && row != rows - 1 && !storage.keyIsKnownNFC(atRow: row)
            })
            let data = try Data(contentsOf: url)
            let spans = Int(header(data, 24))
            return (target, rows, 64 + rows * 96 + spans * 8)
        }()
        #expect(rowCount > 2_000)
        // 换成同一个起始槽位的另一个哈希值:表还是完整的,只有现算一遍才看得出来。
        try rewrite(url) { bytes in bytes[hashesOffset + target * 4] ^= 0x01 }
        #expect(throws: SourceSyncIndexFileError.hashTableMismatch) { try SourceSyncIndex.mapFile(at: url) }
    }

    @Test("Duplicate keys are rejected when mapped, exactly as when read into the heap")
    func duplicateKeysAreRejectedWhenMapped() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let precomposed = "/Books/Les Mis\u{E9}rables"
        let decomposed = "/Books/Les Mise\u{301}rables"
        let cases: [(String, String, String)] = [
            ("same-bytes", "path:/music/a.flac", "path:/music/a.flac"),
            ("canonically-equivalent", precomposed, decomposed),
        ]
        for (name, first, second) in cases {
            let left = SourceSyncIndex([first: SourceSyncIndexFixtures.item(first, parent: "/", songs: ["1"])])
            var rightDictionary = SourceSyncIndexFixtures.cue()
            rightDictionary[second] = SourceSyncIndexFixtures.item(second, parent: "/", songs: ["2"])
            // 拼接不查重(调用方保证没有重复的键),这里故意拼出一份有重复键的。
            let joined = SourceSyncIndex.concatenating([left, SourceSyncIndex(rightDictionary)])
            let encoded = try joined.binaryData(mappable: true)
            let url = directory.appendingPathComponent("\(name).index")
            try encoded.data.write(to: url)
            #expect(throws: SourceSyncIndexFileError.duplicateKey, "\(name)") {
                try SourceSyncIndex.mapFile(at: url)
            }
            #expect(throws: SourceSyncIndexFileError.duplicateKey, "\(name)") {
                try SourceSyncIndex.decodeBinary(encoded.data)
            }
        }
    }

    @Test("Save, map, mutate and commit: the store and the caller end up holding only the mapping")
    func commitRoundTripSwapsToMapping() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SourceSyncStateFileStore(directory: directory)
        var state = SourceSyncState(sourceID: "smb", scopeFingerprint: "scope",
                                    index: SourceSyncIndex(SourceSyncIndexFixtures.server(songs: 500)), scanEpoch: 1)
        let receipt = try #require(try await store.upsert(state, expectedMutationEpoch: 0))
        let committed = try #require(receipt.committedIndex)
        #expect(committed.isMemoryMapped)
        #expect(committed == state.index)
        #expect(await store.snapshot()["smb"]?.index.isIdentical(to: committed) == true)

        // 冷启动读回来:映射的。
        let loaded = SourceSyncStateDirectory.loadDirectory(directory)
        let reloaded = try #require(loaded.states["smb"])
        #expect(reloaded == state)
        #expect(reloaded.index.isMemoryMapped)
        let firstFile = try #require(loaded.records["smb"]?.index?.file)

        // 扫描改一份(拷进堆里),提交:换成映射新文件的那份,旧文件删掉。
        let restarted = SourceSyncStateFileStore(
            directory: directory, initialStates: loaded.states, persistedRecords: loaded.records
        )
        var next = reloaded
        next.scanEpoch += 1
        let key = "hierarchy-song:\(MusicIDs.song(10))"
        var item = try #require(next.index[key])
        item.revision = "rescanned"
        next.index[key] = item
        next.index.removeValue(forKey: "hierarchy-song:\(MusicIDs.song(11))")
        #expect(!next.index.isMemoryMapped)
        #expect(reloaded.index.isMemoryMapped)
        let nextReceipt = try #require(try await restarted.upsert(next, expectedMutationEpoch: 0))
        let nextCommitted = try #require(nextReceipt.committedIndex)
        #expect(nextCommitted.isMemoryMapped)
        #expect(nextCommitted == next.index)
        #expect(await restarted.snapshot()["smb"]?.index.isIdentical(to: nextCommitted) == true)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(firstFile).path))
        // 旧文件删了,握着旧映射的读者照常读到旧内容。
        #expect(reloaded.index == state.index)
        #expect(reloaded.index[key]?.revision != "rescanned")

        // 内容没变的提交沿用文件,回执给的就是手里那份映射。
        var rescoped = next
        rescoped.index = SourceSyncIndex(next.index.dictionary)
        let unchanged = try #require(try await restarted.upsert(rescoped, expectedMutationEpoch: 0))
        #expect(unchanged.committedIndex?.isIdentical(to: nextCommitted) == true)

        // 只改了元数据:沿用同一个映射。
        state = next
        state.scopeFingerprint = "scope-2"
        state.index = nextCommitted
        let metadataOnly = try #require(try await restarted.upsert(state, expectedMutationEpoch: 0))
        #expect(metadataOnly.committedIndex?.isIdentical(to: nextCommitted) == true)
        #expect(SourceSyncStateDirectory.loadDirectory(directory).states["smb"] == state)
    }

    @Test("A receipt only offers a mapped index whose content is exactly the caller's state")
    func supersededCommitOffersNoIndex() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = BlockingFirstWriter()
        defer { writer.release() }
        let store = SourceSyncStateFileStore(directory: directory, atomicWriter: writer.write)
        let first = SourceSyncState(sourceID: "smb", scopeFingerprint: "first",
                                    index: SourceSyncIndex(SourceSyncIndexFixtures.cue()), scanEpoch: 1)
        let second = SourceSyncState(sourceID: "smb", scopeFingerprint: "second",
                                     index: SourceSyncIndex(SourceSyncIndexFixtures.fileSystem()), scanEpoch: 2)
        let firstTask = Task { try await store.upsert(first, expectedMutationEpoch: 0) }
        await writer.waitForFirstWrite()
        let secondTask = Task { try await store.upsert(second, expectedMutationEpoch: 0) }
        while await store.snapshot()["smb"] != second { await Task.yield() }
        writer.release()
        let firstReceipt = try #require(try await firstTask.value)
        let secondReceipt = try #require(try await secondTask.value)
        // 第一份落盘时已经被第二份换掉:不给它映射,免得调用方拿到别的内容。
        #expect(firstReceipt.committedIndex == nil || firstReceipt.committedIndex == first.index)
        let committed = try #require(secondReceipt.committedIndex)
        #expect(committed == second.index)
        #expect(committed.isMemoryMapped)
        #expect(SourceSyncStateDirectory.loadDirectory(directory).states["smb"] == second)
    }

    @Test("Readers of the old mapping are unaffected while a commit replaces and deletes its file")
    func concurrentReadDuringCommit() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dictionary = RandomSyncIndexFixture.make(entries: 20_000, seed: 99)
        let store = SourceSyncStateFileStore(directory: directory)
        let original = SourceSyncState(sourceID: "smb", scopeFingerprint: "scope",
                                       index: SourceSyncIndex(dictionary), scanEpoch: 1)
        let mapped = try #require(try await store.upsert(original, expectedMutationEpoch: 0)?.committedIndex)
        #expect(mapped.isMemoryMapped)
        let keys = dictionary.keys.sorted()
        let expectedBytes = keys.map { RandomSyncIndexFixture.bytes($0, dictionary[$0]!) }

        let readers = (0..<4).map { reader in
            Task.detached { () async -> Int in
                var checked = 0
                for round in 0..<6 {
                    var iterated = 0
                    for (key, item) in mapped {
                        iterated += 1
                        if (iterated + reader + round) % 97 == 0 { _ = RandomSyncIndexFixture.bytes(key, item) }
                    }
                    guard iterated == keys.count else { return -1 }
                    for (offset, key) in keys.enumerated() where (offset + reader) % 3 == 0 {
                        guard let item = mapped[key],
                              RandomSyncIndexFixture.bytes(key, item) == expectedBytes[offset] else { return -1 }
                        checked += 1
                    }
                    await Task.yield()
                }
                return checked
            }
        }
        // 读者还在读的时候提交几轮:每轮写新文件、换映射、删旧文件。
        var next = original
        for round in 0..<5 {
            next.scanEpoch += 1
            let key = keys[round * 7]
            var item = try #require(next.index[key])
            item.revision = "round-\(round)"
            next.index[key] = item
            let committed = try #require(try await store.upsert(next, expectedMutationEpoch: 0)?.committedIndex)
            #expect(committed.isMemoryMapped)
            #expect(committed == next.index)
            next.index = committed
        }
        for reader in readers {
            #expect(await reader.value > 0)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".index") }
        #expect(files.count == 1)
        #expect(mapped.dictionary == dictionary)
        #expect(SourceSyncStateDirectory.loadDirectory(directory).states["smb"] == next)
    }
}

/// 第一次写入停住,直到 `release()`;其余照常原子写入。
private final class BlockingFirstWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var writes = 0
    private var released = false

    func write(_ data: Data, _ url: URL) throws {
        let isFirst = lock.withLock { () -> Bool in
            writes += 1
            return writes == 1
        }
        if isFirst {
            started.signal()
            gate.wait()
        }
        try data.write(to: url, options: .atomic)
    }

    func waitForFirstWrite() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [started] in
                started.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        let shouldSignal = lock.withLock { () -> Bool in
            guard !released else { return false }
            released = true
            return true
        }
        if shouldSignal { gate.signal() }
    }
}

/// 写 `.index` 文件时按模式失败、写坏或照常写;state.json 照常原子写入。
private final class IndexWriteFailingWriter: @unchecked Sendable {
    enum Mode { case fail, corrupt, pass }

    private let lock = NSLock()
    private let mode: Mode
    private var writes = 0

    init(mode: Mode) { self.mode = mode }

    var indexWrites: Int { lock.withLock { writes } }

    func write(_ data: Data, _ url: URL) throws {
        guard url.pathExtension == "index" else {
            try data.write(to: url, options: .atomic)
            return
        }
        lock.withLock { writes += 1 }
        switch mode {
        case .fail:
            throw CocoaError(.fileWriteUnknown)
        case .corrupt:
            var bytes = data
            bytes[bytes.count / 2] ^= 0x55
            try bytes.write(to: url, options: .atomic)
        case .pass:
            try data.write(to: url, options: .atomic)
        }
    }
}
