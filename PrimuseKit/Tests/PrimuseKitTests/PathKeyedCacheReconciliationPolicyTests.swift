import Testing
@testable import PrimuseKit

@Suite("Path keyed cache reconciliation policy")
struct PathKeyedCacheReconciliationPolicyTests {
    @Test("An unchanged location is nothing to reconcile")
    func noneDecisionSkips() {
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .none,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: false
        ) == .skip)
    }

    @Test("A clean move migrates the cache object")
    func cleanMigrate() {
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .migrate,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: false
        ) == .migrate)
    }

    @Test("Any writer owning the destination cancels the migration")
    func destinationInUseSkipsMigration() {
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .migrate,
            hasInFlightOfflineDownloadAtDestination: true,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: false
        ) == .skip)
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .migrate,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: true,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: false
        ) == .skip)
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .migrate,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: true,
            hasActiveStreamingSessionAtDestination: false
        ) == .skip)
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .migrate,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: true
        ) == .skip)
    }

    @Test("Invalidation deletes the previous path regardless of destination use")
    func invalidateIgnoresDestinationUse() {
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .invalidate,
            hasInFlightOfflineDownloadAtDestination: true,
            hasInFlightBackgroundCacheForSong: true,
            hasActivePlaybackUseAtDestination: true,
            hasActiveStreamingSessionAtDestination: true
        ) == .invalidate)
        #expect(PathKeyedCacheReconciliationPolicy.plan(
            decision: .invalidate,
            hasInFlightOfflineDownloadAtDestination: false,
            hasInFlightBackgroundCacheForSong: false,
            hasActivePlaybackUseAtDestination: false,
            hasActiveStreamingSessionAtDestination: false
        ) == .invalidate)
    }
}
