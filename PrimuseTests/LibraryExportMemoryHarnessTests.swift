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

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func report(_ line: String) {
        plog(line)
        print(line)
    }
}
