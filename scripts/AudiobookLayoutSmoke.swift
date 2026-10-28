import AppKit
import SwiftUI

@main
struct AudiobookLayoutSmoke {
    @MainActor static func main() {
        do {
            try verify()
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor private static func verify() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        var count = 0
        for width: CGFloat in [264, 319, 374] {
            for leading in [true, false] {
                for columnHeight: CGFloat in [100, 260, 420] {
                    for proposedHeight: CGFloat? in [nil, 140] {
                        let layout = AudiobookHeroRowLayout(
                            columnLeading: leading, columnWidth: 72, spacing: 24, maxSide: 480
                        ) {
                            Color.red.frame(height: columnHeight)
                            Color.green
                        }
                        let renderer = ImageRenderer(content: layout)
                        renderer.proposedSize = ProposedViewSize(width: width, height: proposedHeight)
                        guard let image = renderer.cgImage else { throw Failure.render }
                        let red = try bounds(of: image, channel: 0)
                        let green = try bounds(of: image, channel: 1)
                        guard image.height >= Int(columnHeight), red.height == columnHeight else {
                            throw Failure.clippedColumn(width, columnHeight, proposedHeight)
                        }
                        guard red.width == 72, green.width == green.height,
                              red.minY == green.minY,
                              (leading ? green.minX - red.maxX : red.minX - green.maxX) >= 24 else {
                            throw Failure.misalignedCover
                        }
                        count += 1
                    }
                }
            }
        }
        print("PASS: \(count) audiobook layouts preserve column height, cover shape and spacing")
    }

    private static func bounds(of image: CGImage, channel: Int) throws -> CGRect {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i + channel] > 150 && pixels[i + (1 - channel)] < 100 && pixels[i + 3] > 240 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw Failure.render }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private enum Failure: Error {
        case render
        case clippedColumn(CGFloat, CGFloat, CGFloat?)
        case misalignedCover
    }
}
