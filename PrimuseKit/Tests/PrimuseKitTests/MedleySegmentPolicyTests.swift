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
