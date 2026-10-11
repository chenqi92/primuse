import Foundation
import XCTest
@testable import Primuse

final class CloudScanConcurrencyTests: XCTestCase {
    func testCancellationStopsActiveListingsAndDoesNotScheduleMore() async throws {
        let ready = expectation(description: "Four listings started")
        let cancelled = expectation(description: "Active listings cancelled")
        cancelled.expectedFulfillmentCount = 4
        let fixture = BlockingListings(ready: ready, cancelled: cancelled)
        let helper = CloudDriveHelper(sourceID: "cancel-scan-\(UUID())")
        let traversal = Task {
            for try await _ in helper.scanAudioFiles(from: "", listFiles: { try await fixture.list($0) }) {}
        }
        await fulfillment(of: [ready], timeout: 5)
        traversal.cancel()
        _ = await traversal.result
        await fulfillment(of: [cancelled], timeout: 5)
        let starts = await fixture.starts
        XCTAssertEqual(starts, 4)
    }

    func testDirectoryFailureCancelsSiblingsAndReachesConsumer() async throws {
        let ready = expectation(description: "Four listings started")
        let cancelled = expectation(description: "Sibling listings cancelled")
        cancelled.expectedFulfillmentCount = 3
        let fixture = BlockingListings(ready: ready, cancelled: cancelled, fail: true)
        let helper = CloudDriveHelper(sourceID: "failed-scan-\(UUID())")
        do {
            for try await _ in helper.scanAudioFiles(from: "", listFiles: { try await fixture.list($0) }) {}
            XCTFail("A failed directory must fail the scan")
        } catch {
            XCTAssertTrue(error is ListingFailure)
        }
        await fulfillment(of: [ready, cancelled], timeout: 5)
        let starts = await fixture.starts
        XCTAssertEqual(starts, 4)
    }

    func testFilesKeepSidecarsProviderIdentityAndRevision() async throws {
        let path = "/artist/record"
        let names = ["song.flac", "song.lrc", "song.mp4", "bonus.mp4", "cover.jpg"]
        let files = names.map {
            RemoteFileItem(name: $0, path: "\(path)/\($0)", isDirectory: false, size: 10,
                           modifiedDate: nil, revision: "revision-\($0)",
                           providerID: "provider-\($0)", parentPath: path)
        }
        let helper = CloudDriveHelper(sourceID: "sidecars-scan-\(UUID())")
        var result: [RemoteFileItem] = []
        for try await item in helper.scanAudioFiles(from: path, listFiles: { _ in files }) {
            result.append(item)
        }
        XCTAssertEqual(Set(result.map(\.name)), ["song.flac", "bonus.mp4"])
        let song = try XCTUnwrap(result.first { $0.name == "song.flac" })
        XCTAssertEqual(song.sidecarHints?.coverPath, "\(path)/cover.jpg")
        XCTAssertEqual(song.sidecarHints?.lyricsPath, "\(path)/song.lrc")
        XCTAssertEqual(song.sidecarHints?.mvPath, "\(path)/song.mp4")
        XCTAssertEqual(song.revision, "revision-song.flac")
        XCTAssertEqual(song.providerID, "provider-song.flac")
        XCTAssertEqual(song.parentPath, path)
        let video = try XCTUnwrap(result.first { $0.name == "bonus.mp4" })
        XCTAssertEqual(video.sidecarHints?.mvPath, video.path)
    }

    func testNestedDirectoriesShareFourListingSlotsWithoutLosingFiles() async throws {
        let ready = expectation(description: "Four leaf listings are waiting")
        let exceeded = expectation(description: "More than four listings are in flight")
        exceeded.isInverted = true
        let fixture = NestedDirectoryFixture(ready: ready, exceeded: exceeded)
        let helper = CloudDriveHelper(sourceID: "scan-fixture-\(UUID())")
        let traversal = Task {
            var paths: [String] = []
            let stream = helper.scanAudioFiles(from: "", listFiles: { path in
                try await fixture.list(path)
            })
            for try await item in stream {
                paths.append(item.path)
            }
            return paths
        }

        await fulfillment(of: [ready], timeout: 5)
        await fulfillment(of: [exceeded], timeout: 0.2)
        await fixture.release()
        let paths = try await traversal.value

        XCTAssertEqual(paths.count, 64)
        XCTAssertEqual(Set(paths).count, 64, "Each leaf file must be yielded exactly once")
        let peak = await fixture.peak
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

private actor NestedDirectoryFixture {
    let ready: XCTestExpectation
    let exceeded: XCTestExpectation
    var peak = 0
    private var active = 0
    private var leafStarts = 0
    private var reportedExcess = false
    private var released = false
    private var blocked: [CheckedContinuation<Void, Never>] = []

    init(ready: XCTestExpectation, exceeded: XCTestExpectation) {
        self.ready = ready
        self.exceeded = exceeded
    }

    func list(_ path: String) async throws -> [RemoteFileItem] {
        try Task.checkCancellation()
        active += 1
        peak = max(peak, active)
        if active > 4, !reportedExcess {
            reportedExcess = true
            exceeded.fulfill()
        }
        defer { active -= 1 }
        if path.count == 3 {
            leafStarts += 1
            if leafStarts == 4 { ready.fulfill() }
            if !released {
                await withCheckedContinuation { blocked.append($0) }
            }
            return [RemoteFileItem(
                name: "song.flac", path: "\(path)/song.flac", isDirectory: false,
                size: 1, modifiedDate: nil
            )]
        }
        await Task.yield()
        return (0..<4).map {
            RemoteFileItem(name: String($0), path: path + String($0),
                           isDirectory: true, size: 0, modifiedDate: nil)
        }
    }

    func release() {
        released = true
        let continuations = blocked
        blocked.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}

private struct ListingFailure: Error {}

private actor BlockingListings {
    let ready: XCTestExpectation
    let cancelled: XCTestExpectation
    let fail: Bool
    var starts = 0

    init(ready: XCTestExpectation, cancelled: XCTestExpectation, fail: Bool = false) {
        self.ready = ready
        self.cancelled = cancelled
        self.fail = fail
    }

    func list(_ path: String) async throws -> [RemoteFileItem] {
        if path.isEmpty {
            return (0..<12).map {
                RemoteFileItem(name: String($0), path: String($0), isDirectory: true,
                               size: 0, modifiedDate: nil)
            }
        }
        starts += 1
        if starts == 4 {
            ready.fulfill()
            if fail { throw ListingFailure() }
        }
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancelled.fulfill(); throw error }
        return []
    }
}
