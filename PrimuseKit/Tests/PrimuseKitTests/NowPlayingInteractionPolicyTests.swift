import Foundation
import Testing
@testable import PrimuseKit

struct NowPlayingInteractionPolicyTests {
    @Test func screenAwakeRequiresEveryVisibilityCondition() {
        #expect(NowPlayingInteractionPolicy.shouldKeepScreenAwake(
            settingEnabled: true,
            lyricsVisible: true,
            sceneIsActive: true
        ))
        #expect(!NowPlayingInteractionPolicy.shouldKeepScreenAwake(
            settingEnabled: false,
            lyricsVisible: true,
            sceneIsActive: true
        ))
        #expect(!NowPlayingInteractionPolicy.shouldKeepScreenAwake(
            settingEnabled: true,
            lyricsVisible: false,
            sceneIsActive: true
        ))
        #expect(!NowPlayingInteractionPolicy.shouldKeepScreenAwake(
            settingEnabled: true,
            lyricsVisible: true,
            sceneIsActive: false
        ))
    }

    @Test func screenWakeLeaseSurvivesUntilTheLastVisibleWindowReleasesIt() {
        let firstWindow = UUID()
        let secondWindow = UUID()
        var owners: Set<UUID> = []

        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: firstWindow,
            shouldHold: true
        )
        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: secondWindow,
            shouldHold: true
        )
        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: firstWindow,
            shouldHold: false
        )
        #expect(owners == [secondWindow])

        owners = NowPlayingInteractionPolicy.updatedScreenWakeOwners(
            owners,
            ownerID: secondWindow,
            shouldHold: false
        )
        #expect(owners.isEmpty)
    }

    @Test func lyricSeekingRequiresTheToggleAndSynchronizedTiming() {
        #expect(NowPlayingInteractionPolicy.shouldSeekFromLyricTap(
            settingEnabled: true,
            lineIsSynchronized: true
        ))
        #expect(!NowPlayingInteractionPolicy.shouldSeekFromLyricTap(
            settingEnabled: false,
            lineIsSynchronized: true
        ))
        #expect(!NowPlayingInteractionPolicy.shouldSeekFromLyricTap(
            settingEnabled: true,
            lineIsSynchronized: false
        ))
    }

    @Test func scrubPreviewClampsToTheTrackAndRejectsInvalidGeometry() {
        #expect(NowPlayingInteractionPolicy.scrubValue(
            location: 25,
            trackWidth: 100,
            duration: 200
        ) == 50)
        #expect(NowPlayingInteractionPolicy.scrubValue(
            location: -20,
            trackWidth: 100,
            duration: 200
        ) == 0)
        #expect(NowPlayingInteractionPolicy.scrubValue(
            location: 120,
            trackWidth: 100,
            duration: 200
        ) == 200)
        #expect(NowPlayingInteractionPolicy.scrubValue(
            location: 20,
            trackWidth: 0,
            duration: 200
        ) == nil)
    }

    @Test func onlyAnIntentionalHorizontalDragBeginsScrubbing() {
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .undecided,
            horizontalTranslation: 0,
            verticalTranslation: 0
        ) == .undecided)
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .undecided,
            horizontalTranslation: 6,
            verticalTranslation: 0
        ) == .undecided)
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .undecided,
            horizontalTranslation: 10,
            verticalTranslation: 24
        ) == .vertical)
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .undecided,
            horizontalTranslation: 24,
            verticalTranslation: 10
        ) == .horizontal)
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .undecided,
            horizontalTranslation: 10,
            verticalTranslation: 9
        ) == .vertical)
    }

    @Test func scrubGestureDirectionLocksForTheWholeGesture() {
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .vertical,
            horizontalTranslation: 80,
            verticalTranslation: 1
        ) == .vertical)
        #expect(NowPlayingInteractionPolicy.scrubGestureIntent(
            currentIntent: .horizontal,
            horizontalTranslation: 1,
            verticalTranslation: 80
        ) == .horizontal)
    }

    @Test func scrubCommitsOnlyToTheTrackWhereTheDragStarted() {
        #expect(NowPlayingInteractionPolicy.shouldCommitScrub(
            intent: .horizontal,
            startedInteractionID: "song-a",
            currentInteractionID: "song-a"
        ))
        #expect(!NowPlayingInteractionPolicy.shouldCommitScrub(
            intent: .horizontal,
            startedInteractionID: "song-a",
            currentInteractionID: "song-b"
        ))
        #expect(!NowPlayingInteractionPolicy.shouldCommitScrub(
            intent: .vertical,
            startedInteractionID: "song-a",
            currentInteractionID: "song-a"
        ))
        #expect(NowPlayingInteractionPolicy.minimumScrubHitTargetSize >= 44)
    }

    @Test func accessibilityAdjustmentUsesBoundedStepsAndClampsOnce() {
        #expect(NowPlayingInteractionPolicy.accessibilityStep(for: 60) == 5)
        #expect(NowPlayingInteractionPolicy.accessibilityStep(for: 400) == 20)
        #expect(NowPlayingInteractionPolicy.accessibilityStep(for: 4_000) == 30)
        #expect(NowPlayingInteractionPolicy.adjustedPlaybackTime(
            currentTime: 98,
            duration: 100,
            incrementing: true
        ) == 100)
        #expect(NowPlayingInteractionPolicy.adjustedPlaybackTime(
            currentTime: 2,
            duration: 100,
            incrementing: false
        ) == 0)
    }
}
