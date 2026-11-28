import Darwin
import Foundation
import PrimuseKit
import SQLite3
import XCTest
@testable import Primuse

/// RC-b D2:升级后补算专辑发行类别时的内存 —— 是峰值还是留住的,留在哪里(malloc 在用的、malloc 空着没还的、
/// SQLite 的页缓存)。量法:另起一条线程每 4 毫秒记一次 phys_footprint 与 malloc 在用的字节数,补完后依次记
/// 刚补完、放掉 SQLite 页缓存(`LibraryCatalog.releaseMemory`)、还掉 malloc 空页(`malloc_zone_pressure_relief`)、
/// 关掉目录之后的 footprint。
enum ReleaseCategoryBackfillProbe {
    struct Sample {
        var footprint: UInt64
        var mallocInUse: UInt64
        var mallocAllocated: UInt64

        static func now() -> Sample {
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(nil, &statistics)
            return Sample(
                footprint: MusicLibrary.residencyFootprintBytes() ?? 0,
                mallocInUse: UInt64(statistics.size_in_use), mallocAllocated: UInt64(statistics.size_allocated)
            )
        }
    }

    /// 另一条线程上记峰值(不用协作线程池:补算是一段同步的阻塞工作)。
    final class Sampler: @unchecked Sendable {
        private let lock = NSLock()
        private var footprintPeak: UInt64
        private var mallocPeak: UInt64
        private var running = true
        private let done = DispatchSemaphore(value: 0)

        init(_ start: Sample) {
            footprintPeak = start.footprint
            mallocPeak = start.mallocInUse
            let thread = Thread { [self] in
                while lock.withLock({ running }) {
                    let sample = Sample.now()
                    lock.withLock {
                        footprintPeak = max(footprintPeak, sample.footprint)
                        mallocPeak = max(mallocPeak, sample.mallocInUse)
                    }
                    usleep(4_000)
                }
                done.signal()
            }
            thread.qualityOfService = .userInteractive
            thread.start()
        }

        /// 停下并给出 (footprint 峰值, malloc 在用的峰值)。
        func stop() -> (footprint: UInt64, mallocInUse: UInt64) {
            lock.withLock { running = false }
            done.wait()
            let last = Sample.now()
            return lock.withLock { (max(footprintPeak, last.footprint), max(mallocPeak, last.mallocInUse)) }
        }
    }

    static func megabytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    /// 对照那一段:这条线程什么都不做,只等着。
    static func idle(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    /// SQLite 自己分配的(全进程,系统库开着统计时才有数)与它的高水位(读完清零)。
    static func sqliteMemory(resetHighWater: Bool) -> (used: Int64, highWater: Int64) {
        (sqlite3_memory_used(), sqlite3_memory_highwater(resetHighWater ? 1 : 0))
    }

    static func walBytes(_ catalogPath: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: catalogPath + "-wal"))?[.size] as? Int) ?? 0
    }

    /// 量一段补算:`work` 在当前线程同步跑,返回它跑了几批。
    static func measure(
        _ label: String, catalog: LibraryCatalog, catalogPath: String, work: () throws -> Int
    ) rethrows -> String {
        _ = sqliteMemory(resetHighWater: true)
        let before = Sample.now()
        let walBefore = walBytes(catalogPath)
        let sampler = Sampler(before)
        let started = ContinuousClock.now
        let batches = try work()
        let ms = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
        let peak = sampler.stop()
        let after = Sample.now()
        let sqlite = sqliteMemory(resetHighWater: false)
        catalog.releaseMemory()
        let afterSQLiteRelease = Sample.now()
        malloc_zone_pressure_relief(nil, 0)
        let afterRelief = Sample.now()
        return String(
            format: "%@: ms=%.0f batches=%d footprint %.1f→peak %.1f→after %.1f→sqliteReleased %.1f→mallocRelieved %.1fMB | "
                + "mallocInUse %.1f→peak %.1f→after %.1fMB mallocAllocated %.1f→%.1f→relieved %.1fMB | "
                + "sqlite used %.1f highWater %.1fMB | wal %.1f→%.1fMB",
            label, ms, batches, megabytes(before.footprint), megabytes(peak.footprint), megabytes(after.footprint),
            megabytes(afterSQLiteRelease.footprint), megabytes(afterRelief.footprint),
            megabytes(before.mallocInUse), megabytes(peak.mallocInUse), megabytes(after.mallocInUse),
            megabytes(before.mallocAllocated), megabytes(after.mallocAllocated), megabytes(afterRelief.mallocAllocated),
            megabytes(UInt64(max(0, sqlite.used))), megabytes(UInt64(max(0, sqlite.highWater))),
            megabytes(UInt64(walBefore)), megabytes(UInt64(walBytes(catalogPath)))
        )
    }

    /// 一批一批地补(每批之间 `between`),返回批数。补完为止。
    static func backfillByBatch(
        _ catalog: LibraryCatalog, batchSize: Int = 500, between: () -> Void = {}, eachBatch: (() throws -> Bool) -> Bool
    ) throws -> Int {
        var batches = 0
        var finished = false
        while !finished {
            var calls = 0
            var failure: Error?
            finished = eachBatch {
                do {
                    return try catalog.backfillReleaseCategories(batchSize: batchSize, isCancelled: {
                        calls += 1
                        return calls > 1
                    })
                } catch {
                    failure = error
                    return true
                }
            }
            if let failure { throw failure }
            batches += 1
            between()
        }
        return batches
    }

    /// 规模测试 `testScaleFixtureResidencyReleaseAndReload` 末尾那一段(RC-a 的「单独补算」):同一个目录再当一次
    /// 「刚升上来」、镜像停着,先空等 3 秒作对照(进程里别的活自己涨多少),再补一遍;补完再空等 5 秒、关掉目录,
    /// 看涨上去的是不是这份目录的(关掉就该还回来)还是进程里别的活的。
    static func isolatedBackfill(catalogPath: String) async throws -> String {
        try await Task.detached(priority: .utility) { () throws -> String in
            let controlBefore: Sample
            let controlPeak: (footprint: UInt64, mallocInUse: UInt64)
            let line: String
            let thenBefore: Sample
            let thenPeak: (footprint: UInt64, mallocInUse: UInt64)
            do {
                let catalog = try LibraryCatalog(path: catalogPath)
                try catalog.simulateReleaseCategoryUpgradeForTesting()
                controlBefore = Sample.now()
                let control = Sampler(controlBefore)
                idle(seconds: 3)
                controlPeak = control.stop()
                line = try measure("backfill", catalog: catalog, catalogPath: catalogPath) {
                    var batches = 0
                    let done = try catalog.backfillReleaseCategories(isCancelled: {
                        batches += 1
                        return false
                    })
                    precondition(done && (try? catalog.releaseCategoriesAreComplete()) == true, "the isolated backfill completed")
                    return batches
                }
                thenBefore = Sample.now()
                let then = Sampler(thenBefore)
                idle(seconds: 5)
                thenPeak = then.stop()
            }
            let closed = Sample.now()
            return String(
                format: "control (3 s, nothing running) footprint %.1f→peak %.1fMB mallocInUse %.1f→peak %.1fMB | %@ | "
                    + "then (5 s, nothing running) footprint %.1f→peak %.1fMB mallocInUse %.1f→peak %.1fMB | "
                    + "catalog closed: footprint %.1fMB mallocInUse %.1fMB",
                megabytes(controlBefore.footprint), megabytes(controlPeak.footprint),
                megabytes(controlBefore.mallocInUse), megabytes(controlPeak.mallocInUse), line,
                megabytes(thenBefore.footprint), megabytes(thenPeak.footprint),
                megabytes(thenBefore.mallocInUse), megabytes(thenPeak.mallocInUse),
                megabytes(closed.footprint), megabytes(closed.mallocInUse)
            )
        }.value
    }
}

/// D2 的单独量法:只开规模夹具(`PRIMUSE_SCALE_DIR` 旁边的 `<名字>-catalog`)里那份 v3 目录的副本,不装曲库、进程里
/// 没有别的活。先量真正的升级(打开即迁到 v4、记「待补算」,补一遍),再量第一次看时查行的那两个 `EXISTS`、降级后的
/// 自愈补算,最后按几种做法各补一遍(先清零当作刚升上来):原样、每批一个 autorelease pool、每批之后放 SQLite 页缓存、
/// 每批 100 张。
final class ReleaseCategoryBackfillScaleTests: XCTestCase {
    private static func report(_ line: String) {
        plog(line)
        print(line)
    }

    func testReleaseCategoryBackfillMemoryOnTheScaleCatalog() async throws {
        guard let scale = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"] else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR to the scale fixture (its -catalog sibling holds the v3 catalog)")
        }
        let fixture = URL(fileURLWithPath: scale, isDirectory: true)
        let source = fixture.deletingLastPathComponent()
            .appendingPathComponent(fixture.lastPathComponent + "-catalog", isDirectory: true)
            .appendingPathComponent("library-catalog.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rc-backfill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library-catalog.sqlite").path
        try FileManager.default.copyItem(atPath: source.path, toPath: path)
        let lines = try await Task.detached(priority: .utility) { () throws -> [String] in
            try Self.measureAll(path: path)
        }.value
        for line in lines { Self.report("📏 RC-b backfill memory " + line) }
    }

    private static func measureAll(path: String) throws -> [String] {
        typealias Probe = ReleaseCategoryBackfillProbe
        var lines: [String] = []
        let opened = Probe.Sample.now()
        let catalog = try LibraryCatalog(path: path)
        let afterOpen = Probe.Sample.now()
        let pending = try catalog.hasPendingReleaseCategoryBackfill()
        lines.append(String(format: "open (v3 → v4) footprint %.1f→%.1fMB pending=%@", Probe.megabytes(opened.footprint),
                            Probe.megabytes(afterOpen.footprint), pending ? "yes" : "no"))
        func asMirror() throws -> Int {
            var batches = 0
            let done = try catalog.backfillReleaseCategories(isCancelled: {
                batches += 1
                return false
            })
            precondition(done, "the backfill completed")
            return batches
        }
        lines.append(try Probe.measure("upgrade (as the mirror runs it)", catalog: catalog, catalogPath: path, work: asMirror))
        func timed(_ body: () throws -> Bool) rethrows -> (Bool, Double) {
            let started = ContinuousClock.now
            let value = try body()
            return (value, Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000)
        }
        let intact = try timed { try catalog.releaseCategoriesAreComplete(checkingRows: true) }
        try catalog.simulateRowsWrittenByAnOlderBuildForTesting(count: 1)
        let damaged = try timed { try catalog.releaseCategoriesAreComplete(checkingRows: true) }
        lines.append(String(format: "first-look row check: intact %.1fms complete=%@ | after older-build rows %.1fms complete=%@",
                            intact.1, intact.0 ? "yes" : "no", damaged.1, damaged.0 ? "yes" : "no"))
        lines.append(try Probe.measure("self-heal backfill", catalog: catalog, catalogPath: path, work: asMirror))
        let variants: [(String, () throws -> Int)] = [
            ("simulated, as is", asMirror),
            ("simulated, autorelease pool per batch", {
                try Probe.backfillByBatch(catalog) { batch in autoreleasepool { (try? batch()) ?? true } }
            }),
            ("simulated, SQLite memory released per batch", {
                try Probe.backfillByBatch(catalog, between: { catalog.releaseMemory() }) { batch in (try? batch()) ?? true }
            }),
            ("simulated, 100 albums per batch", {
                try Probe.backfillByBatch(catalog, batchSize: 100) { batch in (try? batch()) ?? true }
            }),
        ]
        for (label, work) in variants {
            let before = Probe.Sample.now()
            let sampler = Probe.Sampler(before)
            try catalog.simulateReleaseCategoryUpgradeForTesting()
            let simulated = sampler.stop()
            lines.append(String(format: "simulate (one transaction over every album) footprint %.1f→peak %.1fMB wal %.1fMB",
                                Probe.megabytes(before.footprint), Probe.megabytes(simulated.footprint),
                                Probe.megabytes(UInt64(Probe.walBytes(path)))))
            lines.append(try Probe.measure(label, catalog: catalog, catalogPath: path, work: work))
            let complete = try catalog.releaseCategoriesAreComplete()
            precondition(complete, "\(label) completed")
        }
        return lines
    }
}
