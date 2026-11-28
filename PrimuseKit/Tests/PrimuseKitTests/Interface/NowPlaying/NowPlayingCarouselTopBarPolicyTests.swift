import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now playing carousel top bar auto-hide")
struct NowPlayingCarouselTopBarPolicyTests {
    typealias Policy = NowPlayingCarouselTopBarPolicy

    private static let ready = Policy.Conditions(
        settledPage: .player,
        pageCount: 5,
        isActive: true,
        isSurfaceExposed: true,
        isLyricsOverlayVisible: false,
        isDragging: false,
        isSettling: false,
        isControlEditing: false,
        isVoiceOverRunning: false
    )

    private static func changing(_ mutate: (inout Policy.Conditions) -> Void) -> Policy.Conditions {
        var copy = ready
        mutate(&copy)
        return copy
    }

    @Test("Auto-hide delay sits within the requested 2 to 3 second window")
    func autoHideDelayInExpectedRange() {
        #expect(Policy.autoHideDelay >= 2.0)
        #expect(Policy.autoHideDelay <= 3.0)
    }

    @Test("Allows auto-hide only when active, multi-page, exposed, idle and without VoiceOver")
    func autoHideGatingConditions() {
        #expect(Policy.tracksActivity(Self.ready))
        #expect(Policy.mayAutoHide(Self.ready))

        let stopsTracking: [(inout Policy.Conditions) -> Void] = [
            { $0.isActive = false },
            { $0.pageCount = 1 },
            { $0.isSurfaceExposed = false },
            { $0.isLyricsOverlayVisible = true },
        ]
        for mutate in stopsTracking {
            let conditions = Self.changing(mutate)
            #expect(!Policy.tracksActivity(conditions))
            #expect(!Policy.mayAutoHide(conditions))
        }

        let pausesHide: [(inout Policy.Conditions) -> Void] = [
            { $0.isDragging = true },
            { $0.isSettling = true },
            { $0.isControlEditing = true },
            { $0.isVoiceOverRunning = true },
        ]
        for mutate in pausesHide {
            let conditions = Self.changing(mutate)
            #expect(Policy.tracksActivity(conditions))
            #expect(!Policy.mayAutoHide(conditions))
        }
    }

    @Test("Remaining delay counts down cleanly and resets while touching or on bad clocks")
    func remainingDelayBehavior() {
        #expect(Policy.remainingDelay(sinceLastActivity: 0, isInteracting: false) == Policy.autoHideDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: 1.0, isInteracting: false) == Policy.autoHideDelay - 1.0)
        #expect(Policy.remainingDelay(sinceLastActivity: Policy.autoHideDelay, isInteracting: false) == 0)
        #expect(Policy.remainingDelay(sinceLastActivity: 10, isInteracting: false) == 0)
        #expect(Policy.remainingDelay(sinceLastActivity: 10, isInteracting: true) == Policy.autoHideDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: -1, isInteracting: false) == Policy.autoHideDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: .nan, isInteracting: false) == Policy.autoHideDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: .infinity, isInteracting: false) == Policy.autoHideDelay)
    }

    @Test("Player screen fades out while every carousel panel tucks to its leading edge")
    func hiddenPresentationPerPage() {
        #expect(Policy.hiddenPresentation(for: .player) == .fadedOnPlayer)
        for panel in NowPlayingCarouselPanel.allCases {
            #expect(Policy.hiddenPresentation(for: .panel(panel)) == .tuckedToEdge(edge: .leading))
        }
    }

    @Test("Tuck offset mirrors correctly for right-to-left layouts")
    func tuckOffsetRespectsRTL() {
        let ltr = Policy.tuckOffsetX(edge: .leading, barLeadingInset: 16, ballDiameter: 34, isRightToLeft: false)
        let rtl = Policy.tuckOffsetX(edge: .leading, barLeadingInset: 16, ballDiameter: 34, isRightToLeft: true)
        #expect(ltr == -64)
        #expect(rtl == 64)

        let trailingLTR = Policy.tuckOffsetX(edge: .trailing, barLeadingInset: 16, ballDiameter: 34, isRightToLeft: false)
        let trailingRTL = Policy.tuckOffsetX(edge: .trailing, barLeadingInset: 16, ballDiameter: 34, isRightToLeft: true)
        #expect(trailingLTR == 64)
        #expect(trailingRTL == -64)
    }

    @Test("Reduced motion disables ball-tuck travel and falls back to gentle fade")
    func reduceMotionDisablesBallTuck() {
        #expect(Policy.usesBallTuckAnimation(for: .tuckedToEdge(edge: .leading), reduceMotion: false))
        #expect(!Policy.usesBallTuckAnimation(for: .tuckedToEdge(edge: .leading), reduceMotion: true))
        #expect(!Policy.usesBallTuckAnimation(for: .fadedOnPlayer, reduceMotion: false))
        #expect(!Policy.usesBallTuckAnimation(for: .visible, reduceMotion: false))
    }

    @Test("General touch aborts an in-flight collapse to ball but stays quiet once hidden")
    func generalTouchAbortRules() {
        #expect(Policy.shouldAbortHideOnGeneralTouch(stage: .collapsedToBall(edge: .leading)))
        #expect(!Policy.shouldAbortHideOnGeneralTouch(stage: .visible))
        #expect(!Policy.shouldAbortHideOnGeneralTouch(stage: .fadedOnPlayer))
        #expect(!Policy.shouldAbortHideOnGeneralTouch(stage: .tuckedOffEdge(edge: .leading)))
    }
}
