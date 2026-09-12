import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import CarPlay
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
import WidgetKit
#endif

extension AudioPlayerService {
    func bumpCoverRevision() {
        coverRevision &+= 1
    }

    /// 标识一份 nowPlayingInfo 快照里"除歌词行与进度之外"的全部内容。只有
    /// 这些值都没变时, 歌词行推进才可以复用上一份字典和同一个封面对象。
    struct NowPlayingInfoSnapshotKey: Equatable {
        let songID: String
        let artworkRevision: Int
        let albumTitle: String
        let duration: TimeInterval
        let isLiveStream: Bool
        let isMusicVideo: Bool
        let queueCount: Int
        let queueIndex: Int
    }

    func updateNowPlayingInfo(
        artwork: MPMediaItemArtwork? = nil,
        artworkSongID: String? = nil,
        lyricsLineOnly: Bool = false
    ) {
        let signpost = PrimuseSignposts.hitch.beginInterval("player.nowPlayingPublish")
        defer { PrimuseSignposts.hitch.endInterval("player.nowPlayingPublish", signpost) }
        #if os(iOS)
        publishLyricsActivityProbe()
        #endif
        let actualPlaybackIsActive = isPlaybackActuallyActive
        lastPublishedPlaybackWasActive = actualPlaybackIsActive
        let preferredRate = !isSystemAudioPlaybackActive && playbackSettings.outputMode == .effects
            ? Double(playbackSettings.playbackRate)
            : 1
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: currentSong != nil,
            isPlaying: actualPlaybackIsActive,
            isLoading: isLoading,
            preferredPlaybackRate: preferredRate
        )
        synchronizeRemoteCommandAvailability(projection)

        guard currentSong != nil else {
            clearNowPlayingInfo()
            return
        }
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()

        #if os(iOS)
        // 歌词行推进只改标题/副标题与进度。复用上一份快照与其中同一个
        // MPMediaItemArtwork 实例, MediaRemote 就不必在主线程上重新序列化
        // 768 px 位图; 快照身份不一致时照常走下面的完整重建。
        if lyricsLineOnly,
           artwork == nil,
           let cachedKey = cachedNowPlayingInfoKey,
           cachedKey == currentNowPlayingInfoSnapshotKey(),
           var info = cachedNowPlayingInfo {
            let lyricsPresentation = lockScreenLyricsPresentation()
            info[MPMediaItemPropertyTitle] = lyricsPresentation.title
            info[MPMediaItemPropertyArtist] = lyricsPresentation.artist
            info[MPNowPlayingInfoPropertyPlaybackRate] = projection.playbackRate
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(
                0,
                min(currentTime, duration > 0 ? duration : currentTime)
            )
            nowPlayingCenter.nowPlayingInfo = info
            cachedNowPlayingInfo = info
            lastPublishedLockScreenLyricsPresentation = lyricsPresentation
            noteLockScreenLyricsPublished()
            return
        }
        #endif

        // Build a fresh snapshot; artwork is carried forward only when its
        // ownership still matches the current song.
        var info = [String: Any]()
        var publishedTitle = currentSong?.title ?? ""
        var publishedArtist = displayedArtistName(for: currentSong) ?? ""
        #if os(iOS)
        let lyricsPresentation = lockScreenLyricsPresentation()
        publishedTitle = lyricsPresentation.title
        publishedArtist = lyricsPresentation.artist
        lastPublishedLockScreenLyricsPresentation = lyricsPresentation
        #endif
        info[MPMediaItemPropertyTitle] = publishedTitle
        info[MPMediaItemPropertyArtist] = publishedArtist
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = currentSong?.id
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = projection.playbackRate
        info[MPNowPlayingInfoPropertyMediaType] = isMusicVideoPlaybackActive
            ? MPNowPlayingInfoMediaType.video.rawValue
            : MPNowPlayingInfoMediaType.audio.rawValue
        if isLiveRadio {
            info[MPMediaItemPropertyAlbumTitle] = currentRadioStation?.name ?? ""
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            let elapsedTime = max(0, min(currentTime, duration > 0 ? duration : currentTime))
            info[MPMediaItemPropertyAlbumTitle] = currentSong?.albumTitle ?? ""
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsedTime
        }
        if !isLiveRadio, queueEntries.indices.contains(currentIndex) {
            info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queueEntries.count
            info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
        }

        // Publish asynchronously resolved artwork together with the complete
        // current-track snapshot. Ordinary progress/state refreshes may reuse
        // it only while it still belongs to this same song.
        if let artwork,
           artworkSongID == currentSong?.id {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if NowPlayingArtworkPublicationPolicy.shouldReuseArtwork(
            ownedBy: publishedArtworkSongID,
            for: currentSong?.id
        ), let existingArtwork = nowPlayingCenter.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = existingArtwork
        } else if let songID = currentSong?.id,
                  let cachedArtwork = nowPlayingArtworkCache.object(forKey: songID as NSString) {
            // 切歌后的第一份快照必须已带新歌封面: 蓝牙 AVRCP 车机只在这
            // 一刻采样封面, 之后同曲目的补发不会被重新拉取。
            info[MPMediaItemPropertyArtwork] = cachedArtwork
            publishedArtworkSongID = songID
        }

        nowPlayingCenter.nowPlayingInfo = info
        // 记住这份完整快照与它携带的封面对象: 下一次歌词行推进直接在它上面
        // 改两个字符串和进度, 不再重建字典, 也不再换封面。
        let publishedArtwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        if publishedArtwork !== cachedNowPlayingArtwork {
            cachedNowPlayingArtwork = publishedArtwork
            nowPlayingArtworkRevision &+= 1
        }
        cachedNowPlayingInfo = info
        cachedNowPlayingInfoKey = currentNowPlayingInfoSnapshotKey()
        #if os(iOS)
        noteLockScreenLyricsPublished()
        #endif
        #if os(macOS)
        nowPlayingCenter.playbackState = actualPlaybackIsActive && !isLoading ? .playing : .paused
        #endif
    }

    private func currentNowPlayingInfoSnapshotKey() -> NowPlayingInfoSnapshotKey? {
        guard let songID = currentSong?.id else { return nil }
        let hasQueuePosition = !isLiveRadio && queueEntries.indices.contains(currentIndex)
        return NowPlayingInfoSnapshotKey(
            songID: songID,
            artworkRevision: nowPlayingArtworkRevision,
            albumTitle: (isLiveRadio ? currentRadioStation?.name : currentSong?.albumTitle) ?? "",
            duration: duration,
            isLiveStream: isLiveRadio,
            isMusicVideo: isMusicVideoPlaybackActive,
            queueCount: hasQueuePosition ? queueEntries.count : 0,
            queueIndex: hasQueuePosition ? currentIndex : -1
        )
    }

    /// 丢弃增量发布用的快照缓存。任何绕过 `updateNowPlayingInfo` 改动系统
    /// 快照的地方都必须调用它, 下一次发布会重新构建完整字典。
    private func invalidateCachedNowPlayingInfo() {
        cachedNowPlayingInfo = nil
        cachedNowPlayingInfoKey = nil
        cachedNowPlayingArtwork = nil
        nowPlayingArtworkRevision &+= 1
    }

    #if os(iOS)
    /// 任何一次完整或增量发布都重置歌词限流窗口, 并清掉待补发标记。
    private func noteLockScreenLyricsPublished() {
        lastLockScreenLyricsPublishAt = Date()
        pendingLockScreenLyricsPublish = false
    }
    #endif

    func clearNowPlayingInfo() {
        nowPlayingArtworkLoadTask?.cancel()
        nowPlayingArtworkLoadTask = nil
        nowPlayingArtworkPrefetchTask?.cancel()
        nowPlayingArtworkPrefetchTask = nil
        prefetchingArtworkSongID = nil
        nowPlayingArtworkLoadTokens.removeAll()
        lastArtworkSongID = nil
        publishedArtworkSongID = nil
        invalidateCachedNowPlayingInfo()
        let nowPlayingCenter = MPNowPlayingInfoCenter.default()
        nowPlayingCenter.nowPlayingInfo = nil
        #if os(macOS)
        nowPlayingCenter.playbackState = .stopped
        #endif
    }

    /// 远程控制中心各命令的可用性投影。每个属性写入都是一次 MediaRemote
    /// XPC, 而歌词行推进每隔几秒就会走一遍发布路径 —— 先把状态投影出来,
    /// 只有真的变了才写。
    struct RemoteCommandAvailability: Equatable {
        let play: Bool
        let pause: Bool
        let togglePlayPause: Bool
        let changePlaybackPosition: Bool
        let nextTrack: Bool
        let previousTrack: Bool
        let like: Bool
        let likeIsActive: Bool
    }

    private func synchronizeRemoteCommandAvailability(
        _ projection: NowPlayingPlaybackProjection
    ) {
        #if os(iOS)
        let canLikeCurrentSong = !isLiveRadio
            && currentSong.flatMap { library?.song(id: $0.id) } != nil
        let likeIsActive = canLikeCurrentSong
            && (currentSong.map { library?.isLiked(songID: $0.id) ?? false } ?? false)
        #else
        let canLikeCurrentSong = false
        let likeIsActive = false
        #endif
        let availability = RemoteCommandAvailability(
            play: projection.playCommandEnabled,
            pause: projection.pauseCommandEnabled,
            togglePlayPause: currentSong != nil,
            changePlaybackPosition: playbackCapabilities.canSeek,
            nextTrack: !isLiveRadio || radioStationOrder.count > 1,
            previousTrack: !isLiveRadio || radioStationOrder.count > 1,
            like: canLikeCurrentSong,
            likeIsActive: likeIsActive
        )
        // 本进程是这些属性的唯一写者, 缓存值因此就是系统当前状态。切歌、
        // 队列变化、喜欢状态变化都会让投影变化并立刻写下去。
        guard availability != lastWrittenRemoteCommandAvailability else { return }
        lastWrittenRemoteCommandAvailability = availability

        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = availability.play
        center.pauseCommand.isEnabled = availability.pause
        center.togglePlayPauseCommand.isEnabled = availability.togglePlayPause
        center.changePlaybackPositionCommand.isEnabled = availability.changePlaybackPosition
        center.nextTrackCommand.isEnabled = availability.nextTrack
        center.previousTrackCommand.isEnabled = availability.previousTrack
        #if os(iOS)
        center.likeCommand.isEnabled = availability.like
        center.likeCommand.isActive = availability.likeIsActive
        #endif
    }

    /// Loads cover art for a track transition or an explicit same-track refresh.
    func updateNowPlayingArtworkIfNeeded(
        forceReload: Bool = false,
        preservingCurrentArtworkWhileLoading: Bool = false
    ) {
        let songID = currentSong?.id
        guard forceReload || songID != lastArtworkSongID else { return }
        // A token prevents stale publication, but it does not stop the old
        // ImageIO work. Cancel both the former current-song load and its
        // speculative prefetch before starting the new track so rapid skips
        // cannot accumulate sustained decode work on SpringBoard's behalf.
        nowPlayingArtworkLoadTask?.cancel()
        nowPlayingArtworkLoadTask = nil
        nowPlayingArtworkPrefetchTask?.cancel()
        nowPlayingArtworkPrefetchTask = nil
        prefetchingArtworkSongID = nil
        nowPlayingArtworkLoadTokens.removeAll()
        lastArtworkSongID = songID

        let shouldClearArtwork = NowPlayingArtworkPublicationPolicy
            .shouldClearArtworkBeforeLoading(
                isSameItemRefresh: preservingCurrentArtworkWhileLoading
            )
        if shouldClearArtwork {
            publishedArtworkSongID = nil
            // 缓存的那份快照还带着上一张封面; 让下一次发布重建完整快照,
            // 否则歌词行的增量发布会把已经撤下的封面又贴回去。
            invalidateCachedNowPlayingInfo()
        }

        // 内存缓存命中: 立即随完整快照发布新歌封面, 不经过"无封面"的
        // 中间态 —— 蓝牙车机只会采样切歌那一刻的快照。
        if let songID,
           let cachedArtwork = nowPlayingArtworkCache.object(forKey: songID as NSString) {
            publishedArtworkSongID = songID
            updateNowPlayingInfo(artwork: cachedArtwork, artworkSongID: songID)
            prefetchUpcomingNowPlayingArtwork()
            return
        }

        // A track transition must drop the previous song's image immediately.
        // A same-track refresh does the opposite: keep the current complete
        // snapshot until the replacement has decoded, then publish the new
        // MPMediaItemArtwork in one assignment. Bluetooth AVRCP head units may
        // otherwise sample the temporary nil and ignore the later same-track
        // artwork update.
        if shouldClearArtwork {
            var nowInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            nowInfo[MPMediaItemPropertyArtwork] = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowInfo
            invalidateCachedNowPlayingInfo()
        }

        guard let songID else { return }
        let loadToken = UUID()
        nowPlayingArtworkLoadTokens[songID] = loadToken
        let coverRef = currentSong?.coverArtFileName
        let capturedSourceID = currentSong?.sourceID
        let capturedFilePath = currentSong?.filePath
        let capturedFileFormat = currentSong?.fileFormat
        let capturedSourceManager = sourceManager

        nowPlayingArtworkLoadTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard self != nil else { return }
            let loadedImage = await Self.loadSystemArtworkImage(
                songID: songID,
                coverRef: coverRef,
                sourceID: capturedSourceID,
                filePath: capturedFilePath,
                fileFormat: capturedFileFormat,
                sourceManager: capturedSourceManager
            )
            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.nowPlayingArtworkLoadTokens[songID] == loadToken else { return }
                self.nowPlayingArtworkLoadTask = nil
                self.nowPlayingArtworkLoadTokens[songID] = nil
                if let image = loadedImage {
                    // 歌已切走也照样入缓存: 切回来 / 之后再播到这首时,
                    // 第一份快照就能同步带图。
                    self.nowPlayingArtworkCache.setObject(
                        Self.makeArtwork(from: image),
                        forKey: songID as NSString,
                        cost: Self.nowPlayingArtworkCost(image)
                    )
                }
                guard self.currentSong?.id == songID else { return }
                if let artwork = self.nowPlayingArtworkCache.object(forKey: songID as NSString) {
                    self.publishedArtworkSongID = songID
                    self.updateNowPlayingInfo(artwork: artwork, artworkSongID: songID)
                } else if shouldClearArtwork {
                    self.publishedArtworkSongID = nil
                    self.updateNowPlayingInfo()
                } else {
                    // Reload failure is not permission to discard the artwork
                    // already published for this same item.
                    self.updateNowPlayingInfo()
                }
                self.prefetchUpcomingNowPlayingArtwork()
            }
        }
    }

    /// 预载队列下一首的封面进内存缓存。前进到该曲目时, 切歌后的第一份
    /// 系统快照就能同步带上封面(蓝牙车机唯一的采样时机)。shuffle 的
    /// 下一首由 nextSongInQueue 与真实前进路径保持一致。
    private func prefetchUpcomingNowPlayingArtwork() {
        guard !isLiveRadio, !isCastingMode else { return }
        guard let next = nextSongInQueue(),
              !next.id.isEmpty,
              next.id != currentSong?.id else { return }
        guard nowPlayingArtworkCache.object(forKey: next.id as NSString) == nil else { return }
        guard prefetchingArtworkSongID != next.id else { return }
        prefetchingArtworkSongID = next.id

        let songID = next.id
        let coverRef = next.coverArtFileName
        let sourceID = next.sourceID
        let filePath = next.filePath
        let fileFormat = next.fileFormat
        let capturedSourceManager = sourceManager
        nowPlayingArtworkPrefetchTask = Task.detached(priority: .utility) { [weak self] in
            guard self != nil else { return }
            let image = await Self.loadSystemArtworkImage(
                songID: songID,
                coverRef: coverRef,
                sourceID: sourceID,
                filePath: filePath,
                fileFormat: fileFormat,
                sourceManager: capturedSourceManager
            )
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if self.prefetchingArtworkSongID == songID {
                    self.prefetchingArtworkSongID = nil
                    self.nowPlayingArtworkPrefetchTask = nil
                }
                if let image {
                    self.nowPlayingArtworkCache.setObject(
                        Self.makeArtwork(from: image),
                        forKey: songID as NSString,
                        cost: Self.nowPlayingArtworkCost(image)
                    )
                }
            }
        }
    }

    /// Tier 1-4 逐级解析系统封面。命中网络/内嵌数据时把原图写入磁盘缓存,
    /// 返回值统一走降采样解码。detached 上下文执行。
    nonisolated private static func loadSystemArtworkImage(
        songID: String,
        coverRef: String?,
        sourceID: String?,
        filePath: String?,
        fileFormat: AudioFormat?,
        sourceManager: SourceManager?
    ) async -> PlatformImage? {
        guard !Task.isCancelled else { return nil }
        let store = MetadataAssetStore.shared

        // Tier 1: songID-based cache (透明处理 content-addressed redirect)
        let hashedName = store.expectedCoverFileName(for: songID)
        if let data = store.readCoverData(named: hashedName) {
            guard !Task.isCancelled else { return nil }
            if let image = decodeArtworkImage(from: data) {
                return image
            }
            await store.invalidateCoverCache(forSongID: songID)
        }

        // Tier 2: legacy filename (local hashed filename, no "/" or "://")
        if let coverRef, !coverRef.isEmpty,
           !coverRef.contains("/"), !coverRef.contains("://"),
           let data = store.readCoverData(named: coverRef),
           !Task.isCancelled,
           let image = decodeArtworkImage(from: data) {
            return image
        }

        // Tier 3: source fetch — URL reference or sidecar path
        if let coverRef, !coverRef.isEmpty {
            var fetchedData: Data?
            // A source-owned absolute URL may contain the LAN endpoint used by
            // yesterday's scan. Download through the adaptive connector so the
            // Now Playing/full-screen path gets the same route validation and
            // failover as in-app artwork views.
            if let sourceID, let sourceManager {
                fetchedData = await sourceManager.artworkData(
                    for: coverRef,
                    sourceID: sourceID,
                    maximumBytes: 8 * 1024 * 1024
                )
            } else if coverRef.contains("://"), let url = URL(string: coverRef) {
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 10
                let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                if let result = try? await TrustedHTTPTransport.data(
                    from: url,
                    session: session,
                    maxBytes: 8 * 1024 * 1024
                ), let http = result.1 as? HTTPURLResponse,
                   (200...299).contains(http.statusCode) {
                    fetchedData = result.0
                }
            }

            if let data = fetchedData, let image = decodeArtworkImage(from: data) {
                guard !Task.isCancelled else { return nil }
                await store.cacheCover(data, forSongID: songID)
                return image
            }
        }

        // Tier 4: embedded cover extraction from locally cached audio file
        if let sourceID, let filePath, let sourceManager {
            let inferredFormat = fileFormat
                ?? AudioFormat.from(fileExtension: (filePath as NSString).pathExtension)
                ?? .mp3
            let dummySong = Song(id: "", title: "", fileFormat: inferredFormat, filePath: filePath,
                                 sourceID: sourceID, fileSize: 0, dateAdded: Date())
            if let cachedURL = await sourceManager.cachedURL(for: dummySong) {
                guard !Task.isCancelled else { return nil }
                let metadata = await FileMetadataReader.read(from: cachedURL)
                if let coverData = metadata.coverArtData {
                    guard !Task.isCancelled else { return nil }
                    await store.cacheCover(coverData, forSongID: songID)
                    return decodeArtworkImage(from: coverData)
                }
            }
        }
        return nil
    }

    /// 从原始图片数据解码封面, 统一降采样到 ≤768px 并强制立即解码。
    /// 锁屏/车机的显示尺寸远小于原图; 蓝牙 AVRCP 封面走 OBEX 慢速通道,
    /// 超大位图会显著拖慢传输甚至失败, 懒解码则会把解码开销转嫁给
    /// MPMediaItemArtwork 的系统回调队列。
    nonisolated private static func decodeArtworkImage(from data: Data) -> PlatformImage? {
        guard !Task.isCancelled,
              data.count <= 16 * 1_024 * 1_024,
              ArtworkImageCompatibility.isCompleteImage(data),
              !ArtworkImageCompatibility.hasRedundantJPEGSampling(data) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 768,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        #if os(iOS)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #endif
    }

    /// Force-refreshes Now Playing artwork after an in-place cover replacement.
    /// The old published image remains visible until the new image is ready.
    func forceRefreshNowPlayingArtwork() {
        if let songID = currentSong?.id {
            nowPlayingArtworkCache.removeObject(forKey: songID as NSString)
        }
        bumpCoverRevision()
        updateNowPlayingArtworkIfNeeded(
            forceReload: true,
            preservingCurrentArtworkWhileLoading: true
        )
    }

    /// Artwork extraction can finish after playback has already attempted its
    /// initial lookup. Retry the system Now Playing artwork once the song-ID
    /// cache becomes available without treating it as an explicit replacement.
    func retryNowPlayingArtwork(afterCachingSongID songID: String) {
        guard currentSong?.id == songID else { return }
        nowPlayingArtworkCache.removeObject(forKey: songID as NSString)
        updateNowPlayingArtworkIfNeeded(
            forceReload: true,
            preservingCurrentArtworkWhileLoading: true
        )
    }

    func updateNowPlayingArtwork(_ image: PlatformImage) {
        guard let songID = currentSong?.id else { return }
        lastArtworkSongID = songID
        publishedArtworkSongID = songID
        let artwork = Self.makeArtwork(from: image)
        nowPlayingArtworkCache.setObject(
            artwork,
            forKey: songID as NSString,
            cost: Self.nowPlayingArtworkCost(image)
        )
        updateNowPlayingInfo(
            artwork: artwork,
            artworkSongID: songID
        )
    }

    /// Creates MPMediaItemArtwork with a non-isolated requestHandler closure.
    /// Must be nonisolated so the closure doesn't inherit @MainActor isolation —
    /// MediaPlayer calls the handler on a background dispatch queue.
    nonisolated private static func makeArtwork(from image: PlatformImage) -> MPMediaItemArtwork {
        let safeImage = image
        return MPMediaItemArtwork(boundsSize: image.size) { _ in safeImage }
    }

    nonisolated private static func nowPlayingArtworkCost(_ image: PlatformImage) -> Int {
        #if os(iOS)
        if let cgImage = image.cgImage {
            return cgImage.bytesPerRow * cgImage.height
        }
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        return max(0, Int(pixelWidth * pixelHeight * 4))
        #else
        return max(0, Int(image.size.width * image.size.height * 4))
        #endif
    }
}
