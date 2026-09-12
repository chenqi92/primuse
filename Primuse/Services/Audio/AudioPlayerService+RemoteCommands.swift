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
    // MARK: - Remote Commands

    func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            let status = self.handleRemotePlayCommand()
            self.scheduleNowPlayingTransportRepublish(command: "play", status: status)
            return status
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            let status = self.handleRemotePauseCommand()
            self.scheduleNowPlayingTransportRepublish(command: "pause", status: status)
            return status
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            let status = self.handleRemoteToggleCommand()
            self.scheduleNowPlayingTransportRepublish(command: "toggle", status: status)
            return status
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            plog("🎛️ MediaRemote nextTrackCommand fired")
            Task { await self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            plog("🎛️ MediaRemote previousTrackCommand fired")
            Task { await self?.previous() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            guard self?.playbackCapabilities.canSeek == true else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
        #if os(iOS)
        center.likeCommand.addTarget { [weak self] event in
            guard let self else { return .noActionableNowPlayingItem }
            return self.handleRemoteLikeCommand(event)
        }
        #endif
        updateNowPlayingInfo()
    }

    #if os(iOS)
    private func handleRemoteLikeCommand(
        _ event: MPRemoteCommandEvent
    ) -> MPRemoteCommandHandlerStatus {
        guard let feedbackEvent = event as? MPFeedbackCommandEvent,
              !isLiveRadio,
              let songID = currentSong?.id,
              let library,
              library.song(id: songID) != nil else {
            return .noActionableNowPlayingItem
        }

        library.setLiked(
            songID: songID,
            isLiked: !feedbackEvent.isNegative,
            propagatesServerMutation: true
        )
        republishNowPlayingSurfaces()
        return .success
    }
    #endif

    /// MediaRemote may finish dispatching the originating command after the
    /// first synchronous Now Playing assignment. Re-publish the latest complete
    /// snapshot on the next main-actor turn, while a generation and item ID
    /// prevent a late command from restoring stale transport metadata.
    private func scheduleNowPlayingTransportRepublish(
        command: String,
        status: MPRemoteCommandHandlerStatus
    ) {
        let statusDescription = String(describing: status)
        guard let songID = currentSong?.id else {
            plog("MediaRemote \(command) completed status=\(statusDescription) item=nil")
            return
        }
        nowPlayingTransportRepublishGeneration &+= 1
        let generation = nowPlayingTransportRepublishGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  self.nowPlayingTransportRepublishGeneration == generation,
                  self.currentSong?.id == songID else { return }
            self.updateNowPlayingInfo()
            let publishedRate = (
                MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate]
                    as? NSNumber
            )?.doubleValue
            plog(
                "MediaRemote \(command) completed status=\(statusDescription) "
                    + "active=\(self.isPlaybackActuallyActive) "
                    + "publishedRate=\(publishedRate.map { String($0) } ?? "nil")"
            )
        }
    }

    private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        let action = RemotePlayCommandPolicy.action(
            hasCurrentItem: currentSong != nil,
            isPlaybackActuallyActive: isPlaybackActuallyActive,
            isLoading: isLoading,
            playbackIsIntended: interruptionResumePolicy.playbackIsIntended
        )
        switch action {
        case .noActionableItem:
            return .noActionableNowPlayingItem
        case .alreadyPlaying, .awaitInFlightRequest:
            return .success
        case .retryLoadingPlayback:
            retryLoadingPlaybackFromRemote()
            return .success
        case .resume:
            let expectsSynchronousEngineResult = !isAppleMusicMode
                && !isCastingMode
                && !isAtTrackEnd
                && !needsPlaybackRecovery
                && hasPreparedLocalPlayback
            resume()
            if expectsSynchronousEngineResult, !isPlaybackActuallyActive {
                return .commandFailed
            }
            return .success
        }
    }

    private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
        guard currentSong != nil else { return .noActionableNowPlayingItem }
        guard isPlaybackActuallyActive else {
            // A remote Pause during an interruption is still an explicit user
            // decision. Route it through the real transport stop so loading
            // radio/MusicKit/cast work cannot start after the command.
            pause()
            return .success
        }
        let isAsynchronousRoute = isCastingMode
        pause()
        return isAsynchronousRoute || !isPlaying ? .success : .commandFailed
    }

    private func handleRemoteToggleCommand() -> MPRemoteCommandHandlerStatus {
        isPlaybackActuallyActive ? handleRemotePauseCommand() : handleRemotePlayCommand()
    }

    private func retryLoadingPlaybackFromRemote() {
        guard currentSong != nil else { return }
        if isAppleMusicMode || isLiveRadio || isCastingMode {
            resume()
            return
        }
        registerPlayIntent()
        seek(
            to: currentTime,
            startPlaying: true,
            isRecovery: needsPlaybackRecovery
        )
    }

    // MARK: - Sleep Timer

    func scheduleSleep(minutes: Int) {
        cancelSleep()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate
        sleepTimerTask = Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self.pause()
            self.sleepTimerEndDate = nil
        }
    }

    /// 曲终停止 ── 锁定当前曲目, 等它自然播完时自动暂停。如果用户手动
    /// 切歌, `play(song:)` 会取消这个旧锁；currentSong 为空则不激活。
    func scheduleSleepAtTrackEnd() {
        cancelSleep()
        sleepStopAfterSongID = currentSong?.id
    }

    func cancelSleep() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
        sleepStopAfterSongID = nil
    }
}
