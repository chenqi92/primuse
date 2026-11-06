#if os(iOS)
import AVKit
import CoreMedia
import Observation
import PrimuseKit
import UIKit

@MainActor
@Observable
final class LyricsPictureInPicture: NSObject, @preconcurrency AVPictureInPictureControllerDelegate,
    @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = LyricsPictureInPicture()
    private(set) var isPossible = false
    private(set) var isActive = false
    private(set) var isStarting = false
    var errorMessage: String?
    var showsPreview = false
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private weak var preview: LyricsSampleBufferView?
    @ObservationIgnored private var displayLayer: AVSampleBufferDisplayLayer?
    @ObservationIgnored private var lastFrame: [String]?
    @ObservationIgnored private var lastPlaying: Bool?
    @ObservationIgnored private var controllerGeneration: UInt = 0
    @ObservationIgnored private var restoreCompletion: ((Bool) -> Void)?
    @ObservationIgnored private let service = FloatingLyricsService.shared
    @ObservationIgnored private var artworkKey: String?
    @ObservationIgnored private var artwork: UIImage?
    @ObservationIgnored private var palette: [LiquidBackdropColor] = []
    @ObservationIgnored private var artworkGeneration: UInt = 0
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var artworkObservers: [NSObjectProtocol] = []

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ view: LyricsSampleBufferView) {
        preview = view
        if artworkObservers.isEmpty {
            for name in [Notification.Name.primuseArtworkDidCache, .primuseArtworkDidInvalidate] {
                artworkObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let songID = note.object as? String
                    Task { @MainActor [weak self] in
                        guard let self, self.displayLayer != nil,
                              songID == nil || songID == self.service.songID else { return }
                        self.updateArtwork(force: true)
                    }
                })
            }
        }
        if let displayLayer {
            view.install(displayLayer)
        } else {
            let layer = AVSampleBufferDisplayLayer()
            layer.videoGravity = .resizeAspect
            var timebase: CMTimebase?
            if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase {
                CMTimebaseSetTime(timebase, time: .zero)
                CMTimebaseSetRate(timebase, rate: 1)
                layer.controlTimebase = timebase
            }
            view.install(layer)
            displayLayer = layer
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
            let controller = AVPictureInPictureController(contentSource: source)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            controller.canStartPictureInPictureAutomaticallyFromInline = false
            self.controller = controller
            controllerGeneration &+= 1
            let generation = controllerGeneration
            possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
                let possible = change.newValue ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.controllerGeneration == generation else { return }
                    self.isPossible = possible
                }
            }
        }
        service.onPresentationChange = { [weak self] in self?.refresh() }
        lastFrame = nil
        refresh()
    }

    func detach(_ view: LyricsSampleBufferView) {
        guard preview === view else { return }
        preview = nil
        releaseIfIdle()
    }

    func previewDidAppear() {
        let completion = restoreCompletion
        restoreCompletion = nil
        completion?(true)
    }

    func start() {
        guard let controller, isPossible, service.isAvailable, !isActive, !isStarting else { return }
        errorMessage = nil
        isStarting = true
        service.setPictureInPictureDemand(true)
        refresh()
        controller.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    private func releaseIfIdle() {
        guard preview == nil, !isActive, !isStarting else { return }
        possibleObservation = nil
        controllerGeneration &+= 1
        controller = nil
        displayLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        displayLayer = nil
        lastFrame = nil
        lastPlaying = nil
        isPossible = false
        service.onPresentationChange = nil
        artworkTask?.cancel()
        artworkTask = nil
        artworkGeneration &+= 1
        artworkKey = nil
        artwork = nil
        palette = []
        for observer in artworkObservers { NotificationCenter.default.removeObserver(observer) }
        artworkObservers = []
    }

    private func updateArtwork(force: Bool = false) {
        let song = service.player?.currentSong
        let key = song.map { "\($0.sourceID)|\($0.id)|\($0.coverArtFileName ?? "")|\(service.player?.coverRevision ?? 0)" }
        guard force || key != artworkKey else { return }
        artworkTask?.cancel()
        artworkGeneration &+= 1
        let generation = artworkGeneration
        artworkKey = key
        artwork = nil
        palette = []
        lastFrame = nil
        guard let song else { return }
        let songID = song.id, sourceID = song.sourceID, reference = song.coverArtFileName
        let task = Task.detached(priority: .utility) { () -> (UIImage?, [LiquidBackdropColor]) in
            let store = MetadataAssetStore.shared
            let data = store.displayCoverData(songID: songID, reference: reference)
                ?? store.cachedSourceCover(sourceID: sourceID, reference: reference, maximumPixels: 480, checksAge: false)
            guard !Task.isCancelled, let data, let image = UIImage(data: data) else { return (nil, []) }
            let colors = ThemeService.extractLiquidPalette(from: image)
            let thumbnail = image.preparingThumbnail(of: CGSize(width: 144, height: 144))
            return (thumbnail, colors)
        }
        artworkTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard let self, !Task.isCancelled, self.artworkGeneration == generation else { return }
            self.artwork = result.0
            self.palette = result.1
            self.lastFrame = nil
            self.refresh()
        }
    }

    private func refresh() {
        guard preview != nil || isActive || isStarting, let layer = displayLayer else { return }
        updateArtwork()
        if !service.isAvailable, isActive { stop() }
        if lastPlaying != service.isPlaying {
            lastPlaying = service.isPlaying
            controller?.invalidatePlaybackState()
        }
        let current = service.presentation.current ?? (service.hasTimedLyrics ? service.title
            : String(localized: service.isLoading ? "lyrics_loading" : "no_lyrics"))
        let next = service.presentation.next ?? ""
        let artist = service.player?.currentSong?.artistName ?? ""
        let signature = [service.title, artist, current, next]
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            lastFrame = nil
        }
        guard signature != lastFrame, renderer.isReadyForMoreMediaData,
              let sample = Self.makeFrame(title: service.title, current: current, next: next,
                                          artist: artist, artwork: artwork, palette: palette) else { return }
        renderer.enqueue(sample)
        lastFrame = signature
    }

    static func makeFrame(title: String, current: String, next: String, artist: String = "",
                          artwork: UIImage? = nil, palette: [LiquidBackdropColor] = []) -> CMSampleBuffer? {
        let width = 960, height = 540
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                          kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                  attributes, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawBackground(in: context, palette: palette)
        if let artwork {
            context.saveGState()
            let rect = CGRect(x: 56, y: 48, width: 72, height: 72)
            UIBezierPath(roundedRect: rect, cornerRadius: 12).addClip()
            let scale = max(rect.width / max(1, artwork.size.width), rect.height / max(1, artwork.size.height))
            let size = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
            artwork.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            context.restoreGState()
        }
        let titleX: CGFloat = artwork == nil ? 56 : 148
        draw(title, rect: CGRect(x: titleX, y: artist.isEmpty ? 60 : 44, width: 904 - titleX, height: 42),
             size: 30, minimum: 30, weight: .medium, color: .white.withAlphaComponent(0.86), singleLine: true)
        draw(artist, rect: CGRect(x: titleX, y: 88, width: 904 - titleX, height: 36),
             size: 25, minimum: 25, weight: .regular, color: .white.withAlphaComponent(0.62), singleLine: true)
        draw(current, rect: CGRect(x: 56, y: 172, width: 848, height: 204),
             size: 64, minimum: 38, weight: .semibold, color: .white)
        draw(next, rect: CGRect(x: 56, y: 410, width: 848, height: 84),
             size: 34, minimum: 28, weight: .regular, color: .white.withAlphaComponent(0.64))
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &description) == noErr,
              let description else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sample
    }

    private static func drawBackground(in context: CGContext, palette: [LiquidBackdropColor]) {
        let fallback: [LiquidBackdropColor] = [
            .init(red: 0.13, green: 0.24, blue: 0.29),
            .init(red: 0.09, green: 0.12, blue: 0.20),
            .init(red: 0.23, green: 0.20, blue: 0.28)
        ]
        let colors = MeshBackdropPalettePolicy.vividPalette(from: palette.isEmpty ? fallback : palette).map {
            UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let first = colors.first ?? .darkGray
        let last = colors.last ?? first
        if let gradient = CGGradient(colorsSpace: space, colors: [first.cgColor, last.cgColor] as CFArray,
                                     locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 960, y: 540), options: [])
        }
        for (index, color) in colors.enumerated() {
            let center = CGPoint(x: index.isMultiple(of: 2) ? 70 : 890, y: index < 2 ? 60 : 500)
            if let glow = CGGradient(colorsSpace: space,
                                    colors: [color.cgColor, color.withAlphaComponent(0).cgColor] as CFArray,
                                    locations: [0, 1]) {
                context.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                                           endCenter: center, endRadius: 740, options: [])
            }
        }
        context.setFillColor(UIColor.black.withAlphaComponent(0.12).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
    }

    private static func draw(_ text: String, rect: CGRect, size: CGFloat, minimum: CGFloat,
                             weight: UIFont.Weight, color: UIColor, singleLine: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 4
        var size = size
        var attributes: [NSAttributedString.Key: Any] = [:]
        var measured = CGRect.zero
        repeat {
            attributes = [.font: UIFont.systemFont(ofSize: size, weight: weight),
                          .foregroundColor: color, .paragraphStyle: paragraph]
            measured = (text as NSString).boundingRect(with: CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
            if measured.height <= rect.height || size <= minimum { break }
            size -= 2
        } while true
        if singleLine { paragraph.lineBreakMode = .byTruncatingTail }
        let box = CGRect(x: rect.minX, y: rect.minY + max(0, (rect.height - measured.height) / 2),
                         width: rect.width, height: min(rect.height, measured.height))
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.clip(to: rect)
        (text as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        context?.restoreGState()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard let player = service.player else { return }
        if playing { player.resume() } else { player.pause() }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !service.isPlaying
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        lastFrame = nil
        refresh()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = true
        if !service.isAvailable { stop() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isStarting = false
        isActive = false
        service.setPictureInPictureDemand(false)
        releaseIfIdle()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                   failedToStartPictureInPictureWithError error: any Error) {
        isStarting = false
        isActive = false
        errorMessage = String(localized: "lyrics_pip_start_failed")
        service.setPictureInPictureDemand(false)
        releaseIfIdle()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        if showsPreview, preview != nil {
            completionHandler(true)
            return
        }
        restoreCompletion?(false)
        restoreCompletion = completionHandler
        showsPreview = true
    }
}

final class LyricsSampleBufferView: UIView {
    private var videoLayer: AVSampleBufferDisplayLayer?
    func install(_ videoLayer: AVSampleBufferDisplayLayer) {
        self.videoLayer = videoLayer
        videoLayer.removeFromSuperlayer()
        layer.addSublayer(videoLayer)
        setNeedsLayout()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.frame = bounds
        CATransaction.commit()
    }
}
#endif
