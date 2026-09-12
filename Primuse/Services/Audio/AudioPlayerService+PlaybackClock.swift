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
    // MARK: - Time Updates

    func startTimeUpdater() {
        stopTimeUpdater()
        let clockTicket = playbackClockTickGate.issue()
        lastEngineProgressSample = nil
        nearEndStallSampleCount = 0
        let watchdogTicket = playbackAdvancePolicy.activeTicket
        let timer = Timer(timeInterval: Self.timeUpdateInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackClockTickGate.isCurrent(clockTicket) else { return }
                if self.isLiveRadio {
                    if let startedAt = self.radioPlaybackStartedAt, self.isPlaying {
                        self.currentTime = max(0, Date().timeIntervalSince(startedAt))
                    }
                    return
                }
                let transitionWasActive = self.isCrossfading
                let clockDecision = self.localPlaybackClockDecision(
                    isTransitioning: transitionWasActive
                )
                if let time = clockDecision.visibleTime {
                    self.currentTime = time.sanitizedDuration
                    let madeProgress = self.lastEngineProgressSample.map {
                        self.currentTime > $0 + 0.01
                    } ?? true
                    self.lastEngineProgressSample = self.currentTime

                    // AVAudioPlayerNode normally calls the final-buffer
                    // completion, but it can be lost across route/engine
                    // changes. The old `duration + 1s` check never fired when
                    // the node drained exactly at duration. Detect four
                    // consecutive stalled samples in the final 0.75s instead.
                    let nearEndThreshold = max(
                        self.duration - 0.75,
                        self.duration * 0.98
                    )
                    if clockDecision.shouldRunTrackEndWatchdog,
                       self.duration > 0,
                       self.currentTime >= nearEndThreshold,
                       !self.isLoading,
                       self.isPlaying,
                       !madeProgress {
                        self.nearEndStallSampleCount += 1
                    } else {
                        self.nearEndStallSampleCount = 0
                    }
                    let exceededReportedEnd = self.duration > 0
                        && self.currentTime >= self.duration + 1.0
                    let watchdogShouldAdvance = clockDecision.shouldRunTrackEndWatchdog
                        && (exceededReportedEnd
                            || self.nearEndStallSampleCount >= Self.trackEndStallSampleThreshold)
                    if watchdogShouldAdvance {
                        plog("⚠️ Track-end watchdog: progress ended at \(self.currentTime)/\(self.duration), forcing queue advance")
                        self.stopTimeUpdater()
                        if let watchdogTicket {
                            await self.handleTrackEnd(
                                advanceTicket: watchdogTicket,
                                trigger: "track-end-watchdog"
                            )
                        }
                        return
                    }

                    // Scrobble 进度判断 — 50% 或 4 分钟阈值由 service 内部决定。
                    // 传真实 tick 增量而非 currentTime: 否则用户拖进度条到歌曲后段
                    // 一松手就立刻满足 50% 阈值, 一秒没真听就误上报到 Last.fm/Navidrome。
                    // PlayHistoryStore.tick 维护的是 position high-water mark, 仍传 currentTime。
                    if clockDecision.shouldRecordListeningProgress {
                        ScrobbleService.shared.handleProgressTick(
                            playedDelta: Self.timeUpdateInterval
                        )
                        PlayHistoryStore.shared.tick(elapsed: self.currentTime)
                    }
                }
                if !transitionWasActive {
                    await self.sampleDecodedBufferHealth(clockTicket: clockTicket)
                    guard self.playbackClockTickGate.isCurrent(clockTicket) else { return }
                    // Check if crossfade should start
                    self.checkCrossfade()
                }
            }
        }
        // A scheduled timer is installed in the default run-loop mode, which
        // pauses while a SwiftUI List/ScrollView is tracking a drag. Keep the
        // playback clock in the common modes so scrolling a large queue cannot
        // freeze progress, lyrics, Now Playing, or the end-of-track watchdog
        // while the render thread continues producing audio.
        RunLoop.main.add(timer, forMode: .common)
        displayLink = timer
    }

    func stopTimeUpdater() {
        playbackClockTickGate.invalidate()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: - Track End

    func handleTrackEnd(
        advanceTicket: PlaybackAdvanceTicket,
        trigger: String,
        transportIsActive: Bool? = nil
    ) async {
        guard automaticAdvanceDecision(
            for: advanceTicket,
            trigger: trigger,
            consume: true,
            transportIsActive: transportIsActive
        ) == .accepted else { return }
        await performTrackEnd(trigger: trigger)
    }

    func handleAppleMusicTrackEnd(requestID: UUID) async {
        guard interruptionResumePolicy.playbackIsIntended,
              activeAppleMusicRequestID == requestID,
              playID == requestID else { return }
        plog("✅ Apple Music queue end accepted request=\(requestID.uuidString.prefix(8))")
        await performTrackEnd(trigger: "apple-music-end")
    }

    private func performTrackEnd(trigger: String) async {
        plog("⏭️ track end trigger=\(trigger) playID=\(playID?.uuidString.prefix(8) ?? "nil") queueGeneration=\(queueGeneration)")
        // 曲终停止 sleep 模式 ── 锁定的歌刚播完, 暂停而不是 advance。
        if let lockedID = sleepStopAfterSongID, currentSong?.id == lockedID {
            sleepStopAfterSongID = nil
            stopAtTrackEnd()  // 进 "已播完但保留 currentSong" 状态, 跟用户手动暂停一致
            return
        }
        if shuffleEnabled, repeatMode != .one, nextSongInQueue() == nil {
            _ = extendExhaustedShuffleFromLibrary()
        }
        switch repeatMode {
        case .one:
            if let song = currentSong, isSongAvailableForNewPlayback(song) {
                await play(song: song)
            } else if advanceToNextIndex(respectsRepeatOne: false) {
                await play(song: queueEntries[currentIndex].song)
            } else {
                stopAtTrackEnd()
            }
        case .all:
            await next(caller: "auto:\(trigger)", callerLine: 0)
        case .off:
            // Under shuffle, currentIndex is the queue index of the
            // currently-playing song, not the shufflePosition — so
            // comparing it to queue.count - 1 frequently passed (the
            // last shuffled song often isn't the last in original
            // order) and auto-advance kept generating fresh shuffle
            // rounds even though the user picked repeat-off.
            if nextSongInQueue() != nil {
                await next(caller: "auto:\(trigger)", callerLine: 0)
            } else {
                // 没下一首 —— 进 "已播完" 状态而不是 stop() 全清。
                // 否则 currentSong 一旦为 nil, 上层各种 sheet (刮削 /
                // SongInfo / AddToPlaylist) 内容是空的就白屏, mini
                // player 也闪一下消失体验很差。
                stopAtTrackEnd()
            }
        }
    }
}
