import CryptoKit
import Darwin
import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// DL3 C 的量法:10 万首规模夹具(`PRIMUSE_SCALE_DIR`,20g 用的那一份;目录夹具在它旁边的 `-catalog`),歌曲模型
/// 真放掉之后从目录导出整库快照、再走一遍 iCloud 上传的整理(`preparePortableSnapshotDataIncludingArtworkAssets`),
/// 照以前攒在内存里与写进临时文件映射回来两种各一次:之前、导出期间的峰值、拿着导出的那份、整理期间的峰值、
/// 拿着两份、全放掉之后,各记 phys_footprint 与 malloc 在用的字节。没有夹具时跳过。
///   TEST_RUNNER_PRIMUSE_SCALE_DIR=…/scale-100k xcodebuild test … -only-testing:PrimuseTests/LibraryExportMemoryHarnessTests
@MainActor
final class LibraryExportMemoryHarnessTests: XCTestCase {
    func testScaleFixtureExportAndUploadPreparationMemory() async throws {
        guard let scale = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR to the scale fixture")
        }
        let fixture = scale.deletingLastPathComponent().appendingPathComponent(scale.lastPathComponent + "-catalog")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-catalog.sqlite").path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dl3-export-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        let host = try XCTUnwrap(library.catalogHost)
        for _ in 0..<1_500 where !host.revisions.isReadable || !host.mirror.releaseCategoriesComplete {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(host.revisions.isReadable && host.mirror.releaseCategoriesComplete, "the catalog settled")
        let songCount = library.songs.count
        library.applySongModelResidencySettings(.init(isEnabled: true, foregroundHold: false, playbackBlocksRelease: true))
        var outcome = await library.releaseSongModelIfIdle(trigger: "dl3 export harness")
        for _ in 0..<120 where outcome == .skipped("catalog shadow verification in flight") {
            try await Task.sleep(for: .seconds(1))
            outcome = await library.releaseSongModelIfIdle(trigger: "dl3 export harness")
        }
        guard case .released = outcome else { return XCTFail("not released: \(outcome)") }
        await library.songModelReleaseDidReclaimMemory()
        await library.releaseDatabaseMemoryAndWait()
        host.reader.rowCache.removeAll()
        _ = try await settle()
        let started = Self.reading()
        Self.report(String(format: "📏 dl3 export harness songs=%d released footprint=%.1fMB mallocInUse=%.1fMB",
                           songCount, Self.mb(started.footprint), Self.mb(started.malloc)))

        var fingerprints: [String: Data] = [:]
        for (name, inMemory) in [("in memory (before DL3)", true), ("file-backed (DL3)", false), ("in memory again", true)] {
            LibraryCatalogExportOutput.keepsInMemoryForTesting = inMemory
            defer { LibraryCatalogExportOutput.keepsInMemoryForTesting = false }
            let before = try await settle()
            var line = String(format: "📏 dl3 export %@: before footprint=%.1fMB malloc=%.1fMB", name,
                              Self.mb(before.footprint), Self.mb(before.malloc))
            do {
                let sampler = Sampler(before)
                let export = await sampler.measure { await library.portableSnapshotIncludingSongs(byteLimit: 2 << 30) }
                guard case .snapshot(let data) = export else { return XCTFail("\(name): \(export)") }
                let holding = Self.reading()
                fingerprints[name] = Self.fingerprint(data)
                line += String(format: " | export bytes=%d ms=%.0f peak footprint=%.1fMB malloc=%.1fMB | holding footprint=%.1fMB malloc=%.1fMB",
                               data.count, sampler.milliseconds, Self.mb(sampler.peak.footprint), Self.mb(sampler.peak.malloc),
                               Self.mb(holding.footprint), Self.mb(holding.malloc))
                let prepareSampler = Sampler(holding)
                let prepared = await prepareSampler.measure {
                    await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(data)
                }
                let holdingBoth = Self.reading()
                line += String(format: " | prepare result=%@ ms=%.0f peak footprint=%.1fMB malloc=%.1fMB | holding both footprint=%.1fMB malloc=%.1fMB",
                               prepared.map { "\($0.data.count)" } ?? "nil (over the upload limit)", prepareSampler.milliseconds,
                               Self.mb(prepareSampler.peak.footprint), Self.mb(prepareSampler.peak.malloc),
                               Self.mb(holdingBoth.footprint), Self.mb(holdingBoth.malloc))
            }
            let after = try await settle()
            line += String(format: " | after footprint=%.1fMB malloc=%.1fMB", Self.mb(after.footprint), Self.mb(after.malloc))
            Self.report(line)
        }
        XCTAssertEqual(fingerprints["file-backed (DL3)"], fingerprints["in memory (before DL3)"], "the same bytes")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0, "no load")
        await library.stopCatalogMirror()
    }

    // MARK: - DL4: the upload preparation page by page

    /// DL4 的量法:同一份规模夹具,装着歌曲模型时从内存导出、真放掉之后从目录导出(都按 2 GiB 上限编整库),
    /// 两份输入各自整理几遍 —— 局域网与 iCloud 的标准上限(10 万首放不下,编到 64 MiB 就停)、iCloud 关掉主源
    /// (留下 5%,放得下)、上限放到 2 GiB 把整库整理完;10 万首时以前的写法(`…Reference`)也照样各跑一遍比字节。
    /// 每遍记之前、峰值、拿着结果、放掉之后的 phys_footprint 与 malloc 在用。最后(只在 10 万首)找以前那份
    /// 返回之后还占着的 0.9 GB 是什么:返回后每隔一会儿量一次;同一个整理放在「每个任务片段一个自动释放池」的
    /// 执行器上再跑一次;整份解码、整份编码、整库专辑艺人分组各自包在自动释放池里,量池里放掉之后与出池之后。
    ///   TEST_RUNNER_PRIMUSE_SCALE_DIR=…/scale-100k xcodebuild test … -only-testing:PrimuseTests/LibraryExportMemoryHarnessTests
    func testScaleFixtureUploadPreparationPageByPageMemory() async throws {
        guard let scale = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR to the scale fixture")
        }
        let fixture = scale.deletingLastPathComponent().appendingPathComponent(scale.lastPathComponent + "-catalog")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-catalog.sqlite").path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dl4-prepare-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        let host = try XCTUnwrap(library.catalogHost)
        for _ in 0..<1_500 where !host.revisions.isReadable || !host.mirror.releaseCategoriesComplete {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(host.revisions.isReadable && host.mirror.releaseCategoriesComplete, "the catalog settled")
        let songCount = library.songs.count
        let runsReference = songCount <= 150_000
        let wholeLibrary = MusicLibrary.PortableSnapshotSizeLimits(encodedBytes: 2 << 30, withoutArtworkBytes: 2 << 30)
        let cloud = [
            MusicSource(id: "scale-server-source", name: "Scale Navidrome", type: .navidrome),
            MusicSource(id: "scale-second-source", name: "Scale second", type: .navidrome),
        ]
        func newLegs(_ export: Data) -> [(String, @MainActor () async -> MusicLibrary.PortableSnapshotTransferData?)] {
            [
                ("new LAN standard", { await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(export) }),
                ("new iCloud standard", { await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(export, cloudSources: cloud) }),
                ("new iCloud main source opted out", {
                    await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
                        export, cloudSources: cloud, excludedSourceIDs: ["scale-server-source"])
                }),
                ("new iCloud whole library", {
                    await MusicLibrary.preparePortableSnapshotPageByPage(
                        export, cloudSources: cloud, excludedSourceIDs: [], assetStore: .shared,
                        maximumArtworkBytes: MusicLibrary.portableArtworkBudgetBytes, limits: wholeLibrary)
                }),
            ]
        }
        func referenceLegs(_ export: Data) -> [(String, @MainActor () async -> MusicLibrary.PortableSnapshotTransferData?)] {
            [
                ("old iCloud standard", {
                    await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(export, cloudSources: cloud)
                }),
                ("old iCloud main source opted out", {
                    await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(
                        export, cloudSources: cloud, excludedSourceIDs: ["scale-server-source"])
                }),
                ("old iCloud whole library", {
                    await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(
                        export, cloudSources: cloud, limits: wholeLibrary)
                }),
            ]
        }
        var fingerprints: [String: String] = [:]
        func runLegs(_ entry: String, _ export: Data) async throws {
            Self.report("📏 dl4 \(entry) export bytes=\(export.count) songs=\(songCount)")
            for (name, body) in newLegs(export) + (runsReference ? referenceLegs(export) : []) {
                fingerprints["\(entry) \(name)"] = try await measureLeg("\(entry) \(name)", body)
            }
        }

        // 装着模型:导出来自内存里的歌。
        do {
            guard case .snapshot(let loadedExport) = await library.portableSnapshotIncludingSongs(byteLimit: 2 << 30) else {
                return XCTFail("the loaded export")
            }
            try await runLegs("loaded", loadedExport)
        }
        library.applySongModelResidencySettings(.init(isEnabled: true, foregroundHold: false, playbackBlocksRelease: true))
        var outcome = await library.releaseSongModelIfIdle(trigger: "dl4 preparation harness")
        for _ in 0..<120 where outcome == .skipped("catalog shadow verification in flight") {
            try await Task.sleep(for: .seconds(1))
            outcome = await library.releaseSongModelIfIdle(trigger: "dl4 preparation harness")
        }
        guard case .released = outcome else { return XCTFail("not released: \(outcome)") }
        await library.songModelReleaseDidReclaimMemory()
        await library.releaseDatabaseMemoryAndWait()
        host.reader.rowCache.removeAll()
        guard case .snapshot(let releasedExport) = await library.portableSnapshotIncludingSongs(byteLimit: 2 << 30) else {
            return XCTFail("the released export")
        }
        try await runLegs("released", releasedExport)

        for leg in ["iCloud standard", "iCloud main source opted out", "iCloud whole library"] {
            let reference = runsReference ? fingerprints["loaded old \(leg)"] : fingerprints["loaded new \(leg)"]
            XCTAssertEqual(fingerprints["loaded new \(leg)"], reference, "loaded \(leg): same bytes as before")
            XCTAssertEqual(fingerprints["released new \(leg)"], fingerprints["loaded new \(leg)"], "\(leg): loaded and released")
            if runsReference { XCTAssertEqual(fingerprints["released old \(leg)"], reference, "released \(leg)") }
        }
        XCTAssertEqual(fingerprints["released new iCloud standard"], "nil", "the whole library does not fit the upload")
        XCTAssertNotEqual(fingerprints["released new iCloud whole library"], "nil")
        XCTAssertNotEqual(fingerprints["released new iCloud main source opted out"], "nil")

        if runsReference {
            try await findTheResidue(releasedExport)
            try await measureTheReceivingSide(releasedExport)
        }
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0, "no load after the release")
        await library.stopCatalogMirror()
    }

    /// 一遍整理:之前、峰值、拿着结果、放掉之后。返回结果的指纹(长度 + SHA-256),nil 记成 "nil"。
    private func measureLeg(
        _ name: String, _ body: @MainActor () async -> MusicLibrary.PortableSnapshotTransferData?
    ) async throws -> String {
        let before = try await settle()
        var line = String(format: "📏 dl4 %@: before footprint=%.1fMB malloc=%.1fMB", name,
                          Self.mb(before.footprint), Self.mb(before.malloc))
        let fingerprint: String
        do {
            let sampler = Sampler(before)
            let result = await sampler.measure { await body() }
            let holding = Self.reading()
            fingerprint = result.map { Self.fingerprint($0.data).map { String(format: "%02x", $0) }.joined() } ?? "nil"
            let summary = result.map {
                "bytes=\($0.data.count) songs=\($0.eligibleSongCount) lyricsNames=\($0.eligibleLyricsFileNames?.count ?? -1)"
            } ?? "nil"
            line += String(format: " | result %@ ms=%.0f peak footprint=%.1fMB malloc=%.1fMB | holding footprint=%.1fMB malloc=%.1fMB",
                           summary, sampler.milliseconds, Self.mb(sampler.peak.footprint), Self.mb(sampler.peak.malloc),
                           Self.mb(holding.footprint), Self.mb(holding.malloc))
        }
        let after = try await settle()
        line += String(format: " | after footprint=%.1fMB malloc=%.1fMB", Self.mb(after.footprint), Self.mb(after.malloc))
        Self.report(line)
        return fingerprint
    }

    /// 以前那份整理返回之后还占着的那一大块是什么。
    private func findTheResidue(_ export: Data) async throws {
        func timeline(_ name: String, _ body: @MainActor () async -> MusicLibrary.PortableSnapshotTransferData?) async throws {
            let before = try await settle()
            let sampler = Sampler(before)
            let result = await sampler.measure { await body() }
            var line = String(format: "📏 dl4 residue %@: before malloc=%.1fMB peak=%.1fMB | right after return malloc=%.1fMB",
                              name, Self.mb(before.malloc), Self.mb(sampler.peak.malloc), Self.mb(Self.reading().malloc))
            var elapsed = 0
            for delay in [100, 400, 500, 1_000, 1_000, 2_000] {
                try await Task.sleep(for: .milliseconds(delay))
                elapsed += delay
                line += String(format: " +%dms=%.1fMB", elapsed, Self.mb(Self.reading().malloc))
            }
            withExtendedLifetime(result) {}
            Self.report(line)
        }
        try await timeline("old LAN standard (default executor)") {
            await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(export)
        }
        let executor = AutoreleasePoolPerJobExecutor()
        try await timeline("old LAN standard (an autorelease pool per job)") {
            await withTaskExecutorPreference(executor) {
                await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(export)
            }
        }
        try await timeline("new LAN standard (default executor)") {
            await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(export)
        }

        // 各步各自包在自动释放池里:拿着结果、池里放掉之后、出池之后。
        _ = try await settle()
        let stages = await Task.detached(priority: .userInitiated) { () -> String in
            var line = String(format: "📏 dl4 residue stages: start malloc=%.1fMB", Self.mb(Self.reading().malloc))
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            autoreleasepool {
                var snapshot = try? decoder.decode(MusicLibrary.Snapshot.self, from: export)
                line += String(format: " | decode holding=%.1fMB", Self.mb(Self.reading().malloc))
                autoreleasepool {
                    let encoded = snapshot.flatMap { try? encoder.encode($0) }
                    line += String(format: " | encode holding=%.1fMB bytes=%d", Self.mb(Self.reading().malloc), encoded?.count ?? -1)
                }
                line += String(format: " | encode after pool=%.1fMB", Self.mb(Self.reading().malloc))
                autoreleasepool {
                    let derived = snapshot.map {
                        MusicLibrary.computeAlbumsAndArtists(songs: $0.songs, configuration: ArtistNameConfiguration.load(from: .standard))
                    }
                    line += String(format: " | grouping holding=%.1fMB artists=%d", Self.mb(Self.reading().malloc),
                                   derived?.artists.count ?? -1)
                }
                line += String(format: " | grouping after pool=%.1fMB", Self.mb(Self.reading().malloc))
                snapshot = nil
                line += String(format: " | decoded dropped in pool=%.1fMB", Self.mb(Self.reading().malloc))
            }
            line += String(format: " | after pool=%.1fMB", Self.mb(Self.reading().malloc))
            return line
        }.value
        Self.report(stages)
    }

    /// 以前那份整理返回之后还占着的那一大块:在同一个任务里(不跳回主线程)返回后每隔一会儿量一次;再把它的几步在一个
    /// 异步任务里照原样一步步做(整份解码、收封面、整份编码、放掉解出来的歌),每步之后与 100 ms 后各量一次,看是哪一步
    /// 放掉的内存过一会儿才回来。只在 10 万首、`PRIMUSE_SCALE_DIR` 给了时跑。
    func testScaleFixtureOldPreparationResidueAfterReturn() async throws {
        guard let scale = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR to the scale fixture")
        }
        let fixture = scale.deletingLastPathComponent().appendingPathComponent(scale.lastPathComponent + "-catalog")
        guard FileManager.default.fileExists(atPath: fixture.appendingPathComponent("library-catalog.sqlite").path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dl4-residue-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary.makePreparing(storageDirectory: directory, catalogMirroring: .enabled(startDelay: .zero))
        library.publish(await MusicLibrary.prepareStartup(storageDirectory: directory))
        await library.waitForPendingIndex()
        await library.waitForCatalogMirror()
        guard library.songs.count <= 150_000 else { throw XCTSkip("the old preparation is only run at 100k") }
        guard case .snapshot(let export) = await library.portableSnapshotIncludingSongs(byteLimit: 2 << 30) else {
            return XCTFail("the loaded export")
        }
        await library.stopCatalogMirror()

        @Sendable func timeline(_ start: Double) async -> String {
            var line = ""
            var elapsed = 0
            for delay in [50, 50, 100, 100, 200, 500] {
                try? await Task.sleep(for: .milliseconds(delay))
                elapsed += delay
                line += String(format: " +%dms=%.1f", elapsed, Self.mb(Self.reading().malloc) - start)
            }
            return line
        }
        _ = try await settle()
        let sameTask = await Task.detached(priority: .userInitiated) { () -> String in
            let start = Self.mb(Self.reading().malloc)
            let result = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(export)
            var line = String(format: "📏 dl4 residue in the same task (MB above start %.1f): returned %@ =%.1f", start,
                              result == nil ? "nil" : "data", Self.mb(Self.reading().malloc) - start)
            line += await timeline(start)
            return line
        }.value
        Self.report(sameTask)

        _ = try await settle()
        let phases = await Task.detached(priority: .userInitiated) { () -> String in
            let start = Self.mb(Self.reading().malloc)
            var line = String(format: "📏 dl4 residue phases (MB above start %.1f):", start)
            func note(_ name: String) async {
                line += String(format: " | %@ =%.1f", name, Self.mb(Self.reading().malloc) - start)
                try? await Task.sleep(for: .milliseconds(100))
                line += String(format: " +100ms=%.1f", Self.mb(Self.reading().malloc) - start)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var snapshot = try? decoder.decode(MusicLibrary.Snapshot.self, from: export)
            await note("decoded (holding)")
            let artwork = await MusicLibrary.collectPortableArtworkReference(
                songs: snapshot?.songs ?? [], artworkOverrides: snapshot?.artworkOverrides, assetStore: .shared,
                maximumRawBytes: 0, maximumEncodedBytes: 0
            )
            await note("covers collected (\(artwork?.references.count ?? -1) references)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            var encoded = snapshot.flatMap { try? encoder.encode($0) }
            await note("encoded (holding \(encoded?.count ?? -1) bytes)")
            encoded = nil
            await note("encoded dropped")
            snapshot = nil
            await note("decoded dropped")
            line += await timeline(start)
            return line
        }.value
        Self.report(phases)
    }

    /// 不在这个单元里改、只量出来列给后面的:收到整库快照的那一边几处整份解码(电视装快照时的校验、与本机快照
    /// 合并、按行挑选,别的 iPhone / iPad / Mac 导入这台设备的扫描结果)。同一份 10 万首的导出当输入。
    private func measureTheReceivingSide(_ export: Data) async throws {
        let stages: [(String, @Sendable () -> String)] = [
            ("isValidSnapshotData (TV install, TV download, transfer check)", {
                "valid=\(MusicLibrary.isValidSnapshotData(export))"
            }),
            ("mergingSnapshotUserState (TV install over an existing library)", {
                let merged = try? MusicLibrary.mergingSnapshotUserState(
                    localData: export, incomingData: export, locallyRetainedSongIDs: [])
                return "bytes=\(merged?.count ?? -1)"
            }),
            ("JSONSerialization tree (TV install row selection, done twice there)", {
                autoreleasepool {
                    let object = try? JSONSerialization.jsonObject(with: export) as? [String: Any]
                    return "rows=\((object?["songs"] as? [Any])?.count ?? -1)"
                }
            }),
            ("peer scan seed decode (iPhone / iPad / Mac importing another device's scan)", {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return "songs=\((try? decoder.decode(PeerSnapshotRows.self, from: export))?.songs?.count ?? -1)"
            }),
        ]
        for (name, stage) in stages {
            let before = try await settle()
            let sampler = Sampler(before)
            let summary = await sampler.measure { await Task.detached(priority: .userInitiated) { stage() }.value }
            let right = Self.reading()
            let after = try await settle()
            Self.report(String(format: "📏 dl4 receive %@: %@ input=%d ms=%.0f before malloc=%.1fMB peak=%.1fMB right after=%.1fMB after=%.1fMB",
                               name, summary, export.count, sampler.milliseconds, Self.mb(before.malloc),
                               Self.mb(sampler.peak.malloc), Self.mb(right.malloc), Self.mb(after.malloc)))
        }
    }

    // MARK: - Measuring

    private struct Reading {
        var footprint: UInt64
        var malloc: UInt64
    }

    private final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Reading
        private(set) var milliseconds = 0.0
        init(_ start: Reading) { value = start }
        var peak: Reading { lock.withLock { value } }
        func note(_ reading: Reading) {
            lock.withLock {
                value.footprint = max(value.footprint, reading.footprint)
                value.malloc = max(value.malloc, reading.malloc)
            }
        }

        /// 主线程外每 5 ms 量一次。
        @MainActor
        func measure<T>(_ body: @MainActor () async -> T) async -> T {
            let sampling = Task.detached(priority: .high) { [self] in
                while !Task.isCancelled {
                    note(LibraryExportMemoryHarnessTests.reading())
                    try? await Task.sleep(for: .milliseconds(5))
                }
            }
            let started = ContinuousClock.now
            let result = await body()
            milliseconds = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
            sampling.cancel()
            note(LibraryExportMemoryHarnessTests.reading())
            return result
        }
    }

    private func settle() async throws -> Reading {
        await MusicLibrary.drainDisplacedArraysForMeasurement()
        try await Task.sleep(for: .milliseconds(500))
        await MusicLibrary.returnFreedMemoryToSystem()
        try await Task.sleep(for: .seconds(1))
        return Self.reading()
    }

    nonisolated private static func reading() -> Reading {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Reading(footprint: MusicLibrary.residencyFootprintBytes() ?? 0, malloc: UInt64(statistics.size_in_use))
    }

    private static func fingerprint(_ data: Data) -> Data {
        var fingerprint = withUnsafeBytes(of: UInt64(data.count).littleEndian) { Data($0) }
        fingerprint.append(contentsOf: SHA256.hash(data: data))
        return fingerprint
    }

    nonisolated private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func report(_ line: String) {
        plog(line)
        print(line)
    }
}

/// 每个任务片段包一个自动释放池的执行器(DL4:量以前那份整理返回之后还占着的是不是攒在协作线程上的自动释放对象)。
private final class AutoreleasePoolPerJobExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dl4.autoreleasepool-per-job")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { autoreleasepool { job.runSynchronously(on: executor) } }
    }
}

/// 别的设备导入扫描结果时解的那两样(`PeerScanSeedStore` 的 `PeerSnapshotPayload` 同形)。
private struct PeerSnapshotRows: Decodable {
    var songs: [Song]?
    var coverContentSongIDs: [String: [String]]?
}
