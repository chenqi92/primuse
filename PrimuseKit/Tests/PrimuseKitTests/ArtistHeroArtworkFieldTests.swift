import Foundation
import Testing
@testable import PrimuseKit

@Suite("Artist hero artwork geometry")
struct ArtistHeroArtworkGeometryTests {
    @Test("The continuation does not move the photograph, title or controls")
    func layoutAndFades() throws {
        for (width, height) in [(320.0, 260.0), (390, 500), (768, 440)] {
            let geometry = try #require(ArtistHeroArtworkGeometry(width: width, photoHeight: height))
            #expect(geometry.photoHeight == height)
            #expect(geometry.extensionHeight > 0 && geometry.extensionHeight <= 96)
            #expect(geometry.sharpOpacity(at: height * 0.6) == 1)
            #expect(geometry.finalOpacity(at: height * 0.7) == 1)
            #expect(geometry.finalOpacity(at: height) > 0)
            #expect(geometry.sharpOpacity(at: height) == 0)
            #expect(geometry.finalOpacity(at: geometry.totalHeight) == 0)
            var previous = 1.0
            for step in 0...1_000 {
                let opacity = geometry.finalOpacity(at: Double(step) / 1_000 * geometry.totalHeight)
                #expect(opacity >= 0 && opacity <= previous)
                previous = opacity
            }
            #expect(geometry.finalOpacity(at: geometry.totalHeight - 0.1) < 0.00001)
        }
    }

    @Test("Transient, nonfinite and pathological geometry cannot start an image render")
    func invalidGeometry() {
        for (width, height) in [(0.0, 400.0), (390, 0), (-1, 400), (.infinity, 400),
                                (.nan, 400), (390, .infinity), (1e100, 400), (1, 16_384)] {
            #expect(ArtistHeroArtworkGeometry(width: width, photoHeight: height) == nil)
        }
    }
}

#if canImport(CoreGraphics) && canImport(CoreImage)
import CoreGraphics

@Suite("Artist hero static image field")
struct ArtistHeroArtworkFieldTests {
    private func image(width: Int, height: Int,
                       pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
            }
        }
        let data = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: width * 4,
                                   space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: data, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        #expect(drawn)
        return bytes
    }

    private func sample(_ bytes: [UInt8], width: Int, x: Int, y: Int) -> (Int, Int, Int, Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    @Test("A real portrait uses the rectangular aspect-fill crop, without the previous square zoom")
    func cropMatchesSharpSurface() throws {
        let source = try image(width: 400, height: 800) { x, _ in
            x < 100 ? (255, 0, 0) : x >= 300 ? (0, 255, 0) : (0, 0, 255)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 200, photoHeight: 300))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry))
        let bytes = try pixels(result)
        let left = sample(bytes, width: result.width, x: 30, y: 20)
        let center = sample(bytes, width: result.width, x: 100, y: 20)
        let right = sample(bytes, width: result.width, x: 170, y: 20)
        #expect(left.0 > 240 && left.2 < 15)
        #expect(center.2 > 240 && center.0 < 15)
        #expect(right.1 > 240 && right.2 < 15)
    }

    @Test("A neutral photograph stays neutral and opaque through its continued lower edge")
    func neutralPhotoDoesNotAcquireATintOrBlackBorder() throws {
        let source = try image(width: 300, height: 400) { _, _ in (128, 128, 128) }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry))
        let bytes = try pixels(result)
        for y in [0, 200, 399, 400, result.height - 1] {
            for x in [0, 150, result.width - 1] {
                let pixel = sample(bytes, width: result.width, x: x, y: y)
                #expect(abs(pixel.0 - 128) <= 2)
                #expect(abs(pixel.0 - pixel.1) <= 1 && abs(pixel.1 - pixel.2) <= 1)
                #expect(pixel.3 == 255)
            }
        }
    }

    @Test("The continuation contains a real lower band, not a vertically stretched final row")
    func continuedBandHasTwoDimensionalContent() throws {
        let source = try image(width: 300, height: 400) { x, y in
            (UInt8(clamping: y / 2), UInt8(clamping: x / 2), 30)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry))
        let bytes = try pixels(result)
        let upper = sample(bytes, width: result.width, x: 150, y: 425)
        let lower = sample(bytes, width: result.width, x: 150, y: 475)
        let left = sample(bytes, width: result.width, x: 40, y: 450)
        let right = sample(bytes, width: result.width, x: 260, y: 450)
        #expect(abs(upper.0 - lower.0) > 10)
        #expect(abs(left.1 - right.1) > 80)
        let seamAbove = sample(bytes, width: result.width, x: 150, y: 399)
        let seamBelow = sample(bytes, width: result.width, x: 150, y: 400)
        #expect(abs(seamAbove.0 - seamBelow.0) <= 3)
    }

    @Test("Dark clothes continue below the photo rather than abruptly becoming a light fill")
    func darkClothesContinue() throws {
        let source = try image(width: 300, height: 400) { x, y in
            y >= 220 && x >= 60 && x < 240 ? (0, 0, 0) : (230, 230, 220)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry))
        let bytes = try pixels(result)
        for y in [390, 400, 430, 470] {
            let pixel = sample(bytes, width: result.width, x: 150, y: y)
            #expect(max(pixel.0, pixel.1, pixel.2) < 20)
        }
    }

    @Test("Preparation stays bounded independently of screen scale or a requested oversized field")
    func boundedOutput() throws {
        let source = try image(width: 600, height: 600) { _, _ in (30, 70, 100) }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 1_024, photoHeight: 500))
        let small = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry, maximumPixelWidth: 128))
        let bounded = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry, maximumPixelWidth: 8_192))
        #expect(small.width == 128)
        #expect(bounded.width == 512)
        #expect(bounded.height < 300)
        #expect(ArtistHeroArtworkField.render(image: source, geometry: geometry, maximumPixelWidth: 0) == nil)
    }

    @Test("EXIF rotation uses the same orientation as the displayed photograph")
    func orientationIsApplied() throws {
        let source = try image(width: 200, height: 400) { x, _ in x < 100 ? (255, 0, 0) : (0, 0, 255) }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 400, photoHeight: 200))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry, exifOrientation: 6))
        let bytes = try pixels(result)
        let top = sample(bytes, width: result.width, x: 192, y: 20)
        let bottom = sample(bytes, width: result.width, x: 192, y: 160)
        #expect(top.0 > 240 && top.2 < 15)
        #expect(bottom.2 > 220 && bottom.0 < 35)
    }
}
#endif
