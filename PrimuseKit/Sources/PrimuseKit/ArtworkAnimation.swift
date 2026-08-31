import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ArtworkPresentationRole: String, Codable, Equatable, Sendable {
    case staticFirstFrame
    case animatedHero
}

/// Stable identity for static artwork memory entries and shared source fetches.
/// Every source-defining field participates so a replacement cover for the
/// same song cannot reuse an older decoded image or in-flight request.
public enum ArtworkSourceRequestIdentity {
    public static func key(
        songID: String?,
        artworkReference: String?,
        sourceID: String?,
        filePath: String?,
        fileFormat: String?,
        revision: String
    ) -> String? {
        let values = [
            songID ?? "",
            artworkReference ?? "",
            sourceID ?? "",
            filePath ?? "",
            fileFormat ?? "",
            revision,
        ]
        guard values.dropLast().contains(where: { !$0.isEmpty }) else { return nil }
        return values.map { value in
            "\(value.utf8.count):\(value)"
        }.joined(separator: "|")
    }
}

public enum ArtworkContainerFormat: String, Codable, Equatable, Sendable {
    case jpeg
    case png
    case gif
    case webP
    case other

    public var supportsFrameAnimation: Bool {
        switch self {
        case .png, .gif, .webP:
            true
        case .jpeg, .other:
            false
        }
    }
}

public struct ArtworkAnimationLimits: Equatable, Sendable {
    public var maximumCompressedBytes: Int
    public var maximumDimension: Int
    public var maximumFrameCount: Int
    public var maximumDuration: TimeInterval
    public var maximumTotalDecodedPixels: Int64
    public var minimumFrameDuration: TimeInterval
    public var maximumFrameDuration: TimeInterval

    public init(
        maximumCompressedBytes: Int = 32 * 1024 * 1024,
        maximumDimension: Int = 4_096,
        maximumFrameCount: Int = 600,
        maximumDuration: TimeInterval = 60,
        maximumTotalDecodedPixels: Int64 = 600_000_000,
        minimumFrameDuration: TimeInterval = 1.0 / 60.0,
        maximumFrameDuration: TimeInterval = 10
    ) {
        self.maximumCompressedBytes = maximumCompressedBytes
        self.maximumDimension = maximumDimension
        self.maximumFrameCount = maximumFrameCount
        self.maximumDuration = maximumDuration
        self.maximumTotalDecodedPixels = maximumTotalDecodedPixels
        self.minimumFrameDuration = minimumFrameDuration
        self.maximumFrameDuration = maximumFrameDuration
    }

    public static let `default` = ArtworkAnimationLimits()
}

public struct ArtworkDescriptor: Codable, Equatable, Sendable {
    public let typeIdentifier: String
    public let format: ArtworkContainerFormat
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let frameDurations: [TimeInterval]
    public let loopCount: Int?

    public init(
        typeIdentifier: String,
        format: ArtworkContainerFormat,
        pixelWidth: Int,
        pixelHeight: Int,
        frameDurations: [TimeInterval],
        loopCount: Int?
    ) {
        self.typeIdentifier = typeIdentifier
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameDurations = frameDurations
        self.loopCount = loopCount
    }

    public var frameCount: Int {
        max(1, frameDurations.count)
    }

    public var duration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    public var isAnimated: Bool {
        format.supportsFrameAnimation && frameDurations.count > 1
    }

    /// Normalized total playback count. GIF stores an additional-repeat
    /// count, whereas APNG and animated WebP store total plays; callers should
    /// not interpret the raw container value directly.
    public var playbackCount: ArtworkPlaybackCount {
        guard let loopCount else { return .finite(1) }
        guard loopCount > 0 else { return .infinite }
        switch format {
        case .gif:
            return .finite(loopCount == .max ? .max : loopCount + 1)
        case .png, .webP:
            return .finite(loopCount)
        case .jpeg, .other:
            return .finite(1)
        }
    }
}

public enum ArtworkPlaybackCount: Codable, Equatable, Sendable {
    case finite(Int)
    case infinite
}

public enum ArtworkThermalCondition: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    public var permitsAnimation: Bool {
        self == .nominal || self == .fair
    }
}

public struct ArtworkAnimationPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let presentationRole: ArtworkPresentationRole
    public let isVisible: Bool
    public let isSceneActive: Bool
    public let requiresPlayback: Bool
    public let isPlaying: Bool
    public let reduceMotion: Bool
    public let playAnimatedImages: Bool
    public let isLowPowerModeEnabled: Bool
    public let thermalCondition: ArtworkThermalCondition

    public init(
        isEnabled: Bool,
        presentationRole: ArtworkPresentationRole,
        isVisible: Bool,
        isSceneActive: Bool,
        requiresPlayback: Bool,
        isPlaying: Bool,
        reduceMotion: Bool,
        playAnimatedImages: Bool,
        isLowPowerModeEnabled: Bool,
        thermalCondition: ArtworkThermalCondition
    ) {
        self.isEnabled = isEnabled
        self.presentationRole = presentationRole
        self.isVisible = isVisible
        self.isSceneActive = isSceneActive
        self.requiresPlayback = requiresPlayback
        self.isPlaying = isPlaying
        self.reduceMotion = reduceMotion
        self.playAnimatedImages = playAnimatedImages
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalCondition = thermalCondition
    }

    public var shouldAnimate: Bool {
        isEnabled
            && presentationRole == .animatedHero
            && isVisible
            && isSceneActive
            && (!requiresPlayback || isPlaying)
            && !reduceMotion
            && playAnimatedImages
            && !isLowPowerModeEnabled
            && thermalCondition.permitsAnimation
    }
}

public struct ArtworkAnimationFetchPolicy: Equatable, Sendable {
    public let isEnabled: Bool
    public let presentationRole: ArtworkPresentationRole
    public let isVisible: Bool
    public let isReachable: Bool
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let isOnUnmeteredNetwork: Bool
    public let unmeteredOnly: Bool
    public let isLowPowerModeEnabled: Bool
    public let thermalCondition: ArtworkThermalCondition

    public init(
        isEnabled: Bool,
        presentationRole: ArtworkPresentationRole,
        isVisible: Bool,
        isReachable: Bool,
        isExpensive: Bool,
        isConstrained: Bool,
        isOnUnmeteredNetwork: Bool,
        unmeteredOnly: Bool,
        isLowPowerModeEnabled: Bool,
        thermalCondition: ArtworkThermalCondition
    ) {
        self.isEnabled = isEnabled
        self.presentationRole = presentationRole
        self.isVisible = isVisible
        self.isReachable = isReachable
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isOnUnmeteredNetwork = isOnUnmeteredNetwork
        self.unmeteredOnly = unmeteredOnly
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.thermalCondition = thermalCondition
    }

    public var shouldFetchRemoteAnimation: Bool {
        isEnabled
            && presentationRole == .animatedHero
            && isVisible
            && isReachable
            && !isConstrained
            && !isLowPowerModeEnabled
            && thermalCondition.permitsAnimation
            && (!unmeteredOnly || (isOnUnmeteredNetwork && !isExpensive))
    }
}

public extension ArtworkImageCompatibility {
    static func inspect(
        _ data: Data,
        limits: ArtworkAnimationLimits = .default
    ) -> ArtworkDescriptor? {
        guard !currentTaskIsCancelled(),
              !data.isEmpty,
              data.count <= limits.maximumCompressedBytes,
              isCompleteImage(data),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String? else {
            return nil
        }

        let format = containerFormat(for: type)
        let sourceFrameCount = CGImageSourceGetCount(source)
        guard sourceFrameCount > 0,
              sourceFrameCount <= limits.maximumFrameCount,
              let firstProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil),
              let firstSize = pixelSize(from: firstProperties),
              firstSize.width > 0,
              firstSize.height > 0,
              firstSize.width <= limits.maximumDimension,
              firstSize.height <= limits.maximumDimension else {
            return nil
        }

        if sourceFrameCount == 1 || !format.supportsFrameAnimation {
            return ArtworkDescriptor(
                typeIdentifier: type,
                format: format,
                pixelWidth: firstSize.width,
                pixelHeight: firstSize.height,
                frameDurations: [],
                loopCount: nil
            )
        }

        var frameDurations: [TimeInterval] = []
        frameDurations.reserveCapacity(sourceFrameCount)
        var totalDecodedPixels: Int64 = 0
        var totalDuration: TimeInterval = 0
        let probeOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
        ]

        for index in 0..<sourceFrameCount {
            guard !currentTaskIsCancelled(),
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil),
                  let size = pixelSize(from: properties),
                  size.width > 0,
                  size.height > 0,
                  size.width <= limits.maximumDimension,
                  size.height <= limits.maximumDimension,
                  CGImageSourceCreateThumbnailAtIndex(
                    source,
                    index,
                    probeOptions as CFDictionary
                  ) != nil else {
                return nil
            }

            let (framePixels, overflow) = Int64(size.width).multipliedReportingOverflow(
                by: Int64(size.height)
            )
            guard !overflow else { return nil }
            let (newTotalPixels, totalOverflow) = totalDecodedPixels.addingReportingOverflow(framePixels)
            guard !totalOverflow, newTotalPixels <= limits.maximumTotalDecodedPixels else {
                return nil
            }
            totalDecodedPixels = newTotalPixels

            let duration = normalizedFrameDuration(
                from: properties,
                format: format,
                limits: limits
            )
            totalDuration += duration
            guard totalDuration.isFinite, totalDuration <= limits.maximumDuration else {
                return nil
            }
            frameDurations.append(duration)
        }

        let globalProperties = CGImageSourceCopyProperties(source, nil)
        return ArtworkDescriptor(
            typeIdentifier: type,
            format: format,
            pixelWidth: firstSize.width,
            pixelHeight: firstSize.height,
            frameDurations: frameDurations,
            loopCount: loopCount(from: globalProperties, format: format)
        )
    }

    /// Produces a bounded, single-frame mirror for list and grid caches.
    /// Animated originals belong in the animation cache; persisting them as a
    /// normal cover would make every static surface read the whole container.
    static func staticFirstFrameJPEG(
        from data: Data,
        maximumPixelSize: Int = 1_536,
        compressionQuality: Double = 0.86
    ) -> Data? {
        guard !currentTaskIsCancelled(),
              maximumPixelSize > 0,
              compressionQuality.isFinite,
              (0...1).contains(compressionQuality),
              isCompleteImage(data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
              ] as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private static func containerFormat(for typeIdentifier: String) -> ArtworkContainerFormat {
        guard let type = UTType(typeIdentifier) else { return .other }
        if type.conforms(to: .gif) { return .gif }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .webP) { return .webP }
        if type.conforms(to: .jpeg) { return .jpeg }
        return .other
    }

    private static func pixelSize(from properties: CFDictionary) -> (width: Int, height: Int)? {
        let dictionary = properties as NSDictionary
        guard let width = (dictionary[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (dictionary[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            return nil
        }
        return (width, height)
    }

    private static func normalizedFrameDuration(
        from properties: CFDictionary,
        format: ArtworkContainerFormat,
        limits: ArtworkAnimationLimits
    ) -> TimeInterval {
        let dictionary = properties as NSDictionary
        let metadata: NSDictionary?
        let unclampedKey: CFString?
        let delayKey: CFString?
        switch format {
        case .gif:
            metadata = dictionary[kCGImagePropertyGIFDictionary] as? NSDictionary
            unclampedKey = kCGImagePropertyGIFUnclampedDelayTime
            delayKey = kCGImagePropertyGIFDelayTime
        case .png:
            metadata = dictionary[kCGImagePropertyPNGDictionary] as? NSDictionary
            unclampedKey = kCGImagePropertyAPNGUnclampedDelayTime
            delayKey = kCGImagePropertyAPNGDelayTime
        case .webP:
            metadata = dictionary[kCGImagePropertyWebPDictionary] as? NSDictionary
            unclampedKey = kCGImagePropertyWebPUnclampedDelayTime
            delayKey = kCGImagePropertyWebPDelayTime
        case .jpeg, .other:
            metadata = nil
            unclampedKey = nil
            delayKey = nil
        }

        let unclamped = unclampedKey.flatMap { metadata?[$0] as? NSNumber }?.doubleValue
        let delay = delayKey.flatMap { metadata?[$0] as? NSNumber }?.doubleValue
        let raw = [unclamped, delay]
            .compactMap { $0 }
            .first(where: { $0.isFinite && $0 > 0 })
            ?? 0.1
        return min(max(raw, limits.minimumFrameDuration), limits.maximumFrameDuration)
    }

    private static func loopCount(
        from properties: CFDictionary?,
        format: ArtworkContainerFormat
    ) -> Int? {
        guard let properties else { return nil }
        let dictionary = properties as NSDictionary
        let metadata: NSDictionary?
        let key: CFString?
        switch format {
        case .gif:
            metadata = dictionary[kCGImagePropertyGIFDictionary] as? NSDictionary
            key = kCGImagePropertyGIFLoopCount
        case .png:
            metadata = dictionary[kCGImagePropertyPNGDictionary] as? NSDictionary
            key = kCGImagePropertyAPNGLoopCount
        case .webP:
            metadata = dictionary[kCGImagePropertyWebPDictionary] as? NSDictionary
            key = kCGImagePropertyWebPLoopCount
        case .jpeg, .other:
            metadata = nil
            key = nil
        }
        return key.flatMap { metadata?[$0] as? NSNumber }?.intValue
    }
}
