#if os(tvOS)
import XCTest
@testable import PrimuseTV

final class TVContentFocusRoutingTests: XCTestCase {
    func testHorizontalTabTraversalDoesNotIssueContentFocus() {
        var state = TVContentFocusRoutingState()

        XCTAssertNil(state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song))
        XCTAssertNil(state.contentModeDidChange(in: .nowPlaying, nowPlayingMode: .liveRadio))
        XCTAssertNil(state.latestRequest)
    }

    func testExplicitDownEntersNowPlayingAndReturnRestoresTabRouting() {
        var state = TVContentFocusRoutingState()

        let request = state.moveDown(from: .nowPlaying, nowPlayingMode: .song)
        XCTAssertEqual(request?.target, .nowPlaying(.songPrimary))
        XCTAssertEqual(
            state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song)?.target,
            .nowPlaying(.songPrimary)
        )

        state.returnToTabs()
        XCTAssertNil(state.latestRequest)
        XCTAssertNil(state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song))
    }

    func testEmptyNowPlayingCannotReceiveContentFocus() {
        var state = TVContentFocusRoutingState()
        XCTAssertNil(state.moveDown(from: .nowPlaying, nowPlayingMode: .empty))
        XCTAssertNil(state.latestRequest)
    }
}

final class TVImmersiveDirectionalCommandTests: XCTestCase {
    func testHiddenCanvasUsesLeftAndRightForTrackNavigation() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .left,
                at: 10,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .previousTrack
        )
        XCTAssertEqual(
            state.action(
                for: .right,
                at: 11,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .nextTrack
        )
    }

    func testContinuousDirectionalEventsProduceOnlyOneTrackChange() {
        var state = TVImmersiveDirectionalCommandState(quietInterval: 0.45)

        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20), .nextTrack)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.10), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.30), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.50), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 21.00), .nextTrack)
    }

    func testVisibleControlsAndModePickerKeepStandardFocusNavigation() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .left,
                at: 1,
                controlsVisible: true,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .standardNavigation
        )
        XCTAssertEqual(
            state.action(
                for: .right,
                at: 2,
                controlsVisible: false,
                modePickerVisible: true,
                assistiveNavigationEnabled: false
            ),
            .standardNavigation
        )
    }

    func testAssistiveNavigationRevealsControlsWithoutChangingTrack() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .right,
                at: 1,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: true
            ),
            .revealControls
        )
        XCTAssertEqual(hiddenAction(&state, input: .down, at: 2), .revealControls)
    }

    func testReduceMotionUsesNearInstantChromeTransition() {
        XCTAssertEqual(
            TVImmersiveChromeMotionPolicy.duration(0.4, reduceMotion: true),
            0.01,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TVImmersiveChromeMotionPolicy.duration(0.4, reduceMotion: false),
            0.4,
            accuracy: 0.0001
        )
    }

    private func hiddenAction(
        _ state: inout TVImmersiveDirectionalCommandState,
        input: TVImmersiveDirectionalInput,
        at uptime: TimeInterval
    ) -> TVImmersiveDirectionalAction {
        state.action(
            for: input,
            at: uptime,
            controlsVisible: false,
            modePickerVisible: false,
            assistiveNavigationEnabled: false
        )
    }
}

final class TVImmersivePresentationActivityTests: XCTestCase {
    func testQueueCoverPausesAndResumesRendering() {
        var activity = TVImmersivePresentationActivity()
        activity.handle(.appeared)
        XCTAssertTrue(activity.isMounted)
        XCTAssertTrue(activity.isRenderingActive)

        activity.handle(.queuePresented)
        XCTAssertTrue(activity.isMounted)
        XCTAssertFalse(activity.isRenderingActive)

        activity.handle(.queueDismissed)
        XCTAssertTrue(activity.isRenderingActive)
    }

    func testDismissalCannotBeReactivatedByLateQueueCallback() {
        var activity = TVImmersivePresentationActivity()
        activity.handle(.appeared)
        activity.handle(.queuePresented)
        activity.handle(.dismissalRequested)
        activity.handle(.queueDismissed)

        XCTAssertFalse(activity.isMounted)
        XCTAssertFalse(activity.isRenderingActive)
    }

    func testTypographyAndSpectrumEffectsShareTheSameRenderingGate() {
        for effect in [
            FullscreenPlayerEffect.kineticTitle,
            .radialPulse,
            .liveWaveform,
        ] {
            var activity = TVImmersivePresentationActivity()
            activity.handle(.appeared)
            XCTAssertTrue(activity.isRenderingActive, effect.rawValue)
            activity.handle(.disappeared)
            XCTAssertFalse(activity.isRenderingActive, effect.rawValue)
        }
    }
}

final class TVTrackNavigationAvailabilityTests: XCTestCase {
    func testEmptyQueueDisablesRemotePreviousAndNext() {
        XCTAssertEqual(
            availability(hasNowPlaying: true, queueCount: 0, currentIndex: 0),
            .unavailable
        )
    }

    func testSingleTrackKeepsPreviousRestartButDisablesNext() {
        XCTAssertEqual(
            availability(queueCount: 1, currentIndex: 0, available: [0]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: false)
        )
    }

    func testNextSkipsUnavailableQueueEntries() {
        XCTAssertEqual(
            availability(queueCount: 4, currentIndex: 0, available: [0, 3]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
    }

    func testRepeatAllEnablesWrappedNext() {
        XCTAssertEqual(
            availability(queueCount: 3, currentIndex: 2, wrapsNext: true, available: [0, 2]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
    }

    func testLiveRadioRequiresAnotherValidStation() {
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: true, radioStationCount: 1),
            .unavailable
        )
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: true, radioStationCount: 2),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: false, radioStationCount: 2),
            .unavailable
        )
    }

    func testMusicVideoUsesTheSameQueueNavigationSemantics() {
        let videoQueueAvailability = availability(
            queueCount: 2,
            currentIndex: 0,
            available: [0, 1]
        )
        XCTAssertTrue(videoQueueAvailability.canGoPrevious)
        XCTAssertTrue(videoQueueAvailability.canGoNext)
    }

    private func availability(
        hasNowPlaying: Bool = true,
        isLiveRadio: Bool = false,
        hasCurrentRadioStation: Bool = false,
        radioStationCount: Int = 0,
        queueCount: Int = 0,
        currentIndex: Int = 0,
        wrapsNext: Bool = false,
        available: Set<Int> = []
    ) -> TVTrackNavigationAvailability {
        TVTrackNavigationAvailabilityPolicy.availability(
            hasNowPlaying: hasNowPlaying,
            isLiveRadio: isLiveRadio,
            hasCurrentRadioStation: hasCurrentRadioStation,
            radioStationCount: radioStationCount,
            queueCount: queueCount,
            currentIndex: currentIndex,
            wrapsNext: wrapsNext,
            isQueueItemAvailable: available.contains
        )
    }
}
#endif
