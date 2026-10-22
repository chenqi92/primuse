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
