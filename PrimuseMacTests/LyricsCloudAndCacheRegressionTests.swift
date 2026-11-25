import AppKit
import CloudKit
import CoreText
import Foundation
import os
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

@MainActor
final class MacLyricsAssetAvailabilityTests: XCTestCase {
    func testReadingPlaybackStateAndUnsupportedLyricsDoNotProbeAssetPacks() async {
        let probe = expectation(description: "The resource manager stays unused")
        probe.isInverted = true
        let service = LocalLyricsTranslationService(isSupported: true) { _ in
            probe.fulfill()
            return nil
        }
        XCTAssertEqual(service.modelRevision, 0)
        XCTAssertEqual(service.modelState, .notDownloaded)
        let group = LyricTranslationGroup(id: "it", sourceLanguageCode: "it", candidates: [
            .init(id: "line", text: "La luna piega la carta", sourceLanguageCode: "it")
        ])
        let outcome = await service.translate(groups: [group], targetLanguageCode: "de", systemTranslator: nil,
                                              isCurrent: { true }, onTranslation: { _, _ in })
        XCTAssertEqual(outcome.unsupportedGroups, [group])
        await fulfillment(of: [probe], timeout: 0.2)
    }

    func testOfflineRouteDiscoversExistingPacksOnceBeforeRequestingDownload() async {
        let probes = OSAllocatedUnfairLock(initialState: [LocalLyricsTranslationModel.Pack]())
        let service = LocalLyricsTranslationService(isSupported: true) { pack in
            probes.withLock { $0.append(pack) }
            return nil
        }
        let group = LyricTranslationGroup(id: "en", sourceLanguageCode: "en", candidates: [
            .init(id: "line", text: "The paper moon keeps time", sourceLanguageCode: "en")
        ])
        for _ in 0..<2 {
            let outcome = await service.translate(groups: [group], targetLanguageCode: "fa", systemTranslator: nil,
                                                  isCurrent: { true }, onTranslation: { _, _ in })
            XCTAssertEqual(outcome.groupsNeedingModel, [group])
        }
        let lookedUp = probes.withLock { $0 }
        XCTAssertTrue(lookedUp.contains(.persian))
        XCTAssertEqual(Set(lookedUp).count, lookedUp.count)
    }

    func testInterruptedManagerInitializationIsSkippedAndSuccessfulLoadClearsMarker() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("current.pending")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: marker)
        XCTAssertNil(BackgroundAssetsPrerequisites.initializeOnce(marker: marker) {
            XCTFail("The same build must not re-enter an interrupted framework initializer")
            return 1
        })
        let upgraded = directory.appendingPathComponent("upgraded.pending")
        XCTAssertEqual(BackgroundAssetsPrerequisites.initializeOnce(marker: upgraded) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: upgraded.path))
            return 2
        }, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: upgraded.path))
    }
}

@MainActor
final class LyricsCacheObserverTests: XCTestCase {
    private func lines(_ text: String) -> [LyricLine] { [.init(timestamp: 2, text: text)] }

    func testLateCacheArrivalUpdatesCurrentSongAndIgnoresOtherSongs() async {
        let center = NotificationCenter()
        var reads: [String] = []
        var received: [[LyricLine]] = []
        let cached = lines("纸船穿过晨雾")
        let observer = LyricsCacheObserver(center: center, load: { id in reads.append(id); return cached })
        defer { observer.stop() }
        observer.select(songID: "current") { _, value in received.append(value) }
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "other"])
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "current"])
        await observer.waitForPendingLoad()
        XCTAssertEqual(reads, ["current"])
        XCTAssertEqual(received, [cached])
    }

    func testNewCacheReadWinsOverLateSameSongResult() async {
        let started = expectation(description: "first read started")
        var continuation: CheckedContinuation<[LyricLine]?, Never>?
        var count = 0
        var received: [String] = []
        let fresh = lines("新写好的歌词")
        let observer = LyricsCacheObserver(center: NotificationCenter(), load: { _ in
            count += 1
            if count == 1 {
                return await withCheckedContinuation { continuation = $0; started.fulfill() }
            }
            return fresh
        })
        defer { observer.stop() }
        observer.select(songID: "song") { _, lines in received.append(lines[0].text) }
        let old = observer.cacheChanged(songID: "song")
        await fulfillment(of: [started], timeout: 2)
        await observer.cacheChanged(songID: "song")?.value
        continuation?.resume(returning: lines("已经过时的歌词"))
        await old?.value
        XCTAssertEqual(received, [fresh[0].text])
    }

    func testSongChangeAndManualEditCancelPendingCacheRead() async {
        for manualEdit in [false, true] {
            let center = NotificationCenter()
            let started = expectation(description: "cache read started")
            var continuation: CheckedContinuation<[LyricLine]?, Never>?
            var received = 0
            let observer = LyricsCacheObserver(center: center, load: { _ in
                await withCheckedContinuation { continuation = $0; started.fulfill() }
            })
            observer.select(songID: "old") { _, _ in received += 1 }
            let task = observer.cacheChanged(songID: "old")
            await fulfillment(of: [started], timeout: 2)
            if manualEdit {
                center.post(name: .primuseLyricsDidChange, object: "old")
            } else {
                observer.select(songID: "new") { _, _ in received += 1 }
            }
            continuation?.resume(returning: lines("不应覆盖的新旧交界"))
            await task?.value
            XCTAssertEqual(received, 0)
            observer.stop()
        }
    }

    func testStoppingObservationAndEmptyCacheDoNotReplaceLyrics() async {
        let center = NotificationCenter()
        var reads = 0
        var received = 0
        let observer = LyricsCacheObserver(center: center, load: { _ in reads += 1; return [] })
        observer.select(songID: "song") { _, _ in received += 1 }
        await observer.cacheChanged(songID: "song")?.value
        observer.stop()
        center.post(name: .primuseLyricsDidCache, object: nil, userInfo: ["songID": "song"])
        await observer.waitForPendingLoad()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(received, 0)
    }
}

@MainActor
final class EmbeddedLyricsReselectionTests: XCTestCase {
    func testCachedSongCanSwitchBetweenTwoWordTimingsForTheSameLine() async throws {
        let song = Song(id: "embedded-\(UUID().uuidString)", title: "Copper Tide", fileFormat: .flac,
                        filePath: "/Copper Tide.flac", sourceID: "test", fileSize: 1)
        let original = "[00:01.00]<00:01.00>Copper <00:01.70>tide"
        let preferred = "[00:01.00]<00:01.00>Copper <00:01.30>tide"
        let stored = LyricsDocumentSource.embedded.stamped(LyricsContentParser.parseText(original))
        let store = MetadataAssetStore.shared
        addTeardownBlock { await store.invalidateCaches(forSongIDs: [song.id]) }
        let wrote = await store.cacheLyrics(stored, forSongID: song.id, force: true)
        XCTAssertTrue(wrote)
        await store.storeEmbeddedLyricsAlternatives(.init(variants: [.init(text: preferred), .init(text: original)]),
                                                   forSongID: song.id)
        let changed = await LyricsLoader.reselectedEmbeddedVariant(for: song, cached: stored)
        let lastStart = try XCTUnwrap(changed?.first?.syllables?.last?.start)
        XCTAssertEqual(lastStart, 1.3, accuracy: 0.001)
        let cached = await store.cachedLyrics(forSongID: song.id)
        let again = await LyricsLoader.reselectedEmbeddedVariant(for: song, cached: try XCTUnwrap(cached))
        XCTAssertNil(again)
    }

    func testSYLTBeforeUSLTKeepsItsPhysicalPosition() async throws {
        func bytes(_ value: Int, shift: Int = 8) -> Data {
            let mask = (1 << shift) - 1
            return Data((0..<4).reversed().map { UInt8((value >> ($0 * shift)) & mask) })
        }
        func frame(_ name: String, _ payload: Data) -> Data {
            Data(name.utf8) + bytes(payload.count) + Data([0, 0]) + payload
        }
        let prefix = Data([3]) + Data("eng".utf8)
        let timed = prefix + Data([2, 1, 0]) + Data("Copper tide".utf8) + Data([0]) + bytes(1000)
        let plain = prefix + Data([0]) + Data("Paper lantern".utf8)
        let custom = Data([3]) + Data("LYRICS".utf8) + Data([0]) + Data("[00:01.00]Glass harbor".utf8)
        let body = frame("SYLT", timed) + frame("USLT", plain) + frame("TXXX", custom)
        let header = Data([0x49, 0x44, 0x33, 3, 0, 0]) + bytes(body.count, shift: 7)
        let audioFrame = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        var song = header + body
        for _ in 0..<8 { song += audioFrame }
        let metadata = await FileMetadataReader.RangeReadSession().read(from: song, fileExtension: "mp3")
        let alternatives = try XCTUnwrap(metadata.embeddedLyricsAlternatives)
        XCTAssertEqual(alternatives.variants.map(\.text), ["[00:01.000]Copper tide", "Paper lantern", "[00:01.00]Glass harbor"])
        XCTAssertEqual(FileMetadataReader.Metadata.embeddedLyrics(from: alternatives, priority: .firstInFile)?.lyricsText,
                       "[00:01.000]Copper tide")
    }
}

@MainActor
final class LyricLineCommentCloudMappingTests: XCTestCase {
    func testPrivateRecordRoundTripAndRejectsMismatchedPayloadIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let anchor = LyricLineCommentAnchor(text: "灯火照着纸船", occurrence: 0, timestamp: 2)
        try store.save(songID: "song", anchor: anchor, text: "留给下一次听见")
        let local = try XCTUnwrap(store.syncRecords().first)
        let id = CKRecord.ID(recordName: "LibraryReview/" + local.id, zoneID: CloudKitSyncService.zoneID)
        let record = CKRecord(recordType: "LibraryReview", recordID: id)
        XCTAssertTrue(CloudKitSyncService.populateLyricLineCommentRecord(record, cloudKey: local.id, store: store))
        XCTAssertEqual(CloudKitSyncService.decodedLyricLineComment(record), local)
        XCTAssertEqual(CloudKitSyncService.channel(for: "LibraryReview", id: local.id), .playlists)
        XCTAssertFalse(CloudKitSyncService.recordTypeIsShareable("LibraryReview"))
        let forged = CKRecord(recordType: "LibraryReview", recordID: .init(recordName: "LibraryReview/wrong", zoneID: CloudKitSyncService.zoneID))
        forged["payload"] = record["payload"]
        XCTAssertNil(CloudKitSyncService.decodedLyricLineComment(forged))
        let family = CKRecord(recordType: "LibraryReview", recordID: .init(recordName: id.recordName, zoneID: CloudKitSyncService.familyZoneID))
        family["payload"] = record["payload"]
        XCTAssertNil(CloudKitSyncService.decodedLyricLineComment(family))
        XCTAssertFalse(CloudKitSyncService.populateLyricLineCommentRecord(family, cloudKey: local.id, store: store))

        try store.save(songID: "song", anchor: anchor, text: "")
        XCTAssertTrue(CloudKitSyncService.populateLyricLineCommentRecord(record, cloudKey: local.id, store: store))
        XCTAssertTrue(try XCTUnwrap(CloudKitSyncService.decodedLyricLineComment(record)).comment.isDeleted)
        XCTAssertEqual(record["updatedAt"] as? Date, try store.syncRecord(for: local.id)?.comment.updatedAt)
    }
}

@MainActor
final class ImportedPlayerTextFontRegressionTests: XCTestCase {
    func testSystemMaskedAndCollidingFontsRenderUploadedGlyphsWithoutPollutingBuiltins() async throws {
        let baseURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: baseURL.path), "Requires macOS Arial Unicode test base font")

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-font-test-\(UUID().uuidString)")
        let sourcesDir = sandbox.appendingPathComponent("sources", isDirectory: true)
        let storeDir = sandbox.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let previousSnapshot = ImportedFontDescriptorStore.shared.snapshot()
        defer { ImportedFontDescriptorStore.shared.restore(previousSnapshot) }

        // 先预热系统苹方与系统冬青丸，模拟进入字体选择器后系统字体已被缓存的真实场景。
        let pingFangRegularHash = renderHash(Text("字A").font(PlayerTextFont.builtin(.pingFang).font(size: 32, weight: Font.Weight.regular)))
        let pingFangSemiboldHash = renderHash(Text("字A").font(PlayerTextFont.builtin(.pingFang).font(size: 32, weight: Font.Weight.semibold)))
        let hiraginoHash = renderHash(Text("字A").font(.custom("HiraMaruPro-W4", fixedSize: 32)))
        let expectedCustomHash = renderHash(Text("字A").font(.custom("ArialUnicodeMS", fixedSize: 32)))
        XCTAssertNotEqual(expectedCustomHash, pingFangRegularHash)
        XCTAssertNotEqual(expectedCustomHash, pingFangSemiboldHash)

        let baseData = try Data(contentsOf: baseURL)
        let huaLunWanURL = sourcesDir.appendingPathComponent("超级花伦丸.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0409, 1, "PingFang SC"),
            (3, 1, 0x0409, 2, "Regular"),
            (3, 1, 0x0409, 3, "Unique-HuaLunWan"),
            (3, 1, 0x0409, 4, "PingFang SC Regular"),
            (3, 1, 0x0409, 6, "PingFangSC-Regular"),
        ]).write(to: huaLunWanURL)

        let jiaoLiMaskedURL = sourcesDir.appendingPathComponent("角隶.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0409, 1, "PingFang SC"),
            (3, 1, 0x0409, 2, "Regular"),
            (3, 1, 0x0409, 3, "Unique-JiaoLi"),
            (3, 1, 0x0409, 4, "PingFang SC Regular"),
            (3, 1, 0x0409, 6, "PingFangSC-Regular"),
        ]).write(to: jiaoLiMaskedURL)

        let dotPrefixURL = sourcesDir.appendingPathComponent("点前缀替身.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0409, 1, ".PingFang SC"),
            (3, 1, 0x0409, 2, "Regular"),
            (3, 1, 0x0409, 4, ".PingFang SC Regular"),
            (3, 1, 0x0409, 6, ".PingFangSC-Regular"),
        ]).write(to: dotPrefixURL)

        let dongQingWanURL = sourcesDir.appendingPathComponent("冬青丸pro.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0409, 1, "Hiragino Maru Gothic Pro"),
            (3, 1, 0x0409, 2, "W4"),
            (3, 1, 0x0409, 4, "Hiragino Maru Gothic Pro W4"),
            (3, 1, 0x0409, 6, "HiraMaruPro-W4"),
        ]).write(to: dongQingWanURL)

        let leakedFamilyURL = sourcesDir.appendingPathComponent("漏改家族.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0409, 1, "LeakedFamilyFont"),
            (3, 1, 0x0409, 2, "Regular"),
            (3, 1, 0x0409, 4, "LeakedFamilyFont Regular"),
            (3, 1, 0x0409, 6, "LeakedFamilyFont-Regular"),
            (3, 1, 0x0409, 16, "PingFang SC"),
            (3, 1, 0x0409, 17, "Regular"),
        ]).write(to: leakedFamilyURL)

        let library = PlayerTextFontLibrary(loadsImportedFonts: false, descriptorStore: .shared)
        let report = await library.importFonts(
            from: [huaLunWanURL, jiaoLiMaskedURL, dotPrefixURL, dongQingWanURL, leakedFamilyURL],
            into: storeDir
        )
        XCTAssertFalse(report.hasProblems, report.message)
        XCTAssertEqual(report.importedPostScriptNames.count, 5)
        XCTAssertEqual(library.importedFonts.count, 5)
        XCTAssertTrue(library.importedFonts.contains { $0.title == "超级花伦丸" })
        XCTAssertTrue(library.importedFonts.contains { $0.title == "角隶" })
        XCTAssertTrue(library.importedFonts.contains { $0.title == "点前缀替身" })
        XCTAssertTrue(library.importedFonts.contains { $0.title == "漏改家族" })

        // 同一文件再次导入仍应识别为重复。
        let duplicateReport = await library.importFonts(from: [huaLunWanURL], into: storeDir)
        XCTAssertEqual(duplicateReport.duplicates, ["超级花伦丸.ttf"])
        XCTAssertTrue(duplicateReport.importedPostScriptNames.isEmpty)

        for entry in library.importedFonts {
            let font = PlayerTextFont.imported(postScriptName: entry.postScriptName)
            XCTAssertTrue(library.isAvailable(font), entry.title)
            XCTAssertEqual(
                renderHash(Text("字A").font(font.font(size: 32, weight: Font.Weight.regular))),
                expectedCustomHash,
                "\(entry.title) regular must render uploaded font"
            )
            XCTAssertEqual(
                renderHash(Text("字A").font(font.font(size: 32, weight: Font.Weight.semibold))),
                expectedCustomHash,
                "\(entry.title) semibold must render uploaded font without system fallback"
            )
            let typeface = LyricsTypeface(family: font, isAvailable: true)
            let nsFont = typeface.nsFont(size: 32, weight: .semibold)
            let ctURL = (CTFontCopyAttribute(nsFont as CTFont, kCTFontURLAttribute) as? URL)?.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertEqual(
                ctURL?.deletingLastPathComponent(),
                storeDir.resolvingSymlinksInPath().standardizedFileURL,
                "\(entry.title) AppKit nsFont must point to imported file"
            )
        }

        // 内置苹方与系统冬青丸未被进程级注册污染。
        XCTAssertEqual(renderHash(Text("字A").font(PlayerTextFont.builtin(.pingFang).font(size: 32, weight: Font.Weight.regular))), pingFangRegularHash)
        XCTAssertEqual(renderHash(Text("字A").font(PlayerTextFont.builtin(.pingFang).font(size: 32, weight: Font.Weight.semibold))), pingFangSemiboldHash)
        XCTAssertEqual(renderHash(Text("字A").font(.custom("HiraMaruPro-W4", fixedSize: 32))), hiraginoHash)
    }

    func testNonASCIIPostScriptNameRemainsStableAcrossRestartAndRenders() async throws {
        let baseURL = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial Unicode.ttf")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: baseURL.path), "Requires macOS Arial Unicode test base font")

        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("primuse-font-synth-\(UUID().uuidString)")
        let sourcesDir = sandbox.appendingPathComponent("sources", isDirectory: true)
        let storeDir = sandbox.appendingPathComponent("imported", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let previousSnapshot = ImportedFontDescriptorStore.shared.snapshot()
        defer { ImportedFontDescriptorStore.shared.restore(previousSnapshot) }

        let expectedCustomHash = renderHash(Text("字A").font(.custom("ArialUnicodeMS", fixedSize: 32)))
        let baseData = try Data(contentsOf: baseURL)
        let cjkFontURL = sourcesDir.appendingPathComponent("经典繁角隶.ttf")
        try patchFontNameTable(baseData, records: [
            (3, 1, 0x0804, 1, "经典繁角隶"),
            (3, 1, 0x0804, 2, "Regular"),
            (3, 1, 0x0804, 4, "经典繁角隶"),
            (3, 1, 0x0804, 6, "经典繁角隶"),
        ]).write(to: cjkFontURL)

        let firstLibrary = PlayerTextFontLibrary(loadsImportedFonts: false, descriptorStore: .shared)
        let report = await firstLibrary.importFonts(from: [cjkFontURL], into: storeDir)
        XCTAssertFalse(report.hasProblems, report.message)
        let importedID = try XCTUnwrap(report.importedPostScriptNames.first)
        XCTAssertTrue(importedID.hasPrefix("file-"), "Non-ASCII PS name must use content-derived stable ID: \(importedID)")
        XCTAssertFalse(PlayerTextFontSelection.isSyntheticCoreTextPostScriptName(importedID))
        XCTAssertEqual(firstLibrary.importedFonts.first?.title, "经典繁角隶")

        // 跨越 1 秒边界后模拟冷启动重新加载，确认标识不变且仍能正确绘制。
        try await Task.sleep(for: .milliseconds(1150))
        let restartedLibrary = PlayerTextFontLibrary(loadsImportedFonts: false, descriptorStore: .shared)
        await restartedLibrary.reloadImportedFonts(from: storeDir)
        let font = PlayerTextFont.imported(postScriptName: importedID)
        XCTAssertTrue(restartedLibrary.isAvailable(font))
        XCTAssertEqual(restartedLibrary.state(of: font), .available)
        XCTAssertEqual(renderHash(Text("字A").font(font.font(size: 32, weight: Font.Weight.semibold))), expectedCustomHash)
    }

    private func renderHash(_ view: some View) -> UInt64 {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 80, height: 60)
                .background(Color.white)
                .foregroundStyle(Color.black)
        )
        renderer.scale = 1
        guard let cg = renderer.cgImage, let data = cg.dataProvider?.data as Data? else { return 0 }
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private func patchFontNameTable(
        _ sfnt: Data,
        records: [(platformID: UInt16, encodingID: UInt16, languageID: UInt16, nameID: UInt16, value: String)]
    ) throws -> Data {
        func u16(_ data: Data, _ offset: Int) -> UInt16 {
            (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            (UInt32(data[offset]) << 24) | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8) | UInt32(data[offset + 3])
        }
        func appendU16(_ out: inout Data, _ v: UInt16) {
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        func appendU32(_ out: inout Data, _ v: UInt32) {
            out.append(UInt8((v >> 24) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8(v & 0xFF))
        }
        func checksum(_ data: Data) -> UInt32 {
            var sum: UInt32 = 0
            let paddedCount = (data.count + 3) & ~3
            var i = 0
            while i < paddedCount {
                let b0 = i < data.count ? UInt32(data[i]) : 0
                let b1 = i + 1 < data.count ? UInt32(data[i + 1]) : 0
                let b2 = i + 2 < data.count ? UInt32(data[i + 2]) : 0
                let b3 = i + 3 < data.count ? UInt32(data[i + 3]) : 0
                sum &+= (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
                i += 4
            }
            return sum
        }

        let sfntVersion = u32(sfnt, 0)
        let numTables = Int(u16(sfnt, 4))
        var tables: [String: Data] = [:]
        for i in 0..<numTables {
            let off = 12 + i * 16
            let tag = String(decoding: sfnt[off..<(off + 4)], as: UTF8.self)
            let tableOffset = Int(u32(sfnt, off + 8))
            let tableLength = Int(u32(sfnt, off + 12))
            tables[tag] = Data(sfnt[tableOffset..<(tableOffset + tableLength)])
        }

        let sorted = records.sorted {
            ($0.platformID, $0.encodingID, $0.languageID, $0.nameID)
                < ($1.platformID, $1.encodingID, $1.languageID, $1.nameID)
        }
        var storage = Data()
        var recData = Data()
        for r in sorted {
            let encoded = r.value.data(using: .utf16BigEndian) ?? Data()
            let offset = UInt16(storage.count)
            storage.append(encoded)
            appendU16(&recData, r.platformID)
            appendU16(&recData, r.encodingID)
            appendU16(&recData, r.languageID)
            appendU16(&recData, r.nameID)
            appendU16(&recData, UInt16(encoded.count))
            appendU16(&recData, offset)
        }
        var nameTable = Data()
        appendU16(&nameTable, 0)
        appendU16(&nameTable, UInt16(sorted.count))
        appendU16(&nameTable, UInt16(6 + recData.count))
        nameTable.append(recData)
        nameTable.append(storage)
        tables["name"] = nameTable

        if var head = tables["head"], head.count >= 12 {
            head.replaceSubrange(8..<12, with: Data([0, 0, 0, 0]))
            tables["head"] = head
        }

        let tags = tables.keys.sorted()
        var entrySel: UInt16 = 0
        var maxPow2 = 1
        while maxPow2 * 2 <= tags.count {
            maxPow2 *= 2
            entrySel += 1
        }
        let searchRange = UInt16(maxPow2 * 16)
        let rangeShift = UInt16(tags.count * 16) - searchRange

        var out = Data()
        appendU32(&out, sfntVersion)
        appendU16(&out, UInt16(tags.count))
        appendU16(&out, searchRange)
        appendU16(&out, entrySel)
        appendU16(&out, rangeShift)

        var offset = 12 + tags.count * 16
        var directory = Data()
        var body = Data()
        var headOffset = 0
        for tag in tags {
            let tdata = try XCTUnwrap(tables[tag])
            if tag == "head" { headOffset = offset }
            directory.append(Data(tag.utf8))
            appendU32(&directory, checksum(tdata))
            appendU32(&directory, UInt32(offset))
            appendU32(&directory, UInt32(tdata.count))
            body.append(tdata)
            let pad = (4 - (tdata.count % 4)) % 4
            if pad > 0 { body.append(Data(repeating: 0, count: pad)) }
            offset += tdata.count + pad
        }
        out.append(directory)
        out.append(body)
        let adjustment = UInt32(0xB1B0AFBA) &- checksum(out)
        var adjBytes = Data()
        appendU32(&adjBytes, adjustment)
        out.replaceSubrange((headOffset + 8)..<(headOffset + 12), with: adjBytes)
        return out
    }
}
