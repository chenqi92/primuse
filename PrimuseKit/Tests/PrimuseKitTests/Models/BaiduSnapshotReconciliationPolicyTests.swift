import Foundation
import Testing
@testable import PrimuseKit

@Suite struct BaiduSnapshotReconciliationPolicyTests {
    @Test("First-pass retained missing keys do not trip directory completeness checks")
    func retainedMissingKeysAllowedWhileLiveOmissionsStillFail() throws {
        let missing = SourceSyncIndexedItem(
            stableKey: "baidu:1", path: "/Music/Gone.flac", displayName: "Gone.flac",
            parentPath: "/Music", isDirectory: false, songIDs: ["song-gone"],
            size: 100, modifiedDate: nil, revision: "r1"
        )
        let kept = SourceSyncIndexedItem(
            stableKey: "baidu:2", path: "/Music/Keep.flac", displayName: "Keep.flac",
            parentPath: "/Music", isDirectory: false, songIDs: ["song-keep"],
            size: 100, modifiedDate: nil, revision: "r1"
        )
        let added = SourceSyncIndexedItem(
            stableKey: "baidu:3", path: "/Music/New.flac", displayName: "New.flac",
            parentPath: "/Music", isDirectory: false, songIDs: [],
            size: 120, modifiedDate: nil, revision: "r1"
        )

        let plan = try BaiduSnapshotDiffPolicy.plan(
            previousIndex: SourceSyncIndex([missing.stableKey: missing, kept.stableKey: kept]),
            currentItems: [kept, added],
            liveDirectories: ["/Music"]
        )

        #expect(plan.changedParentPaths == ["/Music"])
        #expect(plan.deletedStableKeys.isEmpty)
        let retained = Set(plan.reconciliation?.unresolvedStableKeys ?? [])
        #expect(retained == ["baidu:1"])
        #expect(plan.reconciledIndex["baidu:1"]?.songIDs == ["song-gone"])

        let expectedInDir = Set(plan.reconciledIndex.values.filter { $0.parentPath == "/Music" }.map(\.stableKey))
        #expect(BaiduSnapshotDirectoryReconciliationPolicy.unconfirmedMissingKeys(
            expectedKeys: expectedInDir,
            listedKeys: ["baidu:2", "baidu:3"],
            confirmedDeletedKeys: plan.deletedStableKeys,
            retainedMissingKeys: retained
        ).isEmpty)

        #expect(BaiduSnapshotDirectoryReconciliationPolicy.unconfirmedMissingKeys(
            expectedKeys: expectedInDir,
            listedKeys: ["baidu:3"],
            confirmedDeletedKeys: plan.deletedStableKeys,
            retainedMissingKeys: retained
        ) == ["baidu:2"])
    }
}
