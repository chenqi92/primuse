import Testing
@testable import PrimuseKit

@Suite("Player status bar ownership")
struct PlayerStatusBarOwnershipPolicyTests {
    @Test("A plain open player leaves the status bar to the page underneath")
    func plainPlayerDefersToUnderlyingContent() {
        #expect(PlayerStatusBarOwnershipPolicy.visibilityOwner(
            isPlayerShowing: true, playerHidesStatusBar: false, hasUnderlyingContent: true
        ) == .underlyingContent)
        #expect(PlayerStatusBarOwnershipPolicy.styleOwner(
            isPlayerShowing: true, playerHidesStatusBar: false, playerDeclaresStyle: false, hasUnderlyingContent: true
        ) == .underlyingContent)
    }

    @Test("A collapsed resident player never owns the status bar")
    func dormantPlayerDefersEvenWithStalePreferences() {
        #expect(PlayerStatusBarOwnershipPolicy.visibilityOwner(
            isPlayerShowing: false, playerHidesStatusBar: true, hasUnderlyingContent: true
        ) == .underlyingContent)
        #expect(PlayerStatusBarOwnershipPolicy.styleOwner(
            isPlayerShowing: false, playerHidesStatusBar: true, playerDeclaresStyle: true, hasUnderlyingContent: true
        ) == .underlyingContent)
    }

    @Test("Full-screen effects and music videos still hide the status bar")
    func hidingPlayerKeepsBothDecisions() {
        #expect(PlayerStatusBarOwnershipPolicy.visibilityOwner(
            isPlayerShowing: true, playerHidesStatusBar: true, hasUnderlyingContent: true
        ) == .player)
        #expect(PlayerStatusBarOwnershipPolicy.styleOwner(
            isPlayerShowing: true, playerHidesStatusBar: true, playerDeclaresStyle: false, hasUnderlyingContent: true
        ) == .player)
    }

    @Test("A player with its own text color keeps the style but not visibility")
    func declaredStyleStaysWithPlayer() {
        #expect(PlayerStatusBarOwnershipPolicy.styleOwner(
            isPlayerShowing: true, playerHidesStatusBar: false, playerDeclaresStyle: true, hasUnderlyingContent: true
        ) == .player)
        #expect(PlayerStatusBarOwnershipPolicy.visibilityOwner(
            isPlayerShowing: true, playerHidesStatusBar: false, hasUnderlyingContent: true
        ) == .underlyingContent)
    }

    @Test("Without a page underneath the player answers for itself")
    func noUnderlyingContentKeepsPlayer() {
        #expect(PlayerStatusBarOwnershipPolicy.visibilityOwner(
            isPlayerShowing: false, playerHidesStatusBar: false, hasUnderlyingContent: false
        ) == .player)
        #expect(PlayerStatusBarOwnershipPolicy.styleOwner(
            isPlayerShowing: true, playerHidesStatusBar: false, playerDeclaresStyle: false, hasUnderlyingContent: false
        ) == .player)
    }
}
