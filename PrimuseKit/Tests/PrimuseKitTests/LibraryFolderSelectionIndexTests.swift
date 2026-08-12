import Testing
@testable import PrimuseKit

@Suite("Library folder selection index")
struct LibraryFolderSelectionIndexTests {
    @Test("Transitions a large Other folder through none, partial, all, and none")
    func tracksOtherFolderStatesIncrementally() {
        let nodeID = LibraryFolderNodeID(
            sourceID: "opaque",
            kind: .other,
            normalizedRelativePath: ""
        )
        let songIDs = (0..<82).map { "other-\($0)" }
        let version = LibraryFolderSelectionVersion(
            folderRevision: 1,
            rowOrderRevision: 1
        )
        var selected: Set<String> = []
        var index = LibraryFolderSelectionIndex()

        var snapshot = index.register(
            nodeID: nodeID,
            version: version,
            songIDs: songIDs,
            selectedSongIDs: selected
        )
        #expect(snapshot.state == .none)

        selected.insert(songIDs[0])
        snapshot = onlyChange(index.selectionDidChange(
            changedSongIDs: [songIDs[0]],
            selectedSongIDs: selected
        ))
        #expect(snapshot.state == .partial)
        #expect(snapshot.selectedCount == 1)

        let remaining = Set(songIDs.dropFirst())
        selected.formUnion(remaining)
        snapshot = onlyChange(index.selectionDidChange(
            changedSongIDs: remaining,
            selectedSongIDs: selected
        ))
        #expect(snapshot.state == .all)
        #expect(snapshot.selectedCount == 82)

        let cleared = selected
        selected.removeAll()
        snapshot = onlyChange(index.selectionDidChange(
            changedSongIDs: cleared,
            selectedSongIDs: selected
        ))
        #expect(snapshot.state == .none)
        #expect(snapshot.selectedCount == 0)
    }

    @Test("Updates overlapping root and deep folders without rescanning either group")
    func updatesOverlappingGroups() {
        let root = node("root")
        let deep = node("root/deep")
        let version = LibraryFolderSelectionVersion(
            folderRevision: 4,
            rowOrderRevision: 9
        )
        var selected: Set<String> = []
        var index = LibraryFolderSelectionIndex()

        _ = index.register(
            nodeID: root,
            version: version,
            songIDs: ["root-song", "deep-a", "deep-b"],
            selectedSongIDs: selected
        )
        _ = index.register(
            nodeID: deep,
            version: version,
            songIDs: ["deep-a", "deep-b"],
            selectedSongIDs: selected
        )

        selected.formUnion(["deep-a", "deep-b"])
        let changes = Dictionary(uniqueKeysWithValues: index.selectionDidChange(
            changedSongIDs: ["deep-a", "deep-b"],
            selectedSongIDs: selected
        ).map { ($0.nodeID, $0) })
        #expect(changes[root]?.state == .partial)
        #expect(changes[deep]?.state == .all)

        selected.insert("root-song")
        let rootChange = onlyChange(index.selectionDidChange(
            changedSongIDs: ["root-song"],
            selectedSongIDs: selected
        ))
        #expect(rootChange.nodeID == root)
        #expect(rootChange.state == .all)
    }

    @Test("Replacing a group version removes stale inverse memberships")
    func replacesChangedGroupMembership() {
        let group = node("album")
        var index = LibraryFolderSelectionIndex()
        var selected: Set<String> = ["kept"]

        _ = index.register(
            nodeID: group,
            version: .init(folderRevision: 1, rowOrderRevision: 1),
            songIDs: ["kept", "removed"],
            selectedSongIDs: selected
        )
        let refreshed = index.register(
            nodeID: group,
            version: .init(folderRevision: 2, rowOrderRevision: 2),
            songIDs: ["kept"],
            selectedSongIDs: selected
        )
        #expect(refreshed.state == .all)

        selected.insert("removed")
        #expect(index.selectionDidChange(
            changedSongIDs: ["removed"],
            selectedSongIDs: selected
        ).isEmpty)
    }

    @Test("Keeps 2.5k and 5.6k folder state changes within the regression budget")
    func handlesLargeGroups() {
        let smallIDs = (0..<2_500).map { "small-\($0)" }
        let largeIDs = (0..<5_600).map { "large-\($0)" }
        let version = LibraryFolderSelectionVersion(
            folderRevision: 1,
            rowOrderRevision: 1
        )
        var index = LibraryFolderSelectionIndex()

        let clock = ContinuousClock()
        let start = clock.now
        _ = index.register(
            nodeID: node("small"),
            version: version,
            songIDs: smallIDs,
            selectedSongIDs: []
        )
        _ = index.register(
            nodeID: node("large"),
            version: version,
            songIDs: largeIDs,
            selectedSongIDs: []
        )
        let selected = Set(smallIDs + largeIDs)
        let changes = index.selectionDidChange(
            changedSongIDs: selected,
            selectedSongIDs: selected
        )
        let elapsed = start.duration(to: clock.now)

        #expect(changes.count == 2)
        #expect(changes.allSatisfy { $0.state == .all })
        #expect(elapsed < .seconds(2))
    }

    private func node(_ path: String) -> LibraryFolderNodeID {
        LibraryFolderNodeID(
            sourceID: "source",
            kind: .folder,
            normalizedRelativePath: path
        )
    }

    private func onlyChange(
        _ changes: [LibraryFolderSelectionSnapshot]
    ) -> LibraryFolderSelectionSnapshot {
        #expect(changes.count == 1)
        return changes[0]
    }
}
