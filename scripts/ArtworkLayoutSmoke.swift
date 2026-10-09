import AppKit
import SwiftUI

/// A real SwiftUI pixel-rendering regression check. Artwork IO and playback are
/// outside this harness; the container and book rendering come from production.
@main
struct ArtworkLayoutSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures: [String] = []
        var cases = 0

        for dimensions in [(600, 400), (400, 600), (400, 400), (1600, 200), (200, 1600), (300, 400)] {
            let image = makeImage(width: dimensions.0, height: dimensions.1)
            let layer = Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            for side: CGFloat in [48, 380, 520] {
                for fixedSize in [false, true] {
                    let name = "\(dimensions.0)x\(dimensions.1)-\(Int(side))-\(fixedSize ? "fixed" : "flexible")"
                    let view = CachedArtworkLayoutFixture(size: fixedSize ? side : nil, coverLayer: layer)
                        .frame(width: side, height: side)
                    try check(view, name: name, width: side, height: side, output: output,
                              failures: &failures)
                    cases += 1
                }
            }

            let widthOnly = CachedArtworkLayoutFixture(coverLayer: layer).frame(width: 180)
            try check(widthOnly, name: "\(dimensions.0)x\(dimensions.1)-width-only", width: 180,
                      height: 180, output: output, failures: &failures)
            cases += 1

            // A caller-owned frame must override the decode size, as during
            // matched-geometry transitions. Opposite-aspect layers coexist while fading.
            let other = Image(nsImage: makeImage(width: dimensions.1, height: dimensions.0))
                .resizable().aspectRatio(contentMode: .fill)
            let transition = CachedArtworkLayoutFixture(
                size: 768, fillsProposedSize: true,
                coverLayer: Group { layer.opacity(0.5); other.opacity(0.5) }
            ).frame(width: 180, height: 180)
            try check(transition, name: "\(dimensions.0)x\(dimensions.1)-transition", width: 180,
                      height: 180, output: output, failures: &failures, checkFill: false, markerSide: 90)
            cases += 1

            let singleFade = CachedArtworkLayoutFixture(coverLayer: layer.opacity(0.5))
                .frame(width: 180, height: 180)
            try check(singleFade, name: "\(dimensions.0)x\(dimensions.1)-single-fade", width: 180,
                      height: 180, output: output, failures: &failures, checkFill: false, markerSide: 90)
            cases += 1

            let book = CachedArtworkLayoutFixture(
                size: 768, fillsProposedSize: true, fitsWholeArtwork: true,
                coverLayer: WholeArtworkFixture(image: image)
            ).frame(width: 120, height: 160)
            try check(book, name: "\(dimensions.0)x\(dimensions.1)-book", width: 120,
                      height: 160, output: output, failures: &failures, checkFill: false)
            cases += 1
        }

        for (name, color) in [("placeholder", Color.green), ("loading", Color.clear)] {
            let view = CachedArtworkLayoutFixture(coverLayer: color).frame(width: 380, height: 380)
            try check(view, name: name, width: 380, height: 380, output: output,
                      failures: &failures, checkFill: false, expectsContent: name != "loading")
            cases += 1
        }

        for failure in failures { print("FAIL: \(failure)") }
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(cases) artwork layout cases; \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }

    @MainActor private static func check<Content: View>(
        _ content: Content, name: String, width: CGFloat, height: CGFloat, output: URL,
        failures: inout [String], checkFill: Bool = true, expectsContent: Bool = true,
        markerSide: CGFloat? = nil
    ) throws {
        let padding: CGFloat = 100
        let renderer = ImageRenderer(content: content.padding(padding))
        renderer.scale = 1
        guard let rendered = renderer.cgImage else { throw Failure.cannotRender }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: output.appendingPathComponent(name + ".png")
        )
        let expectedWidth = Int(width + 2 * padding)
        let expectedHeight = Int(height + 2 * padding)
        guard rendered.width == expectedWidth, rendered.height == expectedHeight else {
            failures.append("\(name): container size changed to \(rendered.width)x\(rendered.height)")
            return
        }
        let pixels = rgba(rendered)
        let left = Int(padding), top = Int(padding)
        let right = left + Int(width), bottom = top + Int(height)
        var escaped = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width where x < left || x >= right || y < top || y >= bottom {
                if pixels[(y * rendered.width + x) * 4 + 3] > 2 { escaped += 1 }
            }
        }
        if escaped > 0 { failures.append("\(name): \(escaped) painted pixels outside the cover frame") }
        func pixel(_ x: Int, _ y: Int, _ channel: Int) -> UInt8 {
            pixels[(y * rendered.width + x) * 4 + channel]
        }
        if pixel(left, top, 3) > 2 || pixel(right - 1, bottom - 1, 3) > 2 {
            failures.append("\(name): rounded corners are missing")
        }
        let cx = (left + right) / 2, cy = (top + bottom) / 2
        if expectsContent && pixel(cx, cy, 3) < 2 {
            failures.append("\(name): artwork/placeholder is missing at center")
        }
        if checkFill || markerSide != nil {
            // The fixture has a red centered square half the short image side.
            // A correctly centered, undistorted aspect-fill keeps it square and
            // half the cover side, regardless of the source image's aspect ratio.
            // Account for premultiplied alpha and display color management.
            func isRed(_ x: Int, _ y: Int) -> Bool {
                let alpha = Double(pixel(x, y, 3))
                return alpha > 2 && Double(pixel(x, y, 0)) > alpha * 0.75
                    && Double(pixel(x, y, 1)) < alpha * 0.4
            }
            let redX = (left..<right).filter { isRed($0, cy) }
            let redY = (top..<bottom).filter { isRed(cx, $0) }
            let expectedSide = Int(markerSide ?? width / 2)
            if abs(redX.count - expectedSide) > 2 || abs(redY.count - expectedSide) > 2
                || abs((redX.first ?? -1) - (cx - expectedSide / 2)) > 2
                || abs((redY.first ?? -1) - (cy - expectedSide / 2)) > 2 {
                failures.append("\(name): marker is not centered, square and correctly scaled (\(redX.count)x\(redY.count))")
            }
        }
        if checkFill {
            for (x, y) in [(cx, top + 2), (cx, bottom - 3), (left + 2, cy), (right - 3, cy)] {
                if pixel(x, y, 1) < 240 || pixel(x, y, 3) < 250 {
                    failures.append("\(name): artwork no longer fills the cover")
                    break
                }
            }
        }
    }

    private static func makeImage(width: Int, height: Int) -> NSImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = min(width, height) / 2
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side))
        return NSImage(cgImage: context.makeImage()!, size: NSSize(width: width, height: height))
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private enum Failure: Error { case cannotRender }
}
