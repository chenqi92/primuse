import Accelerate
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
        cancelGaplessPreparation()
        gaplessPreparationTransition = transition
        gaplessPreparationTask = Task { [id, transition] in
            await self.prepareGaplessNextTrack(playID: id, transition: transition)
        }
    }

    /// - Parameter startsInClosingSilence: a sample-rate handoff begins while
    ///   the outgoing song still has closing silence queued, instead of
    ///   waiting for its final buffer.
    func handleGaplessBoundary(
        transition: GaplessTransitionState,
        playID id: UUID,
        startsInClosingSilence: Bool = false
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
        if !startsInClosingSilence, duration > 30, currentTime < duration - 5, !isLoading {
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
        // 同 scheduleLastBuffer:只有**已提交**的转场才算真的接管了边界,
        // 还在准备中的尝试不能把这一首的续播吞掉。
        if shouldUseCrossfade(settings), isCrossfading, committedCrossfade != nil {
            transition.shouldCancelPreparation = true
            cancelGaplessPreparation()
            return
        }
        if shouldUseCrossfade(settings), crossfadeAttemptID != nil || crossfadeTriggered {
            cancelCrossfadeAttempt()
        }

        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            transition.shouldCancelPreparation = true
            cancelGaplessTasks()
            stopAtTrackEnd()
            return
        }

        let plan = continuousTransitionPlan(
            settings: settings,
            nextSourceSampleRate: transition.prepared.map(\.sourceSampleRate)
        )
        // A successor already queued on the node plays on regardless; one
        // still waiting for a sample-rate switch is only started if the
        // switch is still wanted.
        guard plan != .restart,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation,
              let prepared = transition.prepared,
              nextQueueEntryInQueue()?.id == prepared.queueEntryID,
              prepared.sampleRateHandoff == nil || plan.isSampleRateHandoff else {
            transition.shouldCancelPreparation = true
            cancelGaplessPreparation()
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

        if let sampleRateHandoff = prepared.sampleRateHandoff {
            await activateSampleRateHandoff(
                prepared,
                handoff: sampleRateHandoff,
                completedTransition: transition,
                playID: id
            )
        } else {
            activateGaplessTrack(prepared, completedTransition: transition, playID: id)
        }
    }

    private func activateGaplessTrack(
        _ prepared: GaplessPreparedTrack,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        guard playID == id else { return }

        adoptSuccessorFeed(from: completedTransition, playID: id)
        let boundaryWasCommitted = audioEngine.markTrackBoundary(
            completedTransition.boundary
        )
        let activatedSong = adoptSuccessorAsCurrentSong(prepared)
        // The successor's clock starts at its playback range start, if any.
        audioEngine.timelineOrigin = activatedSong.appliedPlaybackRange?.start ?? 0

        guard boundaryWasCommitted else {
            plog("⚠️ gapless boundary token was stale; rebuilding the activated track")
            completedTransition.shouldCancelPreparation = true
            cancelGaplessTasks()
            pendingRecoveryTime = 0
            needsPlaybackRecovery = true
            seek(to: 0, startPlaying: true, isRecovery: true)
            return
        }

        finishSuccessorActivation(
            prepared,
            activatedSong: activatedSong,
            completedTransition: completedTransition,
            playID: id
        )
    }

    /// Switches the device to the successor's rate and starts the successor
    /// from the audio held for it. The outgoing song has played out, or only
    /// its closing silence was left, so the short silence while the device
    /// reclocks is all that is heard. Anything unexpected restarts the
    /// successor through the ordinary output path.
    private func activateSampleRateHandoff(
        _ prepared: GaplessPreparedTrack,
        handoff: SampleRateHandoffPreparation,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) async {
        guard playID == id else {
            handoff.cancel()
            return
        }
        let startedAt = ContinuousClock.now
        adoptSuccessorFeed(from: completedTransition, playID: id)
        stopTimeUpdater()
        // Whatever closing silence is still queued goes now. Its final-buffer
        // callback comes back as a duplicate boundary and is dropped.
        audioEngine.stopPlayback()
        hasPreparedLocalPlayback = false
        let activatedSong = adoptSuccessorAsCurrentSong(prepared)
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()

        do {
            // The running graph was built for the old rate. Build the next one
            // from the device's settled format rather than reusing it.
            audioEngine.requireGraphRebuild()
            let mode = try await configureOutputPipeline(
                for: activatedSong,
                url: prepared.url,
                expectedPlayID: id
            )
            guard playID == id, !completedTransition.shouldCancelPreparation else {
                handoff.cancel()
                return
            }
            guard mode == .pcm, audioEngine.graphRenders(handoff.format) else {
                plog("ℹ️ Sample-rate handoff: graph renders sr\(audioEngine.outputFormat?.sampleRate ?? 0) after the switch, prepared sr\(handoff.format.sampleRate); restarting '\(activatedSong.title)'")
                restartAfterFailedSampleRateHandoff(handoff, completedTransition: completedTransition)
                return
            }
            activeDSDPlaybackMode = mode
            applySpatialAudioSettings()
            applyPlaybackRate()
            audioEffectsService.applySettings()
            equalizerService.applySettings()
            try audioEngine.start()
            audioEngine.resetPlayerVolume()
        } catch {
            handoff.cancel()
            guard !Task.isCancelled, playID == id else { return }
            if PlaybackPipelineFailurePolicy.action(
                requestIsCurrent: true,
                error: error
            ) == .preserveCurrentItem {
                plog("⏸️ Sample-rate handoff unavailable; keeping '\(activatedSong.title)': \(error)")
                suspendPlaybackPreservingSelection(
                    reason: "sample-rate-handoff-unavailable",
                    resumeTime: 0
                )
                return
            }
            plog("⚠️ Sample-rate handoff failed: \(error.localizedDescription); restarting '\(activatedSong.title)'")
            restartAfterFailedSampleRateHandoff(handoff, completedTransition: completedTransition)
            return
        }

        guard let gate = completedTransition.bufferGate else {
            restartAfterFailedSampleRateHandoff(handoff, completedTransition: completedTransition)
            return
        }
        for buffer in handoff.takeHeldBuffers() {
            await scheduleTrackedDecodedBuffer(buffer, gate: gate)
        }
        guard playID == id, !completedTransition.shouldCancelPreparation else {
            handoff.cancel()
            return
        }
        guard isLocalTransportStartAuthorized(
            playID: id,
            itemID: activatedSong.id,
            trigger: "sample-rate-handoff"
        ) else {
            handoff.cancel()
            audioEngine.stopPlayback()
            isPlaying = false
            pendingRecoveryTime = 0
            needsPlaybackRecovery = true
            updateNowPlayingInfo()
            updatePlaybackState()
            return
        }
        hasPreparedLocalPlayback = true
        // The preparation loop carries on decoding behind the held audio.
        handoff.activate()
        audioEngine.timelineOrigin = activatedSong.appliedPlaybackRange?.start ?? 0
        isPlaying = audioEngine.play()
        plog("🎧 Sample-rate handoff to \(handoff.format.sampleRate) Hz for '\(activatedSong.title)' took \(startedAt.duration(to: .now))")

        finishSuccessorActivation(
            prepared,
            activatedSong: activatedSong,
            completedTransition: completedTransition,
            playID: id
        )
    }

    private func restartAfterFailedSampleRateHandoff(
        _ handoff: SampleRateHandoffPreparation,
        completedTransition: GaplessTransitionState
    ) {
        handoff.cancel()
        completedTransition.shouldCancelPreparation = true
        cancelGaplessTasks()
        pendingRecoveryTime = 0
        needsPlaybackRecovery = true
        seek(to: 0, startPlaying: true, isRecovery: true)
    }

    /// The preparation loop becomes the current track's decoder.
    private func adoptSuccessorFeed(
        from completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        resetDecodedBufferHealth(resetRecoveryAttempts: true)
        if let gate = completedTransition.bufferGate {
            installDecodedBufferGate(gate, playID: id)
        }

        // The loop that prepared this track keeps decoding it until the song
        // ends, so from here on it is the current track's decoder rather than
        // a successor preparation. Move it out of the successor slot: shuffle
        // toggles and Up Next edits discard the prepared successor and must
        // not starve the track that is audible.
        completedTransition.isFeedingCurrentTrack = true
        if let feeder = gaplessPreparationTask {
            decodingTask?.cancel()
            decodingTask = feeder
            gaplessPreparationTask = nil
        }
        gaplessPreparationTransition = nil
        sampleRateHandoffWatchTask?.cancel()
        sampleRateHandoffWatchTask = nil
        activeGaplessFeed = ActiveGaplessFeed(playID: id, transition: completedTransition)

        if let previous = currentSong {
            sourceManager?.finalizeStreamingSession(for: previous)
        }
    }

    private func adoptSuccessorAsCurrentSong(_ prepared: GaplessPreparedTrack) -> Song {
        let activatedSong = songRefreshingLatestDuration(prepared.song)
        advanceToNextIndex()
        currentSong = activatedSong
        duration = activatedSong.duration.sanitizedDuration
        // A range's end is not the song's length; the queue keeps the whole song.
        if activatedSong.appliedPlaybackRange == nil {
            applyResolvedDuration(duration, toSongID: activatedSong.id)
        }
        currentTime = activatedSong.appliedPlaybackRange?.start ?? 0
        isLoading = false
        isPlaying = true
        isAtTrackEnd = false
        crossfadeTriggered = false
        isCrossfading = false
        activeDecoderKind = prepared.decoderKind
        library?.recordPlayback(of: activatedSong.id)
        ScrobbleService.shared.handlePlaybackStarted(song: activatedSong)
        PlayHistoryStore.shared.beginSession(song: activatedSong)
        return activatedSong
    }

    private func finishSuccessorActivation(
        _ prepared: GaplessPreparedTrack,
        activatedSong: Song,
        completedTransition: GaplessTransitionState,
        playID id: UUID
    ) {
        // Normally the successor's samples already carry its ReplayGain and
        // the node volume must stay where it is. Only a successor that could
        // not be scaled falls back to changing the node volume here, which
        // lands a moment after the boundary.
        if !prepared.carriesProgramGain {
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

    /// Shuffle toggles and Up Next edits change which song follows, not the
    /// track that is playing. Drop the successor preparation and, while no
    /// stale successor audio sits on the node yet, arm it again so the next
    /// boundary can still be gapless. Once a cancelled preparation has
    /// scheduled buffers, the boundary itself falls back to a normal advance.
    func discardPreparedSuccessorForTraversalChange() {
        let inFlight = gaplessPreparationTransition
        let feed = activeGaplessFeed
        let following = feed?.transition.prepared?.followingTransition
        let inFlightSnapshot = inFlight.map(Self.discardSnapshot)
        let feedSnapshot = feed.map { feed in
            GaplessSuccessorDiscardPolicy.FeedSnapshot(
                ownsCurrentPlayback: feed.playID == playID,
                isStale: feed.transition.shouldCancelPreparation || feed.transition.didFail,
                following: following.map(Self.discardSnapshot)
            )
        }
        cancelGaplessTasks()
        guard let id = playID else { return }

        switch GaplessSuccessorDiscardPolicy.action(
            inFlight: inFlightSnapshot,
            feed: feedSnapshot,
            queueGeneration: queueGeneration
        ) {
        case .restartPreparation:
            guard let inFlight else { return }
            startGaplessPreparation(playID: id, transition: inFlight)
        case .rearmFollowup:
            guard let feed, let following else { return }
            startGaplessFollowupPreparation(
                playID: id,
                after: feed.transition,
                followingTransition: following
            )
        case .leaveToBoundary:
            break
        }
    }

    nonisolated private static func discardSnapshot(
        _ transition: GaplessTransitionState
    ) -> GaplessSuccessorDiscardPolicy.PreparationSnapshot {
        GaplessSuccessorDiscardPolicy.PreparationSnapshot(
            hasScheduledBuffers: transition.prepared?.hasScheduledBuffers ?? false,
            isStale: transition.shouldCancelPreparation,
            queueGeneration: transition.queueGeneration
        )
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
        let nextSong = songApplyingPlaybackRange(nextEntry.song)
        guard nextSong.id != currentSong?.id else { return }
        // 播客单集换集时要先探音频文件的真实大小,走正常起播,不提前接续。
        guard !PodcastPlaybackSong.isEpisode(nextSong) else { return }
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

        // Judge the boundary with the rate the output pipeline will read for
        // this very file, then decode either at the running graph's format or
        // at the format the graph will have after the device switch.
        let nextSourceSampleRate = await continuousTransitionSourceSampleRate(
            for: nextSong,
            url: nextURL,
            decoderKind: nextDecoderKind
        )
        guard playID == id,
              queueGeneration == transition.queueGeneration,
              !transition.shouldCancelPreparation else { return }
        let decodeFormat: AVAudioFormat
        let sampleRateHandoff: SampleRateHandoffPreparation?
        switch continuousTransitionPlan(
            settings: playbackSettings.snapshot(),
            nextSourceSampleRate: .some(nextSourceSampleRate)
        ) {
        case .restart:
            return
        case .seamless:
            decodeFormat = outputFormat
            sampleRateHandoff = nil
        case .sampleRateHandoff(let targetSampleRate):
            guard let format = audioEngine.predictedGraphFormat(
                hardwareSampleRate: targetSampleRate,
                outputMode: outputMode(for: nextSong)
            ) else { return }
            decodeFormat = format
            sampleRateHandoff = SampleRateHandoffPreparation(format: format)
            plog("🎧 Sample-rate handoff: preparing '\(nextSong.title)' at \(targetSampleRate) Hz, graph runs at \(outputFormat.sampleRate) Hz")
        }

        guard let stream = await decodeStream(
            for: nextSong,
            url: nextURL,
            outputFormat: decodeFormat,
            sourceStreamEpoch: sourceStreamEpoch
        ) else {
            return
        }

        let carriesProgramGain: Bool
        let appliedScale: Float?
        if sampleRateHandoff != nil {
            // The rebuilt graph starts at unity node volume, and activation
            // applies the successor's ReplayGain there the ordinary way.
            carriesProgramGain = false
            appliedScale = nil
        } else {
            // The boundary is only observed after the old song's last buffer
            // has been heard, so a node-volume change there would let the new
            // song start at the old song's gain. Multiply the successor's own
            // gain into its samples instead, relative to the node volume it
            // shares.
            let baseNodeVolume = await gaplessBaseNodeVolume(playID: id)
            let targetVolume = await targetProgramVolume(
                for: nextSong,
                url: nextURL,
                allowFileRead: true
            )
            guard playID == id,
                  queueGeneration == transition.queueGeneration,
                  !transition.shouldCancelPreparation else { return }
            let sampleScale = ReplayGainPolicy.gaplessSampleScale(
                targetVolume: targetVolume,
                nodeVolume: baseNodeVolume
            )
            let canScaleSamples = decodeFormat.commonFormat == .pcmFormatFloat32
            carriesProgramGain = sampleScale == nil || canScaleSamples
            appliedScale = canScaleSamples ? sampleScale : nil
            if let appliedScale {
                plog("🎚️ gapless ReplayGain: '\(nextSong.title)' samples ×\(appliedScale)")
            }
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
                followingTransition: followingTransition,
                carriesProgramGain: carriesProgramGain,
                sourceSampleRate: nextSourceSampleRate,
                sampleRateHandoff: sampleRateHandoff
            )
            plog("🔄 gapless prepared next track '\(nextSong.title)'")
        }

        // Until the boundary activates the prepared track, any queue
        // generation change discards it. Once the loop feeds the current
        // track, only losing the play ID or an explicit cancellation stops it.
        func mayContinue() -> Bool {
            guard !Task.isCancelled,
                  playID == id,
                  !transition.shouldCancelPreparation else { return false }
            return transition.isFeedingCurrentTrack
                || queueGeneration == transition.queueGeneration
        }

        // A handoff successor waits here, with its pre-roll in memory, until
        // the boundary has switched the device and scheduled that pre-roll.
        func awaitSampleRateHandoff() async -> Bool {
            guard let sampleRateHandoff, !sampleRateHandoff.isActivated else { return true }
            // Nothing to start the rebuilt graph with: advance normally.
            guard !sampleRateHandoff.heldBuffers.isEmpty else { return false }
            markPreparedIfNeeded()
            armSampleRateHandoffInClosingSilence(transition: transition, playID: id)
            guard await sampleRateHandoff.waitForActivation() else { return false }
            return mayContinue()
        }

        do {
            for try await buffer in stream {
                guard mayContinue() else { return }
                if let appliedScale {
                    Self.scaleSamples(of: buffer, by: appliedScale)
                }

                if let prev = lastBuffer {
                    let bufferedDuration = Self.decodedBufferDuration(prev)
                    let bufferedByteCount = Self.decodedBufferByteCount(prev)
                    if let sampleRateHandoff, !sampleRateHandoff.isActivated {
                        sampleRateHandoff.hold(
                            prev,
                            duration: bufferedDuration,
                            byteCount: bufferedByteCount
                        )
                        lastBuffer = buffer
                        if sampleRateHandoff.prerollIsComplete {
                            guard await awaitSampleRateHandoff() else { return }
                        }
                        continue
                    }
                    await gate.acquire(
                        duration: bufferedDuration,
                        byteCount: bufferedByteCount
                    )
                    guard mayContinue() else { return }
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
            guard mayContinue() else { return }
            if let sampleRateHandoff, !sampleRateHandoff.isActivated {
                // Nothing reached the node; the boundary advances normally
                // and tries this song again from the top.
                plog("Gapless prepare decode error before a sample-rate handoff: \(error.localizedDescription)")
                return
            }
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

        guard mayContinue(), let finalBuffer = lastBuffer else { return }
        // A song shorter than the pre-roll ends while it is still held.
        guard await awaitSampleRateHandoff() else { return }

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
        followingTransition.trailingSilence = audioEngine.primaryTrailingSilence()
        markPreparedIfNeeded()
        transition.isFullyScheduled = true
    }

    /// The successor's rate as `configureOutputPipeline` will read it: an
    /// offline compact copy is encoded at its own rate, and a local file
    /// without a library rate is asked directly.
    private func continuousTransitionSourceSampleRate(
        for song: Song,
        url: URL,
        decoderKind: DecoderKind
    ) async -> Double? {
        if !OfflineCompactArtifact.isCompactURL(url), let rate = song.sampleRate {
            return Double(rate)
        }
        guard url.isFileURL else { return nil }
        let decoder: any PrimuseAudioDecoder = decoderKind == .ffmpeg ? ffmpegDecoder : nativeDecoder
        return try? await decoder.fileInfo(for: url).sampleRate
    }

    /// Starts a prepared sample-rate handoff once the outgoing song is inside
    /// its closing silence, so the device reclocks while nothing is audible.
    /// Without enough silence the handoff waits for the final buffer instead.
    private func armSampleRateHandoffInClosingSilence(
        transition: GaplessTransitionState,
        playID id: UUID
    ) {
        sampleRateHandoffWatchTask?.cancel()
        sampleRateHandoffWatchTask = nil
        guard let boundary = transition.boundary,
              let silence = transition.trailingSilence,
              silence.endFrame == boundary.frameCursor,
              let sampleRate = audioEngine.outputFormat?.sampleRate,
              let switchFrame = SampleRateHandoffTimingPolicy.switchFrame(
                  boundaryFrame: boundary.frameCursor,
                  trailingSilentFrames: silence.silentFrames,
                  sampleRate: sampleRate
              ) else { return }
        plog(String(
            format: "🎧 Sample-rate handoff may start %.2fs before the end, in closing silence",
            Double(boundary.frameCursor - switchFrame) / sampleRate
        ))
        sampleRateHandoffWatchTask = Task { [weak self, transition] in
            while !Task.isCancelled {
                guard let self,
                      self.playID == id,
                      !transition.didBoundaryFire,
                      !transition.shouldCancelPreparation,
                      transition.prepared?.sampleRateHandoff != nil,
                      self.audioEngine.isPrimaryTimelineLive(boundary) else { return }
                let rendered = self.audioEngine.primaryRenderedFrame
                // Only a playing transport may start the switch early. Paused,
                // the boundary would be refused and the song left without a
                // successor once it resumes and plays out.
                let transportIsActive = self.isPlaying
                    && self.audioEngine.isActuallyPlaying
                    && self.interruptionResumePolicy.playbackIsIntended
                if transportIsActive, let rendered, rendered >= switchFrame {
                    // Detach before starting: nothing may cancel the switch
                    // halfway through.
                    self.sampleRateHandoffWatchTask = nil
                    plog("🎧 Sample-rate handoff starting in closing silence playID=\(id.uuidString.prefix(8))")
                    await self.handleGaplessBoundary(
                        transition: transition,
                        playID: id,
                        startsInClosingSilence: true
                    )
                    return
                }
                // Sleep about until the switch frame comes due; a paused or
                // stopped node is simply checked again later.
                var wait: TimeInterval = 0.25
                if transportIsActive, let rendered {
                    let speed = Double(max(self.requestedPlaybackRate, 0.5))
                    wait = Double(switchFrame - rendered) / sampleRate / speed
                }
                let milliseconds = Int((min(max(wait, 0.02), 0.25) * 1000).rounded())
                try? await Task.sleep(for: .milliseconds(milliseconds))
            }
        }
    }

    /// Multiplies a freshly decoded float buffer in place before it is
    /// scheduled. Nothing else holds the buffer yet.
    nonisolated static func scaleSamples(of buffer: AVAudioPCMBuffer, by scale: Float) {
        guard let channels = buffer.floatChannelData else { return }
        let format = buffer.format
        let channelCount = Int(format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 0, frameCount > 0 else { return }
        var factor = scale
        if format.isInterleaved {
            let sampleCount = vDSP_Length(frameCount * channelCount)
            vDSP_vsmul(channels[0], 1, &factor, channels[0], 1, sampleCount)
        } else {
            for channel in 0..<channelCount {
                vDSP_vsmul(channels[channel], 1, &factor, channels[channel], 1, vDSP_Length(frameCount))
            }
        }
    }
}
