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
            self?.logRemoteCommand("nextTrackCommand")
            Task { await self?.next() }; return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.logRemoteCommand("previousTrackCommand")
            Task { await self?.previous() }; return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.logRemoteCommand(
                "changePlaybackPositionCommand",
                detail: "target=\(String(format: "%.1f", event.positionTime))"
            )
            guard self?.playbackCapabilities.canSeek == true else { return .commandFailed }
            self?.seek(to: event.positionTime); return .success
        }
        #if os(iOS)
        center.likeCommand.addTarget { [weak self] event in
            guard let self else { return .noActionableNowPlayingItem }
            return self.handleRemoteLikeCommand(event)
        }
        #endif
        setupSpokenWordRemoteCommands()
        updateNowPlayingInfo()
    }

    /// 系统转来的遥控指令不带来源, 只能靠当时的现场推断是谁发的:
    /// App 在前台且走扬声器 → 多半是手表「正在播放」或 Siri;
    /// 后台 → 锁屏 / 控制中心 / 灵动岛; 蓝牙或车机线路 → 耳机、方向盘按键。
    private func logRemoteCommand(_ name: String, detail: String? = nil) {
        var fields = [
            "position=\(String(format: "%.1f", currentTime))/\(String(format: "%.1f", duration))",
            "playing=\(isPlaying)",
            "song=\(currentSong?.id.prefix(8) ?? "nil")",
        ]
        #if os(iOS)
        let appState = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        fields.append("app=\(appState)")
        fields.append("outputs=[\(outputs)]")
        #endif
        if let detail { fields.append(detail) }
        plog("🎛️ MediaRemote \(name) fired \(fields.joined(separator: " "))")
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
        let total = TimeInterval(minutes * 60)
        let endDate = Date().addingTimeInterval(total)
        sleepTimerEndDate = endDate
        sleepTimerTask = Task {
            // Wait until the fade begins, then bring the level down over the
            // last half minute so falling asleep does not end on a hard cut.
            let fadeStart = max(0, total - SleepFadePolicy.fadeDuration)
            do {
                try await Task.sleep(for: .seconds(fadeStart))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let restoreVolume = self.audioEngine.userVolume
            while true {
                let remaining = endDate.timeIntervalSinceNow
                if remaining <= 0 { break }
                self.setPlaybackVolume(
                    restoreVolume * SleepFadePolicy.volume(remaining: remaining),
                    persist: false
                )
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    // Cancelled mid-fade: give the listener their level back.
                    self.setPlaybackVolume(restoreVolume, persist: false)
                    return
                }
            }
            self.pause()
            self.setPlaybackVolume(restoreVolume, persist: false)
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
        sleepStopAfterChapter = nil
        sleepStopAfterBook = nil
    }
}
