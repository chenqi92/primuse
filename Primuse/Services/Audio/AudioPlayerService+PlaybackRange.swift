import Foundation
import PrimuseKit

/// Per-song playback ranges ("播放时间段") in the player.
///
/// A range keeps the song's timeline. The copy the player plays carries it
/// (`Song.appliedPlaybackRange`): the copy's length is the range end, the
/// decoders trim to `Song.playbackMediaWindow`, the engine clock starts at the
/// range start (`AudioEngine.timelineOrigin`) and seeks stay inside the range.
/// Lyrics, karaoke stems and Now Playing therefore keep reading song time, and
/// reaching the range end is the song's end: the queue advances, gapless and
/// crossfade prepare against it, repeat-one plays the range again.
extension AudioPlayerService {
    /// `song` as the player plays it: inside its playback range when one is
    /// on, otherwise whole. Idempotent — a copy that already carries a range
    /// is re-derived from the whole song.
    func songApplyingPlaybackRange(_ song: Song) -> Song {
        // A medley slice is already a window chosen by the medley.
        guard !medleySongIDs.contains(song.id) else { return song }
        let whole = song.withoutAppliedPlaybackRange
        guard canApplyPlaybackRange(to: whole) else { return whole }
        var measured = whole
        // The library may have learned the real length since this copy was taken.
        if let latest = library?.song(id: whole.id)?.duration, latest > 0 {
            measured.duration = latest
        }
        return whole.playing(SongPlaybackRangeStore.shared.applied(for: measured))
    }

    /// Ranges apply to songs this player decodes itself; a song's music
    /// video and casting play through players that know nothing of them.
    func canApplyPlaybackRange(to song: Song) -> Bool {
        SongPlaybackRangeAvailability.supports(song)
            && !(isMusicVideoModeEnabled && song.mvPath != nil)
            && !isCastingMode
    }

    /// Where the current song's timeline starts playing: its range start, or 0.
    var currentPlaybackRangeStart: TimeInterval {
        currentSong?.appliedPlaybackRange?.start ?? 0
    }

    /// Keeps a seek on the current song inside its playback range.
    func playbackRangeClampedSeekTarget(_ target: TimeInterval) -> TimeInterval {
        guard let applied = currentSong?.appliedPlaybackRange else { return target }
        return SongPlaybackRangePolicy.clampedSeekTarget(target, in: applied)
    }

    func observePlaybackRangeChanges() {
        NotificationCenter.default.addObserver(
            forName: .primuseSongPlaybackRangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let songIDs = notification.userInfo?["songIDs"] as? Set<String>
            Task { @MainActor [weak self] in
                guard let self, let current = self.currentSong else { return }
                if let songIDs, !songIDs.contains(current.id) { return }
                // The editor writes on every nudge; re-cutting the stream once
                // the listener pauses keeps the audio from stuttering per tap.
                self.playbackRangeRefreshTask?.cancel()
                self.playbackRangeRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    self?.refreshCurrentSongPlaybackRange()
                }
            }
        }
    }

    /// Re-applies the current song's range after it was edited, switched or
    /// cleared. The position is kept when it is still inside; otherwise the
    /// song continues from the range start. The seek rebuilds the decoder, so
    /// the new end takes effect at once.
    func refreshCurrentSongPlaybackRange() {
        guard let current = currentSong,
              !isLiveRadio, !isAppleMusicMode, !isCastingMode, !isSystemMediaPlaybackActive,
              !isMedleyActive else { return }
        let updated = songApplyingPlaybackRange(current)
        guard updated.appliedPlaybackRange != current.appliedPlaybackRange else { return }
        let position = currentTime
        currentSong = updated
        duration = updated.duration.sanitizedDuration
        // A-B 只放得到新范围里的那部分;剩下的不够一段就关掉。
        if let loop = abRepeat.loop {
            abRepeat = ABRepeatPolicy.fitted(loop, to: abRepeatPlayableRange).map(ABRepeatState.looping) ?? .off
        }
        let target: TimeInterval
        if let applied = updated.appliedPlaybackRange {
            target = SongPlaybackRangePolicy.startPosition(requested: position, in: applied)
        } else {
            target = position
        }
        plog("✂️ Playback range for '\(updated.title)' → \(updated.appliedPlaybackRange.map { "\(Int($0.start))-\(Int($0.end))s" } ?? "whole song"), resuming at \(Int(target))s")
        if isLoading && !hasPreparedLocalPlayback {
            // Still opening: restart on the new window instead of seeking a
            // decoder that does not exist yet.
            Task { await play(song: updated) }
            return
        }
        seek(to: target)
    }
}

/// Which songs can have a playback range: the ones the app decodes itself.
/// Apple Music plays through the system player and a standalone music video
/// through AVPlayer; spoken word keeps its own resume positions instead.
/// 环境音整段循环着放,截一段出来没有意义,同样不给。
enum SongPlaybackRangeAvailability {
    @MainActor
    static func supports(_ song: Song) -> Bool {
        song.sourceID != AppleMusicLibraryService.systemSourceID
            && !song.isStandaloneMusicVideo
            && !PodcastPlaybackSong.isEpisode(song)
            && SpokenWordStore.shared.isMusic(song)
    }
}

// MARK: - 循环方式、停止点与 A-B 循环

/// 「播完之后」的五种(`repeatBehavior`)、队列里的「播完这首后停止」,以及在一首歌里反复放一段的
/// A-B 循环。A-B 和播放时间段一样用这首歌自己的时间,出不了播放时间段。
///
/// 播完要停、A-B 循环中,这一首的结尾都不交给下一首:曲终统一走 `performTrackEnd`,gapless 与淡入
/// 淡出看到 `holdsQueueAtCurrentTrackEnd` 就不提前接下一首。
extension AudioPlayerService {
    /// 菜单里的「播完之后」:循环关、列表循环、单曲循环,加上每首播完都停的两种。
    var repeatBehavior: RepeatBehavior {
        get { RepeatBehavior(repeatMode: repeatMode, eachTrackStop: eachTrackStop) }
        set {
            if repeatMode != newValue.repeatMode { repeatMode = newValue.repeatMode }
            if eachTrackStop != newValue.eachTrackStop { eachTrackStop = newValue.eachTrackStop }
        }
    }

    /// 每首播完都停要本机看得到曲终:Apple Music 自己排着队列、放电台时做不到。
    var supportsEachTrackStop: Bool {
        !isLiveRadio && !(isAppleMusicMode && !isPrimuseManagingAppleMusicQueue)
    }

    /// 「播放方式」键换到的一种:随机与循环一起换,每首播完都停回到关。
    func applyPlaybackOrderMode(_ mode: PlaybackOrderMode) {
        let target = mode.settings(from: repeatMode)
        repeatBehavior = RepeatBehavior(repeatMode: target.repeatMode, eachTrackStop: nil)
        if shuffleEnabled != target.shuffleEnabled { shuffleEnabled = target.shuffleEnabled }
    }

    /// 这一首播完要停:当前条目标了停止点(停下时下一首就位),或者循环方式是每首播完都停。
    /// 睡眠定时的「播完再停」有自己的锁(`sleepStopAfterSongID`),不在这里。
    var currentTrackEndStop: EachTrackStop? {
        if let stopEntryID = queueStopAfterEntryID,
           queueEntries.indices.contains(currentIndex),
           queueEntries[currentIndex].id == stopEntryID {
            return .cueNext
        }
        // 串烧一段接一段放,段与段之间不停。
        guard !isMedleyActive else { return nil }
        return eachTrackStop
    }

    /// 这一首放完不接下一首:A-B 循环中,或者播完要停。
    var holdsQueueAtCurrentTrackEnd: Bool {
        abRepeat.loop != nil || currentTrackEndStop != nil
    }

    // MARK: 停止点

    func stopsAfterQueueEntry(_ entryID: UUID) -> Bool {
        queueStopAfterEntryID == entryID
    }

    /// 队列里一条的「播完这首后停止」:标上或摘掉。整个队列只有一个停止点,标到别的条目上就挪过去。
    func toggleStopAfterQueueEntry(_ entryID: UUID) {
        queueStopAfterEntryID = queueStopAfterEntryID == entryID ? nil : entryID
    }

    /// 曲终时这首要停:停下,标在这首上的停止点摘掉。处理了返回 true。
    func stopForTrackEndIfNeeded() -> Bool {
        guard let stop = currentTrackEndStop else { return false }
        let reachedStopPoint = queueEntries.indices.contains(currentIndex)
            && queueEntries[currentIndex].id == queueStopAfterEntryID
        // 先停再摘停止点:摘的时候会把整段队列重新交给 Apple Music,停下之前交过去它就接着放了。
        stopAtTrackEnd(cueingNext: stop == .cueNext)
        if reachedStopPoint { queueStopAfterEntryID = nil }
        return true
    }

    /// 播完停下。`cueingNext` 时把下一首放到当前位置,再按播放就从它开始;投放和 Apple Music 的歌
    /// 由别的播放器接着放,这时停在播完的这首上。
    func stopAtTrackEnd(cueingNext: Bool) {
        let target = cueingNext ? nextQueueTraversalTarget(respectsRepeatOne: false) : nil
        stopAtTrackEnd()
        guard let target,
              !isCastingMode,
              !isAppleMusicMode,
              queueEntries.indices.contains(target.queueIndex),
              queueEntries[target.queueIndex].song.sourceID != AppleMusicLibraryService.systemSourceID else { return }
        applyQueueTraversalTarget(target)
        let song = songApplyingPlaybackRange(queueEntries[currentIndex].song)
        currentSong = song
        duration = song.duration.sanitizedDuration
        currentTime = song.appliedPlaybackRange?.start ?? 0
        // 和播完停在这首上一样:再按播放时重新起这一首。
        isAtTrackEnd = true
        persistPlaybackSession()
        updateNowPlayingInfo()
        updateNowPlayingArtworkIfNeeded()
        updatePlaybackState()
        plog("⏹️ Stopped at track end; cued '\(song.title)'")
    }

    // MARK: A-B 循环

    /// 这首此刻放得到的范围:开着播放时间段时是那一段,否则整首。
    var abRepeatPlayableRange: ClosedRange<TimeInterval> {
        let lower = currentPlaybackRangeStart
        return lower...max(lower, duration.sanitizedDuration)
    }

    /// 本机解码的歌才能来回跳:Apple Music、投放、电台、串烧不行,卡拉OK 舞台有自己的逐句循环。
    /// 跳回靠 seek,seek 此刻不动的时候(整首下载起播还没完、边下边放的歌还没缓存完整)也不行。
    /// 环境音整段循环,不给 A-B。
    var canUseABRepeat: Bool {
        guard let song = currentSong, !isLiveRadio, !isAppleMusicMode, !isCastingMode,
              !isMedleyActive, !isKaraokeSessionActive, !currentItemIsAmbient,
              activeStreamingDownloadPreparation == nil else { return false }
        if activeDecoderKind == .streaming, completedFullDownloadURL(for: song) == nil { return false }
        let range = abRepeatPlayableRange
        return range.upperBound - range.lowerBound >= ABRepeatPolicy.minimumLength
    }

    /// A-B 键点一下:在播放头设 A → 设 B 开始循环 → 关掉。
    func advanceABRepeat() {
        guard abRepeat.isActive || canUseABRepeat else { return }
        let time = isPlaying ? interpolatedTime(rate: Double(requestedPlaybackRate)) : currentTime
        abRepeat = ABRepeatPolicy.advanced(abRepeat, at: time, playable: abRepeatPlayableRange)
    }

    /// 编辑区间改出来的一段;nil 关掉 A-B。
    func setABRepeatLoop(_ loop: ABRepeatLoop?) {
        guard let loop else {
            clearABRepeat()
            return
        }
        guard canUseABRepeat,
              let fitted = ABRepeatPolicy.fitted(loop, to: abRepeatPlayableRange) else { return }
        abRepeat = .looping(fitted)
    }

    func clearABRepeat() {
        if abRepeat != .off { abRepeat = .off }
    }

    /// 播放时钟每拍看一眼:到了 B 就回 A;离 B 不到一拍时排一下准点跳回,免得多放出去小半秒。
    func followABRepeatLoop() {
        guard let loop = abRepeat.loop else { return }
        guard isPlaying, !isLoading else {
            abRepeatJumpTask?.cancel()
            abRepeatJumpTask = nil
            return
        }
        let rate = Double(requestedPlaybackRate)
        let time = interpolatedTime(rate: rate)
        if ABRepeatPolicy.reachedEnd(of: loop, at: time) {
            jumpToABRepeatStart(loop)
            return
        }
        let remaining = ABRepeatPolicy.timeUntilEnd(of: loop, at: time, rate: rate)
        guard abRepeatJumpTask == nil, remaining <= Self.timeUpdateInterval * 1.5 else { return }
        let jumpPlayID = playID
        abRepeatJumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            self.abRepeatJumpTask = nil
            guard self.playID == jumpPlayID, self.isPlaying, !self.isLoading,
                  self.abRepeat.loop == loop else { return }
            self.jumpToABRepeatStart(loop)
        }
    }

    /// B 就在曲尾、这首先放完了:回到 A 接着放。跳不回去时关掉 A-B,照常往下放;处理了返回 true。
    func restartABRepeatAtTrackEndIfNeeded() -> Bool {
        guard let loop = abRepeat.loop, currentSong != nil else { return false }
        return jumpToABRepeatStart(loop)
    }

    /// 拖进度条落到区间外就关掉 A-B;只设了 A 时随便拖。
    func noteABRepeatSeek(to target: TimeInterval) {
        if ABRepeatPolicy.seekLeaves(abRepeat, target: target) {
            abRepeat = .off
        }
    }

    /// 回到 A。此刻跳不回去(开始投放、seek 不动)时关掉 A-B、返回 false,这首照常放下去。
    @discardableResult
    private func jumpToABRepeatStart(_ loop: ABRepeatLoop) -> Bool {
        abRepeatJumpTask?.cancel()
        abRepeatJumpTask = nil
        // 睡眠定时「播完再停」锁在这首上:循环里这首放不完,放到 B 就停。
        if let lockedID = sleepStopAfterSongID, lockedID == currentSong?.id {
            sleepStopAfterSongID = nil
            abRepeat = .off
            pause()
            return true
        }
        guard canUseABRepeat else {
            plog("🔁 A-B: cannot seek back to A here; leaving the loop")
            abRepeat = .off
            return false
        }
        seek(to: loop.start, startPlaying: true)
        return true
    }
}
