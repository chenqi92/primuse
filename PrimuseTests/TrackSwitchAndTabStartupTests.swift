import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class TrackSwitchAndTabStartupTests: XCTestCase {
    func testCarouselTopBarHideRulesAndManualTrackTraversalFallback() {
        #if os(iOS)
        let state = NowPlayingCarouselState()
        state.pagesDidChange([.panel(.sound), .player, .panel(.upNext), .panel(.lyrics)])
        XCTAssertEqual(NowPlayingCarouselTopBarPolicy.hiddenPresentation(for: state.settledPage), .fadedOnPlayer)

        state.settle(on: .panel(.lyrics), animated: false)
        XCTAssertEqual(
            NowPlayingCarouselTopBarPolicy.hiddenPresentation(for: state.settledPage),
            .tuckedToEdge(edge: .leading)
        )
        #endif

        // Non-directional jump falls back to smooth crossfade.
        let fallbackMode = TrackSwitchTransitionPolicy.artworkTransition(
            outgoingSongID: "song-a",
            incomingSongID: "song-z",
            allowsDirectionalSwap: true,
            allowsCrossfadeSwap: true,
            reduceMotion: false,
            directionalStyle: ArtworkSwapPolicy.style(
                newSongID: "song-z",
                predictedNextID: "song-b",
                predictedPreviousID: "song-y",
                manualIntent: nil,
                intentAge: nil
            )
        )
        XCTAssertEqual(fallbackMode, .crossfade)
    }
}
