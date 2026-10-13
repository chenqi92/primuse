import Foundation
import Testing
@testable import PrimuseKit

@Suite struct ExternalPlaylistPartialTests {
    @Test func completeAndLegacyPublicPreviewsKeepTheirSemantics() {
        var playlist = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [])
        #expect(!playlist.isPartial)
        #expect(playlist.partialReason == nil)
        playlist.isPartial = true
        #expect(playlist.partialReason == .publicPreview)
        #expect(playlist.partialReason?.canRetry() == false)
        playlist.isPartial = false
        #expect(playlist.partialReason == nil)
    }
    @Test func quotaDeadlineDoesNotRestartWhenPreviewIsReadAgain() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reason = ExternalPlaylist.PartialReason.rateLimited(statusCode: 503, retryAt: start.addingTimeInterval(86400))
        var playlist = ExternalPlaylist(name: "Fixture", platform: .youtube, tracks: [], partialReason: reason)
        #expect(playlist.isPartial)
        playlist.isPartial = true
        #expect(playlist.partialReason == reason)
        #expect(reason.remainingWait(at: start) == 86400)
        #expect(reason.remainingWait(at: start.addingTimeInterval(86399)) == 1)
        #expect(!reason.canRetry(at: start.addingTimeInterval(86399)))
        #expect(reason.canRetry(at: start.addingTimeInterval(86400)))
        #expect(reason.remainingWait(at: start.addingTimeInterval(86401)) == 0)
    }
    @Test func incompleteContinuationIsDistinctFromPublicPreview() {
        let reason = ExternalPlaylist.PartialReason.incomplete
        #expect(reason.canRetry())
        #expect(reason.remainingWait() == nil)
        #expect(reason != .publicPreview)
    }
}
