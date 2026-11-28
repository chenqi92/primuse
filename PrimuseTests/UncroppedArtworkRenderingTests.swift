import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class UncroppedArtworkRenderingTests: XCTestCase {
    func testPaddingSurvivesNativeHostScalingAndResizing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .magenta
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }

        let renderSize: CGFloat = 512
        let coverSide = min(327, window.bounds.width - 40, window.bounds.height - 140)
        for sourceSize in [CGSize(width: 600, height: 400), CGSize(width: 400, height: 600)] {
            let source = UIGraphicsImageRenderer(size: sourceSize).image { context in
                UIColor.cyan.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 0, width: sourceSize.width / 2, height: sourceSize.height / 2))
            }
            let artwork = UncroppedArtwork(image: source) {
                Image(uiImage: source).resizable().scaledToFill()
            }
            .environment(\.artworkContentViewport, CGRect(x: 0, y: 0, width: renderSize, height: renderSize))
            .frame(width: renderSize, height: renderSize)
            let host = UIHostingController(rootView: artwork)
            host.view.backgroundColor = .clear
            host.safeAreaRegions = []
            let mover = UIView(frame: CGRect(x: 0, y: 0, width: renderSize, height: renderSize))
            root.addChild(host)
            root.view.addSubview(mover)
            mover.addSubview(host.view)
            host.view.frame = mover.bounds
            host.didMove(toParent: root)
            defer {
                host.willMove(toParent: nil)
                host.view.removeFromSuperview()
                host.removeFromParent()
                mover.removeFromSuperview()
            }

            // Keep the hosted SwiftUI content mounted while the native player changes its pose.
            for side in [coverSide, coverSide * 0.96, CGFloat(48), coverSide] {
                mover.transform = CGAffineTransform(scaleX: side / renderSize, y: side / renderSize)
                mover.frame.origin = CGPoint(x: 20, y: 100)
                root.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(200))

                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let snapshot = UIGraphicsImageRenderer(size: root.view.bounds.size, format: format).image { _ in
                    root.view.drawHierarchy(in: root.view.bounds, afterScreenUpdates: true)
                }
                let image = try XCTUnwrap(snapshot.cgImage)
                let pixels = try rgbaPixels(image)
                let inner = mover.frame.insetBy(dx: 2, dy: 2)
                var uncovered = 0
                for y in Int(ceil(inner.minY))..<Int(floor(inner.maxY)) {
                    for x in Int(ceil(inner.minX))..<Int(floor(inner.maxX)) {
                        let offset = (y * image.width + x) * 4
                        // The cyan/green cover and its blurred padding cannot contain magenta.
                        if pixels[offset] > 200 && pixels[offset + 1] < 30 && pixels[offset + 2] > 200 {
                            uncovered += 1
                        }
                    }
                }
                XCTAssertEqual(uncovered, 0, "\(sourceSize), native side \(side): exposed background")
                let center = (Int(mover.frame.midY) * image.width + Int(mover.frame.midX)) * 4
                XCTAssertGreaterThan(pixels[center + 1], 200, "The foreground cover must remain visible")
            }
        }
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    func testVideoArtworkFramesResumeFromPausedSourceTimeAndLoop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
            AVVideoCompressionPropertiesKey: [AVVideoAllowFrameReorderingKey: true]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pb)
        for index in 0..<45 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        writer.endSession(atSourceTime: CMTime(value: 45, timescale: 30))
        input.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let frames = MotionArtworkVideoFrames(asset: asset, track: track, range: range, initialStartTime: CMTime(seconds: 0.7, preferredTimescale: 600))
        defer { frames.cancel() }
        var displayedPTS: [Double] = []
        for _ in 0..<90 {
            let sample = try frames.next()
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_DoNotDisplay] as? Bool == true { continue }
            displayedPTS.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            if displayedPTS.count >= 60 { break }
        }
        XCTAssertGreaterThanOrEqual(displayedPTS.count, 50)
        XCTAssertEqual(try XCTUnwrap(displayedPTS.first), 0, accuracy: 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(displayedPTS.last), 1.5)
        XCTAssertEqual(try XCTUnwrap(frames.sourceTime(forTimelineTime: CMTime(seconds: 0.2, preferredTimescale: 600))).seconds, 0.9, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(frames.sourceTime(forTimelineTime: CMTime(seconds: 1.0, preferredTimescale: 600))).seconds, 0.2, accuracy: 0.1)
    }
}
