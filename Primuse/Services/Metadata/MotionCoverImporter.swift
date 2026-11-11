import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import PrimuseKit
import UniformTypeIdentifiers

enum MotionCoverImportError: LocalizedError {
    case rejected(MotionCoverImportRejection)
    case failed

    var errorDescription: String? {
        switch self {
        case .rejected(.tooLong): String(localized: "motion_cover_error_too_long")
        case .rejected(.tooLarge): String(localized: "motion_cover_error_too_large")
        case .rejected(.unreadable), .failed: String(localized: "motion_cover_error_unreadable")
        }
    }
}

/// 把用户挑的视频或动图规整成动态封面视频（#411）。
///
/// 规整的目标：MP4、只有画面没有声音、画幅 1:1 或 3:4、长边不超过 1080、不超过 60 秒、
/// 帧率不超过 60。App 内的视频封面播放器和系统锁屏都能直接放。已经合格的视频只去掉音轨、
/// 换个封装，不重新编码；其余（横竖不对、太大、HDR、旋转、少见编码）重新编码，动图逐帧编码。
/// 全部在调用方的后台任务里跑，可取消。
enum MotionCoverImporter {
    private static let animationLimits = ArtworkAnimationLimits(
        maximumCompressedBytes: MotionCoverImportLimits.maximumAnimationBytes,
        maximumFrameCount: 6_000,
        // 时长上限交给导入规则判，好告诉用户是「太长」而不是「读不出」。
        maximumDuration: 3_600,
        maximumTotalDecodedPixels: 20_000_000_000
    )

    // MARK: - Entry points

    /// 从文件 App / Finder 选来的文件：先拷进暂存目录（安全作用域只在拷贝时需要），再规整。
    nonisolated static func importPickedFile(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MotionCoverAsset {
        let staged = try copyToStaging(url)
        defer { try? FileManager.default.removeItem(at: staged) }
        return try await importItem(at: staged, progress: progress)
    }

    /// 本地文件：动图走逐帧编码，其余当视频处理。
    nonisolated static func importItem(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MotionCoverAsset {
        if isAnimatedImageFile(url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= MotionCoverImportLimits.maximumAnimationBytes else {
                throw MotionCoverImportError.rejected(.tooLarge)
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try await importAnimation(data: data, progress: progress)
        }
        return try await importVideo(at: url, progress: progress)
    }

    nonisolated static func importAnimation(
        data: Data,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MotionCoverAsset {
        guard data.count <= MotionCoverImportLimits.maximumAnimationBytes else {
            throw MotionCoverImportError.rejected(.tooLarge)
        }
        guard let descriptor = ArtworkImageCompatibility.inspect(data, limits: animationLimits),
              descriptor.isAnimated else {
            throw MotionCoverImportError.rejected(.unreadable)
        }
        let plan = MotionCoverImportPlan.forAnimation(
            pixelWidth: descriptor.pixelWidth,
            pixelHeight: descriptor.pixelHeight,
            duration: descriptor.duration,
            frameCount: descriptor.frameCount
        )
        let aspect: MotionCoverAspect
        let width: Int
        let height: Int
        switch plan {
        case .reject(let reason):
            throw MotionCoverImportError.rejected(reason)
        case .remux:
            throw MotionCoverImportError.failed
        case .transcode(let planAspect, let planWidth, let planHeight, _):
            aspect = planAspect
            width = planWidth
            height = planHeight
        }
        let staged = try makeStagingURL(pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        try await encodeAnimation(
            data: data,
            descriptor: descriptor,
            width: width,
            height: height,
            to: staged,
            progress: { progress($0 * 0.9) }
        )
        let asset = try await install(stagedVideo: staged, aspect: aspect)
        progress(1)
        return asset
    }

    nonisolated static func importVideo(
        at url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MotionCoverAsset {
        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard fileSize <= MotionCoverImportLimits.maximumInputBytes else {
            throw MotionCoverImportError.rejected(.tooLarge)
        }
        let source = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await source.loadTracks(withMediaType: .video)
        } catch {
            throw MotionCoverImportError.rejected(.unreadable)
        }
        guard let track = videoTracks.first else { throw MotionCoverImportError.rejected(.unreadable) }
        let audioTracks = (try? await source.loadTracks(withMediaType: .audio)) ?? []

        let geometry: (CMTimeRange, CGSize, CGAffineTransform)
        let details: (Float, [CMFormatDescription], [AVMediaCharacteristic])
        do {
            geometry = try await track.load(.timeRange, .naturalSize, .preferredTransform)
            details = try await track.load(.nominalFrameRate, .formatDescriptions, .mediaCharacteristics)
        } catch {
            throw MotionCoverImportError.rejected(.unreadable)
        }
        let (timeRange, naturalSize, transform) = geometry
        let (frameRate, formats, characteristics) = details

        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let displaySize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        let traits = MotionCoverVideoTraits(
            duration: timeRange.duration.seconds,
            displayWidth: Double(displaySize.width),
            displayHeight: Double(displaySize.height),
            nominalFrameRate: Double(frameRate),
            hasAudioTrack: !audioTracks.isEmpty,
            hasIdentityTransform: transform.isIdentity,
            codec: codec(of: formats.first),
            isHDR: characteristics.contains(.containsHDRVideo),
            fileSize: fileSize
        )
        let plan = MotionCoverImportPlan.make(for: traits)
        // 超过 60 秒一点点的（容器时长常带几帧零头）精确截到 60 秒。
        let clippedRange = CMTimeRange(
            start: timeRange.start,
            duration: CMTimeMinimum(
                timeRange.duration,
                CMTime(seconds: MotionCoverImportLimits.maximumDuration, preferredTimescale: 600)
            )
        )
        let videoSource = VideoSource(
            track: track,
            timeRange: clippedRange,
            naturalSize: naturalSize,
            transform: transform,
            displaySize: displaySize
        )

        let staged = try makeStagingURL(pathExtension: "mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        let aspect: MotionCoverAspect
        switch plan {
        case .reject(let reason):
            throw MotionCoverImportError.rejected(reason)
        case .remux(let planAspect):
            aspect = planAspect
            do {
                try await export(videoSource, transcode: nil, to: staged, progress: { progress($0 * 0.9) })
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // 个别容器不能原样封装进 MP4，退回重新编码。
                try? FileManager.default.removeItem(at: staged)
                let size = planAspect.renderSize(
                    sourceWidth: Double(displaySize.width),
                    sourceHeight: Double(displaySize.height)
                )
                try await export(
                    videoSource,
                    transcode: TranscodeTarget(
                        renderSize: CGSize(width: size.width, height: size.height),
                        frameRate: MotionCoverImportLimits.transcodedFrameRate
                    ),
                    to: staged,
                    progress: { progress($0 * 0.9) }
                )
            }
        case .transcode(let planAspect, let width, let height, let targetFrameRate):
            aspect = planAspect
            try await export(
                videoSource,
                transcode: TranscodeTarget(
                    renderSize: CGSize(width: width, height: height),
                    frameRate: targetFrameRate
                ),
                to: staged,
                progress: { progress($0 * 0.9) }
            )
        }
        try Task.checkCancellation()
        let asset = try await install(stagedVideo: staged, aspect: aspect)
        progress(1)
        return asset
    }

    // MARK: - Video export

    private struct VideoSource {
        let track: AVAssetTrack
        let timeRange: CMTimeRange
        let naturalSize: CGSize
        let transform: CGAffineTransform
        let displaySize: CGSize
    }

    private struct TranscodeTarget {
        let renderSize: CGSize
        let frameRate: Double
    }

    nonisolated private static func export(
        _ source: VideoSource,
        transcode: TranscodeTarget?,
        to outputURL: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let composition = AVMutableComposition()
        let compositionTrack = try insertVideo(source, into: composition)
        let preset = transcode == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHEVC1920x1080
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            throw MotionCoverImportError.failed
        }
        if let transcode {
            session.videoComposition = makeVideoComposition(
                source,
                track: compositionTrack,
                duration: composition.duration,
                target: transcode
            )
        }
        session.shouldOptimizeForNetworkUse = true
        let states = session.states(updateInterval: 0.25)
        let observer = Task {
            for await state in states {
                if case .exporting(let exportProgress) = state {
                    progress(exportProgress.fractionCompleted)
                }
            }
        }
        defer { observer.cancel() }
        try await session.export(to: outputURL, as: .mp4)
    }

    /// 只放画面轨：音轨不进合成，导出来就没有声音。
    nonisolated private static func insertVideo(
        _ source: VideoSource,
        into composition: AVMutableComposition
    ) throws -> AVMutableCompositionTrack {
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw MotionCoverImportError.failed
        }
        try compositionTrack.insertTimeRange(source.timeRange, of: source.track, at: .zero)
        compositionTrack.preferredTransform = source.transform
        return compositionTrack
    }

    /// 转正方向、按画幅居中裁、缩到目标尺寸，一次做完。
    nonisolated private static func makeVideoComposition(
        _ source: VideoSource,
        track: AVMutableCompositionTrack,
        duration: CMTime,
        target: TranscodeTarget
    ) -> AVVideoComposition {
        let renderSize = target.renderSize
        let rotated = CGRect(origin: .zero, size: source.naturalSize).applying(source.transform)
        var transform = source.transform.concatenating(
            CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY)
        )
        let scale = max(
            renderSize.width / max(1, source.displaySize.width),
            renderSize.height / max(1, source.displaySize.height)
        )
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(
            translationX: (renderSize.width - source.displaySize.width * scale) / 2,
            y: (renderSize.height - source.displaySize.height * scale) / 2
        ))

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        let fps = max(1, min(MotionCoverImportLimits.maximumFrameRate, target.frameRate.rounded()))
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        videoComposition.instructions = [instruction]
        return videoComposition
    }

    nonisolated private static func codec(of description: CMFormatDescription?) -> MotionCoverVideoCodec {
        guard let description else { return .other }
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMVideoCodecType_H264: return .h264
        case kCMVideoCodecType_HEVC: return .hevc
        default: return .other
        }
    }

    // MARK: - Animation encoding

    /// 动图逐帧编码成 H.264 MP4。每帧按原有时长写，所以快慢跟原图一样；超过 60 秒的部分丢掉。
    /// 锁屏把自选 GIF 交给系统时也用这条路。
    nonisolated static func encodeAnimation(
        data: Data,
        descriptor: ArtworkDescriptor,
        width: Int,
        height: Int,
        to outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard width > 0, height > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary) else {
            throw MotionCoverImportError.rejected(.unreadable)
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { throw MotionCoverImportError.rejected(.unreadable) }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitRate = max(1_500_000, width * height * 4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
            ]
        )
        guard writer.canAdd(input) else { throw MotionCoverImportError.failed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MotionCoverImportError.failed }
        writer.startSession(atSourceTime: .zero)

        let decodeEdge = min(2_048, max(descriptor.pixelWidth, descriptor.pixelHeight, max(width, height)))
        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeEdge,
        ] as CFDictionary
        let limit = CMTime(seconds: MotionCoverImportLimits.maximumDuration, preferredTimescale: 600)
        var presentation = CMTime.zero
        var appended = 0
        do {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                guard CMTimeCompare(presentation, limit) < 0 else { break }
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                let wrote = try autoreleasepool { () throws -> Bool in
                    guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions),
                          let pool = adaptor.pixelBufferPool else { return false }
                    var created: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
                          let buffer = created,
                          draw(frame, into: buffer, width: width, height: height) else {
                        throw MotionCoverImportError.failed
                    }
                    guard adaptor.append(buffer, withPresentationTime: presentation) else {
                        throw writer.error ?? MotionCoverImportError.failed
                    }
                    return true
                }
                let delay = index < descriptor.frameDurations.count ? descriptor.frameDurations[index] : 0.1
                if wrote {
                    appended += 1
                    presentation = CMTimeMinimum(
                        limit,
                        CMTimeAdd(presentation, CMTime(seconds: max(delay, 0.02), preferredTimescale: 600))
                    )
                }
                progress?(Double(index + 1) / Double(frameCount))
            }
            guard appended > 1 else { throw MotionCoverImportError.rejected(.unreadable) }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: presentation)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MotionCoverImportError.failed }
    }

    /// 等比铺满再居中裁，透明处垫黑。
    nonisolated private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, width: Int, height: Int) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return false }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(canvas)
        context.interpolationQuality = .high
        let imageWidth = CGFloat(max(1, image.width))
        let imageHeight = CGFloat(max(1, image.height))
        let scale = max(canvas.width / imageWidth, canvas.height / imageHeight)
        let drawSize = CGSize(width: imageWidth * scale, height: imageHeight * scale)
        context.draw(image, in: CGRect(
            x: (canvas.width - drawSize.width) / 2,
            y: (canvas.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        ))
        return true
    }

    // MARK: - Install

    /// 核对导出的视频、截首帧、按内容哈希放进动态封面目录。同一段视频已经在了就复用。
    nonisolated private static func install(
        stagedVideo: URL,
        aspect: MotionCoverAspect
    ) async throws -> MotionCoverAsset {
        let output = AVURLAsset(url: stagedVideo)
        guard let track = try await output.loadTracks(withMediaType: .video).first else {
            throw MotionCoverImportError.failed
        }
        let (range, size) = try await track.load(.timeRange, .naturalSize)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0, size.width > 0, size.height > 0,
              max(size.width, size.height) <= CGFloat(MotionCoverImportLimits.maximumLongEdge) + 0.5 else {
            throw MotionCoverImportError.failed
        }
        try Task.checkCancellation()
        let poster = await posterJPEG(forVideoAt: stagedVideo)
        let contentID = try sha256Hex(ofFileAt: stagedVideo)
        let byteCount = Int64((try? stagedVideo.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let asset = MotionCoverAsset(
            contentID: contentID,
            aspect: aspect,
            pixelWidth: Int(size.width.rounded()),
            pixelHeight: Int(size.height.rounded()),
            duration: duration,
            byteCount: byteCount
        )
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: MotionCoverStore.directoryURL, withIntermediateDirectories: true)
        let destination = MotionCoverStore.videoURL(for: asset)
        if fileManager.fileExists(atPath: destination.path) {
            // 刚用过的不能被「没人用的文件」清理赶在写索引之前删掉。
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
        } else {
            try fileManager.moveItem(at: stagedVideo, to: destination)
        }
        if let poster {
            try? poster.write(to: MotionCoverStore.posterURL(for: asset), options: .atomic)
        }
        return asset
    }

    nonisolated static func posterJPEG(forVideoAt url: URL, maximumPixelSize: CGFloat = 1_080) async -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return jpegData(result.image)
    }

    nonisolated static func jpegData(_ image: CGImage, quality: Double = 0.86) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Files

    nonisolated static func isAnimatedImageFile(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier].contains(type) else {
            return false
        }
        return CGImageSourceGetCount(source) > 1
    }

    nonisolated static func makeStagingURL(pathExtension: String) throws -> URL {
        let directory = MotionCoverStore.stagingDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(pathExtension)
    }

    nonisolated private static func copyToStaging(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(size) <= MotionCoverImportLimits.maximumInputBytes else {
            throw MotionCoverImportError.rejected(.tooLarge)
        }
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let destination = try makeStagingURL(pathExtension: ext)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    nonisolated static func sha256Hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
