import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class AppleMusicCatalogSaveTests: XCTestCase {
    func testAcceptedAddWaitsForCanonicalLibrarySongWithoutRepeatingWrite() async throws {
        let requests = CatalogWriteRequests()
        let writer = AppleMusicCatalogLibraryWriter(send: { request in
            await requests.append(request)
            return 202
        })
        var syncs = 0, waits = 0
        let saved = fixtureSong
        let result = try await AppleMusicLibraryService.resolveSavedCatalogSong(
            add: { try await writer.addSong(id: "123456") },
            synchronize: { syncs += 1 },
            lookup: { syncs == 2 ? saved : nil },
            wait: { waits += 1 }
        )
        XCTAssertEqual(result.id, saved.id)
        XCTAssertEqual(syncs, 2)
        XCTAssertEqual(waits, 1)
        let sent = await requests.values
        XCTAssertEqual(sent.count, 1)
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let url = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.music.apple.com")
        XCTAssertEqual(url.path, "/v1/me/library")
        XCTAssertEqual(url.queryItems, [URLQueryItem(name: "ids[songs]", value: "123456")])
        XCTAssertNil(request.httpBody, "Apple returns an empty 202 response; neither side requires a song JSON body")
    }

    func testRejectedWriteDoesNotSyncOrReturnTemporaryCatalogSong() async {
        var syncs = 0
        let writer = AppleMusicCatalogLibraryWriter(send: { _ in 403 })
        do {
            _ = try await AppleMusicLibraryService.resolveSavedCatalogSong(
                add: { try await writer.addSong(id: "123456") },
                synchronize: { syncs += 1 }, lookup: { self.fixtureSong }, wait: {}
            )
            XCTFail("A rejected write cannot report a successful save")
        } catch {}
        XCTAssertEqual(syncs, 0)
    }

    func testAcceptedButMissingSongHasBoundedRetriesAndDoesNotReportSuccess() async {
        var writes = 0, syncs = 0, waits = 0
        do {
            _ = try await AppleMusicLibraryService.resolveSavedCatalogSong(
                add: { writes += 1 }, synchronize: { syncs += 1 }, lookup: { nil }, wait: { waits += 1 }
            )
            XCTFail("Accepted is not the same as saved")
        } catch AppleMusicLibraryService.CatalogSaveError.notSynced {
        } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(syncs, 4)
        XCTAssertEqual(waits, 3)
    }

    func testSyncFailureStopsBeforeApplyingLibraryAction() async {
        var lookups = 0
        do {
            _ = try await AppleMusicLibraryService.resolveSavedCatalogSong(
                add: {}, synchronize: { throw URLError(.notConnectedToInternet) },
                lookup: { lookups += 1; return self.fixtureSong }, wait: {}
            )
            XCTFail("Expected sync failure")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertEqual(lookups, 0)
    }

    func testLibraryIDsAndMultipleResourceInjectionAreRejectedBeforeSending() async {
        let writer = AppleMusicCatalogLibraryWriter(send: { _ in
            XCTFail("Only one catalog song may be added")
            return 202
        })
        for id in ["", "i.library-song", "123,456", "123&ids[albums]=456"] {
            do { try await writer.addSong(id: id); XCTFail("Expected invalid catalog ID") }
            catch AppleMusicLibraryService.CatalogSaveError.unavailable {}
            catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    func testCancellationBeforeSaveDoesNotWriteOrSync() async {
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AppleMusicLibraryService.resolveSavedCatalogSong(
                add: { XCTFail("Cancelled save must not write") },
                synchronize: { XCTFail("Cancelled save must not sync") }, lookup: { nil }, wait: {}
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private var fixtureSong: Song {
        Song(id: "apple-music-library-song", title: "Fixture", fileFormat: .m4a,
             filePath: "i.library-song", sourceID: AppleMusicLibraryService.systemSourceID)
    }
}

private actor CatalogWriteRequests {
    var values: [URLRequest] = []
    func append(_ request: URLRequest) { values.append(request) }
}

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class SongLocationMacTests: XCTestCase {
    override func tearDown() async throws {
        try await Task.sleep(for: .seconds(8))
        try await super.tearDown()
    }

    func testVirtualRowsAreMaterializedBeforeScrollAndHighlight() async throws {
        try await verifyVirtualRows(nestedHorizontalScroll: false)
    }

    func testNestedTableScrollRevealsTargetInsideVerticalViewport() async throws {
        try await verifyVirtualRows(nestedHorizontalScroll: true)
    }

    private func verifyVirtualRows(nestedHorizontalScroll: Bool) async throws {
        let location = SongListLocation()
        var targetFrame = CGRect.zero
        let host = NSHostingView(rootView: VirtualLocationFixture(
            location: location,
            nestedHorizontalScroll: nestedHorizontalScroll,
            targetFrameChanged: { targetFrame = $0 }
        ))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            location.cancel()
            window.orderOut(nil)
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        location.locate("row-2900")
        for _ in 0..<300 where location.highlightedSongID == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(location.highlightedSongID, "row-2900")
        XCTAssertFalse(location.needsScroll)
        XCTAssertGreaterThan(targetFrame.height, 0)
        XCTAssertGreaterThanOrEqual(targetFrame.minY, 0)
        XCTAssertLessThanOrEqual(targetFrame.maxY, 500)
        let firstRequest = try XCTUnwrap(location.request)
        location.locate("row-2900")
        XCTAssertNotEqual(location.request?.id, firstRequest.id)
        XCTAssertFalse(location.needsScroll)
        XCTAssertEqual(location.highlightedSongID, "row-2900")
    }
}

private struct VirtualLocationFixture: View {
    let location: SongListLocation
    var nestedHorizontalScroll = false
    var targetFrameChanged: (CGRect) -> Void = { _ in }
    @State private var firstRow = 0

    var body: some View {
        Group {
            if nestedHorizontalScroll {
                ScrollView {
                    ScrollView(.horizontal) { rows.frame(width: 900) }
                }
                .songLocationScrollPosition(location, revision: 0) { songID, viewportHeight in
                    guard let row = Int(songID.replacingOccurrences(of: "row-", with: "")) else { return nil }
                    return CGFloat(row) * 40 + 20 - viewportHeight / 2
                }
                .onScrollGeometryChange(for: Int.self) { scroll in
                    max(0, Int(scroll.visibleRect.minY / 40) - 10)
                } action: { _, row in firstRow = row }
            } else {
                ScrollView { rows }
                    .songLocationReader(location, revision: firstRow) { songID in
                        if let row = Int(songID.replacingOccurrences(of: "row-", with: "")) {
                            firstRow = max(0, row - 10)
                        }
                    }
            }
        }
        .coordinateSpace(name: "location-test-viewport")
    }

    private var rows: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: CGFloat(firstRow) * 40)
            ForEach(firstRow..<min(3_000, firstRow + 40), id: \.self) { row in
                Text("Row \(row)")
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .songLocationRow("row-\(row)")
                    .onGeometryChange(for: CGRect.self) { proxy in
                        row == 2900 ? proxy.frame(in: .named("location-test-viewport")) : .zero
                    } action: { frame in
                        if row == 2900 { targetFrameChanged(frame) }
                    }
            }
            Color.clear.frame(height: CGFloat(max(0, 3_000 - firstRow - 40)) * 40)
        }
    }
}
#endif
