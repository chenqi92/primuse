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
    // MARK: - Casting (DLNA Controller 路径)

    /// Apple Music cannot share playback ownership with a remote renderer.
    /// Every replacement request awaits the same in-flight Stop operation.
    func prepareAppleMusicPlaybackHandoff(requestID: UUID) async -> Bool {
        let appleMusic = AppServices.shared.appleMusic
        guard appleMusic.isPlaybackRequestPending(requestID),
              !Task.isCancelled else { return false }

        let handoffID: UUID
        let handoffTask: Task<Bool, Never>
        if let existingTask = appleMusicCastingHandoffTask {
            handoffID = appleMusicCastingHandoffID
            handoffTask = existingTask
        } else if let controller = castingController {
            castingPositionTask?.cancel()
            castingPositionTask = nil
            let renderer = castingRenderer
            castingRenderer = nil
            castingController = nil
            isPlaying = false

            handoffID = UUID()
            appleMusicCastingHandoffID = handoffID
            appleMusicCastingHandoffController = controller
            appleMusicCastingHandoffRenderer = renderer
            handoffTask = Task { @MainActor in
                do {
                    try await controller.stop()
                    plog("📡 Cast: stopped for Apple Music handoff")
                    return true
                } catch {
                    plog("⚠️ Cast stop during Apple Music handoff failed: \(error.localizedDescription)")
                    return false
                }
            }
            appleMusicCastingHandoffTask = handoffTask
        } else {
            return appleMusic.isPlaybackRequestPending(requestID)
                && !Task.isCancelled
        }

        let stopped = await handoffTask.value
        guard appleMusicCastingHandoffID == handoffID else { return false }
        if stopped {
            appleMusicCastingHandoffTask = nil
            appleMusicCastingHandoffController = nil
            appleMusicCastingHandoffRenderer = nil
            return appleMusic.isPlaybackRequestPending(requestID)
                && !Task.isCancelled
        }

        let requestIsCurrent = appleMusic.isPlaybackRequestPending(requestID)
        let hasCurrentPendingRequest: Bool
        if let activeRequestID = appleMusic.activePlaybackRequestID {
            hasCurrentPendingRequest = appleMusic.isPlaybackRequestPending(activeRequestID)
        } else {
            hasCurrentPendingRequest = false
        }
        let handoffStillOwnsAudio = activeAppleMusicRequestID == requestID
            && playID == requestID
        // A superseded waiter leaves the failed result installed for the newer
        // request. Restore only while this handoff still owns playback; a local
        // selection or explicit Stop must never resurrect the old renderer.
        if requestIsCurrent || (!hasCurrentPendingRequest && handoffStillOwnsAudio) {
            if castingController == nil,
               let controller = appleMusicCastingHandoffController {
                castingRenderer = appleMusicCastingHandoffRenderer
                castingController = controller
                startCastingPolling()
            }
            appleMusicCastingHandoffTask = nil
            appleMusicCastingHandoffController = nil
            appleMusicCastingHandoffRenderer = nil
            appleMusicCastingHandoffID = UUID()
            if requestIsCurrent {
                appleMusic.failPlaybackRequest(
                    requestID,
                    message: String(localized: "playback_error_apple_music_generic")
                )
            }
        }
        return false
    }

    private func clearAppleMusicCastingHandoff(
        id handoffID: UUID,
        invalidateWaiters: Bool
    ) {
        guard appleMusicCastingHandoffID == handoffID else { return }
        appleMusicCastingHandoffTask = nil
        appleMusicCastingHandoffController = nil
        appleMusicCastingHandoffRenderer = nil
        if invalidateWaiters {
            appleMusicCastingHandoffID = UUID()
        }
    }

    /// A local selection made while the renderer Stop is in flight must wait
    /// for that same operation. Starting AVAudioEngine first would briefly (or,
    /// on Stop failure, indefinitely) play on both outputs.
    func awaitCastingHandoffForLocalPlayback(ownerID: UUID) async -> Bool {
        guard let handoffTask = appleMusicCastingHandoffTask else { return true }
        let handoffID = appleMusicCastingHandoffID
        let stopped = await handoffTask.value
        guard playID == ownerID,
              appleMusicCastingHandoffID == handoffID else { return false }
        if stopped {
            clearAppleMusicCastingHandoff(id: handoffID, invalidateWaiters: false)
            return true
        }

        if castingController == nil,
           let controller = appleMusicCastingHandoffController {
            castingRenderer = appleMusicCastingHandoffRenderer
            castingController = controller
            startCastingPolling()
        }
        clearAppleMusicCastingHandoff(id: handoffID, invalidateWaiters: true)
        isLoading = false
        showPlaybackError(String(localized: "playback_error_connection"))
        return false
    }

    /// `stop()` is synchronous, so finish the already-started renderer Stop in
    /// an owner-scoped task. A failed first command gets one best-effort retry,
    /// but the old renderer is never restored into stopped UI state.
    private func finishCastingHandoffForStop(ownerID: UUID) {
        guard let handoffTask = appleMusicCastingHandoffTask else { return }
        let handoffID = appleMusicCastingHandoffID
        let controller = appleMusicCastingHandoffController
        Task { @MainActor [weak self] in
            let stopped = await handoffTask.value
            guard let self,
                  self.playID == ownerID,
                  self.appleMusicCastingHandoffID == handoffID else { return }
            if !stopped, let controller {
                do {
                    try await controller.stop()
                    plog("📡 Cast: stopped on explicit-stop retry")
                } catch {
                    plog("⚠️ Cast explicit-stop retry failed: \(error.localizedDescription)")
                }
            }
            guard self.playID == ownerID,
                  self.appleMusicCastingHandoffID == handoffID else { return }
            self.clearAppleMusicCastingHandoff(
                id: handoffID,
                invalidateWaiters: true
            )
        }
    }

    /// 开始投屏到远端 renderer ── 本地立刻停, 把当前歌推过去续播 (从当前
    /// 进度起 seek)。后续 togglePlayPause / next / previous / seek 全部路由到
    /// RemoteRendererController。Apple Music DRM 歌无法投屏, 调用前 caller 应
    /// 自己 disable 按钮。
    func startCasting(to renderer: RemoteRenderer) async {
        invalidateInterruptionResumePreservingIntent()
        castingCommandGeneration &+= 1
        let operationGeneration = castingCommandGeneration
        let hasActiveAppleMusicRequest = activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil
            || appleMusicCastingHandoffTask != nil
        guard AppleMusicPlaybackOwnershipPolicy.canStartCasting(
            isAppleMusicMode: isAppleMusicMode,
            hasActivePlaybackRequest: hasActiveAppleMusicRequest
        ) else {
            plog("⚠️ Cast: Apple Music playback ownership is active or pending, ignored")
            return
        }
        // During a committed fade currentSong already names the incoming
        // track while the primary node still names the outgoing one. Complete
        // the node swap before handing the incoming track and time to casting.
        stopTimeUpdater()
        syncPlaybackProgressFromEngine()
        cancelCrossfadeAttempt(
            finishingCommittedTransition: true,
            completionMode: .preserveCachedProgress
        )
        let resumeSong = currentSong
        let resumeTime = currentTime
        let wasPlaying = isPlaying

        // 1. 本地停 (audioEngine + decoding task), audio session 让出去
        appleMusicCastingHandoffID = UUID()
        appleMusicCastingHandoffTask = nil
        appleMusicCastingHandoffController = nil
        appleMusicCastingHandoffRenderer = nil
        playID = UUID()
        invalidateAutomaticAdvance(reason: "casting-start")
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        beginPlaybackErrorScope()
        decodingTask?.cancel(); decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        // A stopped player node can leave AVAudioEngine's output unit running.
        // Stop the complete local render path before yielding the session so
        // playback on the remote renderer does not occupy this device's audio.
        audioEngine.stopSilenceKeepAlive()
        audioEngine.stop()
        hasPreparedLocalPlayback = false
        stopMusicVideoPlayback(clearPlayer: true)
        isPlaying = false
        AudioSessionManager.shared.deactivate()
        updateNowPlayingInfo()
        updatePlaybackState()

        // 2. 切换 cast 状态 + 启动 controller
        castingRenderer = renderer
        castingController = RemoteRendererController(renderer: renderer)
        plog("📡 Cast: started → \(renderer.friendlyName)")

        // 3. 推当前歌到 renderer + seek 到 resumeTime + 自动 play
        if let song = resumeSong {
            await castSong(
                song,
                startAt: resumeTime,
                autoPlay: wasPlaying,
                expectedCastingGeneration: operationGeneration
            )
        }
        // 4. 启动 1Hz 状态轮询
        startCastingPolling()
    }

    /// 停投屏 ── controller stop + 本地从同一首歌当前进度续播 (用户期望)。
    /// 如果 controller 已经断 / 出错, 也强制清状态。
    func stopCasting() async {
        invalidateInterruptionResumePreservingIntent()
        castingCommandGeneration &+= 1
        let operationGeneration = castingCommandGeneration
        castingPositionTask?.cancel(); castingPositionTask = nil
        let controller = castingController
        let resumeSong = currentSong
        let resumeTime = currentTime
        let shouldResumeLocally = isPlaying
        castingRenderer = nil
        castingController = nil
        isPlaying = false
        if let resumeSong {
            currentSong = resumeSong
            currentTime = max(0, resumeTime)
            pendingRecoveryTime = max(0, resumeTime)
            needsPlaybackRecovery = true
            isLoading = false
            hasPreparedLocalPlayback = false
            invalidateAutomaticAdvance(reason: "casting-stop-local-recovery")
            updateNowPlayingInfo()
            updatePlaybackState()
        }

        if let controller {
            try? await controller.stop()
        }
        plog("📡 Cast: stopped, resuming local from \(resumeTime)s")

        guard let song = resumeSong,
              castingCommandGeneration == operationGeneration,
              currentSong?.id == song.id else { return }
        if shouldResumeLocally, interruptionResumePolicy.playbackIsIntended {
            // Build at the renderer's last position. Starting at zero and
            // seeking later can leak a short burst from the beginning.
            seek(to: max(0, resumeTime), startPlaying: true, isRecovery: true)
        }
    }

    /// cast 模式下播指定歌 ── 解析 URL → 推 SetAVTransportURI → Play → 可选 Seek。
    /// 失败不抛错, 只 log + 保持 cast 状态让用户能手动重试。
    func castSong(
        _ song: Song,
        startAt seconds: TimeInterval = 0,
        autoPlay: Bool = true,
        expectedTicket: PlaybackAdvanceTicket? = nil,
        expectedCastingGeneration: UInt64? = nil
    ) async {
        guard let controller = castingController else { return }
        let operationGeneration = expectedCastingGeneration ?? castingCommandGeneration
        if let expectedTicket {
            guard let id = playID,
                  isPendingTransportStartAuthorized(
                playID: id,
                itemID: song.id,
                trigger: "cast-song-start",
                expectedTicket: expectedTicket
            ) else { return }
        }
        currentSong = song
        currentTime = seconds
        duration = song.duration.sanitizedDuration
        do {
            let uri = try await resolveCastURI(for: song)
            guard castingCommandGeneration == operationGeneration,
                  castingController === controller,
                  currentSong?.id == song.id,
                  !autoPlay || interruptionResumePolicy.playbackIsIntended else { return }
            try await controller.setAVTransportURI(uri: uri.absoluteString,
                                                    title: song.title,
                                                    artist: song.artistName)
            guard castingCommandGeneration == operationGeneration,
                  castingController === controller,
                  currentSong?.id == song.id,
                  !autoPlay || interruptionResumePolicy.playbackIsIntended else { return }
            if autoPlay {
                try await controller.play()
                guard castingCommandGeneration == operationGeneration,
                      castingController === controller,
                      interruptionResumePolicy.playbackIsIntended else {
                    try? await controller.pause()
                    return
                }
                isPlaying = true
            }
            if seconds > 0 {
                try? await Task.sleep(for: .milliseconds(200))
                guard castingCommandGeneration == operationGeneration,
                      castingController === controller,
                      currentSong?.id == song.id,
                      !autoPlay || interruptionResumePolicy.playbackIsIntended else { return }
                try? await controller.seek(toSeconds: seconds)
            }
            guard castingCommandGeneration == operationGeneration,
                  castingController === controller,
                  currentSong?.id == song.id else { return }
            plog("📡 Cast: '\(song.title)' → \(controller.renderer.friendlyName)")
        } catch {
            guard castingCommandGeneration == operationGeneration,
                  castingController === controller,
                  currentSong?.id == song.id else { return }
            plog("⚠️ Cast playback failed for '\(song.title)': \(error.localizedDescription)")
            isPlaying = false
        }
        guard castingCommandGeneration == operationGeneration,
              castingController === controller,
              currentSong?.id == song.id else { return }
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    /// 给 renderer 拿一个它能 HTTP GET 的 URL:
    /// - file:// (本地 / cached): 注册到 DLNAMediaServer, 返回 http://<iphone>:49160/<token>/...
    /// - https / http (NAS / Cloud HTTP source): 直接给, renderer 拉 (前提同 LAN 或公网可达)
    /// - primuse-stream:// (range-fetch cloud): 当前不支持 cast, 抛错让 caller 提示用户先离线下载
    private func resolveCastURI(for song: Song) async throws -> URL {
        let url = try await resolvedURL(for: song)
        if url.isFileURL {
            let name = (song.title.isEmpty ? "track" : song.title) + "." + (url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
            return try DLNAMediaServer.shared.registerFile(localURL: url, suggestedName: name)
        }
        if url.scheme == "http" || url.scheme == "https" {
            return url
        }
        throw NSError(domain: "Primuse.DLNA", code: -10,
                      userInfo: [NSLocalizedDescriptionKey: "Source \"\(song.title)\" needs offline download before casting (scheme=\(url.scheme ?? "?"))"])
    }

    private func startCastingPolling() {
        castingPositionTask?.cancel()
        castingPositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard let self, let controller = self.castingController else { break }
                let sampleGeneration = self.castingCommandGeneration
                do {
                    let pos = try await controller.getPositionInfo()
                    let state = try await controller.getTransportInfo()
                    guard !Task.isCancelled,
                          self.castingController === controller,
                          self.castingCommandGeneration == sampleGeneration else {
                        continue
                    }
                    if pos.currentTime >= 0 { self.currentTime = pos.currentTime }
                    if pos.duration > 0 { self.duration = pos.duration }
                    let isRendererPlaying = state == "PLAYING"
                    if self.isPlaying != isRendererPlaying {
                        self.isPlaying = isRendererPlaying
                        self.updateNowPlayingInfo()
                        self.updatePlaybackState()
                    }
                } catch {
                    guard !Task.isCancelled,
                          self.castingController === controller,
                          self.castingCommandGeneration == sampleGeneration else {
                        continue
                    }
                    // 轮询失败 (renderer 断网 / 关机) 不立刻退出 cast, 给 3 次重试机会
                    plog("⚠️ Cast polling error: \(error.localizedDescription)")
                }
            }
        }
    }

    func togglePlayPause() {
        if isLiveRadio {
            if isPlaying || isLoading {
                pause()
            } else {
                resume()
            }
            return
        }
        if isAppleMusicMode {
            isPlaybackActuallyActive ? pause() : resume()
            return
        }
        if isCastingMode {
            isPlaybackActuallyActive ? pause() : resume()
            return
        }
        if isPlaybackActuallyActive { pause() } else { resume() }
    }

    func setCastingPlayback(shouldPlay: Bool) {
        guard let controller = castingController else { return }
        castingCommandGeneration &+= 1
        let commandGeneration = castingCommandGeneration
        Task { [weak self] in
            guard let self,
                  self.castingCommandGeneration == commandGeneration,
                  self.castingController === controller else { return }
            do {
                if shouldPlay {
                    try await controller.play()
                } else {
                    try await controller.pause()
                }
            } catch {
                plog("⚠️ Cast \(shouldPlay ? "play" : "pause") failed: \(error.localizedDescription)")
                return
            }
            guard self.castingCommandGeneration == commandGeneration,
                  self.castingController === controller else {
                if self.castingController === controller {
                    if self.interruptionResumePolicy.playbackIsIntended {
                        try? await controller.play()
                    } else {
                        try? await controller.pause()
                    }
                }
                return
            }
            self.isPlaying = shouldPlay
            self.updateNowPlayingInfo()
            self.updatePlaybackState()
        }
    }

    func stop() {
        registerPauseOrStopIntent()
        // 拖动进度触发的整文件物化会一直下到底, 切歌 / 停止时必须一并取消,
        // 否则被放弃的传输继续占用带宽和缓存配额。直播电台 / Apple Music
        // 分支在下面直接 return, 取消必须排在它们前面。
        // 重入说明: seek 任务只可能经 handleTrackEnd 那条链走到 stop()
        // (performTrackEnd → play/next → 失败 → autoAdvanceAfterFailure →
        // 投屏分支), 而那个调用点已经先把 seekTask 句柄摘成 nil, 取消不到自己。
        seekTask?.cancel()
        seekTask = nil
        if isLiveRadio {
            playID = UUID()
            resetDecodedBufferHealth(resetRecoveryAttempts: true)
            stopRadioTransport(clearSelection: true)
            queueEntries = []
            clearNowPlayingInfo()
            updatePlaybackState()
            AudioSessionManager.shared.deactivate()
            return
        }
        let stopOwnerID = UUID()
        playID = stopOwnerID
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        beginPlaybackErrorScope()
        prefetchTask?.cancel()
        prefetchTask = nil
        sourceManager?.cancelBackgroundAudioCaching(keeping: [])
        pendingAppleMusicRestoredPosition = nil
        finishCastingHandoffForStop(ownerID: stopOwnerID)
        if isAppleMusicMode
            || activeAppleMusicRequestID != nil
            || AppServices.shared.appleMusic.activePlaybackRequestID != nil {
            appleMusicPlaybackTask?.cancel()
            appleMusicPlaybackTask = nil
            appleMusicTimeoutTask?.cancel()
            appleMusicTimeoutTask = nil
            activeAppleMusicRequestID = nil
            AppServices.shared.appleMusic.stopAppleMusic()
            stopAppleMusicMirror()
            isPrimuseManagingAppleMusicQueue = false
            currentSong = nil
            currentTime = 0
            duration = 0
            isPlaying = false
            isLoading = false
            queueEntries = []
            clearNowPlayingInfo()
            updatePlaybackState()
            AudioSessionManager.shared.deactivate()
            return
        }
        // 主动结束当前 streaming session (切走 / 用户点停止时), 让 .partial
        // 有机会转 final。
        let deferredStreamingDownloadSongID = retireStreamingDownloadPreparation()
        if StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
            previousSongID: currentSong?.id,
            newSongID: nil,
            retiredSongID: deferredStreamingDownloadSongID
        ), let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        // Invalidate buffer completion callbacks before stop/reset fires them.
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        audioEngine.resetPlayerVolume()
        stopMusicVideoPlayback(clearPlayer: true)
        sourceManager?.cancelMusicVideoDownloads(keeping: nil)
        isPlaying = false
        isLoading = false
        isAtTrackEnd = false
        currentSong = nil
        currentTime = 0
        duration = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // Clear NowPlaying info so Dynamic Island / Lock Screen also clears
        clearNowPlayingInfo()
        updatePlaybackState()
        AudioSessionManager.shared.deactivate()
    }

    /// Stops an invalid or security-fenced transport without erasing the
    /// user's selected item or queue. A later Play rebuilds this item (or seeks
    /// back to the preserved position) with a fresh request generation.
    func suspendPlaybackPreservingSelection(
        reason: String,
        resumeTime: TimeInterval? = nil
    ) {
        guard currentSong != nil else { return }
        registerPauseOrStopIntent()
        playID = UUID()
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        beginPlaybackErrorScope()
        prefetchTask?.cancel()
        prefetchTask = nil
        sourceManager?.cancelBackgroundAudioCaching(keeping: [])
        let deferredStreamingDownloadSongID = retireStreamingDownloadPreparation()
        if StreamingDownloadRetirementPolicy.shouldFinalizePreviousSession(
            previousSongID: currentSong?.id,
            newSongID: nil,
            retiredSongID: deferredStreamingDownloadSongID
        ), let currentSong {
            sourceManager?.finalizeStreamingSession(for: currentSong)
        }
        stopTimeUpdater()
        if let resumeTime {
            currentTime = max(0, resumeTime)
        } else {
            syncPlaybackProgressFromEngine()
        }
        pendingRecoveryTime = currentTime
        // 拖动进度触发的整文件物化会一直下到底, 切歌 / 停止时必须一并
        // 取消, 否则被放弃的传输继续占用带宽和缓存配额。
        seekTask?.cancel()
        seekTask = nil
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt(
            finishingCommittedTransition: true,
            completionMode: .preserveCachedProgress
        )
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        audioEngine.resetPlayerVolume()
        stopMusicVideoPlayback(clearPlayer: true)
        sourceManager?.cancelMusicVideoDownloads(keeping: nil)
        isPlaying = false
        isLoading = false
        isAtTrackEnd = false
        needsPlaybackRecovery = pendingRecoveryTime > 0
        pendingRecoveryIsColdSessionRestore = false
        ScrobbleService.shared.handlePlaybackStopped()
        PlayHistoryStore.shared.endSession()
        updateNowPlayingInfo()
        updatePlaybackState()
        AudioSessionManager.shared.deactivate()
        plog("⏸️ Playback suspended with current item preserved reason=\(reason)")
    }

    /// 跟 stop() 的差别: 保留 currentSong / queue / currentIndex / duration,
    /// 只清引擎 + 标 isAtTrackEnd = true。给 handleTrackEnd .off 用 ——
    /// 用户搜出来一首歌 (queue 只有一首) 播完时不要把 UI 一下子全清掉
    /// (sheet 白屏 / mini player 闪一下消失)。用户再点 play 可以从头重放
    /// (resume() 检测到 isAtTrackEnd 会走 play(song:) 重新解码)。
    func stopAtTrackEnd() {
        registerPauseOrStopIntent()
        // Invalidate the completed playback before stopping the node. The
        // safety-net timer and AVAudioPlayerNode's .dataPlayedBack callback can
        // arrive a few milliseconds apart for the same track. Without this,
        // the second callback re-enters handleTrackEnd(); most importantly it
        // can clear a "stop after this song" decision and advance the queue.
        if AppleMusicPlaybackOwnershipPolicy.shouldInvalidatePlayIDAtTrackEnd(
            isAppleMusicMode: isAppleMusicMode,
            hasActivePlaybackRequest: activeAppleMusicRequestID != nil
                || AppServices.shared.appleMusic.activePlaybackRequestID != nil
        ) {
            playID = UUID()
        }
        resetDecodedBufferHealth(resetRecoveryAttempts: true)

        // 自然播完一首歌, 触发 finalize —— 这是 .partial → final 最关键的
        // 时机, 用户期望「听完一整首」就该是完整缓存。
        if let cur = currentSong {
            sourceManager?.finalizeStreamingSession(for: cur)
        }
        prefetchTask?.cancel()
        prefetchTask = nil
        sourceManager?.cancelBackgroundAudioCaching(keeping: [])
        // 拖动进度触发的整文件物化会一直下到底, 切歌 / 停止时必须一并
        // 取消, 否则被放弃的传输继续占用带宽和缓存配额。
        seekTask?.cancel()
        seekTask = nil
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        audioEngine.resetPlayerVolume()
        stopMusicVideoPlayback(clearPlayer: false)
        isPlaying = false
        isLoading = false
        isAtTrackEnd = true
        currentTime = 0
        clearPendingPlaybackRecovery()
        stopTimeUpdater()
        ScrobbleService.shared.handlePlaybackStopped(); PlayHistoryStore.shared.endSession()
        // 锁屏 / Dynamic Island 显示「停在 0:00」状态, 不清空 ——
        // 这样用户从锁屏点 play 也能直接重放当前曲。
        updateNowPlayingInfo()
        updatePlaybackState()
        AudioSessionManager.shared.deactivate()
        plog("⏹️ stopAtTrackEnd() currentSong preserved=\(currentSong?.title ?? "nil")")
    }

    @discardableResult
    func next(
        context: QueueAdvanceContext = .userInitiated,
        caller: String = #fileID,
        callerLine: Int = #line
    ) async -> Bool {
        if isLiveRadio {
            guard let station = currentRadioStation,
                  radioStationOrder.count > 1,
                  let index = radioStationOrder.firstIndex(where: { $0.id == station.id }) else { return false }
            let nextIndex = radioStationOrder.index(after: index)
            let target = nextIndex < radioStationOrder.endIndex
                ? radioStationOrder[nextIndex]
                : radioStationOrder[0]
            await play(station: target, within: radioStationOrder)
            return true
        }
        if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
            invalidateInterruptionResumePreservingIntent()
            return await AppServices.shared.appleMusic.skipToNextAppleMusic()
        }
        guard !queue.isEmpty else { return false }
        let callerFile = (caller as NSString).lastPathComponent
        plog("⏭️ next() called FROM=\(callerFile):\(callerLine) currentIndex=\(currentIndex) queueCount=\(queue.count)")
        if queue.count == 1, shuffleEnabled, repeatMode == .off {
            _ = extendExhaustedShuffleFromLibrary()
        }
        // A manual next skips past repeat-one when there is another queue
        // entry, matching the existing transport controls. A true one-song
        // repeat-one queue may still intentionally restart itself.
        let respectsRepeatOne = queue.count == 1
        let successor = nextQueueTraversalTarget(
            respectsRepeatOne: respectsRepeatOne,
            wrapsAtEnd: queue.count > 1 || repeatMode == .all
        )
        guard ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: queue.count,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            hasSuccessor: successor != nil
        ), let successor else {
            plog("⏭️ next: no enabled successor; keeping current playback")
            return false
        }
        applyQueueTraversalTarget(successor)
        // 跳过相邻同 title+artist 的"重复歌曲" —— NAS 上同一首歌有多个版本
        // (mp3 + flac, 不同目录) scan 后是不同 song.id, 但用户看就是同一首,
        // 自动 next 跳到 "下一首是自己" 体验很怪。最多跳 1 次, 防止整个
        // queue 全是同一首时死循环。
        if let cur = currentSong {
            let candidate = queue[currentIndex]
            if QueueAdjacentDuplicatePolicy.shouldSkipCandidate(
                queueCount: queue.count,
                currentTitle: cur.title,
                currentArtist: cur.artistName,
                candidateTitle: candidate.title,
                candidateArtist: candidate.artistName,
                context: context
            ) {
                plog("⏭️ next: skipping duplicate '\(candidate.title)' (same title+artist as current)")
                if let following = nextQueueTraversalTarget(
                    respectsRepeatOne: respectsRepeatOne,
                    wrapsAtEnd: queue.count > 1 || repeatMode == .all
                ) {
                    applyQueueTraversalTarget(following)
                }
            }
        }
        await play(song: queue[currentIndex])
        return true
    }

    @discardableResult
    func previous() async -> Bool {
        if isLiveRadio {
            guard let station = currentRadioStation,
                  radioStationOrder.count > 1,
                  let index = radioStationOrder.firstIndex(where: { $0.id == station.id }) else { return false }
            let previousIndex = index > 0 ? index - 1 : radioStationOrder.count - 1
            await play(station: radioStationOrder[previousIndex], within: radioStationOrder)
            return true
        }
        if isAppleMusicMode && !isPrimuseManagingAppleMusicQueue {
            // 跟本地行为一致 ── 播放进度过 3s 时倒回开头, 否则跳上一首。
            if currentTime > 3 {
                AppServices.shared.appleMusic.seekAppleMusic(to: 0)
                return true
            } else {
                invalidateInterruptionResumePreservingIntent()
                return await AppServices.shared.appleMusic.skipToPreviousAppleMusic()
            }
        }
        guard !queue.isEmpty else { return false }
        if currentTime > 3 {
            seek(to: 0)
            return true
        }
        guard let predecessor = previousQueueTraversalTarget() else { return false }
        applyQueueTraversalTarget(predecessor)
        await play(song: queue[currentIndex])
        return true
    }

    func seek(
        to time: TimeInterval,
        startPlaying: Bool? = nil,
        isRecovery: Bool = false,
        isConfigurationRecovery: Bool = false,
        isColdSessionRestore: Bool = false,
        reacquiringLocalRouteFocus: Bool = false
    ) {
        guard !isLiveRadio else { return }
        if isAppleMusicMode {
            AppServices.shared.appleMusic.seekAppleMusic(to: TimeInterval.sanitized(time))
            return
        }
        if isCastingMode, let controller = castingController {
            let target = TimeInterval.sanitized(time)
            currentTime = target
            Task {
                do { try await controller.seek(toSeconds: target) } catch {
                    plog("⚠️ Cast seek failed: \(error.localizedDescription)")
                }
            }
            return
        }
        guard activeStreamingDownloadPreparation == nil else {
            plog("⚠️ Seek ignored while a bounded full-download startup is still active")
            return
        }
        // A full-download streaming decoder can only seek after its completed
        // file has entered the playback cache. A user scrub must leave the
        // still-running node untouched, but interruption recovery cannot be
        // rejected the same way: the system has already stopped that node and
        // every later play command would otherwise return through this guard.
        if activeDecoderKind == .streaming, let song = currentSong {
            let decision = FullDownloadSeekPolicy.decision(
                hasSeekableFile: sourceManager?.cachedURL(for: song) != nil,
                isInterruptionRecovery: isRecovery
            )
            switch decision {
            case .proceed:
                break
            case .keepCurrentPlayback:
                plog("⚠️ Seek: streaming song not cached yet, leaving playback unchanged")
                return
            case .restartCurrentSong:
                plog("🔄 Recovery: streaming song has no seekable cache; materializing before same-position resume")
            }
        }
        // Timer invalidation alone does not cancel a MainActor task that the
        // old timer already enqueued. Invalidate its clock ticket before the
        // visible target or player timeline changes.
        stopTimeUpdater()
        let requestedTime = TimeInterval.sanitized(time)
        let safeDuration = duration.sanitizedDuration
        let targetTime = safeDuration > 0 ? min(requestedTime, safeDuration) : requestedTime
        if isSystemMediaPlaybackActive {
            let carriedSeekActivity = hasMusicVideoSeekActivityEvidence
            let pendingSystemAudioStart = isSystemAudioPlaybackActive
                && !systemAudioPlaybackDidStart
                && isLoading
                && interruptionResumePolicy.playbackIsIntended
            let shouldStartPlaying = startPlaying
                ?? (isPlaying || carriedSeekActivity || pendingSystemAudioStart)
            guard let song = currentSong,
                  let id = playID,
                  let player = activeSystemMediaPlayer else { return }
            let seekWasActivelyPlaying = isPlaybackActuallyActive
                || lastPublishedPlaybackWasActive
                || carriedSeekActivity
                || pendingSystemAudioStart
            if isSystemAudioPlaybackActive {
                systemAudioStartupWatchdog?.cancel()
                systemAudioStartupWatchdog = nil
                pendingSystemAudioSeek = (
                    playID: id,
                    songID: song.id,
                    time: targetTime,
                    shouldStart: shouldStartPlaying
                )
                if shouldStartPlaying,
                   interruptionResumePolicy.playbackIsIntended {
                    // A remote AVPlayer seek may wait indefinitely for bytes
                    // and never invoke its completion handler. Bound the whole
                    // seek/start operation so PCM fallback remains reachable.
                    armSystemAudioStartupWatchdog(player: player, playID: id)
                }
            }
            invalidateAutomaticAdvance(reason: "music-video-seek")
            let musicVideoSeekTicket: PlaybackAdvanceTicket?
            if shouldStartPlaying, interruptionResumePolicy.playbackIsIntended {
                musicVideoSeekTicket = beginAutomaticAdvanceTransport(
                    itemID: song.id,
                    reason: "music-video-seek"
                )
            } else {
                musicVideoSeekTicket = nil
            }
            configureMusicVideoObservers(for: player, playID: id)
            let observerGeneration = musicVideoObserverGeneration
            if shouldStartPlaying,
               interruptionResumePolicy.playbackIsIntended,
               seekWasActivelyPlaying {
                musicVideoSeekActivityEvidence = .init(
                    itemID: song.id,
                    playID: id,
                    observerGeneration: observerGeneration
                )
            }
            currentTime = targetTime
            isLoading = true
            isPlaying = false
            isAtTrackEnd = false
            // 默认 tolerance —— 视频精确 seek 要重解整个 GOP, 拖进度条会
            // 明显顿挫; 落点由 periodic observer 回写, 进度条自然对齐。
            player.seek(
                to: CMTime(seconds: targetTime, preferredTimescale: 600)
            ) { [weak self, weak player] finished in
                Task { @MainActor [weak self, weak player] in
                    guard let self,
                          let player,
                          self.playID == id,
                          self.activeSystemMediaPlayer === player,
                          self.musicVideoObserverGeneration == observerGeneration else { return }
                    self.musicVideoSeekActivityEvidence = nil
                    guard finished else {
                        if self.isSystemAudioPlaybackActive,
                           self.pendingSystemAudioSeek?.playID == id,
                           shouldStartPlaying,
                           self.interruptionResumePolicy.playbackIsIntended {
                            player.play()
                            self.isLoading = true
                            self.isPlaying = false
                            self.armSystemAudioStartupWatchdog(player: player, playID: id)
                        } else {
                            self.pendingSystemAudioSeek = nil
                            player.pause()
                            self.isLoading = false
                            self.isPlaying = false
                        }
                        self.updateNowPlayingInfo()
                        self.updatePlaybackState()
                        return
                    }
                    if shouldStartPlaying,
                       self.isLocalTransportStartAuthorized(
                        playID: id,
                        itemID: song.id,
                        trigger: "music-video-seek-start",
                        expectedTicket: musicVideoSeekTicket
                       ) {
                        player.play()
                        if self.isSystemAudioPlaybackActive,
                           !self.systemAudioPlaybackDidStart {
                            self.isLoading = true
                            self.isPlaying = false
                            self.armSystemAudioStartupWatchdog(player: player, playID: id)
                        } else {
                            self.isLoading = false
                            self.isPlaying = true
                        }
                    } else {
                        self.pendingSystemAudioSeek = nil
                        player.pause()
                        self.isLoading = false
                        self.isPlaying = false
                    }
                    if isRecovery { self.clearPendingPlaybackRecovery() }
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                }
            }
            updateNowPlayingInfo()
            return
        }
        currentTime = targetTime
        isLoading = true
        // 用户拖进度条 = 重新介入这首歌, 退出 "已播完" 状态
        isAtTrackEnd = false
        updateNowPlayingInfo()

        guard let song = currentSong else { isLoading = false; return }
        let savedDuration = duration
        let shouldStartPlaying = startPlaying ?? isPlaying
        isPlaying = false

        // Invalidate old playID BEFORE stopPlayback() so any pending completion
        // callbacks (triggered by AVAudioPlayerNode.stop()) will fail
        // their guard check and won't trigger handleTrackEnd() → next().
        let id = UUID()
        playID = id
        if isConfigurationRecovery {
            configurationRecoveryOwnerPlayID = id
            if configurationRecoveryActivityEvidence?.itemID == song.id {
                configurationRecoveryActivityEvidence?.rebuildPlayID = id
            }
        }
        if reacquiringLocalRouteFocus {
            localRouteFocusRecoveryOwnerPlayID = id
        }
        let seekAdvanceTicket = beginAutomaticAdvanceTransport(
            itemID: song.id,
            reason: isRecovery ? "recovery-rebuild" : "seek-rebuild"
        )
        resetDecodedBufferHealth(resetRecoveryAttempts: !isRecovery)

        // Stop only the playerNode, not the full pipeline — preserve Live Activity,
        // currentSong, and other state that stop() would tear down.
        seekTask?.cancel()
        decodingTask?.cancel()
        decodingTask = nil
        cancelGaplessTasks()
        cancelCrossfadeAttempt()
        if reacquiringLocalRouteFocus {
            // AVAudioSession cannot safely deactivate while any local render
            // object is running. A player-node stop is insufficient because
            // the output unit remains active.
            audioEngine.stop()
        } else {
            audioEngine.stopPlayback()
        }
        hasPreparedLocalPlayback = false

        // Restore state that stopPlayback clears
        currentSong = song
        currentTime = targetTime
        duration = savedDuration

        seekTask = Task {
            defer {
                if playID == id {
                    seekTask = nil
                }
                if isConfigurationRecovery,
                   configurationRecoveryOwnerPlayID == id {
                    configurationRecoveryOwnerPlayID = nil
                }
                if isConfigurationRecovery,
                   configurationRecoveryActivityEvidence?.itemID == song.id,
                   configurationRecoveryActivityEvidence?.rebuildPlayID == id {
                    configurationRecoveryActivityEvidence = nil
                }
                if localRouteFocusRecoveryOwnerPlayID == id {
                    localRouteFocusRecoveryOwnerPlayID = nil
                }
            }
            do {
                let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(
                    sourceID: song.sourceID
                )
                let url = try await resolvedURL(for: song)
                guard !Task.isCancelled, playID == id else { return }
                let resolvedDecoderKind = await decoderKind(for: song, url: url)
                guard !Task.isCancelled, playID == id else { return }
                activeDecoderKind = resolvedDecoderKind
                activeDSDPlaybackMode = try await configureOutputPipeline(
                    for: song,
                    url: url,
                    expectedPlayID: id,
                    reacquiringLocalRouteFocus: reacquiringLocalRouteFocus
                )
                guard !Task.isCancelled, playID == id else { return }
                applySpatialAudioSettings()
                applyPlaybackRate()
                guard let outputFormat = audioEngine.outputFormat else {
                    isLoading = false
                    isPlaying = false
                    showPlaybackError(String(localized: "playback_error_decode"))
                    republishNowPlayingSurfaces()
                    return
                }
                try audioEngine.start()

                let settings = playbackSettings.snapshot()
                if shouldApplyReplayGain(settings) {
                    await applyReplayGain(
                        for: song,
                        url: url,
                        mode: settings.replayGainMode,
                        allowFileRead: activeDecoderKind != .cloudStream && activeDecoderKind != .httpStream,
                        expectedPlayID: id,
                        expectedSongID: song.id
                    )
                    guard !Task.isCancelled, playID == id else { return }
                }

                // Use the same decoder that was used for initial playback.
                // For streaming, require the cached local file — can't seek in remote streams.
                var seekURL: URL
                var seekDecoderKind = activeDecoderKind
                if activeDecoderKind == .streaming {
                    var cached = sourceManager?.cachedURL(for: song)
                    if cached == nil, isRecovery, !isColdSessionRestore {
                        cached = await materializeCachedURLForPlaybackRecovery(
                            song,
                            trigger: "streaming-recovery-seek"
                        )
                    }
                    guard playID == id else { return }
                    guard let cached else {
                        if isColdSessionRestore {
                            throw AudioDecoderError.seekUnavailable
                        }
                        plog("⚠️ Seek: streaming song could not be materialized for same-position recovery")
                        isLoading = false
                        isPlaying = false
                        invalidateAutomaticAdvance(reason: "streaming-recovery-materialization-failed")
                        showPlaybackError(String(localized: "playback_error_connection"))
                        republishNowPlayingSurfaces()
                        return
                    }
                    seekURL = cached
                } else {
                    seekURL = url
                }

                // Range-backed cloud/HTTP InputSources can expose byte seeking
                // while a format decoder still rejects PCM seeking. Never fall
                // back to decoding millions of frames just to reach a large
                // target. Complete the normal LRU cache once, then seek the
                // local file with FFmpeg/native random access.
                if (activeDecoderKind == .cloudStream || activeDecoderKind == .httpStream),
                   RemoteSeekPreparationPolicy.decision(
                       hasCachedFile: sourceManager?.cachedURL(for: song) != nil,
                       cacheEnabled: playbackSettings.audioCacheEnabled,
                       isColdSessionRestore: isColdSessionRestore
                   ) == .materializeCompleteFile,
                   let cached = await materializeCachedURLForPlaybackRecovery(
                       song,
                       trigger: "remote-seek"
                   ) {
                    guard !Task.isCancelled, playID == id else { return }
                    seekURL = cached
                    seekDecoderKind = await ffmpegCanDecodeOffMain(cached) ? .ffmpeg : .native
                    guard !Task.isCancelled, playID == id else { return }
                    activeDecoderKind = seekDecoderKind
                    plog("📍 Seek materialized remote audio to local cache; decoder=\(seekDecoderKind)")
                }
                let rawStream: AudioBufferStream
                let onResolveLength = makeResolveLengthCallback(for: song)
                var decoderPerformedSeek = false
                var decoderSourceStartTime: TimeInterval = 0
                let physicalSeekTime = max(
                    0,
                    (song.cueStartTime ?? 0) + targetTime
                )
                switch seekDecoderKind {
                case .native:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = nativeDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        dsdMode: activeDSDPlaybackMode,
                        startingAt: physicalSeekTime,
                        onResolveSourceLength: onResolveLength
                    )
                case .streaming:
                    // Custom formats enter through the full-download fallback.
                    // Once cached, FFmpeg can seek at the demuxer level.
                    if await usesFFmpegDecoder(for: song, url: seekURL) {
                        guard !Task.isCancelled, playID == id else { return }
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = ffmpegDecoder.decode(
                            from: seekURL,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: seekURL,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    }
                case .ffmpeg:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = ffmpegDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        startingAt: physicalSeekTime,
                        onResolveSourceLength: onResolveLength
                    )
                case .httpStream:
                    if let cached = sourceManager?.cachedURL(for: song) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: cached,
                            outputFormat: outputFormat,
                            dsdMode: .pcm,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else if let inputSource = await makeHTTPStreamingInputSource(
                        for: song,
                        url: url,
                        sourceStreamEpoch: sourceStreamEpoch
                    ) {
                        guard !Task.isCancelled, playID == id else { return }
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: inputSource,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        if isColdSessionRestore {
                            throw AudioDecoderError.seekUnavailable
                        }
                        plog("⚠️ Seek: failed to build HTTP streaming InputSource")
                        isLoading = false
                        isPlaying = false
                        pendingRecoveryTime = targetTime
                        needsPlaybackRecovery = isRecovery
                        invalidateAutomaticAdvance(reason: "http-seek-input-source-failed")
                        republishNowPlayingSurfaces()
                        return
                    }
                case .cloudStream:
                    // Build a fresh InputSource for the seek session. The
                    // sparse cache file from the prior session is reused
                    // (SFB reads will hit local for any byte range we've
                    // already fetched, fall through to network for the
                    // rest). If the song has since been fully downloaded
                    // and renamed to the canonical path, prefer that.
                    if let cached = sourceManager?.cachedURL(for: song) {
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: cached,
                            outputFormat: outputFormat,
                            dsdMode: .pcm,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else if let manager = sourceManager,
                              let inputSource = try? await manager.makeStreamingInputSource(
                                  for: song,
                                  cacheEnabled: playbackSettings.audioCacheEnabled,
                                  expectedStreamEpoch: sourceStreamEpoch
                              ) {
                        guard !Task.isCancelled, playID == id else { return }
                        decoderPerformedSeek = true
                        decoderSourceStartTime = physicalSeekTime
                        rawStream = nativeDecoder.decode(
                            from: inputSource,
                            outputFormat: outputFormat,
                            startingAt: physicalSeekTime,
                            onResolveSourceLength: onResolveLength
                        )
                    } else {
                        if isColdSessionRestore {
                            throw AudioDecoderError.seekUnavailable
                        }
                        plog("⚠️ Seek: failed to build cloud streaming InputSource")
                        isLoading = false
                        isPlaying = false
                        pendingRecoveryTime = targetTime
                        needsPlaybackRecovery = isRecovery
                        invalidateAutomaticAdvance(reason: "cloud-seek-input-source-failed")
                        republishNowPlayingSurfaces()
                        return
                    }
                case .assetReader:
                    decoderPerformedSeek = true
                    decoderSourceStartTime = physicalSeekTime
                    rawStream = assetReaderDecoder.decode(
                        from: seekURL,
                        outputFormat: outputFormat,
                        startingAt: physicalSeekTime
                    )
                }
                let stream = segmented(
                    rawStream,
                    for: song,
                    sourceStartTime: decoderSourceStartTime
                )
                let seekSamplePosition = targetTime * outputFormat.sampleRate
                guard seekSamplePosition.isFinite else {
                    self.isLoading = false
                    self.updateNowPlayingInfo()
                    self.updatePlaybackState()
                    return
                }
                let progressSeekSamples = Int64(seekSamplePosition.rounded(.down))
                let seekSamples = decoderPerformedSeek ? 0 : progressSeekSamples
                var samplesSkipped: Int64 = 0

                // Set sample time offset so currentTime calculation accounts for seek position
                audioEngine.sampleTimeOffset = -progressSeekSamples

                // Skip buffers until seek position, then schedule first playable buffer before play()
                let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())
                var firstPlayableBuffer: AVAudioPCMBuffer?

                while let buffer = try await iteratorBox.next() {
                    guard !Task.isCancelled, playID == id else { return }
                    let bufferSamples = Int64(buffer.frameLength)
                    if samplesSkipped + bufferSamples <= seekSamples {
                        samplesSkipped += bufferSamples
                        continue
                    }
                    firstPlayableBuffer = buffer
                    break
                }

                guard let firstBuffer = firstPlayableBuffer else {
                    isLoading = false
                    isPlaying = false
                    currentTime = targetTime
                    let seekEndAction = PlaybackSeekEndPolicy.action(isRecovery: isRecovery)
                    if seekEndAction == .preserveCurrentItem {
                        // An authorized interruption/configuration recovery may
                        // only rebuild this item. Reaching EOF while seeking is
                        // not permission to advance before the item resumes.
                        invalidateAutomaticAdvance(reason: "recovery-seek-reached-end")
                        needsPlaybackRecovery = false
                        pendingRecoveryTime = targetTime
                        isAtTrackEnd = true
                    }
                    updateNowPlayingInfo()
                    updatePlaybackState()
                    if seekEndAction == .advance,
                       shouldStartPlaying,
                       playbackAdvancePolicy.activeTicket == seekAdvanceTicket {
                        // 自动续播会经 performTrackEnd 重入 next() / play(song:) /
                        // stopAtTrackEnd, 而它们都会取消 seekTask —— 此刻句柄正
                        // 指向本任务。先摘掉句柄, 下一首才不会在自己触发的
                        // Task.isCancelled 守卫上原地夭折 (停在 isLoading 无声)。
                        seekTask = nil
                        await handleTrackEnd(
                            advanceTicket: seekAdvanceTicket,
                            trigger: "seek-reached-end",
                            transportIsActive: true
                        )
                    }
                    return
                }
                guard !Task.isCancelled, playID == id else { return }

                // Hold one buffer ahead just like the initial playback path.
                // Without this prefetch, a seek/recovery with exactly one
                // remaining buffer schedules it as an ordinary buffer and an
                // unknown-duration stream never receives a terminal callback.
                let secondPlayableBuffer = try await iteratorBox.next()
                guard !Task.isCancelled, playID == id else { return }

                let gate = DecodedBufferGate(
                    maxBufferedDuration: Self.decodedAudioLookahead,
                    maxBufferedBytes: Self.maxInFlightDecodedBytes,
                    maxBufferCount: Self.maxInFlightDecodedBufferCount
                )
                if secondPlayableBuffer == nil {
                    await scheduleDecodedFinalBuffer(firstBuffer, playID: id)
                } else {
                    await scheduleTrackedDecodedBuffer(firstBuffer, gate: gate)
                }
                guard !Task.isCancelled, playID == id else {
                    await gate.drain()
                    return
                }
                installDecodedBufferGate(gate, playID: id)
                hasPreparedLocalPlayback = true
                if shouldStartPlaying,
                   !isLocalTransportStartAuthorized(
                    playID: id,
                    itemID: song.id,
                    trigger: isRecovery ? "recovery-start" : "seek-start",
                    expectedTicket: seekAdvanceTicket
                   ) {
                    audioEngine.stopPlayback()
                    hasPreparedLocalPlayback = false
                    isLoading = false
                    isPlaying = false
                    pendingRecoveryTime = targetTime
                    needsPlaybackRecovery = true
                    await gate.drain()
                    updateNowPlayingInfo()
                    updatePlaybackState()
                    return
                }
                let didStartPlayback = shouldStartPlaying ? audioEngine.play() : false

                isLoading = false
                if didStartPlayback {
                    isPlaying = true
                    startTimeUpdater()
                } else {
                    isPlaying = false
                    stopTimeUpdater()
                    if shouldStartPlaying {
                        showPlaybackError(String(localized: "playback_error_decode"))
                    }
                }
                switch LocalSeekRecoveryPolicy.updateAfterSeek(
                    targetTime: targetTime,
                    didSucceed: true,
                    shouldStartPlaying: shouldStartPlaying,
                    isRecovery: isRecovery,
                    needsRecovery: needsPlaybackRecovery
                ) {
                case .preserve:
                    break
                case .retarget(let recoveryTime):
                    pendingRecoveryTime = recoveryTime
                    pendingRecoveryIsColdSessionRestore = false
                }
                if isRecovery, didStartPlayback || !shouldStartPlaying {
                    clearPendingPlaybackRecovery()
                }
                updateNowPlayingInfo()
                updatePlaybackState()

                // Decode remaining buffers with track-end detection
                if let secondPlayableBuffer {
                    decodingTask = Task { [id, iteratorBox, gate, secondPlayableBuffer] in
                        var lastBuffer: AVAudioPCMBuffer?
                        defer { Task { await gate.drain() } }

                        // 稳态解码泵整体移出 MainActor: 循环本身不再读主 actor 状态, 归属改由
                        // pumpLease 逐块回答; 收尾逻辑仍留在外层这个主 actor Task 里。
                        let loop = DecodedBufferSchedulingLoop<AVAudioPCMBuffer, UUID>(
                            playID: id,
                            lease: self.pumpLease,
                            gate: gate,
                            measure: { buffer in
                                DecodedBufferMeasurement(
                                    duration: Self.decodedBufferDuration(buffer),
                                    byteCount: Self.decodedBufferByteCount(buffer)
                                )
                            },
                            schedule: { [audioEngine = self.audioEngine] buffer, release in
                                audioEngine.scheduleDecodedBuffer(
                                    buffer, on: .primary, completionCallbackType: .dataPlayedBack
                                ) { _ in release() }
                            }
                        )
                        let loopTask = Task.detached(priority: .userInitiated) {
                            await loop.run(
                                next: { try await iteratorBox.next() },
                                initialHeldBuffer: secondPlayableBuffer
                            )
                        }
                        let outcome = await withTaskCancellationHandler {
                            await loopTask.value
                        } onCancel: {
                            loopTask.cancel()
                        }

                        switch outcome {
                        case .cancelled, .lostOwnership:
                            return
                        case .completed(let buffer, _):
                            lastBuffer = buffer
                        case .failed(let error, let buffer, _):
                            lastBuffer = buffer
                            if !Task.isCancelled { plog("Seek decode error: \(error)") }
                        }

                        if let finalBuffer = lastBuffer {
                            guard !Task.isCancelled else { return }
                            if self.scheduleOutgoingCrossfadeTailBuffer(finalBuffer, playID: id) { return }
                            guard self.playID == id else { return }
                            await self.scheduleDecodedFinalBuffer(finalBuffer, playID: id)
                        }
                    }
                } else {
                    decodingTask = nil
                }
            } catch {
                plog("Seek error: \(error)")
                guard !Task.isCancelled, playID == id else { return }
                if error is PlaybackAudioSessionFailure {
                    suspendPlaybackPreservingSelection(
                        reason: "audio-session-unavailable-during-seek",
                        resumeTime: targetTime
                    )
                    return
                }
                let canRestartColdRemoteStream = isRecovery
                    && isColdSessionRestore
                    && sourceManager?.cachedURL(for: song) == nil
                    && (activeDecoderKind == .streaming
                        || activeDecoderKind == .cloudStream
                        || activeDecoderKind == .httpStream)
                if canRestartColdRemoteStream {
                    plog("↩️ Cold remote resume cannot seek through Range; restarting stream from beginning")
                    isLoading = false
                    isPlaying = false
                    currentTime = 0
                    clearPendingPlaybackRecovery()
                    invalidateAutomaticAdvance(reason: "cold-remote-resume-fallback")
                    // play(song:) 会取消 seekTask, 而此刻句柄正指向本任务。
                    // 先摘掉句柄, 冷启动重播才不会被自己的取消打断。
                    seekTask = nil
                    await play(song: song)
                    return
                }
                if !isRecovery {
                    suspendPlaybackPreservingSelection(
                        reason: "seek-failed",
                        resumeTime: targetTime
                    )
                    showPlaybackError(String(localized: "playback_error_decode"))
                    return
                }
                isLoading = false
                isPlaying = false
                currentTime = targetTime
                pendingRecoveryTime = targetTime
                needsPlaybackRecovery = true
                invalidateAutomaticAdvance(reason: "same-position-recovery-failed")
                showPlaybackError(String(localized: "playback_error_decode"))
                republishNowPlayingSurfaces()
            }
        }
    }

    func handleAppWillResignActive() {
        cancelAppActivationInterruptionRecovery()
        let activeEvidence = lastPublishedPlaybackWasActive
            || hasConfigurationRecoveryActivityEvidence
            || hasMusicVideoSeekActivityEvidence
        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        // 退到后台后进程随时可能被挂起, 这一次会话快照必须在返回前落盘。
        updatePlaybackState(flushPlaybackSessionImmediately: true)
        // AVFAudio can stop the graph before delivering its interruption
        // notification. Preserve the last backend-validated active publication
        // across that ordering window. Explicit Pause/Stop has already cleared
        // playback intent; foreground synchronization replaces stale evidence.
        if activeEvidence,
           interruptionResumePolicy.playbackIsIntended,
           isPlaying
            || hasConfigurationRecoveryActivityEvidence
            || hasMusicVideoSeekActivityEvidence
            || interruptionResumePolicy.isAwaitingInterruptionEnd {
            lastPublishedPlaybackWasActive = true
        }
    }

    func handleAppDidBecomeActive() {
        #if os(iOS)
        retryEmptySystemLyricsAfterForegroundingIfNeeded()
        #endif
        if interruptionResumePolicy.isAwaitingInterruptionEnd {
            scheduleAppActivationInterruptionRecovery()
        }
        switch PlaybackAppActivationPolicy.action(
            needsPlaybackRecovery: needsPlaybackRecovery
        ) {
        case .preservePendingRecovery:
            currentTime = max(0, pendingRecoveryTime)
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        case .synchronizeVisibleState:
            break
        }

        syncPlaybackProgressFromEngine()
        updateNowPlayingInfo()
        updatePlaybackState()
    }

    private enum QueueReplacementTransition: Equatable {
        case prepareNewSelection
        case preserveCurrentTransport
    }

    /// Replaces the visible queue and starts its selected item as one operation.
    /// The old transport is never rebuilt on the way to a different song, and a
    /// repeated selection of the active/loading item only updates queue context.
    func play(
        queue songs: [Song],
        startingAt index: Int = 0,
        caller: String = #fileID,
        callerLine: Int = #line
    ) async {
        guard !songs.isEmpty else {
            clearQueue()
            return
        }
        let selectedIndex = max(0, min(index, songs.count - 1))
        let selectedSong = songs[selectedIndex]
        let transportCanBePreserved = !isAppleMusicMode || isPrimuseManagingAppleMusicQueue
        let decision = QueueSelectionPlaybackPolicy.decision(
            selectedItemID: selectedSong.id,
            currentItemID: currentSong?.id,
            transportIsActive: isPlaybackActuallyActive,
            isLoading: isLoading,
            transportCanBePreserved: transportCanBePreserved
        )
        installQueue(
            songs,
            startAt: selectedIndex,
            transition: decision == .preserveCurrentTransport
                ? .preserveCurrentTransport
                : .prepareNewSelection
        )
        guard decision == .startSelectedItem else {
            plog("🎶 queue selection reused active transport for '\(selectedSong.title)'")
            return
        }
        await play(song: selectedSong, caller: caller, callerLine: callerLine)
    }

    func setQueue(_ songs: [Song], startAt index: Int = 0) {
        guard !songs.isEmpty else {
            clearQueue()
            return
        }
        let selectedIndex = max(0, min(index, songs.count - 1))
        let transportCanBePreserved = !isAppleMusicMode || isPrimuseManagingAppleMusicQueue
        let decision = QueueSelectionPlaybackPolicy.decision(
            selectedItemID: songs[selectedIndex].id,
            currentItemID: currentSong?.id,
            transportIsActive: isPlaybackActuallyActive,
            isLoading: isLoading,
            transportCanBePreserved: transportCanBePreserved
        )
        installQueue(
            songs,
            startAt: selectedIndex,
            transition: decision == .preserveCurrentTransport
                ? .preserveCurrentTransport
                : .prepareNewSelection
        )
    }

    private func installQueue(
        _ songs: [Song],
        startAt index: Int,
        transition: QueueReplacementTransition
    ) {
        guard !songs.isEmpty else {
            plog("🎶 setQueue empty — clearing queue")
            clearQueue()
            return
        }

        let preservedEntryID = transition == .preserveCurrentTransport
            && queueEntries.indices.contains(currentIndex) ? queueEntries[currentIndex].id : nil
        var reusableEntryIDs: [String: [UUID]] = [:]
        if transition == .preserveCurrentTransport {
            for entry in queueEntries.reversed() where entry.id != preservedEntryID {
                reusableEntryIDs[entry.song.id, default: []].append(entry.id)
            }
        }
        switch transition {
        case .prepareNewSelection:
            invalidateQueueTransitions(rebuildCurrentTransport: false)
        case .preserveCurrentTransport:
            invalidatePreparedQueueSuccessor()
        }
        queueEntries = songs.enumerated().map { offset, song in
            let id = offset == index ? preservedEntryID : reusableEntryIDs[song.id]?.popLast()
            return QueueEntry(song: song, id: id ?? UUID())
        }
        currentIndex = max(0, min(index, songs.count - 1))
        // Protect any newly-installed canonical queue from an existing Apple
        // Music mirror during the short interval before `play(song:)` runs.
        isPrimuseManagingAppleMusicQueue = true
        let currentTitle = queueEntries[currentIndex].song.title
        let firstTitle = queueEntries.first?.song.title ?? "-"
        let lastTitle = queueEntries.last?.song.title ?? "-"
        plog("🎶 setQueue count=\(songs.count) startIndex=\(currentIndex) current='\(currentTitle)' first='\(firstTitle)' last='\(lastTitle)'")
        // Drop any pre-built next round — the queue itself changed, so
        // prior shuffle plans (and their indices into the old queue)
        // are stale and would index out-of-bounds on wrap.
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
        persistPlaybackSession()
        if transition == .preserveCurrentTransport {
            if isPlaybackActuallyActive { prefetchNextSong() }
            else { synchronizeAppleMusicQueue() }
        }
    }

    /// Re-evaluate prepared queue work after an enable/disable state arrives
    /// from this device or CloudKit. The durable queue is intentionally not
    /// filtered: re-enabling a source makes its existing entries playable
    /// again without rebuilding the user's order.
    func sourceAvailabilityDidChange(for sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty,
              currentSong.map({ sourceIDs.contains($0.sourceID) }) == true
                || queueEntries.contains(where: { sourceIDs.contains($0.song.sourceID) }) else {
            return
        }
        invalidatePreparedQueueSuccessor()
        prefetchNextSong()
    }

    /// Append songs to the end of the current queue without interrupting the
    /// current track. Used by macOS list-level "add all to queue" actions.
    func appendToQueue(_ songs: [Song]) {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return }
        invalidatePreparedQueueSuccessor()
        queueEntries.append(contentsOf: playable.map { QueueEntry(song: $0) })
        if isAppleMusicMode {
            isPrimuseManagingAppleMusicQueue = true
            AppServices.shared.appleMusic.prepareForPrimuseManagedQueue()
        }
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
        persistPlaybackSession()
        if isPlaybackActuallyActive { prefetchNextSong() }
        else { synchronizeAppleMusicQueue() }
    }

    /// Insert songs immediately after the current queue position. If there is
    /// no queue yet, this behaves like `setQueue`.
    @discardableResult
    func insertNextInQueue(_ songs: [Song]) -> Int? {
        let playable = songs.filteredPlayable()
        guard !playable.isEmpty else { return nil }
        guard !queueEntries.isEmpty else {
            setQueue(playable, startAt: 0)
            return 0
        }
        let insertionIndex = min(currentIndex + 1, queueEntries.count)
        invalidatePreparedQueueSuccessor()
        queueEntries.insert(contentsOf: playable.map { QueueEntry(song: $0) }, at: insertionIndex)
        if isAppleMusicMode {
            isPrimuseManagingAppleMusicQueue = true
            AppServices.shared.appleMusic.prepareForPrimuseManagedQueue()
        }
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
        persistPlaybackSession()
        if isPlaybackActuallyActive { prefetchNextSong() }
        else { synchronizeAppleMusicQueue() }
        return insertionIndex
    }
    /// Remove every occurrence of the target songs from the canonical queue
    /// before their library records or source files disappear. If the active
    /// song is part of the batch, playback moves directly to a retained row;
    /// advancing only once can land on another song in the same deletion batch.
    func prepareQueueForRemovingSongs(withIDs songIDs: Set<String>) async {
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: queueEntries.map(\.song.id),
            currentIndex: currentIndex,
            currentSongID: currentSong?.id,
            removingSongIDs: songIDs
        )
        guard plan.action != .unchanged else { return }

        let retainedSongs = plan.retainedIndices.compactMap { index in
            queueEntries.indices.contains(index) ? queueEntries[index].song : nil
        }
        switch plan.action {
        case .unchanged:
            return
        case let .replaceQueue(startAt):
            if retainedSongs.isEmpty {
                clearQueue()
            } else {
                setQueue(retainedSongs, startAt: startAt)
            }
        case let .playReplacement(startAt):
            guard retainedSongs.indices.contains(startAt) else {
                stop()
                clearQueue()
                return
            }
            if isPlaybackActive {
                setQueue(retainedSongs, startAt: startAt)
                await play(song: retainedSongs[startAt])
            } else {
                stop()
                setQueue(retainedSongs, startAt: startAt)
                stagePausedHandoff(song: retainedSongs[startAt], at: 0)
                persistPlaybackSession()
            }
        case .stopAndClearQueue:
            stop()
            clearQueue()
        }
    }

    /// 删掉队列前 `count` 首歌, 同时把 `currentIndex` 往前平移 (不让它跑负)。
    /// MacQueuePanel 的 "清掉已播放" 按钮直接调这个 ── 之前是把 player.queue
    /// 当 var 用, 但 queue 现在是 computed。
    func removeQueuePrefix(count: Int) {
        guard count > 0 else { return }
        let toRemove = min(count, queueEntries.count)
        invalidatePreparedQueueSuccessor()
        queueEntries.removeFirst(toRemove)
        currentIndex = max(0, currentIndex - toRemove)
        pendingNextShuffleIndices = nil
        if shuffleEnabled { rebuildShuffleOrder() }
        persistPlaybackSession()
        if isPlaybackActuallyActive { prefetchNextSong() }
        else { synchronizeAppleMusicQueue() }
    }

    /// Wipe the queue. Replaces the legacy `player.queue = []` setter,
    /// which is no longer accessible since `queue` is now computed.
    func clearQueue() {
        let retainedAppleMusicTransport = isAppleMusicMode && isPrimuseManagingAppleMusicQueue
        appleMusicQueueUpdateTask?.cancel()
        appleMusicQueueUpdateTask = nil
        if retainedAppleMusicTransport { AppServices.shared.appleMusic.retainCurrentManagedQueueEntry() }
        invalidateQueueTransitions()
        queueEntries = []
        currentIndex = 0
        pendingNextShuffleIndices = nil
        shuffledIndices = []
        shufflePosition = 0
        isPrimuseManagingAppleMusicQueue = retainedAppleMusicTransport
        persistPlaybackSession()
    }

    /// Move queue rows without rebuilding the active audio transport. A drag
    /// can invalidate prepared audio for the immediate successor, but the
    /// current song, decoder and natural-end ticket remain unchanged.
    private func moveQueueItems(
        fromOffsets source: IndexSet,
        toOffset destination: Int,
        invalidatesPreparedSuccessor: Bool
    ) {
        guard !source.isEmpty,
              source.allSatisfy({ queueEntries.indices.contains($0) }),
              destination >= 0,
              destination <= queueEntries.count else { return }
        queueEntries.move(fromOffsets: source, toOffset: destination)
        pendingNextShuffleIndices = nil
        if shuffleEnabled {
            rebuildShuffleOrder()
        }
        completeQueueReorder(invalidatesPreparedSuccessor: invalidatesPreparedSuccessor)
    }

    private func completeQueueReorder(invalidatesPreparedSuccessor: Bool) {
        if invalidatesPreparedSuccessor {
            invalidatePreparedQueueSuccessor()
        }
        persistPlaybackSession()
        if currentSong != nil { prefetchNextSong() }
    }

    /// Reorder one visible Up Next occurrence by its durable queue-slot UUID.
    /// The current presentation is resolved again at drop time, so a payload
    /// consumed by a natural transition or a concurrent queue change is a safe
    /// no-op. Managed shuffle mutates only the unplayed traversal suffix; the
    /// canonical queue and the played/current prefix stay untouched.
    @discardableResult
    func moveUpcomingQueueEntry(
        _ dragged: QueueReorderOccurrenceID,
        over target: QueueReorderOccurrenceID
    ) -> Bool {
        let currentUpcoming = upcomingQueueEntries.map {
            QueueReorderOccurrenceID(
                queueEntryID: $0.id.queueEntryID,
                roundOffset: $0.id.roundOffset
            )
        }
        guard let reordered = QueueUpcomingReorderPolicy.reorderedOccurrences(
            dragging: dragged,
            over: target,
            queueEntryIDs: queueEntries.map(\.id),
            upcomingOccurrences: currentUpcoming
        ) else { return false }
        let invalidatesPreparedSuccessor = QueueUpcomingReorderPolicy
            .shouldInvalidatePreparedSuccessor(
                before: currentUpcoming,
                after: reordered
            )

        let roundOffset = dragged.roundOffset
        let currentRoundIDs = currentUpcoming
            .filter { $0.roundOffset == roundOffset }
            .map(\.queueEntryID)
        let reorderedRoundIDs = reordered
            .filter { $0.roundOffset == roundOffset }
            .map(\.queueEntryID)
        let rawIndexByID = Dictionary(uniqueKeysWithValues: queueEntries.indices.map {
            (queueEntries[$0].id, $0)
        })
        let reorderedRawIndices = reorderedRoundIDs.compactMap { rawIndexByID[$0] }
        guard reorderedRawIndices.count == reorderedRoundIDs.count else { return false }

        if usesManagedShuffleOrder {
            switch roundOffset {
            case 0:
                let start = min(max(shufflePosition + 1, 0), shuffledIndices.count)
                let currentRawIndices = Array(shuffledIndices.dropFirst(start))
                let actualCurrentRoundIDs = currentRawIndices.compactMap { index in
                    queueEntries.indices.contains(index) ? queueEntries[index].id : nil
                }
                guard actualCurrentRoundIDs == currentRoundIDs,
                      currentRawIndices.count == reorderedRawIndices.count else { return false }
                shuffledIndices.replaceSubrange(start..<shuffledIndices.count, with: reorderedRawIndices)
            case 1:
                guard repeatMode == .all else { return false }
                let pending = preparedNextShuffleRound()
                let actualNextRoundIDs = pending.compactMap { index in
                    queueEntries.indices.contains(index) ? queueEntries[index].id : nil
                }
                guard actualNextRoundIDs == currentRoundIDs,
                      pending.count == reorderedRawIndices.count else { return false }
                pendingNextShuffleIndices = reorderedRawIndices
            default:
                return false
            }
            completeQueueReorder(
                invalidatesPreparedSuccessor: invalidatesPreparedSuccessor
            )
            return true
        }

        // A system-owned Apple Music shuffle cannot be reordered by changing
        // Primuse's raw mirror. Wait until the canonical managed traversal is
        // available instead of presenting a successful but ineffective drop.
        guard !shuffleEnabled, roundOffset == 0,
              let sourceIndex = rawIndexByID[dragged.queueEntryID],
              let desiredOffset = reorderedRoundIDs.firstIndex(of: dragged.queueEntryID) else {
            return false
        }
        let upcomingStart = min(max(currentIndex + 1, 0), queueEntries.count)
        let desiredRawIndex = upcomingStart + desiredOffset
        guard queueEntries.indices.contains(desiredRawIndex), sourceIndex >= upcomingStart else {
            return false
        }
        let destination = desiredRawIndex > sourceIndex ? desiredRawIndex + 1 : desiredRawIndex
        moveQueueItems(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destination,
            invalidatesPreparedSuccessor: invalidatesPreparedSuccessor
        )
        return true
    }

    /// Remove one durable Up Next occurrence without rebuilding a managed
    /// shuffle round. Repeat-all may present the same slot again in its next
    /// round; deleting either presentation removes that canonical slot once,
    /// while the currently playing slot remains protected.
    @discardableResult
    func removeUpcomingQueueEntry(_ occurrence: QueueReorderOccurrenceID) -> Bool {
        guard canRemoveUpcomingQueueEntries,
              queueEntries.indices.contains(currentIndex) else { return false }

        let currentUpcoming = upcomingQueueEntries.map {
            QueueReorderOccurrenceID(
                queueEntryID: $0.id.queueEntryID,
                roundOffset: $0.id.roundOffset
            )
        }
        guard let removalIndex = QueueUpcomingRemovalPolicy.queueIndex(
            for: occurrence,
            currentQueueEntryID: queueEntries[currentIndex].id,
            queueEntryIDs: queueEntries.map(\.id),
            upcomingOccurrences: currentUpcoming
        ) else { return false }
        let shouldCancelSuccessorPreparation = QueueUpcomingRemovalPolicy
            .shouldCancelSuccessorPreparation(
                removing: occurrence,
                immediateSuccessorQueueEntryID: nextQueueEntryInQueue()?.id
            )

        // Keep the active transport and its end-of-track ticket intact. The
        // old implementation called invalidateQueueTransitions() for every
        // removal, which seeks the current song and creates an audible gap even
        // when an unrelated Up Next slot was deleted. Only preparation for the
        // exact successor can become stale; its boundary callback will resolve
        // the newly rebased queue when the current track naturally finishes.

        let rebasedCurrentIndex = currentIndex - (removalIndex < currentIndex ? 1 : 0)
        if usesManagedShuffleOrder {
            guard let rebasedTraversal = QueueUpcomingRemovalPolicy.rebasedTraversal(
                shuffledIndices,
                currentPosition: shufflePosition,
                removingQueueIndex: removalIndex,
                queueCount: queueEntries.count
            ),
            rebasedTraversal.indices[rebasedTraversal.currentPosition] == rebasedCurrentIndex else {
                return false
            }

            let rebasedPending: [Int]?
            if let pendingNextShuffleIndices {
                guard let nextRound = QueueUpcomingRemovalPolicy.rebasedIndices(
                    pendingNextShuffleIndices,
                    removingQueueIndex: removalIndex,
                    queueCount: queueEntries.count
                ) else { return false }
                rebasedPending = nextRound
            } else {
                rebasedPending = nil
            }

            if shouldCancelSuccessorPreparation {
                cancelGaplessTasks()
                cancelCrossfadeAttempt()
            }
            queueEntries.remove(at: removalIndex)
            currentIndex = rebasedCurrentIndex
            shuffledIndices = rebasedTraversal.indices
            shufflePosition = rebasedTraversal.currentPosition
            pendingNextShuffleIndices = rebasedPending
        } else {
            guard !shuffleEnabled else { return false }
            if shouldCancelSuccessorPreparation {
                cancelGaplessTasks()
                cancelCrossfadeAttempt()
            }
            queueEntries.remove(at: removalIndex)
            currentIndex = rebasedCurrentIndex
            pendingNextShuffleIndices = nil
        }

        persistPlaybackSession()
        if currentSong != nil {
            updateNowPlayingInfo()
            prefetchNextSong()
        }
        return true
    }

    /// Play the queue entry at a raw `queueEntries` index, keeping the player's
    /// shuffle bookkeeping in sync. The QueueView taps map to raw queue indices;
    /// in shuffle mode `currentIndex` alone isn't enough — `shufflePosition` /
    /// `shuffledIndices` also have to point at the tapped track or the next
    /// `next()` advances from a stale shuffle position. Unlike toggling
    /// `shuffleEnabled` (which reshuffles the whole round), this only swaps the
    /// tapped index into the current shuffle position, leaving the *rest* of the
    /// round's order untouched so Up Next stays stable.
    func playFromQueue(at index: Int) async {
        guard queueEntries.indices.contains(index) else { return }
        let song = queueEntries[index].song
        guard isSourceEnabledForPlayback(song.sourceID) else {
            showPlaybackError(String(localized: "playback_error_source_disabled"))
            return
        }

        if usesManagedShuffleOrder, !isMirroringFromAppleMusic {
            if let targetPos = shuffledIndices.firstIndex(of: index) {
                // Pull the tapped track into the current shuffle position. The
                // displaced index moves to where the tapped one was, so every
                // other position keeps its relative order (no reshuffle).
                let anchorPos = min(max(shufflePosition, 0), shuffledIndices.count - 1)
                shuffledIndices.swapAt(anchorPos, targetPos)
                shufflePosition = anchorPos
            }
        }

        currentIndex = index
        persistPlaybackSession()
        await play(song: song)
    }

    /// Played entries in actual traversal order. Raw queue indices are only a
    /// valid played/current/upcoming partition when shuffle is disabled.
    var playedQueueEntries: [QueuePresentationEntry] {
        let occurrences = QueuePresentationPolicy.playedOccurrences(
            queueCount: queueEntries.count,
            currentIndex: currentIndex,
            shuffledIndices: usesManagedShuffleOrder ? shuffledIndices : nil,
            shufflePosition: shufflePosition
        )
        return presentationEntries(for: occurrences)
    }

    /// Up Next entries in the order they'll actually play. The next repeat-all
    /// shuffle round receives a distinct presentation identity even though it
    /// intentionally references the same durable queue slots.
    var upcomingQueueEntries: [QueuePresentationEntry] {
        var nextRoundIndices: [Int]?
        if usesManagedShuffleOrder, repeatMode == .all {
            nextRoundIndices = preparedNextShuffleRound()
        }
        let occurrences = QueuePresentationPolicy.upcomingOccurrences(
            queueCount: queueEntries.count,
            currentIndex: currentIndex,
            shuffledIndices: usesManagedShuffleOrder ? shuffledIndices : nil,
            shufflePosition: shufflePosition,
            nextRoundIndices: nextRoundIndices
        )
        return presentationEntries(for: occurrences)
    }

    var usesManagedShuffleOrder: Bool {
        shuffleEnabled && !(isAppleMusicMode && !isPrimuseManagingAppleMusicQueue)
    }

    private func presentationEntries(
        for occurrences: [QueuePresentationOccurrence]
    ) -> [QueuePresentationEntry] {
        occurrences.compactMap { occurrence in
            guard queueEntries.indices.contains(occurrence.queueIndex) else { return nil }
            return QueuePresentationEntry(
                entry: queueEntries[occurrence.queueIndex],
                roundOffset: occurrence.roundOffset
            )
        }
    }

    func syncSongMetadata(_ updatedSong: Song) {
        if currentSong?.id == updatedSong.id {
            currentSong = updatedSong
            let updatedDuration = updatedSong.duration.sanitizedDuration
            if updatedDuration > 0 {
                duration = updatedDuration
            }
            updateNowPlayingInfo()
            updatePlaybackState()
        }
        // Keep the per-row UUID stable — mutate only `song` so SwiftUI
        // doesn't see a row disappear/reappear when metadata backfill
        // rewrites tags mid-listening.
        if let queueIndex = queueEntries.firstIndex(where: { $0.song.id == updatedSong.id }) {
            queueEntries[queueIndex].song = updatedSong
        }
    }

    /// Replace a transient catalog-derived Apple Music identity with the
    /// canonical user-library row without restarting playback. This is used as
    /// a final guard by metadata actions that can be tapped between MusicKit
    /// polling ticks.
    func adoptCanonicalAppleMusicSong(_ canonical: Song, replacing aliasSongID: String) {
        guard canonical.sourceID == AppleMusicLibraryService.systemSourceID,
              currentSong?.sourceID == AppleMusicLibraryService.systemSourceID,
              currentSong?.id == aliasSongID else { return }

        currentSong = canonical
        if canonical.duration > 0 { duration = canonical.duration }
        for index in queueEntries.indices where queueEntries[index].song.id == aliasSongID {
            queueEntries[index].song = canonical
        }
        updateNowPlayingInfo()
        updatePlaybackState()
    }
}
