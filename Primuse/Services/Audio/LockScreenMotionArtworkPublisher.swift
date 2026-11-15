import AVFoundation
import CoreGraphics
import CoreImage
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
///
/// 锁屏只把 3:4 那份铺成全屏背景，1:1 只显示成方块。所以 iPhone、iPad 上方形素材除了原样放 1:1 位，
/// 还合成一份 3:4（模糊铺底 + 完整方形，见 `LockScreenSquareInTallLayout`）放 3:4 位，同样等系统
/// 真来要视频时才合成并缓存。Mac 上没有锁屏全屏封面，方形素材照旧只放 1:1 位。
@MainActor
final class LockScreenMotionArtworkPublisher {
    static let shared = LockScreenMotionArtworkPublisher()

    /// 系统版本够、而且这台设备至少有一个动态封面位置。设置项和设置搜索按它决定显不显示。
    nonisolated static var isSupportedBySystem: Bool {
        !supportedAspects().isEmpty
    }

    private struct Candidate: Sendable {
        enum Source: Sendable {
            /// 已经规整好的动态封面视频，导入时就截好了首帧。`side` 是短边像素。
            case storedVideo(video: URL, poster: URL, aspect: MotionCoverAspect, contentID: String, side: Int)
            /// 视频文件，画幅和首帧要现读。
            case videoFile(URL)
            /// GIF 等动图文件，交给系统前要转成视频。
            case animationFile(URL)
        }

        let kind: MotionArtworkMaterialKind
        let source: Source

        var identity: String {
            switch source {
            case .storedVideo(_, _, _, let contentID, _): "\(kind.rawValue):\(contentID)"
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
            contentID: asset.contentID,
            side: min(asset.pixelWidth, asset.pixelHeight)
        ))
    }

    // MARK: - Preparation

    private func startPreparation(_ candidates: [Candidate], key: String) {
        preparation?.cancel()
        preparingKey = key
        let supported = Self.supportedAspects()
        let composition = Self.tallComposition()
        preparation = Task { [weak self] in
            let material = await Self.prepareMaterial(
                from: candidates,
                supported: supported,
                composition: composition
            )
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
        var entries: [String: Any] = [:]
        for rendition in material.renditions {
            let entryKey = rendition.slot == .tall
                ? MPNowPlayingInfoProperty3x4AnimatedArtwork
                : MPNowPlayingInfoProperty1x1AnimatedArtwork
            entries[entryKey] = Self.makeArtwork(rendition)
        }
        prepared = Prepared(materialKey: key, entries: entries)
        failedKey = nil
        republish()
    }

    @available(iOS 26.0, macOS 26.0, *)
    nonisolated private static func makeArtwork(_ rendition: PreparedRendition) -> MPMediaItemAnimatedArtwork {
        let preview = rendition.preview
        let video = rendition.video
        return MPMediaItemAnimatedArtwork(
            artworkID: rendition.artworkID,
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

    /// 方形素材要不要合成 3:4、按多宽的可见区域合成。只有 iPhone、iPad 的锁屏会把 3:4 铺成全屏；
    /// Mac（以及在 Mac 上跑的 iPhone 版）没有这个场景，返回 nil，方形素材照旧只放 1:1 位。
    private static func tallComposition() -> LockScreenTallComposition? {
        #if os(iOS)
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return nil }
        let screen = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?
            .screen
        guard let bounds = screen?.nativeBounds,
              bounds.width > 0, bounds.height > 0 else {
            return LockScreenTallComposition(visibleWidthRatio: nil)
        }
        let ratio = Double(min(bounds.width, bounds.height) / max(bounds.width, bounds.height))
        // 折叠屏 iPhone 打开时内屏接近方形，可锁屏大多看的是外屏：手机上偏方的屏幕按常见 iPhone 比例算。
        if UIDevice.current.userInterfaceIdiom == .phone, ratio > 0.6 {
            return LockScreenTallComposition(visibleWidthRatio: nil)
        }
        return LockScreenTallComposition(visibleWidthRatio: ratio)
        #else
        return nil
        #endif
    }
}

/// 方形素材合成 3:4 时用的屏幕信息；nil 比例按 `LockScreenSquareInTallLayout.fallbackVisibleWidthRatio`。
private struct LockScreenTallComposition: Sendable {
    let visibleWidthRatio: Double?
}

// MARK: - Background preparation

/// 后台准备好、交回主线程装进 `MPMediaItemAnimatedArtwork` 的素材：要放几个位置就有几份。
private struct PreparedMaterial: @unchecked Sendable {
    let renditions: [PreparedRendition]
}

/// 放进一个位置的一份。预览图解好码后不再改动。
private struct PreparedRendition: @unchecked Sendable {
    let slot: MotionCoverAspect
    let artworkID: String
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
    enum Output: Sendable {
        /// 动图按原画幅转成 `width`×`height` 的视频。
        case animation(width: Int, height: Int)
        /// 方形视频合成 3:4。
        case videoInTall(LockScreenSquareInTallLayout)
        /// 方形动图合成 3:4。
        case animationInTall(LockScreenSquareInTallLayout)
    }

    let sourceURL: URL
    let cacheName: String
    let output: Output
}

extension LockScreenMotionArtworkPublisher {
    /// 预览图上限：锁屏全屏 3:4 位在这个尺寸下已经够清楚，内存也只多一张图。
    nonisolated private static let previewLongEdge = MotionCoverImportLimits.maximumLongEdge

    nonisolated private static func prepareMaterial(
        from candidates: [Candidate],
        supported: Set<MotionCoverAspect>,
        composition: LockScreenTallComposition?
    ) async -> PreparedMaterial? {
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            if let material = await prepare(candidate, supported: supported, composition: composition) {
                return material
            }
        }
        return nil
    }

    nonisolated private static func prepare(
        _ candidate: Candidate,
        supported: Set<MotionCoverAspect>,
        composition: LockScreenTallComposition?
    ) async -> PreparedMaterial? {
        switch candidate.source {
        case .storedVideo(let video, let poster, let aspect, let contentID, let side):
            let renditions = LockScreenMotionArtworkPolicy.renditions(
                for: aspect, supported: supported, canComposeTall: composition != nil
            )
            guard !renditions.isEmpty,
                  FileManager.default.fileExists(atPath: video.path) else { return nil }
            let decodedPoster = decodeImage(at: poster)
            var videoFrame: CGImage?
            if decodedPoster == nil {
                videoFrame = await firstVideoFrame(video)
            }
            guard let frame = decodedPoster ?? videoFrame else { return nil }
            return makeMaterial(
                kind: candidate.kind,
                contentKey: contentID,
                renditions: renditions,
                originalPreview: frame,
                originalVideo: .file(video),
                firstFrame: frame,
                sourceSide: side > 0 ? side : min(frame.width, frame.height),
                sourceURL: video,
                composition: composition,
                composedOutput: LockScreenMotionConversionJob.Output.videoInTall
            )

        case .videoFile(let url):
            let asset = AVURLAsset(url: url)
            guard FileManager.default.fileExists(atPath: url.path),
                  let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let geometry = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
            let displayRect = CGRect(origin: .zero, size: geometry.0).applying(geometry.1)
            let displayWidth = Double(abs(displayRect.width))
            let displayHeight = Double(abs(displayRect.height))
            guard let aspect = MotionCoverAspect.matching(width: displayWidth, height: displayHeight) else {
                return nil
            }
            let renditions = LockScreenMotionArtworkPolicy.renditions(
                for: aspect, supported: supported, canComposeTall: composition != nil
            )
            guard !renditions.isEmpty, let frame = await firstVideoFrame(url) else { return nil }
            return makeMaterial(
                kind: candidate.kind,
                contentKey: fileContentKey(url),
                renditions: renditions,
                originalPreview: frame,
                originalVideo: .file(url),
                firstFrame: frame,
                sourceSide: Int(min(displayWidth, displayHeight)),
                sourceURL: url,
                composition: composition,
                composedOutput: LockScreenMotionConversionJob.Output.videoInTall
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
            guard case .transcode(let aspect, let width, let height, _) = plan else { return nil }
            let renditions = LockScreenMotionArtworkPolicy.renditions(
                for: aspect, supported: supported, canComposeTall: composition != nil
            )
            guard !renditions.isEmpty, let firstFrame = decodeImage(data: data) else { return nil }
            let contentKey = url.deletingPathExtension().lastPathComponent
            let originalPreview = aspectFilled(firstFrame, width: width, height: height)
            return makeMaterial(
                kind: candidate.kind,
                contentKey: contentKey,
                renditions: renditions,
                originalPreview: originalPreview,
                originalVideo: .convert(LockScreenMotionConversionJob(
                    sourceURL: url,
                    cacheName: LockScreenMotionArtworkPolicy.conversionCacheName(
                        contentKey: contentKey, aspect: aspect, width: width, height: height
                    ),
                    output: .animation(width: width, height: height)
                )),
                firstFrame: firstFrame,
                sourceSide: min(descriptor.pixelWidth, descriptor.pixelHeight),
                sourceURL: url,
                composition: composition,
                composedOutput: LockScreenMotionConversionJob.Output.animationInTall
            )
        }
    }

    /// 同一段素材按要放的位置装成一到两份：原样的一份，和方形合成 3:4 的一份。合成那份的预览图
    /// 用和视频完全相同的合成从首帧画出来，系统先显示的预览和视频第一帧对得上。
    nonisolated private static func makeMaterial(
        kind: MotionArtworkMaterialKind,
        contentKey: String,
        renditions: [LockScreenMotionArtworkRendition],
        originalPreview: CGImage?,
        originalVideo: LockScreenMotionVideoSource,
        firstFrame: CGImage,
        sourceSide: Int,
        sourceURL: URL,
        composition: LockScreenTallComposition?,
        composedOutput: (LockScreenSquareInTallLayout) -> LockScreenMotionConversionJob.Output
    ) -> PreparedMaterial? {
        var prepared: [PreparedRendition] = []
        for rendition in renditions {
            switch rendition {
            case .original(let slot):
                guard let originalPreview else { continue }
                prepared.append(PreparedRendition(
                    slot: slot,
                    artworkID: LockScreenMotionArtworkPolicy.artworkID(
                        kind: kind, contentKey: contentKey, aspect: slot
                    ),
                    preview: PlatformImage.fromCGImage(originalPreview),
                    video: originalVideo
                ))
            case .squareInTall:
                guard let composition,
                      let layout = LockScreenSquareInTallLayout(
                        sourceSide: Double(sourceSide),
                        visibleWidthRatio: composition.visibleWidthRatio
                      ),
                      let preview = LockScreenSquareInTallComposer.previewImage(from: firstFrame, layout: layout)
                else { continue }
                prepared.append(PreparedRendition(
                    slot: .tall,
                    artworkID: LockScreenMotionArtworkPolicy.artworkID(
                        kind: kind, contentKey: contentKey, squareInTall: layout
                    ),
                    preview: PlatformImage.fromCGImage(preview),
                    video: .convert(LockScreenMotionConversionJob(
                        sourceURL: sourceURL,
                        cacheName: LockScreenMotionArtworkPolicy.tallCompositionCacheName(
                            contentKey: contentKey, layout: layout
                        ),
                        output: composedOutput(layout)
                    ))
                ))
            }
        }
        return prepared.isEmpty ? nil : PreparedMaterial(renditions: prepared)
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

// MARK: - Conversion cache

/// 按需转出来的视频（动图转码、方形素材合成 3:4）的缓存。只在系统真来要视频时才转，同一份同时只转一次；
/// 缓存放在 Caches，保留最近用过的一小批。
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
        guard fileManager.fileExists(atPath: job.sourceURL.path),
              (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        let temporary = directory.appendingPathComponent("converting-\(UUID().uuidString).mp4")
        do {
            switch job.output {
            case .animation(let width, let height):
                let (data, descriptor) = try animationSource(job.sourceURL)
                try await MotionCoverImporter.encodeAnimation(
                    data: data,
                    descriptor: descriptor,
                    width: width,
                    height: height,
                    to: temporary
                )
            case .animationInTall(let layout):
                let (data, descriptor) = try animationSource(job.sourceURL)
                try await LockScreenSquareInTallComposer.encodeAnimation(
                    data: data,
                    frameDurations: descriptor.frameDurations,
                    layout: layout,
                    to: temporary
                )
            case .videoInTall(let layout):
                try await LockScreenSquareInTallComposer.encodeVideo(
                    at: job.sourceURL,
                    layout: layout,
                    to: temporary
                )
            }
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

    nonisolated private static func animationSource(_ url: URL) throws -> (Data, ArtworkDescriptor) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let descriptor = ArtworkImageCompatibility.inspect(data),
              descriptor.isAnimated else { throw MotionCoverImportError.rejected(.unreadable) }
        return (data, descriptor)
    }

    nonisolated private static func pruneCache(in directory: URL, keeping current: URL) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let dated = files
            .filter { url in
                url != current && LockScreenMotionArtworkPolicy.conversionCachePrefixes.contains {
                    url.lastPathComponent.hasPrefix($0)
                }
            }
            .map { url in
                (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keptFileCount - 1) {
            try? fileManager.removeItem(at: url)
        }
    }
}

// MARK: - Square-in-tall composition

/// 方形素材合成锁屏用的 3:4 画面（构图见 `LockScreenSquareInTallLayout`）：底层是同一画面放大铺满、
/// 模糊并压暗，上层是完整的方形。预览图和视频每一帧走同一个 `compose`，预览和视频第一帧一致。
/// 只在系统来要视频时合成一次、写进缓存：逐帧在 GPU 上合成，内存里只有当前一帧，编码用 HEVC。
enum LockScreenSquareInTallComposer {
    /// 合成后的视频帧率上限：循环封面 30 帧足够顺，和导入时重新编码的标准一致。
    nonisolated private static let maximumFrameRate = MotionCoverImportLimits.transcodedFrameRate

    nonisolated static func compose(_ frame: CIImage, layout: LockScreenSquareInTallLayout) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        let extent = frame.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite, extent.height.isFinite else {
            return CIImage(color: .black).cropped(to: canvas)
        }
        // 接近方形（2% 以内）的素材先居中裁成正方形，原点挪到 0。
        let side = min(extent.width, extent.height)
        let origin = CGPoint(x: extent.midX - side / 2, y: extent.midY - side / 2)
        let square = frame
            .cropped(to: CGRect(origin: origin, size: CGSize(width: side, height: side)))
            .transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))

        // 底层：等比放大到盖满整个画面、居中，模糊成色块再压暗。先裁回画面再向外延边，模糊到边上不会发黑。
        let fillScale = max(canvas.width, canvas.height) / side
        let background = square
            .transformed(by: CGAffineTransform(scaleX: fillScale, y: fillScale))
            .transformed(by: CGAffineTransform(
                translationX: (canvas.width - side * fillScale) / 2,
                y: (canvas.height - side * fillScale) / 2
            ))
            .cropped(to: canvas)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(canvas.width) * LockScreenSquareInTallLayout.backgroundBlurFraction)
            .applyingFilter("CIColorMatrix", parameters: brightnessMatrix(
                LockScreenSquareInTallLayout.backgroundBrightness
            ))
            .cropped(to: canvas)

        // 上层：完整方形缩到可见宽度。CoreImage 原点在左下，布局给的是离上沿的距离。
        let foregroundSide = CGFloat(layout.foregroundSide)
        let scale = foregroundSide / side
        let foreground = square
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale), highQualityDownsample: scale < 1)
            .cropped(to: CGRect(x: 0, y: 0, width: foregroundSide, height: foregroundSide))
            .transformed(by: CGAffineTransform(
                translationX: CGFloat(layout.foregroundX),
                y: canvas.height - CGFloat(layout.foregroundY) - foregroundSide
            ))
        return foreground.composited(over: background).cropped(to: canvas)
    }

    /// 预览图：和视频第一帧同一套合成。
    nonisolated static func previewImage(from frame: CGImage, layout: LockScreenSquareInTallLayout) -> CGImage? {
        let context = makeContext()
        let image = compose(CIImage(cgImage: frame), layout: layout)
        return context.createCGImage(
            image,
            from: CGRect(x: 0, y: 0, width: layout.width, height: layout.height),
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
    }

    /// 方形视频（时长沿用素材自己的，最多 60 秒）逐帧合成。帧率超过 30 的按 30 抽帧。
    nonisolated static func encodeVideo(
        at url: URL,
        layout: LockScreenSquareInTallLayout,
        to outputURL: URL
    ) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MotionCoverImportError.rejected(.unreadable)
        }
        let (timeRange, transform) = try await track.load(.timeRange, .preferredTransform)
        let limit = CMTimeMinimum(
            timeRange.duration,
            CMTime(seconds: MotionCoverImportLimits.maximumDuration, preferredTimescale: 600)
        )
        guard limit.isNumeric, limit.seconds > 0 else { throw MotionCoverImportError.rejected(.unreadable) }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: timeRange.start, duration: limit)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MotionCoverImportError.failed }
        reader.add(output)
        let writer = try TallFrameWriter(outputURL: outputURL, layout: layout)
        guard reader.startReading() else {
            writer.cancel()
            throw reader.error ?? MotionCoverImportError.failed
        }

        let orientation = imageOrientation(for: transform)
        let minimumGap = 1 / maximumFrameRate - 0.002
        var lastTime: CMTime?
        do {
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let offset = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), timeRange.start)
                // 第一帧放在 0：有的容器首帧时间戳带一点零头，开头不能是空画面。
                let time = lastTime == nil ? .zero : offset
                if let lastTime {
                    guard CMTimeCompare(time, limit) < 0,
                          CMTimeSubtract(time, lastTime).seconds >= minimumGap else { continue }
                }
                try await writer.append(CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation), at: time)
                lastTime = time
            }
            guard reader.status == .completed, let lastTime else {
                throw reader.error ?? MotionCoverImportError.rejected(.unreadable)
            }
            try await writer.finish(at: CMTimeMaximum(
                limit,
                CMTimeAdd(lastTime, CMTime(seconds: 1 / maximumFrameRate, preferredTimescale: 600))
            ))
        } catch {
            reader.cancelReading()
            writer.cancel()
            throw error
        }
    }

    /// 方形动图逐帧合成。每帧按原有时长写，快慢跟原图一样；超过 60 秒的部分丢掉。
    nonisolated static func encodeAnimation(
        data: Data,
        frameDurations: [TimeInterval],
        layout: LockScreenSquareInTallLayout,
        to outputURL: URL
    ) async throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else { throw MotionCoverImportError.rejected(.unreadable) }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 1 else { throw MotionCoverImportError.rejected(.unreadable) }
        // 解码尺寸够画面高度就行：底层铺满要的最大，上层方形比它小，再大也是白占内存。
        let decodeOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: layout.height,
        ] as CFDictionary
        let writer = try TallFrameWriter(outputURL: outputURL, layout: layout)
        let limit = CMTime(seconds: MotionCoverImportLimits.maximumDuration, preferredTimescale: 600)
        var presentation = CMTime.zero
        var appended = 0
        do {
            for index in 0..<frameCount {
                try Task.checkCancellation()
                guard CMTimeCompare(presentation, limit) < 0 else { break }
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, decodeOptions) else { continue }
                try await writer.append(CIImage(cgImage: frame), at: presentation)
                appended += 1
                let delay = index < frameDurations.count ? frameDurations[index] : 0.1
                presentation = CMTimeMinimum(
                    limit,
                    CMTimeAdd(presentation, CMTime(seconds: max(delay, 0.02), preferredTimescale: 600))
                )
            }
            guard appended > 1 else { throw MotionCoverImportError.rejected(.unreadable) }
            try await writer.finish(at: presentation)
        } catch {
            writer.cancel()
            throw error
        }
    }

    // MARK: Helpers

    nonisolated fileprivate static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// 每次合成用自己的上下文：不缓存中间结果，逐帧合成不攒内存；合成完随任务一起释放。
    nonisolated fileprivate static func makeContext() -> CIContext {
        CIContext(options: [
            .cacheIntermediates: false,
            .outputColorSpace: outputColorSpace,
        ])
    }

    nonisolated private static func brightnessMatrix(_ factor: Double) -> [String: Any] {
        [
            "inputRVector": CIVector(x: factor, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: factor, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: factor, w: 0),
        ]
    }

    /// 视频轨的拍摄方向（preferredTransform）换成 CoreImage 的方向；规整过的视频是单位矩阵。
    nonisolated private static func imageOrientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (transform.a.rounded(), transform.b.rounded(), transform.c.rounded(), transform.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        default: .up
        }
    }
}

/// 把合成好的画面逐帧编码成 HEVC MP4。只在一个合成任务里用，不跨线程共享。
private final class TallFrameWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let context = LockScreenSquareInTallComposer.makeContext()
    private let layout: LockScreenSquareInTallLayout
    private let canvas: CGRect

    init(outputURL: URL, layout: LockScreenSquareInTallLayout) throws {
        try? FileManager.default.removeItem(at: outputURL)
        self.layout = layout
        canvas = CGRect(x: 0, y: 0, width: layout.width, height: layout.height)
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        // 底层是大片模糊色块，很好压：HEVC 每像素 2.5 bit/s 已经看不出块，缓存文件也只有 H.264 的一半左右。
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: layout.width,
            AVVideoHeightKey: layout.height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(1_000_000, layout.width * layout.height * 5 / 2),
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: layout.width,
                kCVPixelBufferHeightKey as String: layout.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
        )
        guard writer.canAdd(input) else { throw MotionCoverImportError.failed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MotionCoverImportError.failed }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ frame: CIImage, at time: CMTime) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? MotionCoverImportError.failed }
            try await Task.sleep(for: .milliseconds(5))
        }
        try autoreleasepool {
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? MotionCoverImportError.failed }
            var created: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
                  let buffer = created else { throw MotionCoverImportError.failed }
            context.render(
                LockScreenSquareInTallComposer.compose(frame, layout: layout),
                to: buffer,
                bounds: canvas,
                colorSpace: LockScreenSquareInTallComposer.outputColorSpace
            )
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? MotionCoverImportError.failed
            }
        }
    }

    func finish(at end: CMTime) async throws {
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MotionCoverImportError.failed }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
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
