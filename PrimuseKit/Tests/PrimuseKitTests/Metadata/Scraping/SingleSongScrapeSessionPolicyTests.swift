import Foundation
import Testing
@testable import PrimuseKit

struct SingleSongScrapeSessionPolicyTests {
    @Test func startsWhenThereIsNoActiveSession() {
        let request = SingleSongScrapeKey(songID: "song-a", purpose: .metadataApply)

        #expect(SingleSongScrapeSessionPolicy.admission(active: nil, request: request) == .start)
    }

    @Test func joinsTheSameSongAndPurpose() {
        let runID = UUID()
        let request = SingleSongScrapeKey(songID: "song-a", purpose: .lyricsApply)
        let active = SingleSongScrapeActivity(runID: runID, key: request)

        #expect(
            SingleSongScrapeSessionPolicy.admission(active: active, request: request)
                == .join(runID: runID)
        )
    }

    @Test func rejectsAnotherSongWhileARequestIsActive() {
        let active = SingleSongScrapeActivity(
            runID: UUID(),
            key: SingleSongScrapeKey(songID: "song-a", purpose: .metadataApply)
        )
        let request = SingleSongScrapeKey(songID: "song-b", purpose: .metadataApply)

        #expect(
            SingleSongScrapeSessionPolicy.admission(active: active, request: request)
                == .busy(active: active)
        )
    }

    @Test func treatsPreviewAndApplyAsDifferentRequests() {
        let active = SingleSongScrapeActivity(
            runID: UUID(),
            key: SingleSongScrapeKey(songID: "song-a", purpose: .lyricsPreview)
        )
        let request = SingleSongScrapeKey(songID: "song-a", purpose: .lyricsApply)

        #expect(
            SingleSongScrapeSessionPolicy.admission(active: active, request: request)
                == .busy(active: active)
        )
    }
}
