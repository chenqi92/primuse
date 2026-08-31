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
        switch descriptor.playbackCount {
        case .finite(let count): totalPasses = max(1, count)
        case .infinite: totalPasses = nil
        }

        var pass = 0
        let clock = ContinuousClock()
        var deadline = clock.now
        let resynchronizationThreshold = max(
            Duration.seconds(descriptor.duration),
            Duration.milliseconds(250)
        )
        while totalPasses.map({ pass < $0 }) ?? true {
            for index in 0..<descriptor.frameCount {
                guard !Task.isCancelled, policy.shouldAnimate else {
                    frame = nil
                    return
                }
                deadline = deadline.advanced(
                    by: .seconds(descriptor.frameDurations[index])
                )
                // A slow decode or a background scheduling gap must not queue
                // stale frames. Skip overdue work and keep the timeline tied
                // to the monotonic clock.
                guard clock.now < deadline else { continue }
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
                guard clock.now < deadline else { continue }
                frame = decoded
                try? await clock.sleep(until: deadline)
            }
            pass += 1
            let now = clock.now
            if now > deadline.advanced(by: resynchronizationThreshold) {
                // Preserve the absolute timeline across timely passes. Only a
                // substantial scheduler gap starts a fresh timeline, bounding
                // catch-up work without accumulating ordinary wake-up jitter.
                deadline = now
            }
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
        let decoding = Task.detached(priority: .utility) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else { return nil }
            let image = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize),
            ] as CFDictionary)
            return Task.isCancelled ? nil : image
        }
        let decoded: CGImage? = await withTaskCancellationHandler {
            await decoding.value
        } onCancel: {
            decoding.cancel()
        }
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
