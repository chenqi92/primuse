import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrimuseKit

struct ArtworkImageCompatibilityTests {
    @Test func acceptsCompleteImageAndRejectsTruncatedTransfer() throws {
        let completePNG = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        let completeJPEG = try makeJPEG()

        #expect(ArtworkImageCompatibility.isCompleteImage(completePNG))
        #expect(!ArtworkImageCompatibility.isCompleteImage(Data(completePNG.dropLast(12))))
        #expect(ArtworkImageCompatibility.isCompleteImage(completeJPEG))
        #expect(!ArtworkImageCompatibility.isCompleteImage(Data(completeJPEG.dropLast(2))))
        #expect(!ArtworkImageCompatibility.isCompleteImage(Data("not-image".utf8)))
    }

    private func makeJPEG() throws -> Data {
        let pixels = Data([
            0xFF, 0x00, 0x00, 0xFF,
            0x00, 0xFF, 0x00, 0xFF,
            0x00, 0x00, 0xFF, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF,
        ])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            encoded,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    @Test func detectsRedundantOneByTwoSampling() {
        let jpeg = jpegHeader(componentSamples: [0x12, 0x12, 0x12])
        #expect(ArtworkImageCompatibility.hasRedundantJPEGSampling(jpeg))
    }

    @Test func acceptsDecodableOneByTwoSampling() throws {
        let jpeg = try #require(Data(base64Encoded:
            "/9j/4AAQSkZJRgABAgAAAQABAAD//gAQTGF2YzYyLjI4LjEwMAD/2wBDAAgEBAQEBAUFBQUFBQYGBgYGBgYGBgYGBgYHBwcICAgHBwcGBgcHCAgICAkJCQgICAgJCQoKCgwMCwsODg4RERT/xABNAAEBAAAAAAAAAAAAAAAAAAAABgEBAQEAAAAAAAAAAAAAAAAAAAYHEAEAAAAAAAAAAAAAAAAAAAAAEQEAAAAAAAAAAAAAAAAAAAAA/8AAEQgAEAAQAwESAAISAAMSAP/aAAwDAQACEQMRAD8AixJjfwAB/9k="
        ))

        #expect(ArtworkImageCompatibility.isCompleteImage(jpeg))
        #expect(!ArtworkImageCompatibility.hasRedundantJPEGSampling(jpeg))
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

    @Test func inspectsAnimatedGIFAndAPNG() throws {
        let gif = try makeAnimatedGIF()
        let apng = try makeAnimatedImage(type: .png)

        let gifDescriptor = try #require(ArtworkImageCompatibility.inspect(gif))
        #expect(gifDescriptor.format == .gif)
        #expect(gifDescriptor.isAnimated)
        #expect(gifDescriptor.frameCount == 2)
        #expect(gifDescriptor.loopCount == 0)
        #expect(gifDescriptor.duration >= 0.19)

        let apngDescriptor = try #require(ArtworkImageCompatibility.inspect(apng))
        #expect(apngDescriptor.format == .png)
        #expect(apngDescriptor.isAnimated)
        #expect(apngDescriptor.frameCount == 2)
        #expect(apngDescriptor.loopCount == 0)
        #expect(apngDescriptor.duration >= 0.19)
    }

    @Test func inspectsAnimatedWebP() throws {
        let data = try #require(Data(base64Encoded:
            "UklGRoQAAABXRUJQVlA4WAoAAAACAAAAAQAAAQAAQU5JTQYAAAD/////AABBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAAJWUDhMDwAAAC8BQAAABxDlj/4HIqL/AQBBTk1GKAAAAAAAAAAAAAEAAAEAAGQAAABWUDhMDwAAAC8BQAAABxDR/v4HIqL/AQA="
        ))
        let descriptor = try #require(ArtworkImageCompatibility.inspect(data))

        #expect(descriptor.format == .webP)
        #expect(descriptor.isAnimated)
        #expect(descriptor.frameCount == 2)
        #expect(descriptor.loopCount == 0)
        #expect(descriptor.pixelWidth == 2)
        #expect(descriptor.pixelHeight == 2)
    }

    @Test func rejectsAnimationsOutsideSafetyBudget() throws {
        let gif = try makeAnimatedGIF()

        #expect(ArtworkImageCompatibility.inspect(
            gif,
            limits: ArtworkAnimationLimits(maximumFrameCount: 1)
        ) == nil)
        #expect(ArtworkImageCompatibility.inspect(
            gif,
            limits: ArtworkAnimationLimits(maximumCompressedBytes: gif.count - 1)
        ) == nil)
        #expect(ArtworkImageCompatibility.inspect(
            gif,
            limits: ArtworkAnimationLimits(maximumDuration: 0.1)
        ) == nil)
    }

    private func makeAnimatedImage(type: UTType) throws -> Data {
        let encoded = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            encoded,
            type.identifier as CFString,
            2,
            nil
        ))
        let red = try makeSolidImage(red: 1, green: 0, blue: 0)
        let blue = try makeSolidImage(red: 0, green: 0, blue: 1)

        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 0.1],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, red, frameProperties)
        CGImageDestinationAddImage(destination, blue, frameProperties)

        try #require(CGImageDestinationFinalize(destination))
        return encoded as Data
    }

    private func makeAnimatedGIF() throws -> Data {
        try #require(Data(base64Encoded:
            "R0lGODlhAQABAIAAAAAAAP///yH/C05FVFNDQVBFMi4wAwEAAAAh+QQACgAAACwAAAAAAQABAAACAkQBACH5BAAKAAAALAAAAAABAAEAAAICTAEAOw=="
        ))
    }

    private func makeSolidImage(red: UInt8, green: UInt8, blue: UInt8) throws -> CGImage {
        let pixels = Data([red, green, blue, 0xFF, red, green, blue, 0xFF,
                           red, green, blue, 0xFF, red, green, blue, 0xFF])
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        return try #require(CGImage(
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
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
