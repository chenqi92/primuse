import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple TV snapshot row selection")
struct TVSnapshotRowSelectionTests {
    private func row(_ id: String?, _ sourceID: String?) -> TVSnapshotIncomingRow {
        TVSnapshotIncomingRow(id: id, sourceID: sourceID)
    }

    @Test func lanPayloadReferencingAnUnknownSourceIsRefused() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("a", "src"), row("b", "gone")],
            knownSourceIDs: ["src"],
            retainedSongIDs: [],
            fromCloud: false
        )
        #expect(outcome == nil)
    }

    @Test func cloudPayloadDropsRowsOfUnknownSources() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("a", "src"), row("b", "gone"), row("c", "src")],
            knownSourceIDs: ["src"],
            retainedSongIDs: [],
            fromCloud: true
        )
        #expect(outcome?.keptIncomingIndices == [0, 2])
        #expect(outcome?.retainedLocalIndices == [])
        #expect(outcome?.requiresRewrite == true)
    }

    @Test func completePayloadWithoutLocalSongsIsKeptVerbatim() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("a", "src"), row("b", "src")],
            knownSourceIDs: ["src", "spare"],
            retainedSongIDs: [],
            fromCloud: false
        )
        #expect(outcome?.keptIncomingIndices == [0, 1])
        #expect(outcome?.retainedLocalIndices == [])
        #expect(outcome?.requiresRewrite == false)
    }

    @Test func locallyScannedSongsAreAppendedEvenWhenNothingIsDropped() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("a", "src")],
            knownSourceIDs: ["src", "tv"],
            retainedSongIDs: [TVSnapshotLocalSong(id: "tv-only", sourceID: "tv")],
            fromCloud: false
        )
        #expect(outcome?.keptIncomingIndices == [0])
        #expect(outcome?.retainedLocalIndices == [0])
        #expect(outcome?.requiresRewrite == true)
    }

    @Test func localSongsAlreadyInThePayloadOrOnLostSourcesAreNotAppended() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("a", "src"), row("b", "gone")],
            knownSourceIDs: ["src", "tv"],
            retainedSongIDs: [
                TVSnapshotLocalSong(id: "a", sourceID: "src"),
                TVSnapshotLocalSong(id: "orphan", sourceID: "gone"),
                TVSnapshotLocalSong(id: "tv-only", sourceID: "tv")
            ],
            fromCloud: true
        )
        #expect(outcome?.keptIncomingIndices == [0])
        #expect(outcome?.retainedLocalIndices == [2])
        #expect(outcome?.requiresRewrite == true)
    }

    @Test func droppedRowIdsDoNotBlockTheLocalSongOfTheSameID() {
        // "b" only survives in the dropped row, so the locally scanned copy is
        // the one that must be kept.
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [row("b", "gone")],
            knownSourceIDs: ["tv"],
            retainedSongIDs: [TVSnapshotLocalSong(id: "b", sourceID: "tv")],
            fromCloud: true
        )
        #expect(outcome?.keptIncomingIndices == [])
        #expect(outcome?.retainedLocalIndices == [0])
        #expect(outcome?.requiresRewrite == true)
    }

    @Test func rowsWithoutASourceIDCountAsUnknown() {
        let refused = TVSnapshotRowSelection.select(
            incomingRows: [row("a", nil)],
            knownSourceIDs: ["src"],
            retainedSongIDs: [],
            fromCloud: false
        )
        #expect(refused == nil)
        let dropped = TVSnapshotRowSelection.select(
            incomingRows: [row("a", nil), row("b", "src")],
            knownSourceIDs: ["src"],
            retainedSongIDs: [],
            fromCloud: true
        )
        #expect(dropped?.keptIncomingIndices == [1])
        #expect(dropped?.requiresRewrite == true)
    }

    @Test func retainedSongsKeepTheirInputOrder() {
        let outcome = TVSnapshotRowSelection.select(
            incomingRows: [],
            knownSourceIDs: ["tv"],
            retainedSongIDs: [
                TVSnapshotLocalSong(id: "second", sourceID: "tv"),
                TVSnapshotLocalSong(id: "first", sourceID: "tv")
            ],
            fromCloud: false
        )
        #expect(outcome?.retainedLocalIndices == [0, 1])
        #expect(outcome?.requiresRewrite == true)
    }
}
