#if canImport(Darwin)
import Darwin
import Foundation
import Testing
@testable import PrimuseKit

/// 按现场那份曲库的形状(45.7 万条、SMB、长中文路径)造的已提交扫描索引。
/// 顺序与目录走查相同:分类 → 歌手 → 专辑目录 → 歌。任意一行能按序号现算,查找时不必把键攒起来。
struct SMBCommittedIndexFixture {
    static let genres = ["华语流行", "日本 J-Pop", "欧美 Rock", "古典 Classical",
                         "爵士 Jazz", "原声 Soundtrack", "民谣 Folk", "电子 Electronic"]
    static let surnames = ["周", "林", "陈", "王", "张", "李", "刘", "杨", "黄", "吴", "赵", "孙"]
    static let given = ["杰伦", "俊杰", "奕迅", "菲", "学友", "宇春", "绮贞", "楚生", "鹏", "若昀", "子棋", "雨生"]
    static let titles = ["晴天", "七里香", "夜曲", "稻香", "青花瓷", "以父之名", "简单爱", "告白气球",
                         "说好的幸福呢", "听妈妈的话", "彩虹", "安静"]
    static let songsPerAlbum = 11
    static let albumsPerArtist = 13
    static let root = "/Volumes/音乐库"

    let songs: Int
    let albums: Int
    let artists: Int

    /// 总行数约为 `entries`(歌 + 专辑目录 + 歌手目录 + 分类目录 + 根)。
    init(entries: Int) {
        songs = max(1, entries * 1_000 / 1_098)
        albums = (songs + Self.songsPerAlbum - 1) / Self.songsPerAlbum
        artists = (albums + Self.albumsPerArtist - 1) / Self.albumsPerArtist
    }

    var rowCount: Int { songs + albums + artists + Self.genres.count + 1 }

    private static func padded(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    private static func hex32(_ value: Int, salt: UInt64) -> String {
        let high = String((UInt64(value) &+ salt) &* 0x9E37_79B9_7F4A_7C15, radix: 16)
        let low = String((UInt64(value) ^ 0xA5A5_5A5A_DEAD_BEEF) &* (salt | 1), radix: 16)
        return String(repeating: "0", count: 16 - high.count) + high + String(repeating: "0", count: 16 - low.count) + low
    }

    func genrePath(_ genre: Int) -> String { "\(Self.root)/\(Self.genres[genre])" }

    func artistPath(_ artist: Int) -> String {
        let name = Self.surnames[artist % 12] + Self.given[(artist / 12) % 12]
        return "\(genrePath(artist % Self.genres.count))/\(name) Artist \(Self.padded(artist, 4))"
    }

    func albumPath(_ album: Int) -> String {
        let title = Self.titles[album % 12]
        return "\(artistPath(album / Self.albumsPerArtist))/\(1990 + album % 35) - \(title) 第\(album)张 (FLAC)"
    }

    func songName(_ song: Int) -> String {
        "\(Self.padded(song % Self.songsPerAlbum + 1, 2)) - \(Self.titles[(song / 7) % 12]) Live 第\(song)首.flac"
    }

    func songPath(_ song: Int) -> String { "\(albumPath(song / Self.songsPerAlbum))/\(songName(song))" }

    func songKey(_ song: Int) -> String { "path:" + songPath(song).lowercased() }

    func songItem(_ song: Int, seenEpoch: Int64 = 1) -> SourceSyncIndexedItem {
        let path = songPath(song)
        return SourceSyncIndexedItem(
            stableKey: "path:" + path.lowercased(),
            path: path,
            displayName: songName(song),
            parentPath: albumPath(song / Self.songsPerAlbum),
            isDirectory: false,
            songIDs: [Self.hex32(song, salt: 9)],
            size: 30_000_000 + Int64(song % 4_096) * 7_919,
            modifiedDate: Date(timeIntervalSinceReferenceDate: 600_000_000 + Double(song)),
            revision: song % 2 == 0 ? "\(600_000_000 + song)-\(30_000_000 + song % 4_096)" : nil,
            sidecarFingerprint: song % 4 == 0 ? "lrc:\(Self.hex32(song, salt: 3).prefix(8))|cover" : nil,
            seenEpoch: seenEpoch
        )
    }

    private func directoryItem(_ path: String, parent: String, seenEpoch: Int64) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(
            stableKey: "path:" + path.lowercased(), path: path,
            displayName: (path as NSString).lastPathComponent, parentPath: parent, isDirectory: true,
            size: 0, modifiedDate: Date(timeIntervalSinceReferenceDate: 600_000_000), revision: nil,
            seenEpoch: seenEpoch
        )
    }

    /// 按走查顺序逐条给出。
    func forEachEntry(seenEpoch: Int64 = 1, _ body: (String, SourceSyncIndexedItem) -> Void) {
        body("path:" + Self.root.lowercased(), directoryItem(Self.root, parent: "/Volumes", seenEpoch: seenEpoch))
        for genre in Self.genres.indices {
            let path = genrePath(genre)
            body("path:" + path.lowercased(), directoryItem(path, parent: Self.root, seenEpoch: seenEpoch))
        }
        for artist in 0..<artists {
            let path = artistPath(artist)
            body("path:" + path.lowercased(),
                 directoryItem(path, parent: genrePath(artist % Self.genres.count), seenEpoch: seenEpoch))
        }
        for album in 0..<albums {
            let path = albumPath(album)
            body("path:" + path.lowercased(),
                 directoryItem(path, parent: artistPath(album / Self.albumsPerArtist), seenEpoch: seenEpoch))
            for song in album * Self.songsPerAlbum..<min(songs, (album + 1) * Self.songsPerAlbum) {
                autoreleasepool {
                    body(songKey(song), songItem(song, seenEpoch: seenEpoch))
                }
            }
        }
    }

    func build() -> SourceSyncIndex {
        var builder = SourceSyncIndex.Builder(minimumCapacity: rowCount)
        forEachEntry { key, item in builder.insert(item, forKey: key) }
        return builder.build()
    }
}

enum ProcessFootprint {
    struct Sample {
        let current: UInt64
        let lifetimePeak: UInt64
    }

    static func sample() -> Sample {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return Sample(current: 0, lifetimePeak: 0) }
        return Sample(current: info.ri_phys_footprint, lifetimePeak: info.ri_lifetime_max_phys_footprint)
    }

    /// 让 malloc 把空着的页还给系统,量增长之前先把上一步留下的空页排除掉。
    static func settle() {
        _ = malloc_zone_pressure_relief(nil, 0)
    }

    static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

private func measurementDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("primuse-sync-footprint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 边写边算,不在内存里拼整份文件。
private func writeIndexFile(_ index: SourceSyncIndex, mappable: Bool, to url: URL) throws -> SourceSyncIndex.BinarySummary {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let summary = try index.writeBinary(mappable: mappable) { try handle.write(contentsOf: $0) }
    try handle.synchronize()
    return summary
}

private func fileSize(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

private func milliseconds(since start: ContinuousClock.Instant) -> String {
    let elapsed = ContinuousClock.now - start
    let value = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    return String(format: "%.0f", value)
}

/// 模拟一次完整重扫:按走查顺序在旧索引里查每一条,新条目记进目录走查(与真扫描相同的结构)。
/// 返回走到最后、还没合成之前的进程占用(旧索引与新走查同时在手里的时刻)。
private func simulateRescan(
    over committed: SourceSyncIndex,
    fixture: SMBCommittedIndexFixture
) -> (footprint: UInt64, hits: Int) {
    var walk = SourceScanWalkLog()
    var hits = 0
    fixture.forEachEntry(seenEpoch: 2) { key, item in
        if committed[key] != nil { hits += 1 }
        walk.updateValue(item, forKey: key)
    }
    walk.seal()
    let footprint = ProcessFootprint.sample().current
    withExtendedLifetime(walk) {}
    return (footprint, hits)
}

@Suite("Committed sync index footprint budget", .serialized)
struct SourceSyncIndexFootprintBudgetTests {
    /// 45.7 万条的已提交索引映射进来以后,进程 footprint 只能长这么多(PLAN §4.8)。
    static let idleMappedBudget: Int64 = 5 * 1_048_576
    static let fieldEntries = 457_000

    @Test("A 457k-entry committed index adds at most 5 MiB of footprint while idle and mapped")
    func idleMappedIndexStaysOffHeap() throws {
        let directory = try measurementDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = SMBCommittedIndexFixture(entries: Self.fieldEntries)
        let url = directory.appendingPathComponent("committed.index")
        let summary = try { () throws -> SourceSyncIndex.BinarySummary in
            let built = fixture.build()
            return try writeIndexFile(built, mappable: true, to: url)
        }()
        #expect(summary.rowCount == fixture.rowCount)

        ProcessFootprint.settle()
        let before = ProcessFootprint.sample().current
        let start = ContinuousClock.now
        let mapped = try SourceSyncIndex.mapFile(at: url, expectedSHA256: summary.sha256)
        let mapTime = milliseconds(since: start)
        let idle = ProcessFootprint.sample().current
        var random = SyncIndexSeededGenerator(seed: 457)
        var found = 0
        for _ in 0..<10_000 {
            let song = Int.random(in: 0..<fixture.songs, using: &random)
            if mapped[fixture.songKey(song)]?.songIDs.isEmpty == false { found += 1 }
        }
        let afterLookups = ProcessFootprint.sample().current
        let idleGrowth = Int64(idle) - Int64(before)
        let lookupGrowth = Int64(afterLookups) - Int64(before)
        print(
            "📐 mappedSyncIndex rows=\(mapped.count) fileMB=\(ProcessFootprint.megabytes(fileSize(url))) "
                + "mapAndVerify=\(mapTime)ms idleGrowthMB=\(ProcessFootprint.megabytes(idleGrowth)) "
                + "after10kLookupsGrowthMB=\(ProcessFootprint.megabytes(lookupGrowth))"
        )
        #expect(mapped.isMemoryMapped)
        #expect(mapped.heapByteCount == 0)
        #expect(mapped.count == fixture.rowCount)
        #expect(found == 10_000)
        #expect(idleGrowth <= Self.idleMappedBudget, "idle mapped growth \(idleGrowth) bytes")
        #expect(lookupGrowth <= Self.idleMappedBudget, "growth after lookups \(lookupGrowth) bytes")
        withExtendedLifetime(mapped) {}
    }

    // MARK: 分进程实测(只在设了 `PRIMUSE_SYNC_INDEX_DIR` 时跑)
    //
    // 同一个进程里先后量两种做法,后一种会用上前一种放掉、malloc 还没还给系统的页,数字不准。
    // 分三次 `swift test` 跑,每次一个干净的进程:
    //   PRIMUSE_SYNC_INDEX_DIR=<dir> swift test --filter measurePhaseBuildFixture
    //   PRIMUSE_SYNC_INDEX_DIR=<dir> swift test --filter measurePhaseMapped
    //   PRIMUSE_SYNC_INDEX_DIR=<dir> swift test --filter measurePhaseHeap
    // 量的是:打开(映射或读进堆里)之后空闲、1 万次随机查找之后、整遍重扫走到最后(旧索引与
    // 新走查同时在手里)三个时刻相对打开之前的 footprint 增长。

    static var phaseDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var phaseEntries: Int {
        Int(ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_ENTRIES"] ?? "") ?? fieldEntries
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_DIR"] != nil))
    func measurePhaseBuildFixture() throws {
        let directory = try #require(Self.phaseDirectory)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = SMBCommittedIndexFixture(entries: Self.phaseEntries)
        let start = ContinuousClock.now
        let built = fixture.build()
        let buildTime = milliseconds(since: start)
        let legacy = try writeIndexFile(built, mappable: false, to: directory.appendingPathComponent("committed-v1.index"))
        let mappable = try writeIndexFile(built, mappable: true, to: directory.appendingPathComponent("committed-v2.index"))
        try Data("\(legacy.sha256)\n\(mappable.sha256)\n".utf8).write(to: directory.appendingPathComponent("sha256.txt"))
        print("📐 syncIndexPhase build rows=\(built.count) songs=\(fixture.songs) build=\(buildTime)ms "
            + "heapIndexMB=\(ProcessFootprint.megabytes(Int64(built.heapByteCount))) "
            + "diskV1MB=\(ProcessFootprint.megabytes(fileSize(directory.appendingPathComponent("committed-v1.index")))) "
            + "diskV2MB=\(ProcessFootprint.megabytes(fileSize(directory.appendingPathComponent("committed-v2.index"))))")
    }

    private static func phaseDigests(_ directory: URL) throws -> (legacy: String, mappable: String) {
        let lines = try String(contentsOf: directory.appendingPathComponent("sha256.txt"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        return (lines[0], lines[1])
    }

    /// 打开之后的三个时刻。`open` 返回打开的索引。
    private static func measurePhase(_ name: String, open: () throws -> SourceSyncIndex) throws {
        let fixture = SMBCommittedIndexFixture(entries: phaseEntries)
        ProcessFootprint.settle()
        let base = Int64(ProcessFootprint.sample().current)
        let start = ContinuousClock.now
        let index = try open()
        let openTime = milliseconds(since: start)
        let idle = Int64(ProcessFootprint.sample().current) - base
        var random = SyncIndexSeededGenerator(seed: 10_000)
        var found = 0
        let lookupStart = ContinuousClock.now
        for _ in 0..<10_000 {
            let song = Int.random(in: 0..<fixture.songs, using: &random)
            if index[fixture.songKey(song)] != nil { found += 1 }
        }
        let lookupTime = milliseconds(since: lookupStart)
        let afterLookups = Int64(ProcessFootprint.sample().current) - base
        let rescanStart = ContinuousClock.now
        let rescan = simulateRescan(over: index, fixture: fixture)
        let rescanTime = milliseconds(since: rescanStart)
        let peak = Int64(ProcessFootprint.sample().lifetimePeak) - base
        print("📐 syncIndexPhase \(name) rows=\(index.count) open=\(openTime)ms "
            + "idle=+\(ProcessFootprint.megabytes(idle))MB "
            + "after10kLookups=+\(ProcessFootprint.megabytes(afterLookups))MB (\(found) hits, \(lookupTime)ms) "
            + "duringRescan=+\(ProcessFootprint.megabytes(Int64(rescan.footprint) - base))MB "
            + "(\(rescan.hits) hits, \(rescanTime)ms) peak=+\(ProcessFootprint.megabytes(peak))MB "
            + "heapIndexMB=\(ProcessFootprint.megabytes(Int64(index.heapByteCount))) mapped=\(index.isMemoryMapped)")
        #expect(found == 10_000)
        #expect(rescan.hits == fixture.rowCount)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_DIR"] != nil))
    func measurePhaseMapped() throws {
        let directory = try #require(Self.phaseDirectory)
        let digest = try Self.phaseDigests(directory).mappable
        try Self.measurePhase("mapped") {
            try SourceSyncIndex.mapFile(at: directory.appendingPathComponent("committed-v2.index"), expectedSHA256: digest)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRIMUSE_SYNC_INDEX_DIR"] != nil))
    func measurePhaseHeap() throws {
        let directory = try #require(Self.phaseDirectory)
        let digest = try Self.phaseDigests(directory).legacy
        try Self.measurePhase("heap(current)") {
            try SourceSyncIndex.decodeBinary(
                Data(contentsOf: directory.appendingPathComponent("committed-v1.index"), options: .alwaysMapped),
                expectedSHA256: digest
            )
        }
    }
}
#endif
