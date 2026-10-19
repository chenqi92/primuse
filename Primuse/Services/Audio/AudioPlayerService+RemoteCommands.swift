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
              let songID = currentSong?.id else {
            return .noActionableNowPlayingItem
        }
        if PodcastPlaybackSong.isEpisode(currentSong) {
            let store = PodcastStore.shared
            guard let episode = store.episode(id: songID)?.episode
                ?? store.likedEpisodes().first(where: { $0.episode.id == songID })?.episode else {
                return .noActionableNowPlayingItem
            }
            store.setLiked(!feedbackEvent.isNegative, episode: episode)
            republishNowPlayingSurfaces()
            return .success
        }
        guard let library, library.song(id: songID) != nil else {
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

    /// 正在放的这首能不能标「不喜欢」(#193): 得是曲库里的音乐。电台、播客单集不在曲库里,
    /// 有声书的章节本来就不会被随机或推荐挑中。
    var canDislikeCurrentSong: Bool {
        guard !isLiveRadio, !currentItemIsSpokenWord,
              let songID = currentSong?.id,
              let library else { return false }
        return library.song(id: songID) != nil
    }

    /// 「不喜欢」正在放的这首: 记下来, 并像按下一首一样切走。已经不喜欢时再点只撤销记录,
    /// 不切歌。
    func toggleDislikeForCurrentSong() {
        guard canDislikeCurrentSong, let songID = currentSong?.id, let library else { return }
        let dislikes = !library.isDisliked(songID: songID)
        library.setDisliked(songID: songID, isDisliked: dislikes)
        guard dislikes else { return }
        Task { [weak self] in await self?.next() }
    }

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
        scheduleSleep(until: Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60)))
    }

    /// 按停止时刻定时:自定义时长与「到几点停」都落到这里。
    func scheduleSleep(until endDate: Date) {
        cancelSleep()
        let now = Date()
        sleepTimerStartDate = now
        startSleepCountdown(until: max(endDate, now.addingTimeInterval(1)))
    }

    /// 正在倒数的定时往后推几分钟;没在倒数(只锁了曲终 / 章节)时从现在起算一个新的。
    func extendSleep(minutes: Int) {
        guard let current = sleepTimerEndDate else {
            scheduleSleep(minutes: minutes)
            return
        }
        let endDate = SleepTimerSchedulePolicy.extendedEndDate(current, byMinutes: minutes, now: Date())
        // 换掉等待中的任务;正在渐弱时取消会先把音量还回去。
        sleepTimerTask?.cancel()
        startSleepCountdown(until: endDate)
    }

    /// 「计时结束时播完当前这首」(本机偏好,睡眠定时面板里的开关)。
    var sleepTimerFinishesTrack: Bool {
        get { UserDefaults.standard.bool(forKey: SleepTimerSchedulePolicy.finishesTrackPreferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: SleepTimerSchedulePolicy.finishesTrackPreferenceKey) }
    }

    private func startSleepCountdown(until endDate: Date) {
        sleepTimerEndDate = endDate
        sleepTimerTask = Task {
            // Wait until the fade begins, then bring the level down over the
            // last half minute so falling asleep does not end on a hard cut.
            let fadeStart = max(0, endDate.timeIntervalSinceNow - SleepFadePolicy.fadeDuration)
            do {
                try await Task.sleep(for: .seconds(fadeStart))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            // 要等这首播完的,到点前不渐弱:到点时这首还剩多久按到点那一刻算。
            if self.sleepTimerWillFinishTrack(after: endDate.timeIntervalSinceNow) {
                do {
                    try await Task.sleep(for: .seconds(max(0, endDate.timeIntervalSinceNow)))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if self.sleepTimerWillFinishTrack(after: 0), let songID = self.currentSong?.id {
                    plog("🌙 Sleep timer ran out; letting '\(self.currentSong?.title ?? "")' finish")
                    self.sleepTimerTask = nil
                    self.sleepTimerEndDate = nil
                    self.sleepTimerStartDate = nil
                    self.sleepStopAfterSongID = songID
                    return
                }
                self.pause()
                self.sleepTimerEndDate = nil
                self.sleepTimerStartDate = nil
                return
            }
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
            self.sleepTimerStartDate = nil
        }
    }

    /// 定时再过 `delay` 秒到点时,当前这首要不要播完再停。
    private func sleepTimerWillFinishTrack(after delay: TimeInterval) -> Bool {
        guard currentSong != nil, isPlaying else { return false }
        return SleepTimerSchedulePolicy.shouldFinishTrack(
            isEnabled: sleepTimerFinishesTrack,
            isMusic: currentListeningSpace == .music,
            isLiveRadio: isLiveRadio,
            trackDuration: duration,
            position: currentTime + max(0, delay)
        )
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
        sleepTimerStartDate = nil
        sleepStopAfterSongID = nil
        sleepStopAfterChapter = nil
        sleepStopAfterBook = nil
    }
}
