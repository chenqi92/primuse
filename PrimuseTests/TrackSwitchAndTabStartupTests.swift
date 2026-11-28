import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class TrackSwitchAndTabStartupTests: XCTestCase {
    func testCompactTabBarHoldsAccessorySlotUntilPlaybackSessionRestores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tab-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionURL = directory.appendingPathComponent("playback-session.json")
        let cache = LaunchPersistedSessionCache()

        // No saved session -> stays hidden so < 4 tabs keep compact layout with no jump.
        XCTAssertFalse(cache.hasPersistedSession(at: sessionURL))
        let noSessionState = TabBarStartupPolicy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .pending,
            hasPersistedSession: cache.hasPersistedSession(at: sessionURL),
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        XCTAssertEqual(noSessionState, .hidden)

        // With fewer than 4 tabs and a persisted session, frame 1 holds the slot.
        let compactTabs = AppTabConfiguration(hiddenMask: (1 << AppNavigationTab.settings.rawValue))
        XCTAssertTrue(TabBarStartupPolicy.isCompactTabLayout(visibleTabCount: compactTabs.visibleTabs.count))

        let persistedURL = directory.appendingPathComponent("saved-session.json")
        try Data("{}".utf8).write(to: persistedURL)
        XCTAssertTrue(cache.hasPersistedSession(at: persistedURL))

        let pendingState = TabBarStartupPolicy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .pending,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        XCTAssertEqual(pendingState, .restoringPlaceholder)
        XCTAssertTrue(pendingState.isEnabled)
        XCTAssertFalse(pendingState.isInteractive)
        XCTAssertTrue(TabBarStartupPolicy.minimizesTabBarOnScroll(
            accessoryState: pendingState,
            pinsMiniPlayer: false,
            carPlayEditorActive: false
        ))

        // After restoration succeeds, accessory transitions to live without changing enabled/minimize flags.
        let restoredState = TabBarStartupPolicy.systemBottomAccessoryState(
            hasLivePlayback: true,
            restorePhase: .completed,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        XCTAssertEqual(restoredState, .live)
        XCTAssertEqual(restoredState.isEnabled, pendingState.isEnabled)
    }

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
