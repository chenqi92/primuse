import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// Stage 2 的大库启动基准。回答的是同一个问题的三段: 同步装载在主线程上要
/// 多久、把同样的活儿放到主线程之外要多久、以及留在主线程的那一步(发布)
/// 还剩多少。
///
/// 规模由环境变量 `PRIMUSE_HARNESS_SONGS` 控制(默认 10_000), 两个变体分别
/// 覆盖冷启动(没有启动缓存 / 派生索引缓存)与热启动(两份缓存都在)。
///
/// 只能在 Apple 平台跑:
/// ```
/// xcodebuild test -scheme Primuse \
///   -destination 'platform=iOS Simulator,name=iPhone 16' \
///   -only-testing:PrimuseTests/LibraryStartupHarnessTests \
///   TEST_RUNNER_PRIMUSE_HARNESS_SONGS=20000
/// ```
@MainActor
final class LibraryStartupHarnessTests: XCTestCase {

    // MARK: - 规模

    /// 默认 10_000。`TEST_RUNNER_` 前缀由 xcodebuild 转交给测试进程。
    private static var songCount: Int {
        guard let raw = ProcessInfo.processInfo.environment["PRIMUSE_HARNESS_SONGS"],
              let value = Int(raw), value > 0 else { return 10_000 }
        return value
    }

    /// 低于这个规模时比例断言没有意义(装载本身只有几毫秒, 噪声占主导)。
    private static let ratioAssertionMinimumSongs = 10_000
    /// 发布步骤允许占用的主线程时间上限, 相对同步装载。
    private static let publishToSyncRatioCeiling = 0.25

    // MARK: - 夹具

    private static func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryStartupHarness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func copyDirectory(_ source: URL) throws -> URL {
        let destination = try makeStorageDirectory()
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// N 首合成歌曲, 4 个源, 专辑基数 ≈ N/12, 艺术家基数 ≈ N/40, 外加 20 个
    /// 歌单 —— 与真实中大型库的分组代价同量级。写入走正常的库 API, 所以
    /// 磁盘上的格式(SQLite + 便携快照 + 启动缓存 + 派生索引缓存)与线上一致。
    private static func makeFixture(songCount: Int) async throws -> URL {
        let directory = try makeStorageDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let sourceIDs = (0..<4).map { "harness-source-\($0)" }
        let albumCount = max(1, songCount / 12)
        let artistCount = max(1, songCount / 40)

        // 真实曲库以中文名为主, 还夹着「、」「/」连写的合唱: 艺术家解析会对
        // 每首歌做分隔符检索, 纯 ASCII 的单一名字量不出这段代价。
        let familyNames = ["周", "林", "陈", "王", "张", "李", "刘", "杨", "黄", "吴"]
        let givenNames = ["杰伦", "俊杰", "奕迅", "菲", "学友", "宇春", "绮贞", "楚生", "鹏", "若昀"]
        func artistName(_ artistIndex: Int) -> String {
            guard artistIndex % 3 != 0 else { return "Artist \(artistIndex)" }
            return familyNames[artistIndex % familyNames.count]
                + givenNames[(artistIndex / familyNames.count) % givenNames.count]
                + "\(artistIndex)"
        }
        let genres = ["流行", "Rock", "Jazz", "古典", "民谣", "Electronic", "R&B", "说唱"]

        var songsBySource: [String: [Song]] = [:]
        for index in 0..<songCount {
            let sourceID = sourceIDs[index % sourceIDs.count]
            let albumIndex = index % albumCount
            let artistIndex = index % artistCount
            let performer: String
            switch index % 10 {
            case 0: performer = artistName(artistIndex) + "、" + artistName((artistIndex + 7) % artistCount)
            case 1: performer = artistName(artistIndex) + "/" + artistName((artistIndex + 3) % artistCount)
            default: performer = artistName(artistIndex)
            }
            let song = Song(
                id: "harness-\(index)",
                title: "Track \(index)",
                albumTitle: "Album \(albumIndex)",
                artistName: performer,
                albumArtistName: artistName(albumIndex % artistCount),
                trackNumber: index % 12 + 1,
                discNumber: 1,
                duration: 180 + Double(index % 120),
                fileFormat: .flac,
                filePath: "/Music/\(sourceID)/\(albumIndex)/\(index).flac",
                sourceID: sourceID,
                genre: genres[albumIndex % genres.count],
                year: 1990 + albumIndex % 35,
                coverArtFileName: index % 12 == 0 ? "cover-\(albumIndex).jpg" : nil
            )
            songsBySource[sourceID, default: []].append(song)
        }
        for sourceID in sourceIDs {
            library.addSongs(songsBySource[sourceID] ?? [], affectedSourceIDs: [sourceID])
        }

        let allIDs = library.songs.map(\.id)
        let playlistSize = max(1, min(allIDs.count, 200))
        for playlistIndex in 0..<20 {
            let start = (playlistIndex * playlistSize) % max(1, allIDs.count)
            let end = min(allIDs.count, start + playlistSize)
            let members = start < end ? Array(allIDs[start..<end]) : []
            _ = library.createPlaylist(name: "Harness \(playlistIndex)", songIDs: members)
        }

        guard case .success = await library.persistNowAndWait() else {
            throw XCTSkip("The harness fixture did not finish persistence")
        }
        return directory
    }

    /// 冷启动变体: 丢掉两份可重建的缓存, 装载必须走 SQLite/JSON + 分组排序。
    private static func makeCold(_ fixture: URL) throws -> URL {
        let directory = try copyDirectory(fixture)
        for name in ["library-startup-cache.plist", "library-derived-index.plist"] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return directory
    }

    // MARK: - 单次测量

    private struct Measurement {
        var synchronousMilliseconds: Double
        var prepareMilliseconds: Double
        var publishMilliseconds: Double

        /// 留在主线程上的那一段占同步装载的比例。
        var publishToSyncRatio: Double {
            guard synchronousMilliseconds > 0 else { return 0 }
            return publishMilliseconds / synchronousMilliseconds
        }
    }

    /// 三段都各用一份干净的副本, 互不污染: 同步装载会补写缓存, 发布也会。
    private func measureStartup(
        fixture: URL,
        variant: String,
        cold: Bool,
        songCount: Int
    ) async throws -> Measurement {
        let synchronousDirectory = cold
            ? try Self.makeCold(fixture)
            : try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: synchronousDirectory) }
        let preparedDirectory = cold
            ? try Self.makeCold(fixture)
            : try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }

        // (1) 今天的同步路径: 整库装载全程占用主线程。
        let synchronousStartedAt = ProcessInfo.processInfo.systemUptime
        let synchronous = MusicLibrary(storageDirectory: synchronousDirectory)
        let synchronousFinishedAt = ProcessInfo.processInfo.systemUptime

        // (2) Stage 2 的准备: 同样的读取 / 迁移 / 分组, 但在主线程之外。
        let prepareStartedAt = ProcessInfo.processInfo.systemUptime
        let prepared = await MusicLibrary.prepareStartup(storageDirectory: preparedDirectory)
        let prepareFinishedAt = ProcessInfo.processInfo.systemUptime

        // (3) 唯一留在主线程上的一步。
        let library = MusicLibrary.makePreparing(storageDirectory: preparedDirectory)
        let publishStartedAt = ProcessInfo.processInfo.systemUptime
        library.publish(prepared)
        let publishFinishedAt = ProcessInfo.processInfo.systemUptime

        XCTAssertEqual(synchronous.songs.count, songCount, "同步装载读回的行数不对")
        assertLibraryStartupParity(synchronous: synchronous, prepared: library)

        let measurement = Measurement(
            synchronousMilliseconds: (synchronousFinishedAt - synchronousStartedAt) * 1_000,
            prepareMilliseconds: (prepareFinishedAt - prepareStartedAt) * 1_000,
            publishMilliseconds: (publishFinishedAt - publishStartedAt) * 1_000
        )
        // 与库自己打出的 `🚀 library load …` 同流, 方便在一份日志里对读。
        plog(String(
            format: "🚀 library harness %@ songs=%d sync=%.0fms prepare=%.0fms publish=%.0fms publish/sync=%.1f%%",
            variant,
            songCount,
            measurement.synchronousMilliseconds,
            measurement.prepareMilliseconds,
            measurement.publishMilliseconds,
            measurement.publishToSyncRatio * 100
        ))
        return measurement
    }

    private func assertPublishStaysOffTheCriticalPath(
        _ measurement: Measurement,
        songCount: Int,
        variant: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard songCount >= Self.ratioAssertionMinimumSongs else { return }
        // 断言的是比例而不是绝对毫秒数: 模拟器 / 设备 / 热度都会整体缩放,
        // 但"主线程只剩发布"这个结论不应该随之改变。
        XCTAssertLessThan(
            measurement.publishToSyncRatio,
            Self.publishToSyncRatioCeiling,
            """
            \(variant): 发布步骤占用的主线程时间 \
            \(String(format: "%.0f", measurement.publishMilliseconds))ms 相对同步装载 \
            \(String(format: "%.0f", measurement.synchronousMilliseconds))ms 超过了 \
            \(Int(Self.publishToSyncRatioCeiling * 100))%
            """,
            file: file,
            line: line
        )
    }

    // MARK: - 冷启动 (没有启动缓存 / 派生索引缓存)

    func testColdStartupMovesTheLoadOffTheMainActor() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let measurement = try await measureStartup(
            fixture: fixture,
            variant: "cold",
            cold: true,
            songCount: songCount
        )
        assertPublishStaysOffTheCriticalPath(measurement, songCount: songCount, variant: "cold")
    }

    // MARK: - 热启动 (启动缓存命中)

    func testWarmStartupMovesTheLoadOffTheMainActor() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.appendingPathComponent("library-startup-cache.plist").path
            ),
            "热启动变体需要夹具里带着启动缓存"
        )

        let measurement = try await measureStartup(
            fixture: fixture,
            variant: "warm",
            cold: false,
            songCount: songCount
        )
        assertPublishStaysOffTheCriticalPath(measurement, songCount: songCount, variant: "warm")
    }

    // MARK: - 真机常见状态: 两份缓存都命中的重复冷启动

    /// 上面的「热启动」夹具只是刚写完库, 装载日志是 `startupCache=miss
    /// derivedCache=miss`, 还会重跑一次装载迁移。真机上反复启动时的状态是
    /// 两份缓存都命中, 这里先完整走一遍准备→发布→落盘把缓存补齐, 再连测几轮。
    func testRepeatedStartupWithBothCachesHit() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let settle = MusicLibrary.makePreparing(storageDirectory: fixture)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: fixture))
        guard case .success = await settle.persistNowAndWait() else {
            throw XCTSkip("The harness fixture did not settle its launch caches")
        }
        await Self.drainLaunchCacheWrites(settle)

        // 原地连测: 启动缓存的指纹带文件编号, 复制出来的目录一定对不上。
        // 两份缓存都命中时装载不写盘, 每一轮读到的是同一份状态。
        var rounds: [Double] = []
        for round in 1...3 {
            let directory = fixture
            let startedAt = ProcessInfo.processInfo.systemUptime
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            let preparedAt = ProcessInfo.processInfo.systemUptime
            let library = MusicLibrary.makePreparing(storageDirectory: directory)
            library.publish(prepared)
            XCTAssertEqual(library.songs.count, songCount)
            // 发布可能顺手刷新过期的启动缓存, 等它落盘, 下一轮才是真机上的稳态。
            await Self.drainLaunchCacheWrites(library)
            rounds.append((preparedAt - startedAt) * 1_000)
            plog(String(format: "🚀 library harness repeated round=%d songs=%d prepare=%.0fms", round, songCount, rounds.last ?? 0))
        }
        plog(String(format: "🚀 library harness repeated songs=%d average=%.0fms", songCount, rounds.reduce(0, +) / Double(rounds.count)))
    }

    /// 等在途的快照与启动缓存写入落完(外部写入栅栏会等这两条链)。
    private static func drainLaunchCacheWrites(_ library: MusicLibrary) async {
        await library.beginExternalSnapshotWrite()
        library.endExternalSnapshotWrite()
    }

    // MARK: - XCTClockMetric 基线

    /// 热启动夹具上的同步装载基线。重复跑是安全的: 启动缓存命中时装载不会
    /// 再补写缓存, 每一轮读到的都是同一份磁盘状态。
    func testSynchronousWarmStartupClockBaseline() async throws {
        let songCount = Self.songCount
        let fixture = try await Self.makeFixture(songCount: songCount)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let directory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }

        measure(metrics: [XCTClockMetric()]) {
            let library = MusicLibrary(storageDirectory: directory)
            XCTAssertEqual(library.songs.count, songCount)
        }
    }

    // MARK: - 规模实测: 几十万到上百万首的常驻内存

    /// 两步分在两次 `xcodebuild test` 里跑, 测量进程里没有建夹具留下的垃圾:
    /// ```
    /// TEST_RUNNER_PRIMUSE_SCALE_DIR=/path/scale-400000 TEST_RUNNER_PRIMUSE_SCALE_SONGS=400000 \
    ///   xcodebuild test … -only-testing:PrimuseTests/LibraryStartupHarnessTests/testBuildScaleFixture
    /// TEST_RUNNER_PRIMUSE_SCALE_DIR=/path/scale-400000 \
    ///   xcodebuild test … -only-testing:PrimuseTests/LibraryStartupHarnessTests/testScaleFixtureFootprint
    /// ```
    /// 曲库按真实大库的形状造: 中文歌名、多级目录路径、拼音、封面与艺人图文件名,
    /// 单一服务器源为主再加一个小的本机源, 每张专辑 12 首、每位歌手约 3 张专辑。
    private static var scaleDirectory: URL? {
        ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func residentFootprint() -> (current: UInt64, peak: UInt64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        return (info.phys_footprint, info.ledger_phys_footprint_peak > 0 ? UInt64(info.ledger_phys_footprint_peak) : info.phys_footprint)
    }

    private static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    func testBuildScaleFixture() async throws {
        guard let directory = Self.scaleDirectory,
              let raw = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_SONGS"],
              let songCount = Int(raw), songCount > 0 else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR and PRIMUSE_SCALE_SONGS to build the scale fixture")
        }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let footprintBeforeScan = Self.residentFootprint()
        let library = MusicLibrary(storageDirectory: directory)
        let serverSource = "scale-server-source"
        // 两个都是服务器源: 本机源记录带设备归属, 拷进别的安装里会被当成
        // 别的设备的源清掉, 连带删掉它的歌。
        let secondSource = "scale-second-source"
        let surnames = ["周", "林", "陈", "王", "张", "李", "刘", "杨", "黄", "吴", "赵", "孙"]
        let given = ["杰伦", "俊杰", "奕迅", "菲", "学友", "宇春", "绮贞", "楚生", "鹏", "若昀", "子棋", "雨生"]
        let words = ["夜曲", "晴天", "稻香", "告白气球", "七里香", "青花瓷", "以父之名", "简单爱", "安静", "彩虹", "说好的幸福呢", "听妈妈的话"]
        let genres = ["流行", "Rock", "Jazz", "古典", "民谣", "Electronic", "R&B", "说唱", "Soundtrack", "Metal"]
        let albumCount = max(1, songCount / 12)
        let artistCount = max(1, albumCount / 3)
        func artist(_ index: Int) -> String {
            index % 4 == 0
                ? "Artist Name \(index)"
                : surnames[index % surnames.count] + given[(index / surnames.count) % given.count] + "\(index)"
        }
        var allIDs: [String] = []
        allIDs.reserveCapacity(songCount)
        var batch: [Song] = []
        batch.reserveCapacity(20_000)
        var batchSource = serverSource
        func flush() {
            guard !batch.isEmpty else { return }
            // 和扫描的中间提交一样不剪枝, 也把整库维护延后到最后。
            library.addSongs(
                batch,
                affectedSourceIDs: [batchSource],
                notifyRemovals: false,
                pruneMissingSongs: false,
                indexMaintenance: .deferredIncremental
            )
            batch.removeAll(keepingCapacity: true)
        }
        for index in 0..<songCount {
            let albumIndex = index / 12
            let artistIndex = albumIndex % artistCount
            let sourceID = index < songCount - songCount / 20 ? serverSource : secondSource
            if sourceID != batchSource { flush(); batchSource = sourceID }
            let artistName = artist(artistIndex)
            let albumTitle = words[albumIndex % words.count] + " 专辑 \(albumIndex)"
            let title = words[(index * 7) % words.count] + "（第\(index)首）" + (index % 3 == 0 ? " Live Version" : "")
            let track = index % 12 + 1
            let duration = 180 + Double(index % 240)
            let bitRate = index % 5 == 0 ? 320 : 1_000
            var song = Song(
                id: String(format: "%016llx%016llx%016llx%016llx", UInt64(index) &* 0x9E3779B97F4A7C15, UInt64(index) ^ 0xA5A5_5A5A_DEAD_BEEF, UInt64(index) &* 31, UInt64(index)),
                title: title,
                albumTitle: albumTitle,
                artistName: index % 10 == 0 ? artistName + "、" + artist((artistIndex + 5) % artistCount) : artistName,
                albumArtistName: artistName,
                trackNumber: track,
                discNumber: 1,
                duration: duration,
                fileFormat: index % 5 == 0 ? .mp3 : .flac,
                filePath: "/music/\(artistName)/\(albumTitle)/\(String(format: "%02d", track)) \(title).\(index % 5 == 0 ? "mp3" : "flac")",
                sourceID: sourceID,
                // 与时长、码率对得上, 否则回填的「截断时长」迁移会把它们当坏数据重置。
                fileSize: Int64(duration * Double(bitRate) * 125) + Int64(index % 4_096),
                bitRate: bitRate,
                sampleRate: 44_100,
                bitDepth: index % 5 == 0 ? nil : 16,
                genre: genres[albumIndex % genres.count],
                year: 1980 + albumIndex % 45,
                lastModified: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                coverArtFileName: "al-\(albumIndex)_\(String(format: "%08x", albumIndex &* 2_654_435_761))",
                artistArtworkFileName: "ar-\(artistIndex)_\(String(format: "%08x", artistIndex &* 40_503))"
            )
            if index % 7 == 0 { song.lyricsFileName = "\(String(format: "%02d", track)) \(title).lrc" }
            if index % 4 == 0 {
                song.replayGainTrackGain = -6.5
                song.replayGainTrackPeak = 0.98
            }
            allIDs.append(song.id)
            batch.append(song)
            if batch.count == 20_000 { flush() }
        }
        flush()
        await library.waitForPendingIndex()
        // 首轮扫描刚入库完的常驻: 和下次启动从增量库装载时应当相当。
        let footprintAfterScan = Self.residentFootprint()
        for playlistIndex in 0..<30 {
            let start = (playlistIndex * 7_919) % max(1, songCount)
            let ids = Array(allIDs[start..<min(allIDs.count, start + 500)])
            _ = library.createPlaylist(name: "Scale \(playlistIndex)", songIDs: ids)
        }
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The scale fixture did not persist")
            return
        }
        await Self.drainLaunchCacheWrites(library)
        // 夹具目录可以整份拷进模拟器里 App 的 Application Support/Primuse 当真实曲库用:
        // 源记录也写进去, 否则启动对账会把找不到来源的歌清掉。服务器指向一个
        // 连不上的地址, 界面照常浏览, 只是不能真的播放。
        let sources = SourcesStore(storageDirectoryURL: directory)
        try sources.addDurably(MusicSource(
            id: serverSource, name: "Scale Navidrome", type: .navidrome,
            host: "127.0.0.1", port: 9, useSsl: false, username: "scale"
        ))
        try sources.addDurably(MusicSource(
            id: secondSource, name: "Scale Navidrome 2", type: .navidrome,
            host: "127.0.0.1", port: 10, useSsl: false, username: "scale"
        ))
        // 再走一遍真机的启动路径, 把启动缓存与派生索引缓存补齐成稳态。
        let settle = MusicLibrary.makePreparing(storageDirectory: directory)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await settle.waitForPendingIndex()
        _ = await settle.persistNowAndWait()
        await Self.drainLaunchCacheWrites(settle)
        let summary = String(
            format: "📏 scale fixture songs=%d built in %.0fs scanResident=%.0fMB scanPeak=%.0fMB dir=%@",
            library.songs.count, ProcessInfo.processInfo.systemUptime - startedAt,
            Self.megabytes(footprintAfterScan.current) - Self.megabytes(footprintBeforeScan.current),
            Self.megabytes(footprintAfterScan.peak), directory.path
        )
        plog(summary)
        print(summary)
        XCTAssertEqual(settle.songs.count, songCount)
    }

    /// 测量前在夹具副本上先走一遍启动: 副本的文件号变了, 启动缓存与派生缓存
    /// 都要按新的快照指纹重写一次, 之后量到的才是日常的二次启动。
    func testSettleScaleFixture() async throws {
        guard let directory = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let settle = MusicLibrary.makePreparing(storageDirectory: directory)
        settle.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await settle.waitForPendingIndex()
        _ = await settle.persistNowAndWait()
        await Self.drainLaunchCacheWrites(settle)
    }

    func testScaleFixtureFootprint() async throws {
        guard let directory = Self.scaleDirectory,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("library-songs.sqlite").path) else {
            throw XCTSkip("Build the scale fixture first (PRIMUSE_SCALE_DIR)")
        }
        let before = Self.residentFootprint()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let preparedAt: TimeInterval
        let library: MusicLibrary
        // 装载结果与下面的查找表都收在各自的作用域里: 它们握着整库数组,
        // 活到函数结束会让后面的补丁量到一次 App 里不会发生的整库复制。
        do {
            let prepared = await MusicLibrary.prepareStartup(storageDirectory: directory)
            preparedAt = ProcessInfo.processInfo.systemUptime
            library = MusicLibrary.makePreparing(storageDirectory: directory)
            library.publish(prepared)
        }
        let publishedAt = ProcessInfo.processInfo.systemUptime
        await library.waitForPendingIndex()
        let indexedAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let after = Self.residentFootprint()
        let songCount = library.songs.count

        var inPlace = ["load=\(library.patchWouldWriteInPlaceForTesting())"]
        let idsStartedAt = ProcessInfo.processInfo.systemUptime
        let musicIDs = library.musicSongs.map(\.id)
        let idsAt = ProcessInfo.processInfo.systemUptime
        let plannedCount: Int?
        do {
            let lookup = library.visibleSongLookup()
            plannedCount = LargeQueueRequestPlanner.plan(
                ids: musicIDs, startIndex: 0, order: .shuffled,
                includes: { lookup.contains(id: $0, playableOnly: true) },
                resolve: { lookup.song(id: $0) }
            )?.items.count
        }
        let plannedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(plannedCount, min(songCount, QueueWindowPolicy.windowLimit))
        inPlace.append("plan=\(library.patchWouldWriteInPlaceForTesting())")

        let resident = Self.megabytes(after.current - min(after.current, before.current))
        let summary = (String(
            format: "📏 scale footprint songs=%d before=%.0fMB after=%.0fMB resident=%.0fMB perSong=%.0fB peak=%.0fMB prepare=%.0fms publish=%.0fms index=%.0fms musicIDs=%.0fms plan=%.0fms",
            songCount,
            Self.megabytes(before.current),
            Self.megabytes(after.current),
            resident,
            resident * 1_048_576 / Double(max(1, songCount)),
            Self.megabytes(after.peak),
            (preparedAt - startedAt) * 1_000,
            (publishedAt - preparedAt) * 1_000,
            (indexedAt - publishedAt) * 1_000,
            (idsAt - idsStartedAt) * 1_000,
            (plannedAt - idsAt) * 1_000
        ))
        plog(summary)
        print(summary)

        // 回填期间最常见的两种补丁: 封面/歌词引用、歌词全文。每批量一次耗时与常驻增量。
        let patchIDs = Array(library.songs.prefix(200).map(\.id))
        let patchBefore = Self.residentFootprint()
        let patchStartedAt = ProcessInfo.processInfo.systemUptime
        for id in patchIDs { library.updateAssetReferences(songID: id, coverRef: "patched-cover-\(id).jpg") }
        library.flushPendingAssetReferencePatches()
        let assetPatchAt = ProcessInfo.processInfo.systemUptime
        library.updateLyricsText(Dictionary(uniqueKeysWithValues: patchIDs.map { ($0, "歌词 \($0)") }))
        let lyricsPatchAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        inPlace.append("patched=\(library.patchWouldWriteInPlaceForTesting())")
        let beforeReplace = Self.residentFootprint()
        print("📏 scale sharing before replace: \(library.storageSharingSummaryForTesting)")
        // 开播时的时长校正: 一首歌的整行替换。
        var corrected = try XCTUnwrap(library.song(id: patchIDs[5]))
        corrected.duration += 7
        let replaceStartedAt = ProcessInfo.processInfo.systemUptime
        library.replaceSong(corrected)
        let replaceAt = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .seconds(2))
        let afterReplace = Self.residentFootprint()
        print(String(
            format: "📏 scale replaceSong songs=%d main=%.0fms residentGrowth=%.0fMB sharing after: %@",
            songCount, (replaceAt - replaceStartedAt) * 1_000,
            Self.megabytes(afterReplace.current) - Self.megabytes(beforeReplace.current),
            library.storageSharingSummaryForTesting
        ))
        try await Task.sleep(for: .seconds(2))
        inPlace.append("replaced=\(library.patchWouldWriteInPlaceForTesting())")
        print("📏 scale inPlace " + inPlace.joined(separator: " "))
        let patchAfter = Self.residentFootprint()
        let stages = await library.measureIndexRebuildStagesForTesting()
        let patchSummary = String(
            format: "📏 scale patches songs=%d assetPatch=%.0fms lyricsPatch=%.0fms residentGrowth=%.0fMB rebuild: %@",
            songCount,
            (assetPatchAt - patchStartedAt) * 1_000,
            (lyricsPatchAt - assetPatchAt) * 1_000,
            Self.megabytes(patchAfter.current) - Self.megabytes(patchBefore.current),
            stages
        )
        plog(patchSummary)
        print(patchSummary)

        // 点一次「喜欢」或改一次歌单就会武装一次整库快照写: 量它的耗时与常驻增量。
        let snapshotBefore = Self.residentFootprint()
        let snapshotStartedAt = ProcessInfo.processInfo.systemUptime
        let snapshotResult = await library.persistNowAndWait()
        let snapshotAt = ProcessInfo.processInfo.systemUptime
        let snapshotAfter = Self.residentFootprint()
        let snapshotSize = (try? FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("library-cache.json").path
        )[.size] as? Int) ?? 0
        let snapshotSummary = String(
            format: "📏 scale snapshot songs=%d write=%.0fms bytes=%.0fMB residentGrowth=%.0fMB peak=%.0fMB ok=%@",
            songCount,
            (snapshotAt - snapshotStartedAt) * 1_000,
            Double(snapshotSize) / 1_048_576,
            Self.megabytes(snapshotAfter.current) - Self.megabytes(snapshotBefore.current),
            Self.megabytes(snapshotAfter.peak),
            { if case .success = snapshotResult { return "yes" } else { return "no" } }()
        )
        plog(snapshotSummary)
        print(snapshotSummary)
        XCTAssertGreaterThan(songCount, 0)
    }

}
