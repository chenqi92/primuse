import Testing
@testable import PrimuseKit

@Suite("Deleted directory reconciliation")
struct SourceSyncDirectoryPruningPolicyTests {
    @Test("Deleting a directory removes all descendants including empty nested directories")
    func prunesDeletedSubtree() {
        let items = [item("gone", parent: "root", directory: true),
                     item("nested", parent: "gone", directory: true),
                     item("track", parent: "nested"),
                     item("empty", parent: "nested", directory: true),
                     item("keep", parent: "root")]
        let baseline = Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) })
        var current = baseline
        current["gone"] = nil
        #expect(SourceSyncDirectoryPruningPolicy.confirmedDeletedDirectoryPaths(
            index: baseline, deletedKeys: ["gone"]
        ) == ["gone", "nested", "empty"])
        #expect(SourceSyncDirectoryPruningPolicy.confirmedDeletedDirectoryPaths(
            index: baseline, deletedKeys: ["track"]
        ).isEmpty)
        #expect(SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
            baseline: baseline, current: current
        ) == ["nested", "track", "empty"])
    }

    @Test("A moved subtree and songs moved out of the deleted directory survive")
    func preservesMovedEntries() {
        let items = [item("gone", parent: "root", directory: true),
                     item("moved-directory", parent: "gone", directory: true),
                     item("nested-track", parent: "moved-directory"),
                     item("moved-track", parent: "gone"),
                     item("deleted-track", parent: "gone")]
        let baseline = Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) })
        var current = baseline
        current["gone"] = nil
        current["moved-directory"]?.parentPath = "root"
        current["moved-track"]?.parentPath = "root"
        #expect(SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
            baseline: baseline, current: current
        ) == ["deleted-track"])
        #expect(SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
            baseline: baseline, current: baseline
        ).isEmpty)
    }

    @Test("Replacing a directory identity at the same path does not orphan surviving children")
    func preservesReconciledDirectoryIdentity() {
        let old = item("legacy-key", path: "/Music", parent: "/", directory: true)
        let track = item("track", path: "/Music/a.mp3", parent: "/Music")
        let current = item("provider-key", path: "/Music", parent: "/", directory: true)
        #expect(SourceSyncDirectoryPruningPolicy.orphanedDescendantKeys(
            baseline: [old.stableKey: old, track.stableKey: track],
            current: [current.stableKey: current, track.stableKey: track]
        ).isEmpty)
    }

    private func item(_ key: String, path: String? = nil, parent: String?, directory: Bool = false) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(stableKey: key, path: path ?? key, parentPath: parent,
                             isDirectory: directory, songIDs: directory ? [] : [key],
                             size: 0, modifiedDate: nil, revision: nil)
    }
}
