import Foundation
import Testing
@testable import PrimuseKit

@Suite("Audio decode blocking lane policy")
struct AudioDecodeBlockingLanePolicyTests {
    @Test("A cloud input source needs its own blocking lane")
    func cloudSourceNeedsLane() {
        #expect(
            AudioDecodeBlockingLanePolicy.requiresDedicatedBlockingLane(
                sourceKind: .cloudInputSource
            )
        )
    }

    @Test("A direct HTTP range input source needs its own blocking lane")
    func httpSourceNeedsLane() {
        #expect(
            AudioDecodeBlockingLanePolicy.requiresDedicatedBlockingLane(
                sourceKind: .httpInputSource
            )
        )
    }

    @Test("A local file keeps decoding on the cooperative pool")
    func localFileKeepsCooperativePool() {
        #expect(
            !AudioDecodeBlockingLanePolicy.requiresDedicatedBlockingLane(
                sourceKind: .localFileURL
            )
        )
    }

    @Test("Only the origin of the bytes decides, and every kind is decided")
    func everySourceKindIsClassified() {
        // Nothing about the decode mode (DSD, PCM, DoP) participates: the same
        // source kind produces the same answer for every decode of that source.
        for kind in AudioDecodeSourceKind.allCases {
            #expect(
                AudioDecodeBlockingLanePolicy.requiresDedicatedBlockingLane(sourceKind: kind)
                    == (kind != .localFileURL)
            )
        }
    }
}
