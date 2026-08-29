import Testing
@testable import PrimuseKit

struct SessionStableSnapshotCacheTests {
    @Test func reusesSnapshotForSameSessionRevision() {
        var cache = SessionStableSnapshotCache<[String]>(sessionSeed: "launch-a")
        let build = cache.beginBuild(for: "library-1")
        #expect(cache.isCurrentBuild(build))
        let accepted = cache.commit(["song-a", "song-b"], for: build)

        #expect(accepted)
        #expect(cache.cachedValue(for: "library-1") == ["song-a", "song-b"])
        #expect(cache.cachedValue(for: "library-2") == nil)
    }

    @Test func revisionChangeRejectsOlderCompletion() {
        var cache = SessionStableSnapshotCache<String>(sessionSeed: "launch-a")
        let staleBuild = cache.beginBuild(for: "library-1")
        let currentBuild = cache.beginBuild(for: "library-2")
        #expect(!cache.isCurrentBuild(staleBuild))
        #expect(cache.isCurrentBuild(currentBuild))
        let acceptedStale = cache.commit("stale", for: staleBuild)
        let acceptedCurrent = cache.commit("current", for: currentBuild)

        #expect(!acceptedStale)
        #expect(acceptedCurrent)
        #expect(cache.cachedValue(for: "library-2") == "current")
    }

    @Test func manualRefreshRotatesSeedAndDropsCachedValue() {
        var cache = SessionStableSnapshotCache<String>(sessionSeed: "launch-a")
        let firstBuild = cache.beginBuild(for: "library")
        let acceptedFirst = cache.commit("first", for: firstBuild)
        #expect(acceptedFirst)

        cache.invalidateForManualRefresh()
        #expect(!cache.isCurrentBuild(firstBuild))
        let refreshedBuild = cache.beginBuild(for: "library")
        #expect(cache.cachedValue(for: "library") == nil)
        #expect(firstBuild.randomSeed != refreshedBuild.randomSeed)

        let acceptedStale = cache.commit("stale", for: firstBuild)
        let acceptedRefresh = cache.commit("refreshed", for: refreshedBuild)

        #expect(!acceptedStale)
        #expect(acceptedRefresh)
        #expect(cache.cachedValue(for: "library") == "refreshed")
    }

    @Test func processSessionsUseIndependentSeeds() {
        var first = SessionStableSnapshotCache<String>(sessionSeed: "launch-a")
        var second = SessionStableSnapshotCache<String>(sessionSeed: "launch-b")

        #expect(
            first.beginBuild(for: "library").randomSeed
                != second.beginBuild(for: "library").randomSeed
        )
    }
}
