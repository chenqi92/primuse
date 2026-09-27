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
}
