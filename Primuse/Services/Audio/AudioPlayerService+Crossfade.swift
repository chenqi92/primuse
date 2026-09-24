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
    // MARK: - Crossfade

    /// 把 playID / crossfade 归属发布给已经离开 MainActor 的解码泵。
    /// 三个来源字段的 didSet 都调用它, 漏掉任何一个都会让退役的泵继续投递。
    func syncPumpLease() {
        pumpLease.update(
            currentPlayID: playID,
            isCrossfading: isCrossfading,
            outgoingPlayID: committedCrossfade?.outgoingPlayID
        )
    }

    /// 换出的那一首在 ramp 期间解码到自然结尾时, 手里还留着一块"最后缓冲"。
    /// 它不能走 `scheduleDecodedFinalBuffer` —— track-end / gapless 回调属于
    /// 已经轮换走的 playID; 但直接丢掉会让淡出轨在 ramp 收尾前少一块音频。
    /// 这里按普通缓冲补给 primary 节点 (宽限期内它仍归换出轨所有), 不挂任何
    /// 回调; 这块缓冲从未占用 gate 配额, 所以也不需要 release。
    /// 返回 true 表示已排好, 调用方直接收工。
    func scheduleOutgoingCrossfadeTailBuffer(
        _ buffer: AVAudioPCMBuffer,
        playID id: UUID
    ) -> Bool {
        guard PrimaryPumpFinalBufferPolicy.disposition(
            playID: id,
            currentPlayID: playID,
            isCrossfading: isCrossfading,
            outgoingPlayID: committedCrossfade?.outgoingPlayID
        ) == .scheduleOutgoingTail else { return false }
        audioEngine.scheduleBuffer(buffer)
        plog("🎚️ Crossfade grace: scheduled outgoing tail buffer playID=\(id.uuidString.prefix(8))")
        return true
    }

    /// The manual rules mirror `next()` / `previous()`: a manual next steps
    /// past repeat-one and wraps a multi-song queue even with repeat off.
    func manualNextTraversalTarget() -> QueueTraversalTarget? {
        nextQueueTraversalTarget(
            respectsRepeatOne: queue.count == 1,
            wrapsAtEnd: queue.count > 1 || repeatMode == .all
        )
    }

    private func crossfadeSuccessorTarget(
        _ rule: CrossfadeSuccessorRule
    ) -> QueueTraversalTarget? {
        switch rule {
        case .automatic: nextQueueTraversalTarget()
        case .manualNext: manualNextTraversalTarget()
        case .manualPrevious: previousQueueTraversalTarget()
        }
    }

    private func crossfadeSuccessorEntry(
        _ rule: CrossfadeSuccessorRule
    ) -> QueueEntry? {
        guard let target = crossfadeSuccessorTarget(rule),
              queueEntries.indices.contains(target.queueIndex) else { return nil }
        return queueEntries[target.queueIndex]
    }

    private func isCurrentCrossfadeAttempt(
        _ attemptID: UUID,
        sourcePlayID: UUID,
        queueGeneration sourceQueueGeneration: Int,
        nextEntryID: UUID,
        successorRule: CrossfadeSuccessorRule
    ) -> Bool {
        !Task.isCancelled
            && isPlaying
            && crossfadeAttemptID == attemptID
            && playID == sourcePlayID
            && queueGeneration == sourceQueueGeneration
            && crossfadeSuccessorEntry(successorRule)?.id == nextEntryID
    }

    private func failCrossfadeAttempt(_ attemptID: UUID) {
        guard crossfadeAttemptID == attemptID else { return }
        lastFailedCrossfadeAttemptID = attemptID
        let hadAudibleTransition = isCrossfading || crossfadeTimer != nil
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTimerAttemptID = nil
        crossfadeTriggered = false
        isCrossfading = false
        crossfadeSwapDone = false
        if hadAudibleTransition {
            audioEngine.stopCrossfadeNode()
            audioEngine.restorePrimaryProgramVolume()
        }
    }

    /// Invalidates both the not-yet-ready startup and any active fade/feeder.
    /// Every queue or playback ownership change goes through this helper so an
    /// old task cannot mutate a newer attempt's flags or queue index.
    func cancelCrossfadeAttempt(
        finishingCommittedTransition: Bool = false,
        completionMode: CrossfadeCompletionMode = .activePlayback
    ) {
        if finishingCommittedTransition,
           let committedCrossfade,
           crossfadeAttemptID == committedCrossfade.attemptID,
           playID == committedCrossfade.playID {
            crossfadeTimer?.invalidate()
            crossfadeTimer = nil
            crossfadeTimerAttemptID = nil
            completeCrossfade(
                attemptID: committedCrossfade.attemptID,
                playID: committedCrossfade.playID,
                nextSong: committedCrossfade.song,
                nextURL: committedCrossfade.url,
                nextDecoderKind: committedCrossfade.decoderKind,
                programVolume: committedCrossfade.programVolume,
                completionMode: completionMode
            )
            return
        }
        let hadAudibleTransition = isCrossfading || crossfadeTimer != nil
        let hadActiveAttempt = crossfadeAttemptID != nil
            || crossfadeStartupTask != nil
            || crossfadeDecodingTask != nil
            || crossfadeTimer != nil
            || crossfadeTriggered
            || isCrossfading
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask?.cancel()
        crossfadeStartupTask = nil
        crossfadeDecodingTask?.cancel()
        crossfadeDecodingTask = nil
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeTimerAttemptID = nil
        crossfadeTriggered = false
        isCrossfading = false
        crossfadeSwapDone = false
        if hadActiveAttempt {
            audioEngine.stopCrossfadeNode()
        }
        if hadAudibleTransition {
            audioEngine.restorePrimaryProgramVolume()
        }
    }

    func invalidateQueueTransitions(rebuildCurrentTransport: Bool = true) {
        let pendingMusicVideoID = pendingMusicVideoPlayID == playID
            ? pendingMusicVideoPlayID
            : nil
        let hadActiveMusicVideoSeek = hasMusicVideoSeekActivityEvidence
        let hadAdvanceEligibility = playbackAdvancePolicy.activeTicket != nil
        let shouldPreservePendingMusicVideoTicket = rebuildCurrentTransport
            && pendingMusicVideoID != nil
            && hadAdvanceEligibility
        invalidateInterruptionResumePreservingIntent()
        let shouldRebuildCurrentTransport = rebuildCurrentTransport
            && hadAdvanceEligibility
            && isPlaying
            && currentSong != nil
            && !isAppleMusicMode
            && !isLiveRadio
            && !isCastingMode
            && !isSystemMediaPlaybackActive
        let shouldRearmMusicVideo = rebuildCurrentTransport
            && hadAdvanceEligibility
            && (isPlaying || hadActiveMusicVideoSeek)
            && isSystemMediaPlaybackActive
        if !shouldPreservePendingMusicVideoTicket {
            invalidateAutomaticAdvance(reason: "queue-generation-change")
        }
        queueGeneration += 1
        cancelGaplessTasks()
        if shouldRebuildCurrentTransport {
            stopTimeUpdater()
            syncPlaybackProgressFromEngine()
        }
        cancelCrossfadeAttempt(
            finishingCommittedTransition: true,
            completionMode: shouldRebuildCurrentTransport
                ? .preserveCachedProgress
                : .activePlayback
        )
        if let pendingMusicVideoID,
           shouldPreservePendingMusicVideoTicket,
           pendingMusicVideoID == playID {
            pendingMusicVideoPlayID = pendingMusicVideoID
        } else if shouldRearmMusicVideo,
           let song = currentSong,
           let player = activeSystemMediaPlayer,
           let id = playID {
            if hadActiveMusicVideoSeek {
                musicVideoSeekActivityEvidence = .init(
                    itemID: song.id,
                    playID: id,
                    observerGeneration: musicVideoObserverGeneration
                )
                seek(to: currentTime, startPlaying: true)
            } else {
                _ = beginAutomaticAdvanceTransport(
                    itemID: song.id,
                    reason: "queue-generation-music-video-rearm"
                )
                configureMusicVideoObservers(for: player, playID: id)
            }
        } else if shouldRebuildCurrentTransport {
            let resumeTime = currentTime
            pendingRecoveryTime = resumeTime
            needsPlaybackRecovery = true
            seek(to: resumeTime, startPlaying: true, isRecovery: true)
        }
    }

    // MARK: - Manual skip

    /// An earlier skip is still preparing its neighbour and the queue position
    /// has not moved yet. Whoever calls this takes that attempt over: it is
    /// cancelled here, and its target is handed back so a second skip can count
    /// the first one instead of landing on the same song twice.
    func takePendingManualSkipCrossfade() -> QueueTraversalTarget? {
        guard let pending = pendingManualSkipCrossfade else { return nil }
        pendingManualSkipCrossfade = nil
        guard crossfadeAttemptID == pending.attemptID,
              lastCommittedCrossfadeAttemptID != pending.attemptID else { return nil }
        cancelCrossfadeAttempt()
        guard pending.queueGeneration == queueGeneration else { return nil }
        return pending.target
    }

    /// Runs a user skip through the crossfade commit and swap instead of
    /// cutting the audible song off. Returns nil when the skip is not eligible
    /// and nothing was touched; the caller then cuts exactly as before.
    func crossfadeToManualNeighbour(
        _ target: QueueTraversalTarget,
        rule: CrossfadeSuccessorRule
    ) async -> ManualSkipCrossfadePolicy.Outcome? {
        guard queueEntries.indices.contains(target.queueIndex),
              let sourcePlayID = playID else { return nil }
        let entry = queueEntries[target.queueIndex]
        let song = entry.song
        let hasLocalAudio = playbackMetadataSourceType?(song.sourceID) == .local
            || sourceManager?.hasUsableCachedAudioForPlayback(song) == true
        guard ManualSkipCrossfadePolicy.isEligible(.init(
            crossfadeIsEnabled: shouldUseCrossfade(playbackSettings.snapshot()),
            localEngineIsRendering: isPlaying
                && !isLoading
                && !isAppleMusicMode
                && !isLiveRadio
                && !isCastingMode
                && castingController == nil
                && !isSystemMediaPlaybackActive
                && audioEngine.isActuallyPlaying,
            hasActiveCrossfadeAttempt: crossfadeAttemptID != nil
                || crossfadeTriggered
                || isCrossfading
                || crossfadeTimer != nil,
            hasPendingTransportWork: needsPlaybackRecovery
                || seekTask != nil
                || activeStreamingDownloadPreparation != nil,
            neighbourIsCurrentSong: song.id == currentSong?.id,
            neighbourBypassesContinuousAudio: shouldBypassContinuousAudioTransition(for: song),
            neighbourHasLocalAudio: hasLocalAudio
        )) else { return nil }

        // The same bookkeeping `play(song:)` does for an explicit track change.
        registerPlayIntent()
        beginPlaybackErrorScope()
        if let lockedID = sleepStopAfterSongID, lockedID != song.id {
            plog("🌙 Sleep-at-track-end cancelled by explicit track change")
            sleepStopAfterSongID = nil
        }
        sourceManager?.cancelMusicVideoDownloads(keeping: song)

        let attemptID = UUID()
        let sourceQueueGeneration = queueGeneration
        crossfadeAttemptID = attemptID
        crossfadeTriggered = true
        pendingManualSkipCrossfade = PendingManualSkipCrossfade(
            attemptID: attemptID,
            target: target,
            queueGeneration: sourceQueueGeneration
        )
        plog("🎚️ Manual skip crossfade → '\(song.title)'")
        crossfadeStartupTask?.cancel()
        let startup = Task {
            await startCrossfade(
                duration: ManualSkipCrossfadePolicy.overlapDuration,
                attemptID: attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: entry.id,
                successorRule: rule,
                preparationTimeout: ManualSkipCrossfadePolicy.preparationTimeout
            )
        }
        crossfadeStartupTask = startup
        await startup.value

        if pendingManualSkipCrossfade?.attemptID == attemptID {
            pendingManualSkipCrossfade = nil
        }
        let outcome = ManualSkipCrossfadePolicy.outcome(
            attemptID: attemptID,
            lastCommittedAttemptID: lastCommittedCrossfadeAttemptID,
            lastFailedAttemptID: lastFailedCrossfadeAttemptID
        )
        // A stale exit leaves the attempt's flags behind. Nothing else will
        // clear them for this song, and they would block its automatic fade.
        if outcome == .superseded, crossfadeAttemptID == attemptID {
            cancelCrossfadeAttempt()
        }
        if outcome != .committed {
            plog("🎚️ Manual skip crossfade \(outcome) for '\(song.title)'")
        }
        return outcome
    }

    func checkCrossfade() {
        // This runs on every playback progress tick. Avoid copying the full
        // settings payload in the overwhelmingly common disabled case.
        guard playbackSettings.outputMode == .effects,
              playbackSettings.crossfadeEnabled,
              !crossfadeTriggered else { return }
        let settings = playbackSettings.snapshot()
        let songID = currentSong?.id
        let silenceProfile = songID.flatMap { silenceProfiles[$0] }
        let analyzedDuration = silenceProfile?.playableDuration
        let nominalDuration = duration > 0 ? duration : (analyzedDuration ?? 0)
        let smartMixAnalysis = settings.crossfadeMode == .smart
            ? songID.flatMap { smartMixAnalyses[$0] }
            : nil
        let sourceTimelineOffset = smartMixAnalysis?.backend == .musicUnderstanding
            ? (currentSong?.cueStartTime ?? 0)
            : 0
        guard let transitionPlan = SmartMixTransitionPlanner.plan(
            nominalDuration: nominalDuration,
            analyzedPlayableDuration: analyzedDuration,
            requestedOverlap: settings.crossfadeDuration,
            analysis: smartMixAnalysis,
            analysisTimelineOffset: sourceTimelineOffset
                + (silenceProfile?.leadingTrimmedDuration ?? 0)
        ), currentTime >= transitionPlan.triggerTime else { return }
        // "Stop after this song" owns the upcoming boundary. Let the normal
        // end callback stop playback instead of committing the next queue item.
        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            return
        }
        // Skip under repeat-one — `nextSongInQueue()` returns the
        // current song there, which would crossfade-to-self. Pre-fix
        // `currentIndex < queue.count - 1` was always false in the
        // single-song repeat-one case so crossfade was never enabled;
        // preserve that.
        guard repeatMode != .one,
              let sourcePlayID = playID,
              let nextEntry = nextQueueEntryInQueue() else { return }
        let nextSong = nextEntry.song
        guard nextSong.id != currentSong?.id else { return }
        guard shouldBypassContinuousAudioTransition(for: nextSong) == false else { return }

        let attemptID = UUID()
        let sourceQueueGeneration = queueGeneration
        let effectiveDuration = SmartTransitionPolicy.effectiveOverlap(
            requestedOverlap: transitionPlan.overlapDuration,
            currentTime: currentTime,
            playableEndpoint: transitionPlan.playableEndpoint
        )
        guard effectiveDuration > 0 else { return }
        if settings.crossfadeMode == .smart {
            plog(
                String(
                    format: "Smart mix %@ via %@: %.2fs overlap",
                    transitionPlan.basis.rawValue,
                    transitionPlan.analysisBackend?.rawValue ?? "fallback",
                    effectiveDuration
                )
            )
        }
        crossfadeAttemptID = attemptID
        crossfadeTriggered = true
        crossfadeStartupTask?.cancel()
        crossfadeStartupTask = Task {
            await startCrossfade(
                duration: effectiveDuration,
                attemptID: attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntry.id
            )
            // 过期退出(暂停、别的播放请求、后继歌曲变了)不会走 failCrossfadeAttempt,
            // 这一尝试的标记就留在了原地。没人会再清它: `crossfadeTriggered` 挡住
            // 本首后面的重试, `isCrossfading` 会同时关掉曲末看门狗与每拍的
            // checkCrossfade。手动切歌那条路早就补了这一步(见 crossfadeToManualNeighbour),
            // 自动这条一直漏着。
            guard crossfadeAttemptID == attemptID,
                  lastCommittedCrossfadeAttemptID != attemptID else { return }
            plog("🎚️ Crossfade attempt superseded; clearing its flags")
            cancelCrossfadeAttempt()
        }
    }

    private func startCrossfade(
        duration crossfadeDuration: Double,
        attemptID: UUID,
        sourcePlayID: UUID,
        queueGeneration sourceQueueGeneration: Int,
        nextEntryID: UUID,
        successorRule: CrossfadeSuccessorRule = .automatic,
        preparationTimeout: TimeInterval = TimeInterval(AudioPlayerService.firstBufferTimeoutSeconds)
    ) async {
        guard isCurrentCrossfadeAttempt(
            attemptID,
            sourcePlayID: sourcePlayID,
            queueGeneration: sourceQueueGeneration,
            nextEntryID: nextEntryID,
            successorRule: successorRule
        ) else { return }
        guard shouldUseCrossfade(playbackSettings.snapshot()) else {
            failCrossfadeAttempt(attemptID)
            return
        }
        guard let nextEntry = crossfadeSuccessorEntry(successorRule),
              nextEntry.id == nextEntryID else {
            failCrossfadeAttempt(attemptID)
            return
        }
        let nextSong = nextEntry.song
        guard shouldBypassContinuousAudioTransition(for: nextSong) == false else {
            failCrossfadeAttempt(attemptID)
            return
        }
        let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(
            sourceID: nextSong.sourceID
        )

        let preparationDeadline = Date().addingTimeInterval(preparationTimeout)
        do {
            let nextURL = try await resolvedURL(
                for: nextSong,
                forContinuousPreparation: true
            )
            let nextDecoderKind = await decoderKind(for: nextSong, url: nextURL)
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID,
                successorRule: successorRule
            ) else { return }
            guard nextDecoderKind == .native
                    || nextDecoderKind == .ffmpeg,
                  nextDecoderKind != .native
                    || nativeDecoder.canDecode(url: nextURL),
                  let outputFormat = audioEngine.outputFormat else {
                failCrossfadeAttempt(attemptID)
                return
            }
            if nextSong.id == currentSong?.id,
               activeDecoderKind == .cloudStream
                    || activeDecoderKind == .httpStream
                    || nextDecoderKind == .cloudStream
                    || nextDecoderKind == .httpStream {
                failCrossfadeAttempt(attemptID)
                return
            }

            // crossfade 一开始就把 UI 切到下一首 —— 用户听到的主音是 next
            // 在淡入接管, 看到的应该跟着是 next。之前要等 ramp 跑完才切,
            // 出现「下一首歌的声音出来了但播放器还显示上一首」的不一致。
            // 在拿到下一首缓冲 *之前* 不冻结进度、不推进队列索引/
            // currentSong/scrobble —— 否则网络预取慢或 decode 失败时会抑制
            // 曲末 watchdog，并出现
            // 「UI 已切到下一首、声音还停在上一首、isCrossfading 卡 true 进度永久冻结」。

            // 下一首的回放增益和解码准备并行解析。ramp 要直接淡入到它的稳态
            // 音量, 而不是先淡到 1.0、换节点后再跳一次; 出去那首同样从自己的
            // 稳态音量淡出, 而不是第一拍先跳回 1.0。
            let startupSettings = playbackSettings.snapshot()
            let replayGainResolution: Task<ReplayGainValues, Never>? = shouldApplyReplayGain(startupSettings)
                ? Task { [nextSong, nextURL] in
                    await self.resolveReplayGainValues(
                        for: nextSong,
                        url: nextURL,
                        mode: startupSettings.replayGainMode,
                        allowFileRead: true
                    )
                }
                : nil

            // Decode into crossfade node — 先确保能解码并拿到首个 buffer。
            guard let stream = await decodeStream(
                for: nextSong,
                url: nextURL,
                outputFormat: outputFormat,
                sourceStreamEpoch: sourceStreamEpoch
            ) else {
                failCrossfadeAttempt(attemptID)
                return
            }
            let iteratorBox = BufferIteratorBox(stream.makeAsyncIterator())

            // swap 还没发生 —— 新曲的 buffer 先进 crossfade 节点。
            crossfadeSwapDone = false
            let firstBufferSeconds = Int(ceil(preparationDeadline.timeIntervalSinceNow))
            guard firstBufferSeconds > 0 else {
                failCrossfadeAttempt(attemptID)
                return
            }
            guard let firstBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: firstBufferSeconds
            ) else {
                failCrossfadeAttempt(attemptID)
                return
            }
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID,
                successorRule: successorRule
            ) else { return }
            // Hold one decoded buffer back so EOF is known before scheduling
            // the physical last buffer. This gives unknown-duration cloud
            // tracks a reliable `.dataPlayedBack` boundary instead of relying
            // on the duration watchdog.
            let remainingBufferSeconds = Int(ceil(preparationDeadline.timeIntervalSinceNow))
            guard remainingBufferSeconds > 0 else {
                failCrossfadeAttempt(attemptID)
                return
            }
            let secondBuffer = try await awaitFirstBuffer(
                from: iteratorBox,
                timeoutSeconds: remainingBufferSeconds
            )
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID,
                successorRule: successorRule
            ) else { return }
            // 回放增益的解析通常早就完成了(本机文件只要几毫秒)。等它是为了
            // 让 ramp 拿到确定的目标音量; 等完要重验一次尝试是否仍然有效。
            let commitSettings = playbackSettings.snapshot()
            var incomingReplayGain = ReplayGainValues()
            if shouldApplyReplayGain(commitSettings) {
                if let replayGainResolution {
                    incomingReplayGain = await replayGainResolution.value
                } else {
                    incomingReplayGain = await resolveReplayGainValues(
                        for: nextSong,
                        url: nextURL,
                        mode: commitSettings.replayGainMode,
                        allowFileRead: true
                    )
                }
            } else {
                replayGainResolution?.cancel()
            }
            guard isCurrentCrossfadeAttempt(
                attemptID,
                sourcePlayID: sourcePlayID,
                queueGeneration: sourceQueueGeneration,
                nextEntryID: nextEntryID,
                successorRule: successorRule
            ) else { return }
            // Settings and the sleep lock can change while remote resolution
            // or prefetch is in flight. Revalidate at the commit boundary.
            guard shouldUseCrossfade(playbackSettings.snapshot()),
                  sleepStopAfterSongID != currentSong?.id else {
                failCrossfadeAttempt(attemptID)
                return
            }
            let incomingProgramVolume = incomingReplayGain.linearGain
            isCrossfading = true
            lastCommittedCrossfadeAttemptID = attemptID
            let nextPlayID = UUID()
            let activatedSong = songRefreshingLatestDuration(nextSong)
            committedCrossfade = CommittedCrossfade(
                attemptID: attemptID,
                playID: nextPlayID,
                song: activatedSong,
                url: nextURL,
                decoderKind: nextDecoderKind,
                outgoingPlayID: sourcePlayID,
                programVolume: incomingProgramVolume
            )
            playID = nextPlayID
            beginAutomaticAdvanceTransport(
                itemID: activatedSong.id,
                reason: "crossfade-commit"
            )
            resetDecodedBufferHealth(resetRecoveryAttempts: true)

            // 解码就绪, 现在才把 UI/索引/scrobble 切到下一首 —— 用户听到 next
            // 淡入接管, 看到的也跟着切。
            if let previous = currentSong {
                sourceManager?.finalizeStreamingSession(for: previous)
            }
            if let target = crossfadeSuccessorTarget(successorRule) {
                applyQueueTraversalTarget(target)
            }
            currentSong = activatedSong
            currentTime = 0
            duration = activatedSong.duration.sanitizedDuration
            applyResolvedDuration(duration, toSongID: activatedSong.id)
            library?.recordPlayback(of: activatedSong.id)
            ScrobbleService.shared.handlePlaybackStarted(song: activatedSong)
            PlayHistoryStore.shared.beginSession(song: activatedSong)
            updateNowPlayingInfo()
            updateNowPlayingArtworkIfNeeded()
            updatePlaybackState()
            // 淡入淡出只接受已经在本机的下一首。这里不接着预取的话, 起播时那一批
            // 预取用完之后, 远端音乐源上的转场就再也不会发生, 每次都退回硬切。
            prefetchNextSong()

            let gate = DecodedBufferGate(
                maxBufferedDuration: Self.decodedAudioLookahead,
                maxBufferedBytes: Self.maxInFlightDecodedBytes,
                maxBufferCount: Self.maxInFlightDecodedBufferCount
            )
            if secondBuffer == nil {
                scheduleCrossfadeFinalBuffer(firstBuffer, playID: nextPlayID)
            } else {
                await scheduleTrackedDecodedBuffer(
                    firstBuffer,
                    onCrossfadeNode: true,
                    gate: gate
                )
                guard !Task.isCancelled,
                      playID == nextPlayID,
                      crossfadeAttemptID == attemptID,
                      committedCrossfade?.playID == nextPlayID else {
                    await gate.drain()
                    return
                }
            }
            installDecodedBufferGate(gate, playID: nextPlayID)
            audioEngine.playCrossfadeNode()

            crossfadeStartupTask = nil
            crossfadeDecodingTask = Task { [iteratorBox, gate] in
                var lastBuffer = secondBuffer
                var decodeFailed = false
                defer { Task { await gate.drain() } }
                do {
                    while let buffer = try await iteratorBox.next() {
                        guard !Task.isCancelled else { return }
                        if let previous = lastBuffer {
                            let bufferedDuration = Self.decodedBufferDuration(previous)
                            let bufferedByteCount = Self.decodedBufferByteCount(previous)
                            await gate.acquire(
                                duration: bufferedDuration,
                                byteCount: bufferedByteCount
                            )
                            guard !Task.isCancelled, self.playID == nextPlayID else { return }
                            // swap 之后, 这个解码任务投递的物理节点已经变成
                            // primary。继续用 scheduleCrossfadeBuffer 会把 buffer
                            // 喂到换出后被静音/reset 的旧节点上(歌中途静音)。
                            if self.crossfadeSwapDone {
                                self.audioEngine.scheduleBuffer(
                                    previous,
                                    completionCallbackType: .dataPlayedBack
                                ) { _ in
                                    gate.release(
                                        duration: bufferedDuration,
                                        byteCount: bufferedByteCount
                                    )
                                }
                            } else {
                                self.audioEngine.scheduleCrossfadeBuffer(
                                    previous,
                                    completionCallbackType: .dataPlayedBack
                                ) { _ in
                                    gate.release(
                                        duration: bufferedDuration,
                                        byteCount: bufferedByteCount
                                    )
                                }
                            }
                        }
                        lastBuffer = buffer
                    }
                } catch {
                    if !Task.isCancelled {
                        decodeFailed = true
                        plog("Crossfade decode error: \(error)")
                    }
                }
                if let finalBuffer = lastBuffer {
                    guard !Task.isCancelled, self.playID == nextPlayID else { return }
                    if decodeFailed {
                        self.scheduleCrossfadeFinalBufferAsFailure(finalBuffer, playID: nextPlayID)
                    } else {
                        self.scheduleCrossfadeFinalBuffer(finalBuffer, playID: nextPlayID)
                    }
                } else if decodeFailed, !Task.isCancelled, self.playID == nextPlayID {
                    await self.autoAdvanceAfterFailure()
                }
            }

            startCrossfadeRamp(
                duration: crossfadeDuration,
                attemptID: attemptID,
                playID: nextPlayID,
                nextSong: nextSong,
                nextURL: nextURL,
                nextDecoderKind: nextDecoderKind,
                programVolume: incomingProgramVolume
            )
        } catch {
            guard crossfadeAttemptID == attemptID else { return }
            plog("Crossfade start error: \(error)")
            failCrossfadeAttempt(attemptID)
        }
    }

    private func startCrossfadeRamp(
        duration: Double,
        attemptID: UUID,
        playID rampPlayID: UUID,
        nextSong: Song,
        nextURL: URL,
        nextDecoderKind: DecoderKind,
        programVolume incomingProgramVolume: Float
    ) {
        guard crossfadeAttemptID == attemptID,
              playID == rampPlayID,
              committedCrossfade?.attemptID == attemptID else { return }
        // primary 此刻还是出去的那首, 它的稳态音量就是淡出的起点。
        let outgoingProgramVolume = audioEngine.primaryProgramVolume
        let totalSteps = max(1, (duration / 0.05).finiteInt(or: 1))
        let stepCounter = StepCounter()
        crossfadeTimerAttemptID = attemptID
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.crossfadeAttemptID == attemptID,
                      self.playID == rampPlayID else {
                    if self?.crossfadeTimerAttemptID == attemptID {
                        self?.crossfadeTimer?.invalidate()
                        self?.crossfadeTimer = nil
                        self?.crossfadeTimerAttemptID = nil
                    }
                    return
                }
                // AudioEngine pauses both physical nodes. Freeze the ramp too;
                // otherwise a user pause completes the swap in silence.
                guard self.isPlaying else { return }
                stepCounter.value += 1
                let progress = Float(stepCounter.value) / Float(totalSteps)

                if progress >= 1.0 {
                    if self.crossfadeTimerAttemptID == attemptID {
                        self.crossfadeTimer?.invalidate()
                        self.crossfadeTimer = nil
                        self.crossfadeTimerAttemptID = nil
                    }
                    self.completeCrossfade(
                        attemptID: attemptID,
                        playID: rampPlayID,
                        nextSong: nextSong,
                        nextURL: nextURL,
                        nextDecoderKind: nextDecoderKind,
                        programVolume: incomingProgramVolume
                    )
                } else {
                    // Equal-power curve between the two songs' own program
                    // volumes: the outgoing song fades out from its ReplayGain
                    // level and the incoming one fades in to its own, so the
                    // transition never steps through unity gain.
                    let volumes = ReplayGainPolicy.crossfadeVolumes(
                        progress: Double(progress),
                        outgoingGain: outgoingProgramVolume,
                        incomingGain: incomingProgramVolume
                    )
                    self.audioEngine.setCrossfadeVolumes(
                        primary: volumes.outgoing,
                        crossfade: volumes.incoming
                    )
                }
            }
        }
        crossfadeTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func completeCrossfade(
        attemptID: UUID,
        playID completedPlayID: UUID,
        nextSong: Song,
        nextURL: URL,
        nextDecoderKind: DecoderKind,
        programVolume: Float,
        completionMode: CrossfadeCompletionMode = .activePlayback
    ) {
        guard crossfadeAttemptID == attemptID, playID == completedPlayID else { return }
        // Normal completion captures the incoming node while it still has its
        // crossfade identity. Lifecycle-driven completion has already frozen
        // that visible clock and must not query the stopped graph again.
        if completionMode == .activePlayback {
            syncPlaybackProgressFromEngine()
        }
        // Stop old decoding
        decodingTask?.cancel()
        decodingTask = nil

        // swap 把 crossfade 节点变成 primary。先置位, 让仍在运行的 crossfade
        // 解码任务从下一个 buffer 起改投 primary 节点, 不再喂换出的旧节点。
        crossfadeSwapDone = true

        // Swap nodes. The ramp already faded the incoming song in to its
        // program volume; the swap hands that volume over unchanged.
        audioEngine.swapPlayerNodes(programVolume: programVolume)

        // Transfer crossfade decoding task to main
        decodingTask = crossfadeDecodingTask
        crossfadeDecodingTask = nil

        // 注意: currentSong / queue index / scrobble session 已经在
        // startCrossfade 早期设置好了, 不在这里重复 (重复会让 ScrobbleService
        // 误以为又开了一首新歌, 重新计时)。
        activeDecoderKind = nextDecoderKind
        crossfadeAttemptID = nil
        committedCrossfade = nil
        crossfadeStartupTask = nil
        crossfadeTriggered = false
        isCrossfading = false
        if completionMode == .activePlayback {
            startTimeUpdater()
        }
        plog("🔄 completeCrossfade: swap done, currentSong=\(nextSong.title)")

        if !nextSong.isCueTrack,
           nextDecoderKind != .cloudStream,
           nextDecoderKind != .httpStream,
           nextDecoderKind != .streaming {
            Task {
                let decoder: any PrimuseAudioDecoder = nextDecoderKind == .ffmpeg
                    ? self.ffmpegDecoder : self.nativeDecoder
                if let info = try? await decoder.fileInfo(for: nextURL) {
                    guard self.playID == completedPlayID,
                          self.currentSong?.id == nextSong.id,
                          info.duration.isFinite,
                          info.duration > 0 else { return }
                    self.duration = info.duration
                }
            }
        }

        if completionMode == .activePlayback {
            updateNowPlayingInfo()
            updatePlaybackState()
        }
    }
}
