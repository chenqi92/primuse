import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 标签补读逐首记账的存储:迁移前在内存(与原来的几套集合一致),迁进目录后读写走 `songMaintenance`,
/// 迁移期间的改动、整套清空、落库前后的读都要与逐笔改内存集合的结果一样。
final class MetadataBackfillMaintenanceStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackfillMaintenance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeCatalog() throws -> LibraryCatalog {
        try LibraryCatalog(path: directory.appendingPathComponent("library-catalog.sqlite").path)
    }

    func testMemoryStorageBehavesLikeTheOldSets() {
        let store = MetadataBackfillMaintenanceStore(storage: .memory)
        let failed = MetadataBackfillFlagSet(.failed, store)
        let checked = MetadataBackfillFlagSet(.titleChecked, store)
        failed.formUnion(["a", "b"])
        checked.insert("a")
        XCTAssertTrue(failed.contains("a"))
        XCTAssertEqual(failed.remove("a"), "a")
        XCTAssertNil(failed.remove("a"))
        XCTAssertEqual(failed.members(), ["b"])
        XCTAssertEqual(failed.count, 1)
        checked.removeAll()
        XCTAssertTrue(checked.isEmpty)
        let counts = MetadataBackfillRetryCounts(store: store)
        counts["b"] = 3
        XCTAssertEqual(counts["b"], 3)
        XCTAssertEqual(counts.removeValue(forKey: "b"), 3)
        XCTAssertNil(counts["b"])
        let diagnostics = MetadataBackfillDiagnostics(store: store)
        let record = MetadataBackfillDiagnosticRecord(
            state: .retryPending, reason: "timeout\u{1F}x", attemptCount: 2, lastAttemptAt: Date(timeIntervalSinceReferenceDate: 12.5)
        )
        diagnostics["b"] = record
        XCTAssertEqual(diagnostics["b"], record)
        diagnostics.removeValues(forKeys: ["b"], ifStateIn: [.unreadableTags])
        XCTAssertEqual(diagnostics["b"], record)
        diagnostics.removeValues(forKeys: ["b"], ifStateIn: [.retryPending, .stalled])
        XCTAssertNil(diagnostics["b"])
        XCTAssertNotNil(store.legacySnapshot())
    }

    func testMigrationCarriesTheStateAndChangesMadeMeanwhile() async throws {
        let store = MetadataBackfillMaintenanceStore(storage: .memory)
        var legacy = MetadataBackfillMaintenanceStore.LegacyState()
        legacy.sets[MetadataBackfillMaintenanceFlags.titleChecked.rawValue] = Set((0..<500).map { "song-\($0)" })
        legacy.sets[MetadataBackfillMaintenanceFlags.failed.rawValue] = ["song-1", "song-2"]
        legacy.sets[MetadataBackfillMaintenanceFlags.sessionGivenUp.rawValue] = ["song-3"]
        legacy.retryCounts = ["song-4": 2]
        legacy.diagnostics = ["song-5": MetadataBackfillDiagnosticRecord(
            state: .fileUnavailable, reason: "gone", attemptCount: 1, lastAttemptAt: Date(timeIntervalSinceReferenceDate: 99)
        )]
        store.loadLegacy(legacy)
        let catalog = try makeCatalog()
        let reader = try catalog.makeMaintenanceReader()
        try await store.migrate(to: catalog, reader: reader)

        XCTAssertEqual(store.storage, .catalog)
        XCTAssertNil(store.legacySnapshot())
        XCTAssertTrue(store.contains("song-499", .titleChecked))
        XCTAssertTrue(store.contains("song-1", .failed))
        XCTAssertTrue(store.contains("song-3", .sessionGivenUp))
        XCTAssertEqual(store.row("song-4").retryCount, 2)
        XCTAssertEqual(store.row("song-5").diagnostic?.reason, "gone")
        XCTAssertEqual(try catalog.maintenanceCount(withAny: .failed), 2)

        // 迁移之后的改动先在待写里(读得到),落库后从目录读回一样。
        let failed = MetadataBackfillFlagSet(.failed, store)
        failed.subtract(["song-1"])
        failed.insert("song-9")
        XCTAssertEqual(failed.members(), ["song-2", "song-9"])
        await store.flushNow()
        XCTAssertEqual(Set(try catalog.maintenanceSongIDs(withAny: .failed)), ["song-2", "song-9"])
        XCTAssertEqual(failed.members(), ["song-2", "song-9"])

        // 整套清空之后再置的位留着。
        failed.removeAll()
        failed.insert("song-7")
        XCTAssertEqual(failed.members(), ["song-7"])
        await store.flushNow()
        XCTAssertEqual(try catalog.maintenanceSongIDs(withAny: .failed), ["song-7"])

        // 下次启动接上同一个目录:本次有效的位清掉,其余照旧。
        let next = MetadataBackfillMaintenanceStore(storage: .catalog)
        XCTAssertFalse(next.isReady)
        try await next.attach(catalog: catalog, reader: try catalog.makeMaintenanceReader())
        XCTAssertTrue(next.isReady)
        XCTAssertFalse(next.contains("song-3", .sessionGivenUp))
        XCTAssertTrue(next.contains("song-7", .failed))
        XCTAssertTrue(next.contains("song-0", .titleChecked))
    }

    func testWritesBeforeAttachLandAfterwards() async throws {
        let store = MetadataBackfillMaintenanceStore(storage: .catalog)
        store.update(["x", "y"], .init(setFlags: .titleChecked))
        XCTAssertTrue(store.contains("x", .titleChecked))
        let catalog = try makeCatalog()
        try await store.attach(catalog: catalog, reader: try catalog.makeMaintenanceReader())
        await store.flushNow()
        XCTAssertEqual(try catalog.maintenanceCount(withAny: .titleChecked), 2)
        XCTAssertEqual(store.rows(["x", "z"]).map { $0.flags.contains(.titleChecked) }, [true, false])
    }
}
