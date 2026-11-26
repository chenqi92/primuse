import Foundation
import XCTest
@testable import Primuse

@MainActor
final class YearlyReportArtworkServiceTests: XCTestCase {
    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let sampleWebPBase64 =
        "UklGRmQAAABXRUJQVlA4WAoAAAAQAAAAAwAAAwAAQUxQSA0AAAABD/DA/4iIMA8R/Y8BAFZQOCAwAAAA8AEAnQEqBAAEAAEAHiWgAnS6AfgABEwAAP7Lt//PzO7cX9Vv/sHf0rH0rH69AAAA"

    private func makeFixtureDirectory(ext: String = "webp") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-yearly-artwork-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data: Data
        if ext == "webp" {
            data = try XCTUnwrap(Data(base64Encoded: Self.sampleWebPBase64))
        } else {
            let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2dIAAAAASUVORK5CYII="
            data = try XCTUnwrap(Data(base64Encoded: pngBase64))
        }
        try data.write(to: dir.appendingPathComponent("\(YearlyReportArtworkPack.sentinelName).\(ext)"))
        return dir
    }

    func testLoadsLocalArtworkWithoutDownloading() async throws {
        let dir = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloads = AtomicCounter()
        let service = YearlyReportArtworkService(
            isSystemSupported: { true },
            locate: { dir },
            download: {
                downloads.increment()
                return dir
            }
        )

        service.ensureAvailable()
        await service.waitForCurrentLoad()

        XCTAssertEqual(service.artworkDirectory, dir)
        XCTAssertEqual(downloads.count, 0)
        XCTAssertNotNil(service.image(named: YearlyReportArtworkPack.sentinelName))
        XCTAssertNil(service.image(named: "nonexistent_yearly_artwork_xyz"))
    }

    func testDownloadsOnDemandWhenSupportedAndCoalescesCalls() async throws {
        let dir = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let downloads = AtomicCounter()
        let service = YearlyReportArtworkService(
            isSystemSupported: { true },
            locate: { nil },
            download: {
                downloads.increment()
                try await Task.sleep(for: .milliseconds(30))
                return dir
            }
        )

        service.ensureAvailable()
        service.ensureAvailable()
        await service.waitForCurrentLoad()

        XCTAssertEqual(downloads.count, 1)
        XCTAssertEqual(service.artworkDirectory, dir)
        XCTAssertNotNil(service.image(named: YearlyReportArtworkPack.sentinelName))
    }

    func testUnsupportedSystemFallsBackWithoutDownloading() async {
        let downloads = AtomicCounter()
        let service = YearlyReportArtworkService(
            isSystemSupported: { false },
            locate: { nil },
            download: {
                downloads.increment()
                throw YearlyReportArtworkError.unavailable
            }
        )

        service.ensureAvailable()
        await service.waitForCurrentLoad()

        XCTAssertEqual(downloads.count, 0)
        XCTAssertNil(service.artworkDirectory)
        XCTAssertNil(service.image(named: YearlyReportArtworkPack.sentinelName))
    }

    func testResolvedArtworkDirectoryFindsNestedArtworkFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-yearly-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent(YearlyReportArtworkPack.artworkDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(
            to: nested.appendingPathComponent("\(YearlyReportArtworkPack.sentinelName).png")
        )

        XCTAssertEqual(YearlyReportArtworkPack.resolvedArtworkDirectory(from: root), nested)
    }

    func testLiveAppleHostedAssetPackDownload() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["PRIMUSE_RUN_LIVE_ASSET_PACK_TEST"] == "1",
            "Set PRIMUSE_RUN_LIVE_ASSET_PACK_TEST=1 to exercise live AssetPackManager"
        )
        XCTAssertTrue(
            YearlyReportArtworkPack.isSystemSupported,
            "YearlyReportArtworkPack.isSystemSupported is false (check OS >= 26.4 and PRIMUSE_ASSET_PACKS=1 on dev macOS)"
        )

        await YearlyReportArtworkPack.remove()
        XCTAssertNil(YearlyReportArtworkPack.locateDirectory(), "Pack should be absent right after remove()")

        let downloadedDir = try await YearlyReportArtworkPack.download()
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadedDir.path))

        let service = YearlyReportArtworkService()
        service.ensureAvailable()
        await service.waitForCurrentLoad()
        XCTAssertEqual(service.artworkDirectory, downloadedDir)

        let expectedNames = [
            "decor_artists_chorus", "decor_badge_moment", "decor_curtain_close", "decor_first_song",
            "decor_overview_hourglass", "decor_record_stack", "decor_source_cloud", "decor_source_local",
            "decor_source_nas", "decor_sources_pipeline", "decor_trophy",
            "month_01", "month_02", "month_03", "month_04", "month_05", "month_06",
            "month_07", "month_08", "month_09", "month_10", "month_11", "month_12",
            "personality_EFND", "personality_EFNM", "personality_EFVD", "personality_EFVM",
            "personality_EOND", "personality_EONM", "personality_EOVD", "personality_EOVM",
            "personality_LFND", "personality_LFNM", "personality_LFVD", "personality_LFVM",
            "personality_LOND", "personality_LONM", "personality_LOVD", "personality_LOVM",
            "timeofday_dawn", "timeofday_dusk", "timeofday_night", "timeofday_noon",
        ]
        for name in expectedNames {
            XCTAssertNotNil(
                YearlyReportArtworkPack.imageURL(named: name, in: downloadedDir),
                "Missing file for \(name) in \(downloadedDir.path)"
            )
            XCTAssertNotNil(service.image(named: name), "Failed to decode \(name)")
        }
    }
}
