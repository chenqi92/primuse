import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import PrimuseKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// 锁屏等系统「正在播放」位置的动态封面（iOS / iPadOS / macOS 26 起的 `MPMediaItemAnimatedArtwork`）。
///
/// 只用已经在本机的素材，按优先级：用户给歌曲指定的视频 > 专辑的视频 > 用户配置的动态封面服务已缓存的素材
/// > 自选动图。整份「正在播放」照旧先带静态封面发出去；素材准备好（核对文件、读画幅、取首帧做预览）以后
/// 再补发一次带动态封面的。动图要等系统真来要视频时才转码并缓存。系统只在有人看着时才要预览和视频，
/// 低电量、低数据、发热、减少动态效果时它自己退回预览图；App 不做任何持续的解码。
@MainActor
final class LockScreenMotionArtworkPublisher {
    static let shared = LockScreenMotionArtworkPublisher()

    /// 系统版本够、而且这台设备至少有一个动态封面位置。设置项和设置搜索按它决定显不显示。
    nonisolated static var isSupportedBySystem: Bool {
        !supportedAspects().isEmpty
    }

    private struct Candidate: Sendable {
        enum Source: Sendable {
            /// 已经规整好的动态封面视频，导入时就截好了首帧。
            case storedVideo(video: URL, poster: URL, aspect: MotionCoverAspect, contentID: String)
            /// 视频文件，画幅和首帧要现读。
            case videoFile(URL)
            /// GIF 等动图文件，交给系统前要转成视频。
            case animationFile(URL)
        }

        let kind: MotionArtworkMaterialKind
        let source: Source

        var identity: String {
            switch source {
            case .storedVideo(_, _, _, let contentID): "\(kind.rawValue):\(contentID)"
            case .videoFile(let url), .animationFile(let url): "\(kind.rawValue):\(url.path)"
            }
        }
    }

    private struct Prepared {
        let materialKey: String
        let entries: [String: Any]
    }

    private weak var player: AudioPlayerService?
    private var prepared: Prepared?
    private var preparingKey: String?
    private var failedKey: String?
    /// 上一次真的放进「正在播放」的素材；设置或素材变了时拿它判断要不要补发。
    private var publishedKey: String?
    private var preparation: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var preferenceSnapshot: [Bool] = []

    private init() {}

    // MARK: - Now Playing integration

    /// 每次整份重建「正在播放」时调用：素材准备好了就放进去，没准备好就开始准备、这一次什么也不加。
    func decorate(_ info: inout [String: Any], song: Song, player: AudioPlayerService) {
        // 系统不支持时什么都不做，也不挂任何监听。
        guard Self.isSupportedBySystem else { return }
        self.player = player
        installObserversIfNeeded()
        guard let key = desiredMaterialKey(song: song, player: player) else {
            cancelPreparation()
            prepared = nil
            publishedKey = nil
            return
        }
        if let prepared, prepared.materialKey == key {
            for (entryKey, value) in prepared.entries { info[entryKey] = value }
            publishedKey = key
            return
        }
        publishedKey = nil
        guard failedKey != key, preparingKey != key else { return }
        startPreparation(candidates(for: song, player: player), key: key)
    }

    /// 停止播放、清空「正在播放」时调用。
    func reset() {
        cancelPreparation()
        prepared = nil
        failedKey = nil
        publishedKey = nil
    }

    /// 切歌时临时撤掉封面的那一份快照里，上一首的动态封面也要一起撤。
    nonisolated static func removeEntries(from info: inout [String: Any]) {
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        info[MPNowPlayingInfoProperty1x1AnimatedArtwork] = nil
        info[MPNowPlayingInfoProperty3x4AnimatedArtwork] = nil
    }

    // MARK: - Material choice

    /// nil 表示这首不发动态封面（系统不支持、开关关着、不是曲库音乐或没有素材）。
    private func desiredMaterialKey(song: Song, player: AudioPlayerService) -> String? {
        guard Self.isSupportedBySystem else { return nil }
        let context = LockScreenMotionArtworkContext(
            systemSupportsAnimatedArtwork: true,
            animatedArtworkEnabled: Self.animatedArtworkEnabled,
            lockScreenEnabled: Self.lockScreenEnabled,
            content: Self.content(of: song, player: player),
            materialIsLocal: true,
            unmeteredOnly: AnimatedArtworkPreferences.shared.animatedArtworkUnmeteredOnly,
            isOnUnmeteredNetwork: NetworkMonitor.shared.isOnUnmeteredNetwork
        )
        guard LockScreenMotionArtworkPolicy.permitsPublishing(context) else { return nil }
        let candidates = candidates(for: song, player: player)
        guard !candidates.isEmpty else { return nil }
        return candidates.map(\.identity).joined(separator: "|")
    }

    private static func content(of song: Song, player: AudioPlayerService) -> LockScreenMotionArtworkContent {
        if player.isAppleMusicMode || song.sourceID == AppleMusicLibraryIdentity.sourceID { return .appleMusic }
        if player.isLiveRadio { return .liveRadio }
        if player.isMusicVideoPlaybackActive { return .musicVideo }
        let space = player.currentListeningSpace
        if space == .podcast { return .podcast }
        if space == .radio { return .liveRadio }
        if space == .spokenWord || player.currentItemIsAudiobook { return .spokenWord }
        return .music
    }

    /// 主线程上只做字典查找和字符串解析；文件核对、读画幅、取首帧都在后台准备时做。
    private func candidates(for song: Song, player: AudioPlayerService) -> [Candidate] {
        var result: [Candidate] = []
        let store = MotionCoverStore.shared
        let albumID = song.albumID.flatMap { $0.isEmpty ? nil : $0 }
        if let asset = store.asset(for: .song(song.id)) {
            result.append(Self.storedCandidate(asset, kind: .songVideo))
        }
        if let albumID, let asset = store.asset(for: .album(albumID)) {
            result.append(Self.storedCandidate(asset, kind: .albumVideo))
        }
        if let material = MotionCoverServiceMaterialRegistry.shared.material(songID: song.id, albumID: albumID) {
            result.append(Candidate(
                kind: .serviceMaterial,
                source: material.isVideo ? .videoFile(material.fileURL) : .animationFile(material.fileURL)
            ))
        }
        let customDirectory = MetadataAssetStore.shared.customArtworkDirectoryURL
        if let reference = song.coverArtFileName,
           StoredArtworkOrigin.resolve(reference) == .selected,
           let contentID = StoredArtworkOrigin.contentID(reference) {
            result.append(Candidate(
                kind: .customAnimation,
                source: .animationFile(customDirectory.appendingPathComponent("\(contentID).jpg"))
            ))
        }
        if let albumID,
           let override = player.library?.artworkOverride(for: LibraryArtworkOwner(kind: .album, id: albumID)),
           override.mode == .uploaded,
           let contentID = override.uploadedContentID,
           LibraryArtworkContentIDPolicy.isValid(contentID) {
            result.append(Candidate(
                kind: .customAnimation,
                source: .animationFile(customDirectory.appendingPathComponent("\(contentID).jpg"))
            ))
        }
        return MotionArtworkMaterialSelection.ordered(result) { $0.kind }
    }

    private static func storedCandidate(_ asset: MotionCoverAsset, kind: MotionArtworkMaterialKind) -> Candidate {
        Candidate(kind: kind, source: .storedVideo(
            video: MotionCoverStore.videoURL(for: asset),
            poster: MotionCoverStore.posterURL(for: asset),
            aspect: asset.aspect,
            contentID: asset.contentID
        ))
    }

    // MARK: - Preparation

    private func startPreparation(_ candidates: [Candidate], key: String) {
        preparation?.cancel()
        preparingKey = key
        let supported = Self.supportedAspects()
        preparation = Task { [weak self] in
            let material = await Self.prepareMaterial(from: candidates, supported: supported)
            guard !Task.isCancelled else { return }
            self?.finishPreparation(material, key: key)
        }
    }

    private func cancelPreparation() {
        preparation?.cancel()
        preparation = nil
        preparingKey = nil
    }

    private func finishPreparation(_ material: PreparedMaterial?, key: String) {
        guard preparingKey == key else { return }
        preparingKey = nil
        preparation = nil
        guard let material else {
            // 这一组素材都用不了：同一组不再反复尝试，素材或设置变了才重来。
            failedKey = key
            return
        }
        guard #available(iOS 26.0, macOS 26.0, *) else { return }
        let entryKey = material.aspect == .tall
            ? MPNowPlayingInfoProperty3x4AnimatedArtwork
            : MPNowPlayingInfoProperty1x1AnimatedArtwork
        prepared = Prepared(materialKey: key, entries: [entryKey: Self.makeArtwork(material)])
        failedKey = nil
        republish()
    }

    @available(iOS 26.0, macOS 26.0, *)
    nonisolated private static func makeArtwork(_ material: PreparedMaterial) -> MPMediaItemAnimatedArtwork {
        let preview = material.preview
        let video = material.video
        return MPMediaItemAnimatedArtwork(
            artworkID: material.artworkID,
            previewImageRequestHandler: { _ in preview },
            videoAssetFileURLRequestHandler: { _ in await video.resolveFileURL() }
        )
    }

    /// 重新整份发布一次「正在播放」，让刚准备好的（或刚撤掉的）动态封面生效。
    private func republish() {
        guard let player, player.currentSong != nil else { return }
        // 歌词逐行推进复用上一份快照；换掉快照身份，下一次也会整份重建。
        player.nowPlayingArtworkRevision &+= 1
        player.updateNowPlayingInfo()
    }

    /// 设置或素材变了：这首歌该发的和已经发出去的不一样时才补发。
    private func refreshIfNeeded() {
        guard let player, let song = player.currentSong else { return }
        let desired = desiredMaterialKey(song: song, player: player)
        if desired != nil, desired == preparingKey { return }
        guard desired != publishedKey else { return }
        failedKey = nil
        republish()
    }

    // MARK: - Observation

    private func installObserversIfNeeded() {
        guard observers.isEmpty else { return }
        preferenceSnapshot = Self.preferenceValues()
        observers.append(NotificationCenter.default.addObserver(
            forName: .primuseMotionCoverDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNeeded() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .primuseMotionCoverServiceMaterialDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfNeeded() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            // 偏好变更在写入线程上同步送达，挂主队列会让后台写偏好等主线程。
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.preferencesMayHaveChanged() }
        })
    }

    private func preferencesMayHaveChanged() {
        let values = Self.preferenceValues()
        guard values != preferenceSnapshot else { return }
        preferenceSnapshot = values
        refreshIfNeeded()
    }

    private static func preferenceValues() -> [Bool] {
        [animatedArtworkEnabled, lockScreenEnabled]
    }

    private static var animatedArtworkEnabled: Bool {
        UserDefaults.standard.object(forKey: PlayerAppearancePreferences.animatedArtworkEnabledKey) as? Bool
            ?? PlayerAppearancePreferences.animatedArtworkEnabledByDefault
    }

    private static var lockScreenEnabled: Bool {
        UserDefaults.standard.object(forKey: PlayerAppearancePreferences.lockScreenAnimatedArtworkKey) as? Bool
            ?? PlayerAppearancePreferences.lockScreenAnimatedArtworkByDefault
    }

    /// 设备能放动态封面的位置。系统给的是固定清单，只问一次。
    nonisolated private static func supportedAspects() -> Set<MotionCoverAspect> {
        supportedAspectSet
    }

    nonisolated private static let supportedAspectSet: Set<MotionCoverAspect> = {
        guard #available(iOS 26.0, macOS 26.0, *) else { return [] }
        let keys = Set(MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys)
        var aspects = Set<MotionCoverAspect>()
        if keys.contains(MPNowPlayingInfoProperty1x1AnimatedArtwork) { aspects.insert(.square) }
        if keys.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) { aspects.insert(.tall) }
        return aspects
    }()
}

// MARK: - Background preparation

/// 后台准备好、交回主线程装进 `MPMediaItemAnimatedArtwork` 的素材。预览图解好码后不再改动。
private struct PreparedMaterial: @unchecked Sendable {
    let artworkID: String
    let aspect: MotionCoverAspect
    let preview: PlatformImage
    let video: LockScreenMotionVideoSource
}

private enum LockScreenMotionVideoSource: Sendable {
    case file(URL)
    case convert(LockScreenMotionConversionJob)

    /// 系统来要视频时才调用。文件不在了（素材被移除）就给 nil，系统退回预览图。
    func resolveFileURL() async -> URL? {
        switch self {
        case .file(let url):
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .convert(let job):
            return await LockScreenMotionArtworkConverter.shared.videoURL(for: job)
        }
    }
}

private struct LockScreenMotionConversionJob: Sendable {
    let sourceURL: URL
    let cacheName: String
    let width: Int
    let height: Int
}

extension LockScreenMotionArtworkPublisher {
    /// 预览图上限：锁屏全屏 3:4 位在这个尺寸下已经够清楚，内存也只多一张图。
    nonisolated private static let previewLongEdge = MotionCoverImportLimits.maximumLongEdge

    nonisolated private static func prepareMaterial(
        from candidates: [Candidate],
        supported: Set<MotionCoverAspect>
    ) async -> PreparedMaterial? {
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            if let material = await prepare(candidate, supported: supported) { return material }
        }
        return nil
    }

    nonisolated private static func prepare(
        _ candidate: Candidate,
        supported: Set<MotionCoverAspect>
    ) async -> PreparedMaterial? {
        switch candidate.source {
        case .storedVideo(let video, let poster, let aspect, let contentID):
            guard LockScreenMotionArtworkPolicy.slot(for: aspect, supported: supported) != nil,
                  FileManager.default.fileExists(atPath: video.path) else { return nil }
            let decodedPoster = decodeImage(at: poster)
            var videoFrame: CGImage?
            if decodedPoster == nil {
                videoFrame = await firstVideoFrame(video)
            }
            guard let frame = decodedPoster ?? videoFrame else { return nil }
            return PreparedMaterial(
                artworkID: LockScreenMotionArtworkPolicy.artworkID(
                    kind: candidate.kind, contentKey: contentID, aspect: aspect
                ),
                aspect: aspect,
                preview: PlatformImage.fromCGImage(frame),
                video: .file(video)
            )

        case .videoFile(let url):
            let asset = AVURLAsset(url: url)
            guard FileManager.default.fileExists(atPath: url.path),
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let geometry = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let displayRect = CGRect(origin: .zero, size: geometry.0).applying(geometry.1)
            guard let aspect = MotionCoverAspect.matching(
                    width: Double(abs(displayRect.width)),
                    height: Double(abs(displayRect.height))
                  ),
                  LockScreenMotionArtworkPolicy.slot(for: aspect, supported: supported) != nil,
                  let frame = await firstVideoFrame(url) else { return nil }
            return PreparedMaterial(
                artworkID: LockScreenMotionArtworkPolicy.artworkID(
                    kind: candidate.kind, contentKey: fileContentKey(url), aspect: aspect
                ),
                aspect: aspect,
                preview: PlatformImage.fromCGImage(frame),
                video: .file(url)
            )

        case .animationFile(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0, size <= MotionCoverImportLimits.maximumAnimationBytes,
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let descriptor = ArtworkImageCompatibility.inspect(data),
                  descriptor.isAnimated else { return nil }
            let plan = MotionCoverImportPlan.forAnimation(
                pixelWidth: descriptor.pixelWidth,
                pixelHeight: descriptor.pixelHeight,
                duration: descriptor.duration,
                frameCount: descriptor.frameCount
            )
            guard case .transcode(let aspect, let width, let height, _) = plan,
                  LockScreenMotionArtworkPolicy.slot(for: aspect, supported: supported) != nil,
                  let firstFrame = decodeImage(data: data),
                  let preview = aspectFilled(firstFrame, width: width, height: height) else { return nil }
            let contentKey = url.deletingPathExtension().lastPathComponent
            return PreparedMaterial(
                artworkID: LockScreenMotionArtworkPolicy.artworkID(
                    kind: candidate.kind, contentKey: contentKey, aspect: aspect
                ),
                aspect: aspect,
                preview: PlatformImage.fromCGImage(preview),
                video: .convert(LockScreenMotionConversionJob(
                    sourceURL: url,
                    cacheName: LockScreenMotionArtworkPolicy.conversionCacheName(
                        contentKey: contentKey, aspect: aspect, width: width, height: height
                    ),
                    width: width,
                    height: height
                ))
            )
        }
    }

    /// 没有内容哈希的视频文件用路径、大小、修改时间认身份：换了内容就是新的 artworkID。
    nonisolated private static func fileContentKey(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let identity = [
            url.path,
            String(values?.fileSize ?? 0),
            String(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(identity.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func decodeImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    nonisolated private static func decodeImage(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { return nil }
        return thumbnail(from: source)
    }

    nonisolated private static func thumbnail(from source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: previewLongEdge,
        ] as CFDictionary)
    }

    nonisolated private static func firstVideoFrame(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewLongEdge, height: previewLongEdge)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        guard let result = try? await generator.image(at: .zero) else { return nil }
        return result.image
    }

    /// 动图首帧按转出来的视频同样的方式铺满、居中裁，预览和视频第一帧对得上。
    nonisolated private static func aspectFilled(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
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
        return context.makeImage()
    }
}

// MARK: - Animation conversion cache

/// 动图转成视频的缓存。只在系统真来要视频时才转，同一份同时只转一次；缓存放在 Caches，
/// 保留最近用过的一小批。
private actor LockScreenMotionArtworkConverter {
    static let shared = LockScreenMotionArtworkConverter()
    private static let keptFileCount = 24
    private var inFlight: [String: Task<URL?, Never>] = [:]

    func videoURL(for job: LockScreenMotionConversionJob) async -> URL? {
        let directory = MotionCoverStore.lockScreenCacheDirectoryURL
        let destination = directory.appendingPathComponent(job.cacheName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        if let running = inFlight[job.cacheName] { return await running.value }
        let task = Task.detached(priority: .utility) { () -> URL? in
            await Self.convert(job, to: destination)
        }
        inFlight[job.cacheName] = task
        let url = await task.value
        inFlight[job.cacheName] = nil
        return url
    }

    nonisolated private static func convert(_ job: LockScreenMotionConversionJob, to destination: URL) async -> URL? {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: job.sourceURL, options: .mappedIfSafe),
              let descriptor = ArtworkImageCompatibility.inspect(data),
              descriptor.isAnimated,
              (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let temporary = directory.appendingPathComponent("converting-\(UUID().uuidString).mp4")
        do {
            try await MotionCoverImporter.encodeAnimation(
                data: data,
                descriptor: descriptor,
                width: job.width,
                height: job.height,
                to: temporary
            )
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            pruneCache(in: directory, keeping: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: temporary)
            return nil
        }
    }

    nonisolated private static func pruneCache(in directory: URL, keeping current: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let dated = files
            .filter { $0.lastPathComponent.hasPrefix("animation-") && $0 != current }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keptFileCount - 1) {
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Service material registry

extension Notification.Name {
    static let primuseMotionCoverServiceMaterialDidChange = Notification.Name(
        "primuseMotionCoverServiceMaterialDidChange"
    )
}

/// 用户自己配置的动态封面服务返回的素材。大封面位拿到以后在锁屏缓存目录里留一份，锁屏发动态封面时
/// 直接用，不为锁屏再去联网。只记进程里最近的一批。
@MainActor
final class MotionCoverServiceMaterialRegistry {
    static let shared = MotionCoverServiceMaterialRegistry()

    struct Material: Equatable, Sendable {
        let fileURL: URL
        let isVideo: Bool
    }

    nonisolated private static let capacity = 32
    private var entries: [String: Material] = [:]
    private var order: [String] = []

    private init() {}

    func material(songID: String, albumID: String?) -> Material? {
        if let material = entries[Self.songKey(songID)] { return material }
        if let albumID, let material = entries[Self.albumKey(albumID)] { return material }
        return nil
    }

    /// 服务给的动图（GIF、APNG、动态 WebP）。
    func noteAnimation(_ data: Data, songID: String?, albumID: String?) {
        let keys = Self.keys(songID: songID, albumID: albumID)
        guard !keys.isEmpty, !data.isEmpty,
              data.count <= MotionCoverImportLimits.maximumAnimationBytes else { return }
        Task { [weak self] in
            guard let url = await Self.keepCopy(of: data) else { return }
            self?.record(Material(fileURL: url, isVideo: false), for: keys)
        }
    }

    /// 服务给的视频，已经缓存在本机的文件。
    func noteVideo(at url: URL, songID: String?, albumID: String?) {
        let keys = Self.keys(songID: songID, albumID: albumID)
        guard !keys.isEmpty else { return }
        Task { [weak self] in
            guard let copy = await Self.keepCopy(ofVideoAt: url) else { return }
            self?.record(Material(fileURL: copy, isVideo: true), for: keys)
        }
    }

    private func record(_ material: Material, for keys: [String]) {
        var changed = false
        for key in keys {
            if entries[key] != material {
                entries[key] = material
                changed = true
            }
            order.removeAll { $0 == key }
            order.append(key)
        }
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
        if changed {
            NotificationCenter.default.post(name: .primuseMotionCoverServiceMaterialDidChange, object: nil)
        }
    }

    private static func keys(songID: String?, albumID: String?) -> [String] {
        var keys: [String] = []
        if let songID, !songID.isEmpty { keys.append(songKey(songID)) }
        if let albumID, !albumID.isEmpty { keys.append(albumKey(albumID)) }
        return keys
    }

    private static func songKey(_ id: String) -> String { "song:\(id)" }
    private static func albumKey(_ id: String) -> String { "album:\(id)" }

    nonisolated private static func keepCopy(of data: Data) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let destination = MotionCoverStore.lockScreenCacheDirectoryURL
                .appendingPathComponent("service-\(hash).img")
            return Self.install(destination) { try data.write(to: destination, options: .atomic) }
        }.value
    }

    nonisolated private static func keepCopy(ofVideoAt source: URL) async -> URL? {
        await Task.detached(priority: .utility) { () -> URL? in
            guard let hash = try? MotionCoverImporter.sha256Hex(ofFileAt: source) else { return nil }
            let destination = MotionCoverStore.lockScreenCacheDirectoryURL
                .appendingPathComponent("service-\(hash).mp4")
            return Self.install(destination) {
                // 硬链接不占额外空间；服务缓存过期删掉原文件时这一份还在。
                do {
                    try FileManager.default.linkItem(at: source, to: destination)
                } catch {
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            }
        }.value
    }

    nonisolated private static func install(_ destination: URL, write: () throws -> Void) -> URL? {
        let fileManager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try write()
        } catch {
            return nil
        }
        // 只留最近的一批。
        if let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let stale = files
                .filter { $0.lastPathComponent.hasPrefix("service-") && $0 != destination }
                .map { url in
                    (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
                }
                .sorted { $0.1 > $1.1 }
                .dropFirst(capacity - 1)
            for (url, _) in stale { try? fileManager.removeItem(at: url) }
        }
        return destination
    }
}
