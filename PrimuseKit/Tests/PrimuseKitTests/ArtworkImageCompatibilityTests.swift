import Foundation
import Testing
@testable import PrimuseKit

struct ArtworkImageCompatibilityTests {
    @Test func detectsRedundantOneByTwoSampling() {
        let jpeg = jpegHeader(componentSamples: [0x12, 0x12, 0x12])
        #expect(ArtworkImageCompatibility.hasRedundantJPEGSampling(jpeg))
    }

    @Test func acceptsStandardFourTwoZeroSampling() {
        let jpeg = jpegHeader(componentSamples: [0x22, 0x11, 0x11])
        #expect(!ArtworkImageCompatibility.hasRedundantJPEGSampling(jpeg))
    }

    @Test func acceptsStandardFourFourFourSampling() {
        let jpeg = jpegHeader(componentSamples: [0x11, 0x11, 0x11])
        #expect(!ArtworkImageCompatibility.hasRedundantJPEGSampling(jpeg))
    }

    @Test func ignoresNonJPEGAndTruncatedData() {
        #expect(!ArtworkImageCompatibility.hasRedundantJPEGSampling(Data("not-jpeg".utf8)))
        #expect(!ArtworkImageCompatibility.hasRedundantJPEGSampling(Data([0xFF, 0xD8, 0xFF])))
    }

    private func jpegHeader(componentSamples: [UInt8]) -> Data {
        var payload: [UInt8] = [
            8,             // precision
            0, 16,         // height
            0, 16,         // width
            UInt8(componentSamples.count),
        ]
        for (index, sampling) in componentSamples.enumerated() {
            payload.append(UInt8(index + 1))
            payload.append(sampling)
            payload.append(0)
        }
        let length = payload.count + 2
        return Data(
            [0xFF, 0xD8, 0xFF, 0xC0, UInt8(length >> 8), UInt8(length & 0xFF)]
                + payload
                + [0xFF, 0xDA]
        )
    }
}
