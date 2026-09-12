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
    // MARK: - Gapless Playback

    func startGaplessPreparation(playID id: UUID, transition: GaplessTransitionState) {
        gaplessPreparationTask?.cancel()
        gaplessPreparationTask = Task { [id, transition] in
            await self.prepareGaplessNextTrack(playID: id, transition: transition)
        }
    }

    func handleGaplessBoundary(
        transition: GaplessTransitionState,
        playID id: UUID
    ) async {
        guard !transition.didBoundaryFire else {
            plog("🛡️ dropped duplicate gapless boundary ticket=\(transition.advanceTicket.id.uuidString.prefix(8))")
            return
        }
        guard automaticAdvanceDecision(
            for: transition.advanceTicket,
            trigger: "gapless-boundary",
            consume: false
        ) == .accepted else {
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            return
        }
        transition.didBoundaryFire = true

        // 防御性兜底: 10 秒内 boundary 触发 ≥4 次 = 队列里有 partial/坏掉
        // 的歌反复切歌, 强制 pause 并 cancel 后续准备, 避免占满
        // CPU + 不停下载 + UI 像是 loading 卡死的体感。
        let now = Date()
        recentBoundaryTimes.append(now)
        recentBoundaryTimes.removeAll { now.timeIntervalSince($0) > Self.boundaryStormWindow }
        if recentBoundaryTimes.count >= Self.boundaryStormThreshold {
            plog("⚠️ gapless boundary storm: \(recentBoundaryTimes.count) 次 / \(Int(Self.boundaryStormWindow))s — 暂停播放, 队列里可能有不完整的缓存文件")
            recentBoundaryTimes.removeAll()
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            pause()
            return
        }

        // Sanity check: 当前歌还远没听完就 fire boundary, 说明上游有问题
        // (CloudPlaybackSource 短读 / decoder 误判 EOF / MP3 帧元数据偏差),
        // 直接切歌会让用户体感是"歌没播完就跳了"。这里重建当前歌曲的
        // decoder pipeline, 从当前进度前一点继续拉数据; 如果仍失败,
        // seek 路径会停在当前曲而不是静默跳到下一首。
        if duration > 30, currentTime < duration - 5, !isLoading {
            plog("⚠️ premature gapless boundary suppressed: currentTime=\(String(format: "%.1f", currentTime))s duration=\(String(format: "%.1f", duration))s playID=\(id.uuidString.prefix(8))")
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            showPlaybackError(String(localized: "playback_error_connection"))
            let recoveryTime = max(0, currentTime - 2)
            seek(to: recoveryTime, startPlaying: true, isRecovery: true)
            return
        }

        let settings = playbackSettings.snapshot()

        // The user can switch Crossfade on after the gapless final buffer
        // has already been scheduled. In that race, the crossfade path owns
        // the transition and will swap nodes; do not also advance here.
        if shouldUseCrossfade(settings), crossfadeTriggered {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            return
        }

        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            stopAtTrackEnd()
            return
        }

        guard shouldAttemptGapless(settings: settings),
              queueGeneration == transition.queueGeneration,
              let prepared = transition.prepared,
              nextQueueEntryInQueue()?.id == prepared.queueEntryID else {
            transition.shouldCancelPreparation = true
            gaplessPreparationTask?.cancel()
            gaplessPreparationTask = nil
            await handleTrackEnd(
                advanceTicket: transition.advanceTicket,
                trigger: "gapless-fallback"
            )
            return
        }

        let handoff = playbackAdvancePolicy.handoff(
            from: transition.advanceTicket,
            to: prepared.followingTransition.advanceTicket,
            currentItemID: currentSong?.id,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended,
            transportIsActive: isPlaying && audioEngine.isActuallyPlaying
        )
        guard handoff == .accepted else {
            plog("🛡️ dropped gapless handoff reason=\(handoff.rawValue) generation=\(transition.advanceTicket.generation)")
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            return
        }
        localPipelineAdvanceTicket = prepared.followingTransition.advanceTicket
        plog("✅ auto-advance handoff trigger=gapless-boundary generation=\(prepared.followingTransition.advanceTicket.generation) ticket=\(prepared.followingTransition.advanceTicket.id.uuidString.prefix(8))")

        activateGaplessTrack(prepared, completedTransition: transition, playID: id)
    }

    private func activateGaplessTrack(
        _ prepared: GaplessPreparedTrack,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        guard playID == id else { return }

        let activatedSong = songRefreshingLatestDuration(prepared.song)
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        if let gate = completedTransition.bufferGate {
            installDecodedBufferGate(gate, playID: id)
        }

        if let previous = currentSong {
            sourceManager?.finalizeStreamingSession(for: previous)
        }

        let boundaryWasCommitted = audioEngine.markTrackBoundary(
            completedTransition.boundary
        )
        advanceToNextIndex()
        currentSong = activatedSong
        duration = activatedSong.duration.sanitizedDuration
        applyResolvedDuration(duration, toSongID: activatedSong.id)
        currentTime = 0
        isLoading = false
        isPlaying = true
        isAtTrackEnd = false
        crossfadeTriggered = false
        isCrossfading = false
        activeDecoderKind = prepared.decoderKind
        library?.recordPlayback(of: activatedSong.id)
        ScrobbleService.shared.handlePlaybackStarted(song: activatedSong)
        PlayHistoryStore.shared.beginSession(song: activatedSong)

        guard boundaryWasCommitted else {
            plog("⚠️ gapless boundary token was stale; rebuilding the activated track")
            completedTransition.shouldCancelPreparation = true
            cancelGaplessTasks()
            pendingRecoveryTime = 0
            needsPlaybackRecovery = true
            seek(to: 0, startPlaying: true, isRecovery: true)
            return
        }

        let settings = playbackSettings.snapshot()
        if shouldApplyReplayGain(settings) {
            Task { [id] in
                await self.applyReplayGain(
                    for: activatedSong,
                    url: prepared.url,
                    mode: settings.replayGainMode,
                    allowFileRead: prepared.decoderKind != .cloudStream && prepared.decoderKind != .httpStream,
                    expectedPlayID: id,
                    expectedSongID: activatedSong.id
                )
            }
        } else {
            audioEngine.resetPlayerVolume()
        }

        if duration <= 0,
           !activatedSong.isCueTrack,
           prepared.decoderKind != .cloudStream,
           prepared.decoderKind != .httpStream {
            Task { [id] in
                let decoder: any PrimuseAudioDecoder = prepared.decoderKind == .ffmpeg
                    ? self.ffmpegDecoder : self.nativeDecoder
                if let info = try? await decoder.fileInfo(for: prepared.url) {
                    guard self.playID == id, self.currentSong?.id == activatedSong.id else { return }
                    if self.applyResolvedDuration(info.duration, toSongID: activatedSong.id) {
                        self.updateNowPlayingInfo()
                    }
                }
            }
        }

        startTimeUpdater()
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        prefetchNextSong()
        startGaplessFollowupPreparation(
            playID: id,
            after: completedTransition,
            followingTransition: prepared.followingTransition
        )
    }

    private func startGaplessFollowupPreparation(
        playID id: UUID,
        after completedTransition: GaplessTransitionState,
        followingTransition: GaplessTransitionState
    ) {
        gaplessFollowupTask?.cancel()
        gaplessFollowupTask = Task { [id, completedTransition, followingTransition] in
            // 等当前边界落定再排下一首, 不再 100ms 轮询一整首歌。
            await completedTransition.settlement.waitUntilSettled()

            guard !Task.isCancelled,
                  self.playID == id,
                  self.queueGeneration == completedTransition.queueGeneration,
                  !completedTransition.shouldCancelPreparation,
                  !completedTransition.didFail,
                  completedTransition.isFullyScheduled else { return }

            guard !Task.isCancelled,
                  self.playID == id,
                  self.queueGeneration == followingTransition.queueGeneration else { return }
            self.startGaplessPreparation(playID: id, transition: followingTransition)
        }
    }

    private func prepareGaplessNextTrack(
        playID id: UUID,
        transition: GaplessTransitionState
    ) async {
        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              shouldAttemptGapless(settings: playbackSettings.snapshot()),
              let nextEntry = nextQueueEntryInQueue() else { return }
        let nextSong = nextEntry.song
        guard nextSong.id != currentSong?.id else { return }
        let sourceStreamEpoch = CloudPlaybackSource.streamEpochTicket(
            sourceID: nextSong.sourceID
        )

        var nextURL: URL
        var nextDecoderKind: DecoderKind
        do {
            nextURL = try await resolvedURL(
                for: nextSong,
                forContinuousPreparation: true
            )
            nextDecoderKind = await decoderKind(for: nextSong, url: nextURL)
        } catch {
            plog("Gapless prepare URL error: \(error.localizedDescription)")
            return
        }

        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              nextDecoderKind == .native || nextDecoderKind == .ffmpeg,
              nextDecoderKind != .native || nativeDecoder.canDecode(url: nextURL),
              let outputFormat = audioEngine.outputFormat else { return }
        if nextSong.id == currentSong?.id,
           activeDecoderKind == .cloudStream
                || activeDecoderKind == .httpStream
                || nextDecoderKind == .cloudStream
                || nextDecoderKind == .httpStream {
            // Two same-song range decoders share one sparse path. Keep repeat
            // playback serial so the prepared successor cannot retire or
            // finalize the still-audible writer.
            return
        }

        guard let stream = await decodeStream(
            for: nextSong,
            url: nextURL,
            outputFormat: outputFormat,
            sourceStreamEpoch: sourceStreamEpoch
        ) else {
            return
        }

        guard let followingTicket = preparedAutomaticAdvanceTicket(itemID: nextSong.id) else {
            return
        }
        let followingTransition = GaplessTransitionState(
            queueGeneration: queueGeneration,
            advanceTicket: followingTicket
        )
        var lastBuffer: AVAudioPCMBuffer?
        var didMarkPrepared = false
        // Pace the next track's buffers to consumption of the *current* track's
        // buffers (same player node) so a fully prepared gapless track doesn't
        // double the resident PCM alongside the song that's still playing.
        let gate = DecodedBufferGate(
            maxBufferedDuration: Self.decodedAudioLookahead,
            maxBufferedBytes: Self.maxInFlightDecodedBytes,
            maxBufferCount: Self.maxInFlightDecodedBufferCount
        )
        defer { Task { await gate.drain() } }

        func markPreparedIfNeeded() {
            guard !didMarkPrepared else { return }
            didMarkPrepared = true
            transition.bufferGate = gate
            transition.prepared = GaplessPreparedTrack(
                queueEntryID: nextEntry.id,
                song: nextSong,
                url: nextURL,
                decoderKind: nextDecoderKind,
                followingTransition: followingTransition
            )
            plog("🔄 gapless prepared next track '\(nextSong.title)'")
        }

        do {
            for try await buffer in stream {
                guard !Task.isCancelled,
                      playID == id,
                      queueGeneration == transition.queueGeneration,
                      !transition.shouldCancelPreparation else { return }

                if let prev = lastBuffer {
                    let bufferedDuration = Self.decodedBufferDuration(prev)
                    let bufferedByteCount = Self.decodedBufferByteCount(prev)
                    await gate.acquire(
                        duration: bufferedDuration,
                        byteCount: bufferedByteCount
                    )
                    guard !Task.isCancelled,
                          playID == id,
                          queueGeneration == transition.queueGeneration,
                          !transition.shouldCancelPreparation else { return }
                    audioEngine.scheduleBuffer(
                        prev,
                        completionCallbackType: .dataPlayedBack
                    ) { _ in
                        gate.release(
                            duration: bufferedDuration,
                            byteCount: bufferedByteCount
                        )
                    }
                    markPreparedIfNeeded()
                }
                lastBuffer = buffer
            }
        } catch {
            guard !Task.isCancelled,
                  playID == id,
                  queueGeneration == transition.queueGeneration,
                  !transition.shouldCancelPreparation else { return }
            transition.didFail = true
            plog("Gapless prepare decode error: \(error.localizedDescription)")
            if let tailBuffer = lastBuffer {
                audioEngine.scheduleBuffer(
                    tailBuffer,
                    completionCallbackType: .dataPlayedBack
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.playID == id else { return }
                        await self.autoAdvanceAfterFailure(
                            advanceTicket: followingTransition.advanceTicket,
                            trigger: "gapless-failure"
                        )
                    }
                }
                markPreparedIfNeeded()
                transition.isFullyScheduled = true
            }
            return
        }

        guard !Task.isCancelled,
              playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              let finalBuffer = lastBuffer else { return }

        followingTransition.boundary = audioEngine.scheduleBuffer(
            finalBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, followingTransition] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playID == id else { return }
                plog("🔔 gapless boundary fired (prepared) playID=\(id.uuidString.prefix(8))")
                await self.handleGaplessBoundary(transition: followingTransition, playID: id)
            }
        }
        markPreparedIfNeeded()
        transition.isFullyScheduled = true
    }
}
