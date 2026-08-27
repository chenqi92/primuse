import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit
import SwiftUI

nonisolated(unsafe) private let animatedArtworkFrameCache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 32
    cache.totalCostLimit = 48 * 1024 * 1024
    return cache
}()

/// Plays one validated ImageIO animation without retaining every decoded frame.
/// The caller remains responsible for the static first-frame fallback, which is
/// also what lists, paused/inactive scenes, and constrained devices display.
struct AnimatedArtworkDataView<Fallback: View>: View {
    let data: Data
    let descriptor: ArtworkDescriptor
    let cacheKey: String
    let presentationRole: ArtworkPresentationRole
    let isVisible: Bool
    let requiresPlayback: Bool
    let isPlaying: Bool
    let maximumPixelSize: Int
    @ViewBuilder let fallback: () -> Fallback

    @AppStorage(PlayerAppearancePreferences.animatedArtworkEnabledKey)
    private var isEnabled = PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @State private var frame: CGImage?
    @State private var runtimeRevision = 0

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                fallback()
            }
        }
        .task(id: activityIdentity) {
            await playFramesIfAllowed()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: Notification.Name.NSProcessInfoPowerStateDidChange
        )) { _ in
            runtimeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(
            for: ProcessInfo.thermalStateDidChangeNotification
        )) { _ in
            runtimeRevision &+= 1
        }
        .onDisappear {
            frame = nil
        }
    }

    private var policy: ArtworkAnimationPolicy {
        ArtworkAnimationPolicy(
            isEnabled: isEnabled,
            presentationRole: presentationRole,
            isVisible: isVisible,
            isSceneActive: scenePhase == .active,
            requiresPlayback: requiresPlayback,
            isPlaying: isPlaying,
            reduceMotion: reduceMotion,
            playAnimatedImages: playAnimatedImages,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalCondition: Self.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }

    private var activityIdentity: String {
        [
            cacheKey,
            String(descriptor.frameCount),
            String(policy.shouldAnimate),
            String(maximumPixelSize),
            String(runtimeRevision),
        ].joined(separator: "|")
    }

    @MainActor
    private func playFramesIfAllowed() async {
        frame = nil
        guard descriptor.isAnimated, policy.shouldAnimate else { return }

        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), CGImageSourceGetCount(source) == descriptor.frameCount else {
            return
        }

        let totalPasses: Int?
        if let loopCount = descriptor.loopCount, loopCount > 0 {
            totalPasses = loopCount + 1
        } else if descriptor.loopCount == nil {
            totalPasses = 1
        } else {
            totalPasses = nil
        }

        var pass = 0
        while totalPasses.map({ pass < $0 }) ?? true {
            for index in 0..<descriptor.frameCount {
                guard !Task.isCancelled, policy.shouldAnimate else {
                    frame = nil
                    return
                }
                let decoded = await Self.decodedFrame(
                    data: data,
                    index: index,
                    cacheKey: cacheKey,
                    maximumPixelSize: maximumPixelSize
                )
                guard !Task.isCancelled, policy.shouldAnimate, let decoded else {
                    frame = nil
                    return
                }
                frame = decoded
                let duration = descriptor.frameDurations[index]
                try? await Task.sleep(for: .seconds(duration))
            }
            pass += 1
        }
        frame = nil
    }

    private nonisolated static func decodedFrame(
        data: Data,
        index: Int,
        cacheKey: String,
        maximumPixelSize: Int
    ) async -> CGImage? {
        let key = "\(cacheKey)|\(maximumPixelSize)|\(index)" as NSString
        if let cached = animatedArtworkFrameCache.object(forKey: key) { return cached }
        let decoded: CGImage? = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
            ] as CFDictionary)
        }.value
        if let decoded {
            animatedArtworkFrameCache.setObject(
                decoded,
                forKey: key,
                cost: decoded.bytesPerRow * decoded.height
            )
        }
        return decoded
    }

    private nonisolated static func thermalCondition(
        _ state: ProcessInfo.ThermalState
    ) -> ArtworkThermalCondition {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .critical
        }
    }
}
