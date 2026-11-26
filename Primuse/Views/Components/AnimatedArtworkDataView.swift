import CoreGraphics
import AVFoundation
import Foundation
import ImageIO
import PrimuseKit
import SwiftUI

private struct UploadedArtworkAnimationRequest: Hashable, Sendable {
    let contentID: String?
    let previewData: Data?
    let enabled: Bool
}

private struct UploadedArtworkAnimationResource: Sendable {
    let request: UploadedArtworkAnimationRequest
    let data: Data
    let descriptor: ArtworkDescriptor

    nonisolated static func load(_ request: UploadedArtworkAnimationRequest) async -> Self? {
        let worker = Task.detached(priority: .utility) { () -> Self? in
            guard let data = request.previewData ?? request.contentID.flatMap({
                MetadataAssetStore.shared.customArtworkData(contentID: $0)
            }), let descriptor = ArtworkImageCompatibility.inspect(data), descriptor.isAnimated else { return nil }
            return Self(request: request, data: data, descriptor: descriptor)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

/// The poster remains independent of the animation so scrolling, background
/// color extraction and accessibility fallbacks never need all GIF frames.
struct UploadedArtworkAnimation<Fallback: View>: View {
    var contentID: String? = nil
    var previewData: Data? = nil
    var presentationRole: ArtworkPresentationRole = .staticFirstFrame
    var isVisible = true
    var requiresPlayback = false
    var isPlaying = true
    var maximumPixelSize = 1200
    @ViewBuilder var fallback: () -> Fallback

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @State private var animation: UploadedArtworkAnimationResource?

    private var request: UploadedArtworkAnimationRequest {
        UploadedArtworkAnimationRequest(contentID: contentID, previewData: previewData, enabled:
            presentationRole == .animatedHero && isVisible && scenePhase == .active
            && AnimatedArtworkPreferences.shared.animatedArtworkEnabled
            && !reduceMotion && playAnimatedImages)
    }

    var body: some View {
        let request = request
        Group {
            if let animation, animation.request == request {
                AnimatedArtworkDataView(
                    data: animation.data, descriptor: animation.descriptor,
                    cacheKey: contentID ?? "upload-preview-\(animation.data.hashValue)",
                    presentationRole: presentationRole, isVisible: isVisible,
                    requiresPlayback: requiresPlayback, isPlaying: isPlaying,
                    maximumPixelSize: maximumPixelSize, fallback: fallback
                )
            } else {
                fallback()
            }
        }
        .task(id: request) {
            animation = nil
            guard request.enabled else { return }
            let loaded = await UploadedArtworkAnimationResource.load(request)
            guard !Task.isCancelled, self.request == request else { return }
            animation = loaded
        }
        .onDisappear { animation = nil }
    }
}

struct MotionArtworkVideoView<Fallback: View>: View {
    let url: URL
    let displayMode: ArtworkAnimationDisplayMode
    /// 视频首帧截图（本地设置的动态封面优先读现成 `.jpg`，缺省或在线视频会按需从首帧提取并缓存）。
    var posterURL: URL? = nil
    @ViewBuilder let fallback: () -> Fallback
    @State private var playback: MotionArtworkVideoPlayback?
    @State private var playbackURL: URL?
    @State private var isVideoReady = false
    @State private var poster: CGImage?
    @State private var posterSourcePath: String?

    init(
        url: URL,
        displayMode: ArtworkAnimationDisplayMode,
        posterURL: URL? = nil,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) {
        self.url = url
        self.displayMode = displayMode
        self.posterURL = posterURL
        self.fallback = fallback
    }

    init(
        url: URL,
        shouldAnimate: Bool,
        posterURL: URL? = nil,
        @ViewBuilder fallback: @escaping () -> Fallback
    ) {
        self.init(
            url: url,
            displayMode: shouldAnimate ? .playing : .stopped,
            posterURL: posterURL,
            fallback: fallback
        )
    }

    private var showsVideoLayer: Bool {
        displayMode == .playing || displayMode == .pausedOnCurrentFrame
    }

    private var posterTaskIdentity: String {
        guard displayMode.preservesDynamicArtwork else { return "" }
        return "\(url.path)|\(posterURL?.path ?? "")"
    }

    private var playbackTaskIdentity: String {
        "\(url.path)|\(displayMode)"
    }

    var body: some View {
        fallback()
            .overlay {
                if let poster, !(isVideoReady && playback != nil && showsVideoLayer) {
                    Color.clear
                        .overlay {
                            Image(decorative: poster, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .clipped()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if showsVideoLayer, let playback {
                    MotionArtworkVideoLayer(playback: playback) { ready in
                        isVideoReady = ready
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: posterTaskIdentity) {
                guard displayMode.preservesDynamicArtwork else {
                    poster = nil
                    posterSourcePath = nil
                    return
                }
                if posterSourcePath == url.path, poster != nil { return }
                let decoded = await MotionArtworkPosterLoader.load(posterURL: posterURL, videoURL: url)
                guard !Task.isCancelled else { return }
                poster = decoded
                posterSourcePath = decoded == nil ? nil : url.path
            }
            .task(id: playbackTaskIdentity) {
                if playbackURL != url {
                    playback?.stop()
                    playback = nil
                    playbackURL = nil
                    isVideoReady = false
                }
                switch displayMode {
                case .stopped, .stillFrame:
                    playback?.stop()
                    playback = nil
                    playbackURL = nil
                    isVideoReady = false
                case .pausedOnCurrentFrame:
                    playback?.pause()
                case .playing:
                    if let playback, playbackURL == url {
                        playback.play()
                        return
                    }
                    do {
                        let prepared = try await MotionArtworkVideoPlayback.prepare(url: url)
                        guard !Task.isCancelled else { prepared.stop(); return }
                        playback = prepared
                        playbackURL = url
                        if #available(tvOS 17.4, *) {
                            isVideoReady = prepared.videoLayer.isReadyForDisplay
                        } else {
                            isVideoReady = true
                        }
                        prepared.play()
                    } catch {
                        // The static cover (or the poster frame) remains visible if the rendition cannot be decoded.
                        plog("🎞️ motion artwork video failed to prepare file=\(url.lastPathComponent) error=\(error)")
                    }
                }
            }
            .onDisappear {
                playback?.stop()
                playback = nil
                playbackURL = nil
                isVideoReady = false
                poster = nil
                posterSourcePath = nil
            }
    }
}

@MainActor
final class MotionArtworkVideoPlayback {
    let videoLayer: AVSampleBufferDisplayLayer
    private let feed: MotionArtworkVideoFeed

    private init(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) {
        videoLayer = AVSampleBufferDisplayLayer()
        videoLayer.videoGravity = .resizeAspectFill
        feed = MotionArtworkVideoFeed(
            renderer: videoLayer.sampleBufferRenderer,
            frames: MotionArtworkVideoFrames(asset: asset, track: track, range: range)
        )
    }

    static func prepare(url: URL) async throws -> MotionArtworkVideoPlayback {
        guard url.isFileURL else { throw URLError(.unsupportedURL) }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetOverrideMIMETypeKey: "video/mp4",
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            AVURLAssetAllowsCellularAccessKey: false,
            AVURLAssetAllowsExpensiveNetworkAccessKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: false,
        ])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw URLError(.cannotDecodeContentData)
        }
        let (range, size) = try await track.load(.timeRange, .naturalSize)
        guard range.duration.seconds.isFinite, range.duration.seconds > 0, range.duration.seconds <= 60,
              size.width > 0, size.height > 0, max(size.width, size.height) <= 1080 else {
            throw URLError(.cannotDecodeContentData)
        }
        try Task.checkCancellation()
        return MotionArtworkVideoPlayback(asset: asset, track: track, range: range)
    }

    func play() { feed.play() }
    func pause() { feed.pause() }
    func stop() { feed.stop() }
    deinit { feed.stop() }
}

/// Reads only the video track. AVPlayer can activate the app's audio session
/// even when muted, so decorative artwork must never create an AVPlayer.
/// This reader and its loop state are confined to the feed's serial queue.
final class MotionArtworkVideoFrames {
    private let asset: AVAsset
    private let track: AVAssetTrack
    private let range: CMTimeRange
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var loopStart = CMTime.zero
    private var sourceOrigin = CMTime.invalid
    private var loopDuration = CMTime.zero
    private var samplesInLoop = 0

    init(asset: AVAsset, track: AVAssetTrack, range: CMTimeRange) {
        self.asset = asset
        self.track = track
        self.range = range
    }

    func next() throws -> CMSampleBuffer {
        if reader == nil { try beginLoop() }
        if let sample = copyNextVideoSample() { return try retimed(sample) }
        guard reader?.status == .completed, samplesInLoop > 0, loopDuration.seconds > 0 else {
            throw reader?.error ?? URLError(.cannotDecodeContentData)
        }
        loopStart = CMTimeAdd(loopStart, loopDuration)
        try beginLoop()
        guard let sample = copyNextVideoSample() else {
            throw reader?.error ?? URLError(.cannotDecodeContentData)
        }
        return try retimed(sample)
    }

    private func copyNextVideoSample() -> CMSampleBuffer? {
        while let sample = output?.copyNextSampleBuffer() {
            // Fragmented MP4 can include empty edit/end markers without timing.
            if CMSampleBufferGetNumSamples(sample) > 0 { return sample }
        }
        return nil
    }

    func cancel() {
        reader?.cancelReading()
        output = nil
        reader = nil
    }

    func reset() {
        cancel()
        loopStart = .zero
        sourceOrigin = .invalid
        loopDuration = .zero
        samplesInLoop = 0
    }

    private func beginLoop() throws {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw URLError(.cannotDecodeContentData) }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? URLError(.cannotDecodeContentData) }
        self.reader = reader
        self.output = output
        samplesInLoop = 0
        sourceOrigin = .invalid
        loopDuration = .zero
    }

    private func retimed(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { throw URLError(.cannotDecodeContentData) }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil) == noErr else {
            throw URLError(.cannotDecodeContentData)
        }
        if !sourceOrigin.isValid { sourceOrigin = timings[0].presentationTimeStamp }
        guard sourceOrigin.isNumeric else { throw URLError(.cannotDecodeContentData) }
        let offset = CMTimeSubtract(loopStart, sourceOrigin)
        for index in timings.indices {
            let timing = timings[index]
            guard timing.presentationTimeStamp.isNumeric, timing.duration.isNumeric,
                  timing.duration.seconds > 0 else { throw URLError(.cannotDecodeContentData) }
            let end = CMTimeSubtract(CMTimeAdd(timing.presentationTimeStamp, timing.duration), sourceOrigin)
            guard end.seconds.isFinite, end.seconds <= 60 else { throw URLError(.cannotDecodeContentData) }
            loopDuration = CMTimeMaximum(loopDuration, end)
            timings[index].presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, offset)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
            }
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: timings.count, sampleTimingArray: &timings,
            sampleBufferOut: &result
        ) == noErr, let result else { throw URLError(.cannotDecodeContentData) }
        samplesInLoop += 1
        return result
    }
}

/// All reader, renderer and clock operations run on one queue. Only a video
/// renderer is attached: this clock cannot acquire or interrupt audio playback.
private final class MotionArtworkVideoFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.primuse.motion-artwork", qos: .userInitiated)
    private let renderer: AVSampleBufferVideoRenderer
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let frames: MotionArtworkVideoFrames
    private var started = false
    private var paused = false
    private var stopped = false

    init(renderer: AVSampleBufferVideoRenderer, frames: MotionArtworkVideoFrames) {
        self.renderer = renderer
        self.frames = frames
    }

    func play() {
        queue.async { [self] in
            guard !stopped else { return }
            if !started {
                started = true
                paused = false
                synchronizer.addRenderer(renderer)
                renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.enqueueFrames() }
                synchronizer.setRate(1, time: .zero)
                return
            }
            guard paused else { return }
            paused = false
            if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                renderer.flush(removingDisplayedImage: false)
                frames.reset()
                renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.enqueueFrames() }
                synchronizer.setRate(1, time: .zero)
                return
            }
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.enqueueFrames() }
            synchronizer.setRate(1, time: .invalid)
        }
    }

    func pause() {
        queue.async { [self] in
            guard started, !stopped, !paused else { return }
            paused = true
            renderer.stopRequestingMediaData()
            synchronizer.setRate(0, time: .invalid)
        }
    }

    func stop() {
        queue.async { [self] in finish() }
    }

    private func enqueueFrames() {
        do {
            while !stopped, !paused, renderer.isReadyForMoreMediaData {
                guard renderer.status != .failed else { finish(); return }
                renderer.enqueue(try frames.next())
            }
        } catch { finish() }
    }

    private func finish() {
        guard !stopped else { return }
        stopped = true
        paused = false
        renderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: .invalid)
        frames.cancel()
        renderer.flush(removingDisplayedImage: true)
    }
}

#if os(macOS)
private struct MotionArtworkVideoLayer: NSViewRepresentable {
    let playback: MotionArtworkVideoPlayback
    let onReadyChange: (Bool) -> Void
    func makeNSView(context: Context) -> MotionArtworkVideoSurface { MotionArtworkVideoSurface() }
    func updateNSView(_ view: MotionArtworkVideoSurface, context: Context) {
        view.setPlayback(playback, onReadyChange: onReadyChange)
    }
    static func dismantleNSView(_ view: MotionArtworkVideoSurface, coordinator: ()) {
        view.setPlayback(nil, onReadyChange: nil)
    }
}
private typealias MotionArtworkVideoSurfaceBase = NSView
#else
private struct MotionArtworkVideoLayer: UIViewRepresentable {
    let playback: MotionArtworkVideoPlayback
    let onReadyChange: (Bool) -> Void
    func makeUIView(context: Context) -> MotionArtworkVideoSurface { MotionArtworkVideoSurface() }
    func updateUIView(_ view: MotionArtworkVideoSurface, context: Context) {
        view.setPlayback(playback, onReadyChange: onReadyChange)
    }
    static func dismantleUIView(_ view: MotionArtworkVideoSurface, coordinator: ()) {
        view.setPlayback(nil, onReadyChange: nil)
    }
}
private typealias MotionArtworkVideoSurfaceBase = UIView
#endif

private final class MotionArtworkVideoSurface: MotionArtworkVideoSurfaceBase {
    private var videoLayer: AVSampleBufferDisplayLayer?
    private var readiness: MotionArtworkReadinessObservation?
    private var onReadyChange: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        #if os(macOS)
        wantsLayer = true
        #else
        backgroundColor = .clear
        isOpaque = false
        #endif
    }

    required init?(coder: NSCoder) { nil }

    func setPlayback(_ playback: MotionArtworkVideoPlayback?, onReadyChange: ((Bool) -> Void)?) {
        self.onReadyChange = onReadyChange
        guard videoLayer !== playback?.videoLayer else { return }
        readiness = nil
        videoLayer?.removeFromSuperlayer()
        videoLayer = playback?.videoLayer
        guard let videoLayer else { return }
        videoLayer.isHidden = true
        #if os(macOS)
        layer?.addSublayer(videoLayer)
        #else
        layer.addSublayer(videoLayer)
        #endif
        layoutVideo()
        if #available(tvOS 17.4, *) {
            readiness = MotionArtworkReadinessObservation(layer: videoLayer) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let videoLayer = self.videoLayer else { return }
                    let ready = videoLayer.isReadyForDisplay
                    videoLayer.isHidden = !ready
                    self.onReadyChange?(ready)
                }
            }
            let ready = videoLayer.isReadyForDisplay
            videoLayer.isHidden = !ready
            if ready {
                Task { @MainActor [weak self] in
                    guard let self, self.videoLayer === videoLayer else { return }
                    self.onReadyChange?(true)
                }
            }
        } else {
            videoLayer.isHidden = false
            Task { @MainActor [weak self] in
                guard let self, self.videoLayer === videoLayer else { return }
                self.onReadyChange?(true)
            }
        }
    }

    #if os(macOS)
    override func layout() { super.layout(); layoutVideo() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutVideo() }
    #endif

    private func layoutVideo() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }
}


private final class MotionArtworkReadinessObservation {
    private let token: NSObjectProtocol

    @available(tvOS 17.4, *)
    init(layer: AVSampleBufferDisplayLayer, onChange: @escaping @Sendable () -> Void) {
        // Sample-buffer readiness uses notifications, unlike AVPlayerLayer's KVO.
        token = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVSampleBufferDisplayLayerReadyForDisplayDidChange,
            object: layer, queue: .main
        ) { _ in onChange() }
    }

    deinit { NotificationCenter.default.removeObserver(token) }
}

nonisolated(unsafe) private let motionArtworkPosterCache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 8
    cache.totalCostLimit = 24 * 1024 * 1024
    return cache
}()

private enum MotionArtworkPosterLoader {
    nonisolated static func load(posterURL: URL?, videoURL: URL) async -> CGImage? {
        let key = (posterURL?.path ?? videoURL.path) as NSString
        if let cached = motionArtworkPosterCache.object(forKey: key) {
            return cached
        }
        let worker = Task.detached(priority: .utility) { () -> CGImage? in
            if let posterURL,
               let source = CGImageSourceCreateWithURL(posterURL as CFURL, [
                kCGImageSourceShouldCache: false,
               ] as CFDictionary),
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_080,
               ] as CFDictionary) {
                return thumbnail
            }
            guard !Task.isCancelled, videoURL.isFileURL else { return nil }
            let asset = AVURLAsset(url: videoURL, options: [
                AVURLAssetOverrideMIMETypeKey: "video/mp4",
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
                AVURLAssetAllowsCellularAccessKey: false,
                AVURLAssetAllowsExpensiveNetworkAccessKey: false,
                AVURLAssetAllowsConstrainedNetworkAccessKey: false,
            ])
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1_080, height: 1_080)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
            return try? await generator.image(at: .zero).image
        }
        let decoded = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        if let decoded {
            motionArtworkPosterCache.setObject(
                decoded,
                forKey: key,
                cost: decoded.bytesPerRow * decoded.height
            )
        }
        return decoded
    }
}

nonisolated(unsafe) private let animatedArtworkFrameCache: NSCache<NSString, CGImage> = {
    let cache = NSCache<NSString, CGImage>()
    cache.countLimit = 32
    cache.totalCostLimit = DecodedImageCacheBudget.foregroundLimit(for: .animatedArtwork)
    return cache
}()

/// 动态封面帧缓存的上限(`DecodedImageCacheBudget`):退到后台时先清空再压低,回到前台恢复。
enum AnimatedArtworkFrameCache {
    nonisolated static func applyBudget(_ limit: Int, purge: Bool) {
        if purge {
            animatedArtworkFrameCache.removeAllObjects()
            motionArtworkPosterCache.removeAllObjects()
        }
        animatedArtworkFrameCache.totalCostLimit = limit
        motionArtworkPosterCache.totalCostLimit = min(limit, 24 * 1024 * 1024)
    }
}

/// Plays one validated ImageIO animation without retaining every decoded frame.
/// When paused while visible in the foreground, it freezes on the current frame
/// (or frame 0 if not yet started) and resumes from the following frame.
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

    private var isEnabled: Bool { AnimatedArtworkPreferences.shared.animatedArtworkEnabled }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages
    @State private var frame: CGImage?
    @State private var frameCacheKey: String?
    @State private var currentFrameIndex = 0
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
            frameCacheKey = nil
            currentFrameIndex = 0
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
            thermalCondition: AnimatedArtworkFrameDecoder.thermalCondition(ProcessInfo.processInfo.thermalState)
        )
    }

    private var activityIdentity: String {
        [
            cacheKey,
            String(descriptor.frameCount),
            String(describing: policy.displayMode),
            String(maximumPixelSize),
            String(runtimeRevision),
        ].joined(separator: "|")
    }

    @MainActor
    private func playFramesIfAllowed() async {
        if frameCacheKey != cacheKey {
            frame = nil
            frameCacheKey = cacheKey
            currentFrameIndex = 0
        }

        let displayMode = policy.displayMode
        guard descriptor.isAnimated else {
            frame = nil
            currentFrameIndex = 0
            return
        }

        switch displayMode {
        case .stopped:
            frame = nil
            currentFrameIndex = 0
            return
        case .pausedOnCurrentFrame:
            if frame != nil { return }
            let decoded = await AnimatedArtworkFrameDecoder.decodedFrame(
                data: data,
                index: 0,
                cacheKey: cacheKey,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled, policy.displayMode == .pausedOnCurrentFrame, let decoded else { return }
            frame = decoded
            currentFrameIndex = 0
            return
        case .stillFrame:
            if frame != nil, currentFrameIndex == 0 { return }
            let decoded = await AnimatedArtworkFrameDecoder.decodedFrame(
                data: data,
                index: 0,
                cacheKey: cacheKey,
                maximumPixelSize: maximumPixelSize
            )
            guard !Task.isCancelled, policy.displayMode == .stillFrame, let decoded else { return }
            frame = decoded
            currentFrameIndex = 0
            return
        case .playing:
            break
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary), CGImageSourceGetCount(source) == descriptor.frameCount else {
            frame = nil
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
        var startIndex = frame != nil && currentFrameIndex < descriptor.frameCount
            ? (currentFrameIndex + 1) % descriptor.frameCount
            : 0
        while totalPasses.map({ pass < $0 }) ?? true {
            for index in startIndex..<descriptor.frameCount {
                guard !Task.isCancelled, policy.displayMode == .playing else { return }
                deadline = deadline.advanced(
                    by: .seconds(descriptor.frameDurations[index])
                )
                // A slow decode or a background scheduling gap must not queue
                // stale frames. Skip overdue work and keep the timeline tied
                // to the monotonic clock.
                guard clock.now < deadline else { continue }
                let decoded = await AnimatedArtworkFrameDecoder.decodedFrame(
                    data: data,
                    index: index,
                    cacheKey: cacheKey,
                    maximumPixelSize: maximumPixelSize
                )
                guard !Task.isCancelled, policy.displayMode == .playing else { return }
                guard let decoded else {
                    frame = nil
                    return
                }
                guard clock.now < deadline else { continue }
                frame = decoded
                currentFrameIndex = index
                try? await clock.sleep(until: deadline)
            }
            startIndex = 0
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
        currentFrameIndex = 0
    }
}

/// 解帧与热状态换算放在非泛型的类型里。
///
/// 之前它们是 `AnimatedArtworkDataView<Fallback>` 的 static 方法，`await Self.decodedFrame(...)`
/// 会把泛型元数据（含 `Fallback` 对 `View` 的遵循）带进并发上下文；SwiftUI 的 `View` 遵循可能
/// 是 MainActor 隔离的，于是编译器报 #IsolatedConformances 警告。搬到这里就没有泛型可带了。
private enum AnimatedArtworkFrameDecoder {
    nonisolated static func decodedFrame(
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

    nonisolated static func thermalCondition(
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
