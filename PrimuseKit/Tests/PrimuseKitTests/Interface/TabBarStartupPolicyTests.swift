import Foundation
import Testing
@testable import PrimuseKit

@Suite("Tab bar cold-launch stability")
struct TabBarStartupPolicyTests {
    typealias Policy = TabBarStartupPolicy

    @Test("Identifies compact tab layouts with fewer than four tabs")
    func compactTabCountDetection() {
        #expect(!Policy.isCompactTabLayout(visibleTabCount: 0))
        #expect(Policy.isCompactTabLayout(visibleTabCount: 1))
        #expect(Policy.isCompactTabLayout(visibleTabCount: 2))
        #expect(Policy.isCompactTabLayout(visibleTabCount: 3))
        #expect(!Policy.isCompactTabLayout(visibleTabCount: 4))
    }

    @Test("Pre-enables accessory placeholder while a persisted session is pending or restoring")
    func holdsAccessorySlotDuringPendingRestore() {
        for phase in [PlaybackSessionRestoreLifecycle.Phase.pending, .restoring] {
            let state = Policy.systemBottomAccessoryState(
                hasLivePlayback: false,
                restorePhase: phase,
                hasPersistedSession: true,
                isSafeModeActive: false,
                isSuppressedByOverlay: false
            )
            #expect(state == .restoringPlaceholder)
            #expect(state.isEnabled)
            #expect(!state.isInteractive)
        }
    }

    @Test("Keeps accessory hidden on cold launch when no persisted session exists")
    func staysHiddenWithoutPersistedSession() {
        let state = Policy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .pending,
            hasPersistedSession: false,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        #expect(state == .hidden)
        #expect(!state.isEnabled)
    }

    @Test("Transitions seamlessly to live when playback restores, or hides when restore ends empty")
    func postRestoreOutcomes() {
        let restored = Policy.systemBottomAccessoryState(
            hasLivePlayback: true,
            restorePhase: .completed,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        #expect(restored == .live)
        #expect(restored.isEnabled)
        #expect(restored.isInteractive)

        let emptyAfterRestore = Policy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .completed,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        #expect(emptyAfterRestore == .hidden)

        let supersededEmpty = Policy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .superseded,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: false
        )
        #expect(supersededEmpty == .hidden)
    }

    @Test("Safe mode and overlays suppress the placeholder and live accessory")
    func safeModeAndOverlaysSuppressAccessory() {
        #expect(Policy.systemBottomAccessoryState(
            hasLivePlayback: false,
            restorePhase: .pending,
            hasPersistedSession: true,
            isSafeModeActive: true,
            isSuppressedByOverlay: false
        ) == .hidden)

        #expect(Policy.systemBottomAccessoryState(
            hasLivePlayback: true,
            restorePhase: .completed,
            hasPersistedSession: true,
            isSafeModeActive: false,
            isSuppressedByOverlay: true
        ) == .hidden)
    }

    @Test("Tab bar minimize behavior stays aligned across placeholder and live states")
    func minimizeBehaviorMatchesAccessoryStability() {
        #expect(Policy.minimizesTabBarOnScroll(accessoryState: .restoringPlaceholder, pinsMiniPlayer: false, carPlayEditorActive: false))
        #expect(Policy.minimizesTabBarOnScroll(accessoryState: .live, pinsMiniPlayer: false, carPlayEditorActive: false))
        #expect(!Policy.minimizesTabBarOnScroll(accessoryState: .restoringPlaceholder, pinsMiniPlayer: true, carPlayEditorActive: false))
        #expect(!Policy.minimizesTabBarOnScroll(accessoryState: .live, pinsMiniPlayer: false, carPlayEditorActive: true))
        #expect(!Policy.minimizesTabBarOnScroll(accessoryState: .hidden, pinsMiniPlayer: false, carPlayEditorActive: false))
    }

    @Test("Persisted session probe reflects file presence on disk")
    func persistedSessionProbe() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionURL = dir.appendingPathComponent("playback-session.json")
        #expect(!Policy.hasPersistedSession(at: sessionURL))
        try Data("{}".utf8).write(to: sessionURL)
        #expect(Policy.hasPersistedSession(at: sessionURL))
    }
}
