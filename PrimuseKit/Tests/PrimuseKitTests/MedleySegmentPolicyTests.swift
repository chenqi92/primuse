import Foundation
import Testing
@testable import PrimuseKit

@Suite struct MedleyPreparationLeadTests {
    @Test func leadLeavesTheSliceItsOwnTime() {
        for seconds in MedleySegmentPolicy.allowedSegmentLengths {
            let length = TimeInterval(seconds)
            let lead = MedleySegmentPolicy.preparationLead(segmentLength: length)
            let overlap = MedleySegmentPolicy.overlap(segmentLength: length)
            #expect(lead > 0)
            #expect(lead <= 12)
            // Preparation starts after the slice has been heard for a while.
            #expect(length - overlap - lead >= length * 0.45)
        }
    }

    @Test func noLeadForUnknownLength() {
        #expect(MedleySegmentPolicy.preparationLead(segmentLength: 0) == 0)
        #expect(MedleySegmentPolicy.preparationLead(segmentLength: .nan) == 0)
    }
}

@Suite struct MedleyDataUsagePolicyTests {
    @Test func asksOnlyOnMeteredNetworkWithSomethingToDownload() {
        #expect(MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: true, isOnUnmeteredNetwork: false,
            promptDisabled: false, hasSongToDownload: true
        ))
        #expect(!MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: true, isOnUnmeteredNetwork: true,
            promptDisabled: false, hasSongToDownload: true
        ))
        #expect(!MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: true, isOnUnmeteredNetwork: false,
            promptDisabled: false, hasSongToDownload: false
        ))
        #expect(!MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: true, isOnUnmeteredNetwork: false,
            promptDisabled: true, hasSongToDownload: true
        ))
        // Before the first network path arrives nothing is known to be metered.
        #expect(!MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: false, isOnUnmeteredNetwork: false,
            promptDisabled: false, hasSongToDownload: true
        ))
    }
}
