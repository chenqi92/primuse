import Testing
@testable import PrimuseKit

@Suite("Duplicate cleanup selection")
struct DuplicateCleanupSelectionPolicyTests {
    @Test("Read-only songs are locked while one writable copy is preserved")
    func defaultsKeepReadOnlyAndPreferredWritable() {
        let kept = DuplicateCleanupSelectionPolicy.defaultKeptSongIDs(
            readOnlySongIDs: ["catalogue"],
            writableSongIDs: ["local-best", "local-other"],
            preferredWritableSongID: "local-best"
        )

        #expect(kept == ["catalogue", "local-best"])
        #expect(DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: ["local-best", "local-other"],
            keptSongIDs: kept
        ) == ["local-other"])
    }

    @Test("A read-only song cannot be toggled into the deletion set")
    func readOnlyToggleIsIgnored() {
        let kept = DuplicateCleanupSelectionPolicy.toggledKeptSongIDs(
            currentKeptSongIDs: ["catalogue", "local"],
            toggledSongID: "catalogue",
            readOnlySongIDs: ["catalogue"],
            writableSongIDs: ["local"]
        )

        #expect(kept == ["catalogue", "local"])
    }

    @Test("The last writable copy cannot be removed")
    func lastWritableCopyStaysKept() {
        let kept = DuplicateCleanupSelectionPolicy.toggledKeptSongIDs(
            currentKeptSongIDs: ["catalogue", "local"],
            toggledSongID: "local",
            readOnlySongIDs: ["catalogue"],
            writableSongIDs: ["local"]
        )

        #expect(kept == ["catalogue", "local"])
        #expect(DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: ["local"],
            keptSongIDs: kept
        ).isEmpty)
    }

    @Test("Deletion candidates can be unchecked and the kept copy can change")
    func manualWinnerCanBeChanged() {
        let firstToggle = DuplicateCleanupSelectionPolicy.toggledKeptSongIDs(
            currentKeptSongIDs: ["best"],
            toggledSongID: "other",
            readOnlySongIDs: [],
            writableSongIDs: ["best", "other"]
        )
        let secondToggle = DuplicateCleanupSelectionPolicy.toggledKeptSongIDs(
            currentKeptSongIDs: firstToggle,
            toggledSongID: "best",
            readOnlySongIDs: [],
            writableSongIDs: ["best", "other"]
        )

        #expect(firstToggle == ["best", "other"])
        #expect(DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: ["best", "other"],
            keptSongIDs: firstToggle
        ).isEmpty)
        #expect(secondToggle == ["other"])
    }

    @Test("Groups containing only read-only songs have no deletion candidates")
    func allReadOnlySongsStayLocked() {
        let readOnlySongIDs: Set<String> = ["catalogue-a", "catalogue-b"]
        let kept = DuplicateCleanupSelectionPolicy.defaultKeptSongIDs(
            readOnlySongIDs: readOnlySongIDs,
            writableSongIDs: [],
            preferredWritableSongID: nil
        )

        #expect(kept == readOnlySongIDs)
        #expect(DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: [],
            keptSongIDs: kept
        ).isEmpty)
    }

    @Test("Large selections remain a single linear pass")
    func largeSelectionProducesExpectedRemovalSet() {
        let writableSongIDs = (0..<10_000).map { "song-\($0)" }
        let kept = DuplicateCleanupSelectionPolicy.defaultKeptSongIDs(
            readOnlySongIDs: [],
            writableSongIDs: writableSongIDs,
            preferredWritableSongID: "song-4321"
        )
        let removable = DuplicateCleanupSelectionPolicy.removableSongIDs(
            writableSongIDs: writableSongIDs,
            keptSongIDs: kept
        )

        #expect(kept == ["song-4321"])
        #expect(removable.count == 9_999)
        #expect(!removable.contains("song-4321"))
    }
}
