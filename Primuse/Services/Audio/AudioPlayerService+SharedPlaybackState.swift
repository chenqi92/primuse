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
    // MARK: - Shared Playback State

    /// Restores only queue/navigation context. Relaunching never starts audio
    /// on its own; a later Play command rebuilds the decoder at the saved time.
    func restorePlaybackSessionIfAvailable() async {
        let restoreStartedAt = ProcessInfo.processInfo.systemUptime
        guard let restoreToken = playbackSessionRestoreLifecycle.begin() else { return }
        defer { playbackSessionRestoreLifecycle.complete(token: restoreToken) }
        guard let library else { return }
        let initialQueueGeneration = queueGeneration
        let initialAdvanceGeneration = playbackAdvancePolicy.generation
        let visibleSongs = library.visibleSongs
        let store = playbackSessionStore
        let preparationTask = Task<PreparedPlaybackSessionRestore?, Never>.detached(priority: .userInitiated) {
            let snapshot: PlaybackSessionSnapshot
            do {
                guard let loaded = try store.load() else { return nil }
                snapshot = loaded
            } catch {
                plog("⚠️ Playback session load failed: \(error.localizedDescription)")
                return nil
            }
            let loadFinishedAt = ProcessInfo.processInfo.systemUptime

            var playableSongsByID: [String: Song] = [:]
            playableSongsByID.reserveCapacity(visibleSongs.count)
            for song in visibleSongs where song.isPlayable && playableSongsByID[song.id] == nil {
                playableSongsByID[song.id] = song
            }
            guard let plan = PlaybackSessionRestorationPolicy.plan(
                snapshot: snapshot,
                availableSongIDs: Set(playableSongsByID.keys)
            ) else {
                plog("⚠️ Playback session ignored because its current track is unavailable or invalid")
                return nil
            }
            let planFinishedAt = ProcessInfo.processInfo.systemUptime

            let entries = plan.queueSongIDs.compactMap { songID in
                playableSongsByID[songID].map { QueueEntry(song: $0) }
            }
            guard entries.count == plan.queueSongIDs.count,
                  entries.indices.contains(plan.currentIndex) else { return nil }
            return PreparedPlaybackSessionRestore(
                plan: plan,
                entries: entries,
                loadFinishedAt: loadFinishedAt,
                planFinishedAt: planFinishedAt,
                lookupFinishedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        let prepared = await preparationTask.value
        guard let prepared else { return }

        // The user may have started a new queue while the old session was being
        // decoded off-main. Never let delayed restoration replace live intent.
        guard playbackSessionRestoreLifecycle.permitsApply(token: restoreToken),
              queueGeneration == initialQueueGeneration,
              playbackAdvancePolicy.generation == initialAdvanceGeneration,
              currentSong == nil,
              queueEntries.isEmpty else { return }
        let plan = prepared.plan

        isRestoringPlaybackSession = true
        defer { isRestoringPlaybackSession = false }
        queueEntries = prepared.entries
        currentIndex = plan.currentIndex
        // Apply these while currentSong is nil so restoring an Apple Music
        // item cannot write into ApplicationMusicPlayer during AppServices init.
        shuffleEnabled = plan.shuffleEnabled
        repeatMode = plan.repeatMode
        shuffledIndices = plan.shuffledIndices
        shufflePosition = plan.shufflePosition
        pendingNextShuffleIndices = plan.pendingNextShuffleIndices

        let song = prepared.entries[plan.currentIndex].song
        currentSong = song
        duration = song.duration.isFinite && song.duration > 0
            ? song.duration
            : plan.duration
        currentTime = duration > 0 ? min(plan.currentTime, duration) : plan.currentTime
        isPlaying = plan.shouldStartPlayback
        isLoading = false
        isAtTrackEnd = plan.isAtTrackEnd
        hasPreparedLocalPlayback = false
        pendingRecoveryTime = currentTime
        needsPlaybackRecovery = currentTime > 0 && !isAtTrackEnd
        pendingRecoveryIsColdSessionRestore = needsPlaybackRecovery
        interruptionResumePolicy = PlaybackInterruptionResumePolicy()
        playbackAdvancePolicy = PlaybackAdvanceEligibilityPolicy()
        localPipelineAdvanceTicket = nil
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        let restoreFinishedAt = ProcessInfo.processInfo.systemUptime
        plog(String(
            format: "▶️ Restored paused playback session: queue=%d index=%d shuffle=%@ position=%d total=%.0fms load=%.0f plan=%.0f lookup=%.0f apply=%.0f",
            queueEntries.count,
            currentIndex,
            String(shuffleEnabled),
            shufflePosition,
            (restoreFinishedAt - restoreStartedAt) * 1_000,
            (prepared.loadFinishedAt - restoreStartedAt) * 1_000,
            (prepared.planFinishedAt - prepared.loadFinishedAt) * 1_000,
            (prepared.lookupFinishedAt - prepared.planFinishedAt) * 1_000,
            (restoreFinishedAt - prepared.lookupFinishedAt) * 1_000
        ))
    }

    /// Installs a Handoff selection without starting any audio pipeline. The
    /// caller has already stopped the previous transport and restored queue
    /// context; a later explicit Play rebuilds at this saved position.
    func stagePausedHandoff(song: Song, at time: TimeInterval) {
        registerPauseOrStopIntent()
        playbackKind = .track
        playID = UUID()
        playbackAdvancePolicy = PlaybackAdvanceEligibilityPolicy()
        localPipelineAdvanceTicket = nil
        currentSong = song
        duration = song.duration.sanitizedDuration
        currentTime = duration > 0 ? min(max(0, time), duration) : max(0, time)
        isPlaying = false
        isLoading = false
        isAtTrackEnd = false
        hasPreparedLocalPlayback = false
        pendingRecoveryTime = currentTime
        needsPlaybackRecovery = currentTime > 0
        pendingRecoveryIsColdSessionRestore = needsPlaybackRecovery
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
    }

    func persistPlaybackSession(
        clearWhenEmpty: Bool = false,
        flushImmediately: Bool = false
    ) {
        let signpost = PrimuseSignposts.hitch.beginInterval("player.sessionPersist")
        defer { PrimuseSignposts.hitch.endInterval("player.sessionPersist", signpost) }
        // 退到后台这类切换必须在返回前把在飞的写入排干。下面的提前返回(正在
        // 恢复 / 直播流 / 空状态还不允许清空)都不会再提交新请求, 但上一次
        // save 可能还停在后台任务里, 而进程马上就要被挂起。
        var didDrainSynchronously = false
        defer {
            if flushImmediately, !didDrainSynchronously {
                Self.reportPlaybackSessionPersistence(playbackSessionPersistence.drain())
            }
        }
        guard !isRestoringPlaybackSession else { return }
        guard !isLiveRadio else { return }
        guard let song = currentSong else {
            guard clearWhenEmpty else { return }
            guard playbackSessionRestoreLifecycle.permitsEmptySessionClear else {
                // During launch, scene activation publishes an empty player
                // before deferred restoration has loaded its snapshot. That is
                // transient UI state, not an explicit Stop request.
                return
            }
            submitPlaybackSessionPersistence(.clear, flushImmediately: flushImmediately)
            didDrainSynchronously = flushImmediately
            return
        }

        let snapshotQueueIDs: [String]
        let snapshotCurrentIndex: Int
        let snapshotShuffleOrder: [Int]
        let snapshotShufflePosition: Int
        let snapshotPendingOrder: [Int]?
        if queueEntries.indices.contains(currentIndex),
           queueEntries[currentIndex].song.id == song.id {
            snapshotQueueIDs = queueEntries.map(\.song.id)
            snapshotCurrentIndex = currentIndex
            snapshotShuffleOrder = shuffleEnabled ? shuffledIndices : []
            snapshotShufflePosition = shuffleEnabled ? shufflePosition : 0
            snapshotPendingOrder = shuffleEnabled ? pendingNextShuffleIndices : nil
        } else {
            // Direct playback can briefly have no canonical queue. Persisting
            // a one-item queue still restores the selected track safely.
            snapshotQueueIDs = [song.id]
            snapshotCurrentIndex = 0
            snapshotShuffleOrder = shuffleEnabled ? [0] : []
            snapshotShufflePosition = 0
            snapshotPendingOrder = nil
        }

        let progress = isPlaying ? interpolatedTime() : currentTime
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: snapshotQueueIDs,
            currentSongID: song.id,
            currentIndex: snapshotCurrentIndex,
            currentTime: progress,
            duration: duration,
            wasPlaying: isPlaying,
            shuffleEnabled: shuffleEnabled,
            shuffledIndices: snapshotShuffleOrder,
            shufflePosition: snapshotShufflePosition,
            pendingNextShuffleIndices: snapshotPendingOrder,
            repeatMode: repeatMode,
            isAtTrackEnd: isAtTrackEnd
        )
        // 只有在协调器确认这一代(或更顶掉它的更新一代)真的落盘之后, 才允许
        // 后续的空状态清空旧快照: 写失败时上一次启动留下的有效快照必须保留。
        submitPlaybackSessionPersistence(
            .save(snapshot),
            flushImmediately: flushImmediately,
            promotesRestoreLifecycleOnSuccess: true
        )
        didDrainSynchronously = flushImmediately
    }

    /// 把最新状态交给后台写入协调器。`flushImmediately` 只给退到后台这类
    /// 生命周期切换用: 那一刻进程可能马上被挂起, 必须在返回前落盘。
    private func submitPlaybackSessionPersistence(
        _ request: PlaybackSessionPersistenceRequest,
        flushImmediately: Bool,
        promotesRestoreLifecycleOnSuccess: Bool = false
    ) {
        playbackSessionPersistGeneration &+= 1
        let generation = playbackSessionPersistGeneration
        let coordinator = playbackSessionPersistence
        coordinator.enqueue(request, generation: generation)
        guard !flushImmediately else {
            let outcome = coordinator.drain()
            Self.reportPlaybackSessionPersistence(outcome)
            if promotesRestoreLifecycleOnSuccess {
                promotePlaybackSessionRestoreLifecycle(
                    outcome,
                    requestedGeneration: generation
                )
            }
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let outcome = coordinator.drain()
            Self.reportPlaybackSessionPersistence(outcome)
            guard promotesRestoreLifecycleOnSuccess else { return }
            // 写盘发生在后台, 生命周期状态只属于主 actor, 因此回到主 actor
            // 再推进; 服务已经销毁时没有需要推进的状态。
            await self?.promotePlaybackSessionRestoreLifecycle(
                outcome,
                requestedGeneration: generation
            )
        }
    }

    /// 写入成功才把"当前会话已经落盘"的结论交给生命周期。协调器合并请求,
    /// 所以只要有不老于本次请求的一代落盘, 本次请求的状态就已经被更新的
    /// 状态取代, 同样满足"旧快照可以被替换"的前提。
    private func promotePlaybackSessionRestoreLifecycle(
        _ outcome: PlaybackSessionPersistenceOutcome,
        requestedGeneration: UInt64
    ) {
        guard outcome.persisted(generation: requestedGeneration) else { return }
        playbackSessionRestoreLifecycle.didPersistCurrentSession()
    }

    /// 写入合并之后无法把失败精确归给某一次请求(更新的状态会顶掉旧的),
    /// 因此保存与清空共用一条失败日志。
    private nonisolated static func reportPlaybackSessionPersistence(
        _ outcome: PlaybackSessionPersistenceOutcome
    ) {
        guard let failure = outcome.failureDescription else { return }
        plog("⚠️ Playback session persist failed: \(failure)")
    }

    /// macOS Widget Sync 设置页里 "立即更新" 按钮直接调这个。包装一下 private
     /// 的 updatePlaybackState, 让 mac 设置面板可以强制刷一遍 widget 状态而无需
     /// 把整个内部方法暴露成 public。
    func publishWidgetStateForMacWidgetSync() {
        updatePlaybackState()
    }

    func updatePlaybackState(flushPlaybackSessionImmediately: Bool = false) {
        persistPlaybackSession(
            clearWhenEmpty: currentSong == nil,
            flushImmediately: flushPlaybackSessionImmediately
        )
        #if os(macOS)
        let sampledCurrentTime = currentTime
        let sampledAt = Date()
        let request = MacWidgetPlaybackPublishRequest(
            currentSong: currentSong,
            artistDisplayName: displayedArtistName(for: currentSong),
            isPlaying: isPlaybackActuallyActive,
            sampledAt: sampledAt,
            currentTime: sampledCurrentTime,
            duration: duration,
            queueSongIDs: isLiveRadio ? [] : queue.map(\.id),
            playbackKind: playbackKind,
            radioStationID: currentRadioStation?.id,
            repeatMode: repeatMode,
            isLiked: currentSong.map { library?.isLiked(songID: $0.id) ?? false }
        )
        Task {
            await MacWidgetPlaybackPublisher.shared.enqueue(request)
        }
        return
        #else
        // 非 macOS 分支整段(封面写盘 + RecentAlbums + PlaybackState)都在
        // 主 actor 上同步跑, 每次切歌 / gapless / 交叉淡入边界各一次。
        let widgetPublishSignpost = PrimuseSignposts.hitch.beginInterval("player.widgetPublish")
        defer { PrimuseSignposts.hitch.endInterval("player.widgetPublish", widgetPublishSignpost) }
        #if os(iOS)
        refreshInstalledLyricsWidgetDemand()
        #endif
        guard WidgetSettings.syncEnabled(),
              WidgetSettings.widgetEnabled(PrimuseConstants.widgetNowPlayingEnabledKey) else {
            PlaybackState.clear()
            #if os(iOS)
            publishWidgetLyricsIfNeeded()
            #endif
            WidgetCenter.shared.reloadAllTimelines()
            return
        }

        // Privacy scope: the user can narrow what's published into the App
        // Group container. `includesCover` gates the cover files; `includesProgress`
        // gates currentTime/duration. (`includesLyrics` is enforced by the
        // lyrics publisher, not here.)
        let scope = WidgetSettings.sharedDataScope()

        var coverName: String?
        var recentAlbumsChanged = false
        let recentAlbumsEnabled = scope.includesCover
            && WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey)

        if !scope.includesCover {
            // Scope narrowed below `cover`: never write cover art, and purge any
            // files left from a wider scope so the WidgetKit extension can't keep
            // disclosing album art the user opted out of.
            clearSharedWidgetCovers()
            lastWidgetCoverSongID = nil
            if WidgetSettings.widgetEnabled(PrimuseConstants.widgetRecentAlbumsEnabledKey),
               !RecentAlbumsStore.load().isEmpty {
                // Recent-albums widget renders covers; with covers disclosed off
                // there's nothing meaningful to show, so clear its store too.
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else if let song = currentSong {
            let sharedCoverName = "widget_cover.png"
            let needsSharedCoverRefresh = song.id != lastWidgetCoverSongID || !sharedWidgetCoverExists(named: sharedCoverName)

            if needsSharedCoverRefresh {
                if let writtenCoverName = writeWidgetCover(song: song, fileName: sharedCoverName) {
                    coverName = writtenCoverName
                    lastWidgetCoverSongID = song.id
                } else {
                    // Current song has no usable cover. Any existing
                    // widget_cover.png belongs to the *previous* song, so
                    // reusing it would show the wrong album art for this whole
                    // track. Delete it and leave coverName nil so the widget
                    // falls back to its placeholder gradient; keep
                    // lastWidgetCoverSongID nil so the next event retries.
                    removeSharedWidgetCover(named: sharedCoverName)
                    lastWidgetCoverSongID = nil
                }

                if recentAlbumsEnabled, let albumEntry = makeRecentAlbumEntry(for: song) {
                    if let albumCoverName = albumEntry.coverImageName,
                       !sharedWidgetCoverExists(named: albumCoverName) {
                        _ = writeWidgetCover(song: song, fileName: albumCoverName, size: 200)
                    }
                    RecentAlbumsStore.record(albumEntry)
                    recentAlbumsChanged = true
                }
            } else {
                coverName = sharedCoverName
            }
            if !recentAlbumsEnabled {
                RecentAlbumsStore.clear()
                recentAlbumsChanged = true
            }
        } else {
            lastWidgetCoverSongID = nil
        }

        let sampledCurrentTime = scope.includesProgress ? currentTime : 0
        let sampledAt = Date()
        let state = PlaybackState(
            currentSongID: currentSong?.id,
            songTitle: currentSong?.title,
            artistName: displayedArtistName(for: currentSong),
            albumTitle: currentSong?.albumTitle,
            fileFormat: currentSong.map { $0.fileFormat.displayName },
            coverImageName: coverName,
            isPlaying: isPlaybackActuallyActive,
            // Progress gated by scope: omit currentTime/duration when the user
            // hasn't granted progress disclosure (defaults to 0 via the init).
            currentTime: sampledCurrentTime,
            duration: scope.includesProgress ? duration : 0,
            queueSongIDs: isLiveRadio ? [] : queue.map(\.id),
            playbackKind: playbackKind,
            radioStationID: currentRadioStation?.id,
            repeatMode: repeatMode,
            // 锁屏 widget / Live Activity 只能渲染这颗心, 解析不了 —— 曲库在
            // 主 app 沙盒里, 必须由这里发布出去。
            isLiked: currentSong.map { library?.isLiked(songID: $0.id) ?? false },
            updatedAt: sampledAt
        )
        state.save()
        #if os(iOS)
        publishWidgetLyricsIfNeeded(coverImageName: coverName)
        #endif

        let timelineSignature = widgetTimelineSignature(for: state)
        if recentAlbumsChanged || timelineSignature != lastWidgetTimelineSignature {
            lastWidgetTimelineSignature = timelineSignature
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    /// 喜欢状态在锁屏 widget 上有一份副本, 从 intent 改完库以后要立刻重新
    /// 发布, 否则乐观 UI 会被下一次刷新的旧数据打回去。
    func republishNowPlayingSurfaces() {
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    /// Writes a cover image to the App Group shared container for Widget rendering.
    /// Returns the filename if successful.
    ///
    /// iOS 与 macOS 共用同一 App Group 路径与文件名约定; widget 扩展的
    /// WidgetCoverImageView / RecentAlbumCoverView 只按 coverImageName 从
    /// App Group 容器读 JPEG, 两端别无他路, 故 macOS 也必须落盘真实封面,
    /// 否则桌面 widget 永远只显示占位渐变。
    @discardableResult
    private func writeWidgetCover(song: Song, fileName: String, size: CGFloat = 300) -> String? {
        // 封面解码 / 重绘 / JPEG 编码 / 原子写盘目前都在主 actor 上完成,
        // 先把这段开销标成独立区间, 设备上才能量出它在切歌时占了多少帧。
        let coverSignpost = PrimuseSignposts.hitch.beginInterval("player.widgetCover")
        defer { PrimuseSignposts.hitch.endInterval("player.widgetCover", coverSignpost) }
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return nil }

        let store = MetadataAssetStore.shared

        // Try songID-based cache first (透明处理 content-addressed redirect)
        var coverData: Data?
        let hashedName = store.expectedCoverFileName(for: song.id)
        coverData = store.readCoverData(named: hashedName)

        // Fallback: legacy local filename
        if coverData == nil, let ref = song.coverArtFileName, !ref.isEmpty,
           !ref.contains("/"), !ref.contains("://") {
            coverData = store.readCoverData(named: ref)
        }

        guard let data = coverData else { return nil }

        let targetSize = CGSize(width: size, height: size)
        let destinationURL = containerURL.appendingPathComponent(fileName)

        /// Aspect-fill (centered crop) rect for `sourceSize` into `targetSize`.
        func aspectFillRect(sourceSize: CGSize) -> CGRect {
            let sourceAspect = sourceSize.width / sourceSize.height
            if sourceAspect > 1 {
                let scaledWidth = targetSize.height * sourceAspect
                return CGRect(x: (targetSize.width - scaledWidth) / 2, y: 0,
                              width: scaledWidth, height: targetSize.height)
            } else {
                let scaledHeight = targetSize.width / sourceAspect
                return CGRect(x: 0, y: (targetSize.height - scaledHeight) / 2,
                              width: targetSize.width, height: scaledHeight)
            }
        }

        #if os(iOS)
        guard let originalImage = UIImage(data: data) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))
            originalImage.draw(in: aspectFillRect(sourceSize: originalImage.size))
        }

        guard let jpegData = resizedImage.jpegData(compressionQuality: 0.8) else { return nil }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
        #elseif os(macOS)
        guard let originalImage = NSImage(data: data) else { return nil }

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = targetSize

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        NSRect(origin: .zero, size: targetSize).fill()
        // Centered aspect-fill crop is symmetric in both axes, so AppKit's
        // y-up coordinate space yields the same framing as iOS's renderer.
        originalImage.draw(
            in: aspectFillRect(sourceSize: originalImage.size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1.0
        )
        context.flushGraphics()
        NSGraphicsContext.current = previousContext

        guard let jpegData = rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.8]
        ) else { return nil }

        do {
            try jpegData.write(to: destinationURL, options: .atomic)
            return fileName
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func sharedWidgetCoverExists(named fileName: String) -> Bool {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else {
            return false
        }
        return FileManager.default.fileExists(atPath: containerURL.appendingPathComponent(fileName).path)
    }

    /// Removes a stale shared widget cover so it isn't mistaken for the current
    /// song's art when the current song has no usable cover.
    private func removeSharedWidgetCover(named fileName: String) {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        try? FileManager.default.removeItem(at: containerURL.appendingPathComponent(fileName))
    }

    /// Purges every widget cover file in the App Group container
    /// (`widget_cover.png` + `widget_album_*`). Used when the user narrows the
    /// shared-data scope below `cover`, so the WidgetKit extension stops
    /// rendering album art that's no longer disclosed. Mirrors
    /// `WidgetSharedStore.clearSharedCoverFiles()`, which is internal to
    /// PrimuseKit and not reachable from this target.
    private func clearSharedWidgetCovers() {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PrimuseConstants.appGroupIdentifier
        ) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: containerURL.appendingPathComponent("widget_cover.png"))
        guard let entries = try? fm.contentsOfDirectory(
            at: containerURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in entries where url.lastPathComponent.hasPrefix("widget_album_") {
            try? fm.removeItem(at: url)
        }
    }

    private func makeRecentAlbumEntry(for song: Song) -> RecentAlbumEntry? {
        guard let rawAlbumTitle = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawAlbumTitle.isEmpty else {
            return nil
        }

        let artistName = displayedArtistName(for: song)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumKey = stableWidgetAlbumKey(for: song, albumTitle: rawAlbumTitle, artistName: artistName)
        let coverImageName = "widget_album_\(albumKey).jpg"

        return RecentAlbumEntry(
            id: albumKey,
            title: rawAlbumTitle,
            artistName: artistName,
            coverImageName: coverImageName
        )
    }

    private func stableWidgetAlbumKey(for song: Song, albumTitle: String, artistName: String) -> String {
        let baseKey = song.albumID ?? "\(song.sourceID)|\(albumTitle.lowercased())|\(artistName.lowercased())"
        let digest = SHA256.hash(data: Data(baseKey.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func displayedArtistName(for song: Song?) -> String? {
        guard let song else { return nil }
        if isLiveRadio { return song.artistName }
        return song.displayArtistName(configuration: artistNameConfiguration)
    }

    private func widgetTimelineSignature(for state: PlaybackState) -> String {
        [
            state.currentSongID ?? "",
            state.songTitle ?? "",
            state.artistName ?? "",
            state.albumTitle ?? "",
            state.coverImageName ?? "",
            state.isPlaying ? "1" : "0",
            state.playbackKind?.rawValue ?? PlaybackKind.track.rawValue,
            state.radioStationID ?? "",
            state.repeatMode?.rawValue ?? RepeatMode.off.rawValue,
            state.isLiked == true ? "1" : "0",
            String(state.currentTime.rounded().finiteInt()),
            String(state.duration.rounded().finiteInt())
        ].joined(separator: "|")
    }
}
