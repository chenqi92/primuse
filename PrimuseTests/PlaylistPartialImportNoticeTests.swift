import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

final class PlaylistPartialImportNoticeTests: XCTestCase {
    func testBothPlatformPreviewsExplainQuotaAndRemainingWait() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tracks = [ExternalPlaylistTrack(title: "Fixture", artists: [])]
        let quota = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: tracks,
            partialReason: .rateLimited(statusCode: 503, retryAt: now.addingTimeInterval(86400)))
        let notice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: quota, platformName: "YouTube"))
        let before = notice.message(at: now)
        let remaining = HTTPResponseFailure(statusCode: 503, retryAfter: 86400).localizedDescription
        XCTAssertTrue(before.contains(remaining), "The preview must display the actual server wait")
        XCTAssertFalse(notice.reason.canRetry(at: now))
        XCTAssertTrue(notice.reason.canRetry(at: now.addingTimeInterval(86400)))
        XCTAssertNotEqual(before, notice.message(at: now.addingTimeInterval(86400)))
        let preview = ExternalPlaylist(name: "Fixture", platform: .spotify, tracks: tracks, isPartial: true)
        let publicNotice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: preview, platformName: "Spotify"))
        XCTAssertNotEqual(before, publicNotice.message(at: now), "Quota failures must not use the public-preview explanation")
        XCTAssertFalse(publicNotice.reason.canRetry(at: now))
    }
    func testCompleteImportHasNoPartialWarningAndGenericFailureIsDistinct() throws {
        let complete = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [])
        XCTAssertNil(PlaylistPartialImportNotice(playlist: complete, platformName: "YouTube"))
        let incomplete = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [], partialReason: .incomplete)
        let notice = try XCTUnwrap(PlaylistPartialImportNotice(playlist: incomplete, platformName: "YouTube"))
        XCTAssertFalse(notice.message().isEmpty)
        XCTAssertTrue(notice.reason.canRetry())
    }
}
