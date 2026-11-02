import Foundation
import Testing
@testable import PrimuseKit

@Suite("Artist hero artwork geometry")
struct ArtistHeroArtworkGeometryTests {
    @Test("The measured dark-photo envelope is linear and the legacy fade remains available")
    func linearAndProtectedFades() throws {
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 440, photoHeight: 350))
        #expect(abs(geometry.finalOpacity(at: 350 * 0.80, captionWeight: 0) - 0.625) < 1e-12)
        #expect(abs(geometry.finalOpacity(at: 350, captionWeight: 0) - 0.375) < 1e-12)
        for weight in [0.0, 0.4, 1.0] {
            var previous = 1.0
            for step in 0...1_000 {
                let position = geometry.totalHeight * Double(step) / 1_000
                let alpha = geometry.finalOpacity(at: position, captionWeight: weight)
                #expect(alpha >= 0 && alpha <= previous + 1e-12)
                if weight == 1 { #expect(abs(alpha - geometry.finalOpacity(at: position)) < 1e-12) }
                previous = alpha
            }
            #expect(geometry.finalOpacity(at: geometry.totalHeight, captionWeight: weight) == 0)
        }
    }

    @Test("The continuation does not move the photograph, title or controls")
    func layoutAndFades() throws {
        for (width, height) in [(320.0, 260.0), (390, 500), (768, 440)] {
            let geometry = try #require(ArtistHeroArtworkGeometry(width: width, photoHeight: height))
            #expect(geometry.photoHeight == height)
            #expect(geometry.extensionHeight > 0 && geometry.extensionHeight <= 144)
            #expect(geometry.sharpOpacity(at: height * 0.4) == 1)
            #expect(geometry.finalOpacity(at: height * 0.4) == 1)
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
        try rgbaImage(width: width, height: height) { x, y in
            let p = pixel(x, y)
            return (p.0, p.1, p.2, 255)
        }
    }

    private func rgbaImage(width: Int, height: Int,
                           pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = pixel(x, y)
                let offset = (y * width + x) * 4
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = color.3
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
        var previous: Int?
        for y in [390, 400, 430, 470] {
            let pixel = sample(bytes, width: result.width, x: 150, y: y)
            let brightness = max(pixel.0, pixel.1, pixel.2)
            // A spatial blur mixes adjacent light pixels into the coat. Its
            // continued center must nevertheless remain dark and continuous,
            // rather than changing to the 230-level surrounding fill.
            #expect(brightness < 80)
            if let previous { #expect(abs(brightness - previous) < 6) }
            previous = brightness
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
        #expect(bounded.height < 350)
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

    @Test("Transition edge colors come from the visible rectangular crop, not hidden source margins")
    func edgeColorsShareDisplayedCrop() throws {
        let source = try image(width: 900, height: 400) { x, _ in
            x < 300 ? (255, 0, 0) : x >= 600 ? (0, 255, 0) : (0, 0, 255)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 200, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
        let edge = try #require(result.edgeColor)
        #expect(edge.blue > 0.98 && edge.red < 0.02 && edge.green < 0.02)
        #expect(result.edgePalette.count == 3)
        for color in result.edgePalette {
            #expect(color.blue > 0.98 && color.red < 0.02 && color.green < 0.02)
        }
    }

    @Test("Edge color follows EXIF rotation along with the displayed photograph")
    func edgeColorIsUpright() throws {
        let source = try image(width: 200, height: 400) { x, _ in x < 100 ? (255, 0, 0) : (0, 0, 255) }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 400, photoHeight: 200))
        let clockwise = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry, exifOrientation: 6))
        let counterclockwise = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry, exifOrientation: 8))
        let bottomBlue = try #require(clockwise.edgeColor)
        let bottomRed = try #require(counterclockwise.edgeColor)
        #expect(bottomBlue.blue > 0.98 && bottomBlue.red < 0.02)
        #expect(bottomRed.red > 0.98 && bottomRed.blue < 0.02)
    }

    @Test("The variable-radius field spreads detail progressively, without a sharp ghost underneath")
    func progressiveSpatialBlur() throws {
        let source = try image(width: 300, height: 400) { x, _ in
            (148...151).contains(x) ? (0, 0, 0) : (255, 255, 255)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.render(image: source, geometry: geometry))
        let bytes = try pixels(result)
        func halfDepthWidth(at y: Int) -> Int {
            let depths = (70..<230).map { 255 - sample(bytes, width: result.width, x: $0, y: y).0 }
            let peak = depths.max() ?? 0
            return depths.filter { Double($0) >= Double(peak) * 0.5 && $0 > 0 }.count
        }
        let clear = halfDepthWidth(at: 100)
        let soft = halfDepthWidth(at: 315)
        let blurred = halfDepthWidth(at: 440)
        #expect(clear <= 5)
        #expect(soft >= 8, "A fading fixed-radius blur leaves the original narrow black stripe visible")
        #expect(blurred > soft, "The blur footprint should grow towards the continued lower field")
    }

    @Test("A transparent edge neither invents black tint nor acquires an opaque border")
    func transparentEdgeStaysTransparent() throws {
        let source = try rgbaImage(width: 300, height: 400) { _, y in
            y < 160 ? (200, 100, 50, 255) : (0, 0, 0, 0)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
        #expect(result.edgeColor == nil)
        #expect(result.edgePalette.isEmpty)
        let bytes = try pixels(result.image)
        #expect(sample(bytes, width: result.image.width, x: 150, y: 20).3 == 255)
        #expect(sample(bytes, width: result.image.width, x: 150, y: result.image.height - 1).3 < 3)
    }

    @Test("Partial transparency is weighted without darkening the supplied page color")
    func partialAlphaDoesNotBecomeBlack() throws {
        let source = try rgbaImage(width: 300, height: 400) { _, _ in (200, 100, 50, 128) }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
        let edge = try #require(result.edgeColor)
        #expect(abs(edge.red - 200.0 / 255) < 0.02)
        #expect(abs(edge.green - 100.0 / 255) < 0.02)
        #expect(abs(edge.blue - 50.0 / 255) < 0.02)
    }

    @Test("Scene background is independent of clothing, transition crop and small corner highlights")
    func sourceBackgroundExcludesClothesAndCrop() throws {
        var scenes: [ArtistHeroArtworkColor] = []
        for clothing: (UInt8, UInt8, UInt8) in [(240, 240, 235), (20, 15, 5)] {
            let source = try image(width: 600, height: 400) { x, y in
                guard y < 80 && (x < 72 || x >= 528) else { return clothing }
                if y < 20 && x < 40 { return (255, 10, 10) }
                return (145, 158, 139)
            }
            for (width, height) in [(200.0, 400.0), (400.0, 200.0)] {
                let geometry = try #require(ArtistHeroArtworkGeometry(width: width, photoHeight: height))
                let prepared = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
                let scene = try #require(prepared.sourceBackground)
                scenes.append(scene)
                #expect(abs(scene.red - 145.0 / 255) < 0.01)
                #expect(abs(scene.green - 158.0 / 255) < 0.01)
                #expect(abs(scene.blue - 139.0 / 255) < 0.01)
                let edge = try #require(prepared.edgeColor)
                #expect(abs(edge.red - Double(clothing.0) / 255) < 0.02)
            }
        }
        #expect(scenes.allSatisfy { $0 == scenes[0] })
    }

    @Test("Scene corner sampling follows EXIF orientation before any hero crop")
    func sourceBackgroundFollowsRotation() throws {
        let source = try image(width: 200, height: 400) { x, _ in
            x < 50 ? (80, 140, 90) : x >= 150 ? (130, 90, 160) : (240, 240, 240)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 200, photoHeight: 300))
        for (orientation, expected): (Int32, (Double, Double, Double)) in [
            (6, (80, 140, 90)), (8, (130, 90, 160)),
        ] {
            let prepared = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry,
                                                                      exifOrientation: orientation))
            let scene = try #require(prepared.sourceBackground)
            #expect(abs(scene.red - expected.0 / 255) < 0.01)
            #expect(abs(scene.green - expected.1 / 255) < 0.01)
            #expect(abs(scene.blue - expected.2 / 255) < 0.01)
        }
    }

    @Test("Transparent scene corners are ignored, and partial alpha does not darken the scene")
    func sourceBackgroundHandlesTransparency() throws {
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        let absent = try rgbaImage(width: 300, height: 400) { x, y in
            y < 80 && (x < 36 || x >= 264) ? (255, 0, 0, 0) : (230, 230, 230, 255)
        }
        let missing = try #require(ArtistHeroArtworkField.prepare(image: absent, geometry: geometry))
        #expect(missing.sourceBackground == nil)
        let partial = try rgbaImage(width: 300, height: 400) { x, y in
            if y < 80 && x < 36 { return (255, 0, 0, 0) }
            if y < 80 && x >= 264 { return (150, 170, 140, 64) }
            return (230, 230, 230, 255)
        }
        let sampled = try #require(ArtistHeroArtworkField.prepare(image: partial, geometry: geometry))
        let scene = try #require(sampled.sourceBackground)
        #expect(abs(scene.red - 150.0 / 255) < 0.02)
        #expect(abs(scene.green - 170.0 / 255) < 0.02)
        #expect(abs(scene.blue - 140.0 / 255) < 0.02)
    }

    @Test("Caption samples measure bright lower-photo content, excluding scene corners and transparent pixels")
    func captionColorSamplesTheVisibleLowerCrop() throws {
        let source = try rgbaImage(width: 400, height: 400) { x, y in
            if x < 48 || x >= 352 || y < 288 { return (255, 0, 0, 255) }
            if x < 100 { return (255, 255, 255, 100) }
            if x >= 300 { return (200, 210, 220, 255) }
            return (30, 40, 50, 255)
        }
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 400, photoHeight: 400))
        let result = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
        let caption = try #require(result.captionColor)
        #expect(abs(caption.red - 200.0 / 255) < 0.02)
        #expect(abs(caption.green - 210.0 / 255) < 0.02)
        #expect(abs(caption.blue - 220.0 / 255) < 0.02)
        let absent = try rgbaImage(width: 400, height: 400) { _, _ in (255, 255, 255, 100) }
        let transparent = try #require(ArtistHeroArtworkField.prepare(image: absent, geometry: geometry))
        #expect(transparent.captionColor == nil)
    }

    @Test("Caption protection keeps measured dark portraits linear and minimally protects bright clothing")
    func captionWeightProtectsOnlyWhenNeeded() throws {
        func color(_ red: Double, _ green: Double, _ blue: Double) -> ArtistHeroArtworkColor {
            ArtistHeroArtworkColor(red: red / 255, green: green / 255, blue: blue / 255)
        }
        // Measured photo/scene pairs, not artist identities or production
        // branches. Dark backgrounds can keep the Apple-like linear envelope.
        let darkPairs = [(color(210, 210, 208), color(10, 10, 8)),
                         (color(154, 106, 86), color(7, 7, 6))]
        for (photo, scene) in darkPairs {
            #expect(ArtistHeroCaptionFade.weight(photo: photo, background: scene) == 0)
        }

        let geometry = try #require(ArtistHeroArtworkGeometry(width: 440, photoHeight: 350))
        func contrast(photo: ArtistHeroArtworkColor, scene: ArtistHeroArtworkColor,
                      position: Double, weight: Double, ink: [Double]) -> Double {
            let body = LibraryDetailTintPolicy.rgbComponents(of: LibraryDetailTintPolicy.backgroundTint(
                red: scene.red, green: scene.green, blue: scene.blue).top)
            let alpha = geometry.finalOpacity(at: geometry.photoHeight * position, captionWeight: weight)
            let pixels = zip([body.red, body.green, body.blue], [photo.red, photo.green, photo.blue])
                .map { $0 + alpha * ($1 - $0) }
            func luminance(_ rgb: [Double]) -> Double {
                let values = rgb.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
                return zip(values, [0.2126, 0.7152, 0.0722]).map(*).reduce(0, +)
            }
            return (luminance(ink) + 0.05) / (luminance(pixels) + 0.05)
        }
        let photo = color(221, 226, 236), scene = color(214, 219, 215)
        let weight = ArtistHeroCaptionFade.weight(photo: photo, background: scene)
        #expect(weight > 0 && weight < 1)
        let title = contrast(photo: photo, scene: scene, position: 0.8, weight: weight, ink: [1, 1, 1])
        let secondary = [245.0 / 255, 247.0 / 255, 246.0 / 255]
        let summary = contrast(photo: photo, scene: scene, position: 1, weight: weight, ink: secondary)
        #expect(title >= 3.1 - 1e-9)
        #expect(summary >= 4.65 - 1e-9)
        let lessTitle = contrast(photo: photo, scene: scene, position: 0.8, weight: weight - 0.001, ink: [1, 1, 1])
        let lessSummary = contrast(photo: photo, scene: scene, position: 1, weight: weight - 0.001, ink: secondary)
        #expect(lessTitle < 3.1 || lessSummary < 4.65, "A smaller weight must fail a guard, rather than over-fading every photograph")
        let white = color(255, 255, 255)
        let strongest = ArtistHeroCaptionFade.weight(photo: white, background: white)
        #expect(strongest > weight && strongest <= 1)
        // Invalid input must remain bounded and conservatively protect text.
        #expect(ArtistHeroCaptionFade.weight(photo: color(.nan, 0, 0), background: scene) == 1)
    }

    @Test("Bright clothing fades into a readable title and translucent summary without a dark stripe")
    func brightPortraitTextHandoff() throws {
        let geometry = try #require(ArtistHeroArtworkGeometry(width: 300, photoHeight: 400))
        // These are representative high-key clothing/neutral portrait fields;
        // the page's readable tint and text alpha are caller responsibilities.
        // Check composed pixels at the title/lower-summary authoring anchors,
        // rather than asserting a particular opacity constant.
        for level: UInt8 in [180, 230] {
            let source = try image(width: 300, height: 400) { _, _ in (level, level, level) }
            let result = try #require(ArtistHeroArtworkField.prepare(image: source, geometry: geometry))
            let bytes = try pixels(result.image)
            func luminance(_ component: Double) -> Double {
                let value = component / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            for (position, textAlpha, minimum) in [(0.90, 1.0, 3.0), (0.95, 0.90, 4.5)] {
                let imageAlpha = geometry.finalOpacity(at: geometry.photoHeight * position)
                let photo = sample(bytes, width: result.image.width, x: 150,
                                   y: Int(geometry.photoHeight * position))
                let background = Double(photo.0) * imageAlpha + 100 * (1 - imageAlpha)
                let foreground = 255 * textAlpha + background * (1 - textAlpha)
                let contrast = (luminance(foreground) + 0.05) / (luminance(background) + 0.05)
                #expect(contrast >= minimum)
            }
        }
    }
}
#endif
