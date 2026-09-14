// 实况照片只在 iOS 上提供: macOS 端的歌词海报导出静态图并交给"存储为文件"
// 与系统分享, 不碰相册, 因此整份实况照片管线不进 Mac 二进制。
#if os(iOS)
import Foundation
import AVFoundation
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import Photos
import PrimuseKit

/// 一张实况照片的两半。系统靠写在两个文件里的同一个 asset identifier
/// 把它们配成一张实况照片, 少了任何一半都只会存成普通照片/视频。
struct LyricPosterLivePhotoBundle {
    let stillURL: URL
    let videoURL: URL
    let assetIdentifier: String
}

enum LyricPosterLivePhotoError: LocalizedError {
    case renderFailed
    case videoSetupFailed
    case videoWriteFailed(String)
    case stillWriteFailed

    var errorDescription: String? {
        switch self {
        case .renderFailed:
            return String(localized: "lyric_poster_error_render")
        case .videoSetupFailed, .videoWriteFailed:
            return String(localized: "lyric_poster_error_motion_export")
        case .stillWriteFailed:
            return String(localized: "lyric_poster_error_write_file")
        }
    }
}

/// 逐帧把海报写成实况照片。
///
/// 帧是"拉"过来的, 不是先渲染成数组: 一段 1080×1920 的五秒动画有一百多帧,
/// 全部留在内存里是几百 MB, 手机上必然被系统杀掉。
@MainActor
enum LyricPosterLivePhotoWriter {
    /// 静图那一帧在视频里的停留窗口。太短系统会认不出静帧标记。
    private static let stillImageTimeWindow = CMTime(value: 1, timescale: 10)

    static func write(
        plan: LyricPosterMotionPlan,
        size: CGSize,
        directory: URL,
        baseName: String,
        frame: @MainActor (Int) -> CGImage?,
        onProgress: @MainActor (Double) -> Void = { _ in }
    ) async throws -> LyricPosterLivePhotoBundle {
        let assetIdentifier = UUID().uuidString
        let videoURL = directory.appendingPathComponent("\(baseName).mov")
        let stillURL = directory.appendingPathComponent("\(baseName).jpg")
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: stillURL)

        // 静帧先渲染: 它是实况照片在相册里静止时显示的那一张, 也是导出失败
        // 时唯一还能交付给用户的东西。
        guard let stillImage = frame(plan.stillFrameIndex) else {
            throw LyricPosterLivePhotoError.renderFailed
        }
        try writeStill(stillImage, assetIdentifier: assetIdentifier, to: stillURL)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        } catch {
            throw LyricPosterLivePhotoError.videoWriteFailed(error.localizedDescription)
        }
        writer.metadata = [contentIdentifierItem(assetIdentifier)]

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
            ]
        )
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )

        guard let stillTimeDescription = makeStillImageTimeFormatDescription() else {
            throw LyricPosterLivePhotoError.videoSetupFailed
        }
        let metadataInput = AVAssetWriterInput(
            mediaType: .metadata,
            outputSettings: nil,
            sourceFormatHint: stillTimeDescription
        )
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else {
            throw LyricPosterLivePhotoError.videoSetupFailed
        }
        writer.add(videoInput)
        writer.add(metadataInput)

        guard writer.startWriting() else {
            throw LyricPosterLivePhotoError.videoWriteFailed(
                writer.error?.localizedDescription ?? ""
            )
        }
        writer.startSession(atSourceTime: .zero)

        // 静帧标记必须指向视频里的某个时刻, 否则系统只当成一段普通视频。
        let stillTime = CMTime(
            value: CMTimeValue(plan.stillFrameIndex),
            timescale: CMTimeScale(plan.frameRate)
        )
        metadataAdaptor.append(
            AVTimedMetadataGroup(
                items: [stillImageTimeItem()],
                timeRange: CMTimeRange(start: stillTime, duration: stillImageTimeWindow)
            )
        )
        metadataInput.markAsFinished()

        let frameCount = plan.frameCount
        for index in 0..<frameCount {
            if Task.isCancelled {
                writer.cancelWriting()
                throw CancellationError()
            }
            guard let image = frame(index) else {
                writer.cancelWriting()
                throw LyricPosterLivePhotoError.renderFailed
            }
            while !videoInput.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            guard let buffer = makePixelBuffer(from: image, pool: adaptor.pixelBufferPool, size: size) else {
                writer.cancelWriting()
                throw LyricPosterLivePhotoError.videoSetupFailed
            }
            let presentationTime = CMTime(
                value: CMTimeValue(index),
                timescale: CMTimeScale(plan.frameRate)
            )
            guard adaptor.append(buffer, withPresentationTime: presentationTime) else {
                writer.cancelWriting()
                throw LyricPosterLivePhotoError.videoWriteFailed(
                    writer.error?.localizedDescription ?? ""
                )
            }
            onProgress(Double(index + 1) / Double(frameCount))
            // 渲染在主线程上跑, 不让出的话进度条和取消按钮整段时间都是死的。
            await Task.yield()
        }

        videoInput.markAsFinished()
        await finishWriting(writer)

        guard writer.status == .completed else {
            throw LyricPosterLivePhotoError.videoWriteFailed(
                writer.error?.localizedDescription ?? ""
            )
        }

        return LyricPosterLivePhotoBundle(
            stillURL: stillURL,
            videoURL: videoURL,
            assetIdentifier: assetIdentifier
        )
    }

    // MARK: - 文件写出

    /// 静图必须带上 Apple 私有 maker note 的 17 号键 —— 那就是实况照片的
    /// 配对标识, 普通 JPEG 写出来会丢。
    static func writeStill(
        _ image: CGImage,
        assetIdentifier: String,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw LyricPosterLivePhotoError.stillWriteFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.96,
            kCGImagePropertyMakerAppleDictionary: ["17": assetIdentifier],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LyricPosterLivePhotoError.stillWriteFailed
        }
    }

    private static func contentIdentifierItem(_ identifier: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = AVMetadataKey.quickTimeMetadataKeyContentIdentifier as NSString
        item.keySpace = .quickTimeMetadata
        item.value = identifier as NSString
        return item
    }

    private static func stillImageTimeItem() -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.key = "com.apple.quicktime.still-image-time" as NSString
        item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
        item.value = 0 as NSNumber
        item.dataType = kCMMetadataBaseDataType_SInt8 as String
        return item
    }

    private static func makeStillImageTimeFormatDescription() -> CMFormatDescription? {
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String:
                "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String:
                kCMMetadataBaseDataType_SInt8 as String,
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func makePixelBuffer(
        from image: CGImage,
        pool: CVPixelBufferPool?,
        size: CGSize
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        } else {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferCGImageCompatibilityKey: true,
                    kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                ] as CFDictionary,
                &buffer
            )
        }
        guard let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.draw(
            image,
            in: CGRect(
                x: 0,
                y: 0,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        )
        return pixelBuffer
    }

    private static func finishWriting(_ writer: AVAssetWriter) async {
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}

// MARK: - 相册

enum LyricPosterPhotoLibraryError: LocalizedError {
    case denied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .denied:
            return String(localized: "lyric_poster_error_photos_denied")
        case .saveFailed(let message):
            return message.isEmpty
                ? String(localized: "lyric_poster_error_photos_save")
                : message
        }
    }
}

/// 存相册。只申请"仅添加"权限 —— 分享歌词不需要读用户的照片。
enum LyricPosterPhotoLibrary {
    static func requestAddPermission() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            return granted == .authorized || granted == .limited
        default:
            return false
        }
    }

    static func save(image url: URL) async throws {
        try await requirePermission()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset()
                    .addResource(with: .photo, fileURL: url, options: nil)
            }
        } catch {
            throw LyricPosterPhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }

    /// 两个资源必须写在同一次 performChanges 里 —— 分两次提交会变成
    /// 一张普通照片外加一段视频, 实况照片的配对关系就没了。
    static func save(livePhoto bundle: LyricPosterLivePhotoBundle) async throws {
        try await requirePermission()
        let stillURL = bundle.stillURL
        let videoURL = bundle.videoURL
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = false
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: stillURL, options: options)
                request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
            }
        } catch {
            throw LyricPosterPhotoLibraryError.saveFailed(error.localizedDescription)
        }
    }

    private static func requirePermission() async throws {
        guard await requestAddPermission() else {
            throw LyricPosterPhotoLibraryError.denied
        }
    }
}
#endif
