import Foundation
import Testing
@testable import PrimuseKit

@Suite("Snapshot baseline staleness")
struct SnapshotBaselineGateTests {
    private let baseline = SnapshotFileIdentity(size: 1024, modificationNanoseconds: 42, fileNumber: 7)

    @Test func unchangedFileKeepsTheBaseline() {
        let current = SnapshotFileIdentity(size: 1024, modificationNanoseconds: 42, fileNumber: 7)
        #expect(SnapshotBaselineGate.isStillValid(captured: baseline, current: current))
    }

    @Test func rewrittenFileInvalidatesTheBaseline() {
        let grown = SnapshotFileIdentity(size: 2048, modificationNanoseconds: 42, fileNumber: 7)
        let touched = SnapshotFileIdentity(size: 1024, modificationNanoseconds: 99, fileNumber: 7)
        #expect(!SnapshotBaselineGate.isStillValid(captured: baseline, current: grown))
        #expect(!SnapshotBaselineGate.isStillValid(captured: baseline, current: touched))
    }

    @Test func replaceByRenameInvalidatesTheBaselineEvenAtTheSameSizeAndTime() {
        let replaced = SnapshotFileIdentity(size: 1024, modificationNanoseconds: 42, fileNumber: 8)
        #expect(!SnapshotBaselineGate.isStillValid(captured: baseline, current: replaced))
    }

    @Test func aFileMissingBothTimesKeepsTheBaseline() {
        #expect(SnapshotBaselineGate.isStillValid(captured: nil, current: nil))
    }

    @Test func anAppearingOrDisappearingFileInvalidatesTheBaseline() {
        #expect(!SnapshotBaselineGate.isStillValid(captured: nil, current: baseline))
        #expect(!SnapshotBaselineGate.isStillValid(captured: baseline, current: nil))
    }
}
