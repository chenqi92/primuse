import Foundation
import MediaPlayer
import PrimuseKit

/// Spoken-word playback: per-item resume positions, chapter marks, and the
/// skip intervals an audiobook or a 评书 series is listened to with.
///
/// None of it touches music playback. `currentItemIsSpokenWord` gates every
/// behaviour here, and it is false for everything the classifier does not have
/// positive evidence for.
extension AudioPlayerService {
    // MARK: - Track changes

    /// Called when the current item changes: resets chapter state and arms the
    /// resume for the incoming item.
    ///
    /// The outgoing item's position is **not** written here — by this point the
    /// clock may already have been reset for the new item. Every path that
    /// leaves an item (play, pause, stop, backgrounding) stores it while the
    /// old position is still true.
    func handleSpokenWordItemChange(to song: Song?) {
        chapterLoadTask?.cancel()
        chapterLoadTask = nil
        serverSpokenWordStateTask?.cancel()
        serverSpokenWordStateTask = nil
        serverSpokenWordStateRequestID = nil
        serverSpokenWordStateSongID = nil
        pendingServerSpokenWordResume = nil
        spokenWordChapters = []
        currentChapterIndex = nil
        chapterLoadedSongID = nil
        lastSpokenWordPositionSave = 0
        lastServerSpokenWordPositionPush = 0
        pendingSpokenWordResumeSongID = nil
        currentSpokenWordIntroOutro = nil
        spokenWordLocalTouchAt = nil
        spokenWordStoppedAt = nil
        spokenWordRepositionedWhilePaused = false
        // 片尾跳过、换走时不存位置,都只对那一条;换到别的条目就作废。
        let playbackState = PodcastPlaybackState.shared
        if playbackState.outroHandledEpisodeID != song?.id { playbackState.outroHandledEpisodeID = nil }
        if playbackState.positionSaveSuppressedEpisodeID != song?.id { playbackState.positionSaveSuppressedEpisodeID = nil }

        let wasSpokenWord = currentItemIsSpokenWord
        defer {
            // Spoken word runs at its own speed; switching between a book and a
            // song switches the rate with it.
            if wasSpokenWord != currentItemIsSpokenWord { applyPlaybackRate() }
        }
        guard let song else {
            currentItemIsSpokenWord = false
            pendingSpokenWordSeekOverride = nil
            updateSpokenWordRemoteCommands()
            return
        }
        currentItemIsSpokenWord = SpokenWordStore.shared.isSpokenWord(song)
        if let override = pendingSpokenWordSeekOverride, override.songID != song.id {
            pendingSpokenWordSeekOverride = nil
        }
        updateSpokenWordRemoteCommands()
        guard currentItemIsSpokenWord else {
            pendingSpokenWordSeekOverride = nil
            return
        }
        // 播客单集:片头跳过与 feed 里的章节。
        preparePodcastItem(song)
        currentSpokenWordIntroOutro = serverSpokenWordIntroOutro(for: song)
        noteSpokenWordItemSelected(song)
        // Arm the resume even when nothing is stored: the seek is skipped, but
        // the flag also tells the position writer to ignore the opening zeroes.
        if pendingSpokenWordSeekOverride != nil
            || spokenWordResumeTarget(for: song) != nil {
            pendingSpokenWordResumeSongID = song.id
        }
        refreshServerSpokenWordState(for: song)
    }

    /// Follows the store when the playing item's kind changes under it.
    func observeSpokenWordClassification() {
        for name in [Notification.Name.primuseSpokenWordDidChange, .primuseSpokenWordClassificationDidChange] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshCurrentItemContentKind() }
            }
        }
    }

    /// Re-decides whether the playing item is spoken word.
    ///
    /// The kind can change while an item plays: the listener marks it from
    /// its row or the smart nudge, tags its folder, or another device's
    /// correction arrives. Deciding only on an item change left a book just
    /// marked as one playing as music until the next item — no position
    /// stored, so it started over after a relaunch, song buttons on the lock
    /// screen and in the widgets, and nothing on the "continue listening"
    /// shelf — while the library already showed it among the books.
    func refreshCurrentItemContentKind() {
        guard let song = currentSong else { return }
        let isSpokenWord = SpokenWordStore.shared.isSpokenWord(song)
        guard isSpokenWord != currentItemIsSpokenWord else { return }
        currentItemIsSpokenWord = isSpokenWord
        // Both only make sense for an item that was spoken word when it began.
        pendingSpokenWordResumeSongID = nil
        pendingSpokenWordSeekOverride = nil
        applyPlaybackRate()
        updateSpokenWordRemoteCommands()
        updatePlaybackState()
        plog("🎧 Spoken word: '\(song.title)' now plays as \(isSpokenWord ? "spoken word" : "music")")
        // The book continues from here, not from the next autosave.
        if isSpokenWord { rememberSpokenWordPosition(force: true) }
    }

    // MARK: - Server-kept progress and chapters

    static let serverSpokenWordPushInterval: TimeInterval = 30

    /// 服务端自己记进度的源(Audiobookshelf、Ting Reader):换条目时把服务端的位置拿回来 —— 别的客户端听过的,
    /// 比本机新就按它续播;章节也从服务端拿,流式播放时本机没有文件可解析。
    ///
    /// 开播不等这次读取:解码器先从本机记的位置打开,服务端的更新晚到时再跳过去
    /// (`applyPendingServerSpokenWordResumeIfNeeded`)。用户从目录 / 书签点进来的有自己的起点,不跳。
    ///
    /// 续播(`resuming`)时整本书一起取:别的设备可能已经听到了这本书的另一条,比本机最后一次动这一条还晚,
    /// 就换到那一条接着听(`spokenWordFollowTarget`)。
    /// - Parameter resumePoint: 继续播放时实际要接着放的位置(智能回退退过之后的);缺省是当前位置。
    func refreshServerSpokenWordState(
        for song: Song,
        resuming: Bool = false,
        resumingFrom resumePoint: TimeInterval? = nil
    ) {
        guard let manager = sourceManager else { return }
        let songID = song.id
        let followsServer = pendingSpokenWordSeekOverride?.songID != songID
        let anchor = resuming ? (resumePoint ?? currentTime) : (spokenWordResumeTarget(for: song) ?? 0)
        serverSpokenWordStateTask?.cancel()
        let requestID = UUID()
        serverSpokenWordStateRequestID = requestID
        serverSpokenWordStateSongID = songID
        serverSpokenWordStateTask = Task { [weak self] in
            defer {
                if let self, self.serverSpokenWordStateRequestID == requestID {
                    self.serverSpokenWordStateSongID = nil
                    self.serverSpokenWordStateRequestID = nil
                }
            }
            guard await manager.supportsServerListeningProgress(for: song) else { return }
            let bookProgress = resuming ? await manager.fetchServerBookListeningProgress(for: song) : nil
            let progress: ServerListeningProgress?
            if let bookProgress {
                progress = bookProgress.first { $0.songPath == song.filePath }
            } else {
                progress = await manager.fetchServerListeningProgress(for: song)
            }
            guard !Task.isCancelled, let self, self.currentSong?.id == songID,
                  self.serverSpokenWordStateRequestID == requestID else { return }
            if let progress,
               SpokenWordStore.shared.adoptServerProgress(
                    songID: songID,
                    position: progress.position,
                    duration: progress.duration,
                    isFinished: progress.isFinished,
                    updatedAt: progress.updatedAt
               ) {
                // 服务端更新:时钟还没走起来就重新上膛,首个 tick 跳过去。
                // 听完的一条也可能带着重听的位置,有位置就跳。
                if self.currentTime < 2, self.spokenWordResumeTarget(for: song) != nil {
                    self.pendingSpokenWordResumeSongID = songID
                }
                // 已经从本机记的旧位置开播了:还停在那附近就改从服务端的位置续。
                if followsServer {
                    self.pendingServerSpokenWordResume = (songID, anchor)
                    self.applySyncedSpokenWordPosition(for: song)
                }
                plog("🎧 Spoken word: adopted server position \(Int(progress.position))s for '\(song.title)'")
            }
            if let bookProgress {
                self.adoptServerSpokenWordBookProgress(bookProgress, around: song)
                if followsServer,
                   abs(self.currentTime - anchor) <= Self.serverSpokenWordResumeWindow,
                   let target = self.spokenWordFollowTarget() {
                    let next = target.songs[target.index]
                    plog("🎧 Spoken word: '\(next.title)' was heard on another device after '\(song.title)'; continuing there")
                    // 刚续上的这一条不再存位置:它的位置暂停时存过,现在存会把它变成这本书最新的一条。
                    PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = songID
                    if self.isPlaying || self.isLoading {
                        await self.play(queue: target.songs, startingAt: target.index)
                    } else {
                        self.followSpokenWordBookIfPaused()
                    }
                    return
                }
            }
            await self.refreshServerSpokenWordIntroOutro(for: song)
            let chapters = await manager.fetchServerChapters(for: song)
            guard !Task.isCancelled, self.currentSong?.id == songID,
                  !chapters.isEmpty, self.spokenWordChapters.isEmpty else { return }
            self.spokenWordChapters = chapters
            self.refreshCurrentChapter()
            plog("🎧 Chapters: \(chapters.count) marks from the server for '\(song.title)'")
        }
    }

    /// 暂停队列也要更新恢复位置，否则下一次恢复仍会拿会话里旧的时间覆盖进度。
    /// 开着智能回退时停在原位,等按下播放再按停了多久往回退。
    func applySyncedSpokenWordPosition(for song: Song) {
        guard currentSong?.id == song.id, currentItemIsSpokenWord,
              !isPlaying, !isLoading, pendingSpokenWordSeekOverride == nil else { return }
        let target = spokenWordResumeTarget(for: song, rewinding: spokenWordSmartRewindLimit == nil) ?? 0
        currentTime = target
        lastSpokenWordPositionSave = target
        pendingRecoveryTime = target
        needsPlaybackRecovery = true
        pendingRecoveryIsColdSessionRestore = !hasPreparedLocalPlayback
        isAtTrackEnd = false
        pendingSpokenWordResumeSongID = nil
        pendingServerSpokenWordResume = nil
        updateNowPlayingInfo()
        updatePlaybackState()
        persistPlaybackSession()
    }

    // MARK: - Following the book to another device

    private static let selectedItemDefaultsKey = "primuse.spokenWord.selectedItem.v1"

    /// 记下本机换到这一条的时间。冷启动恢复的那一条用上次记下的,和它自己在本机存位置的时间取晚的
    /// (刚从服务端采纳来的那次不算本机的)。
    private func noteSpokenWordItemSelected(_ song: Song) {
        let defaults = UserDefaults.standard
        if isRestoringPlaybackSession {
            let store = SpokenWordStore.shared
            let saved = defaults.dictionary(forKey: Self.selectedItemDefaultsKey)
            let selectedAt = (saved?["songID"] as? String) == song.id
                ? (saved?["at"] as? Double).map(Date.init(timeIntervalSince1970:))
                : nil
            let localChange = store.serverAdoptedChange(forSongID: song.id) == nil
                ? store.lastChange(forSongID: song.id)
                : nil
            spokenWordLocalTouchAt = [selectedAt, localChange].compactMap { $0 }.max()
        } else {
            let now = Date()
            spokenWordLocalTouchAt = now
            defaults.set(["songID": song.id, "at": now.timeIntervalSince1970], forKey: Self.selectedItemDefaultsKey)
        }
    }

    /// 续播时整本书取回来的进度:当前这一条之外的也记进本机,书架和「在听」跟着更新。
    private func adoptServerSpokenWordBookProgress(_ records: [ServerListeningProgress], around song: Song) {
        guard let library, !records.isEmpty else { return }
        let bookID = spokenWordBookID(for: song)
        let idsByPath = Dictionary(
            library.spokenWordSongs.lazy
                .filter { $0.sourceID == song.sourceID && library.spokenWordBookIDs[$0.id] == bookID }
                .map { ($0.filePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        var adopted = 0
        for record in records where record.songPath != song.filePath {
            guard let songID = idsByPath[record.songPath] else { continue }
            if SpokenWordStore.shared.adoptServerProgress(
                songID: songID,
                position: record.position,
                duration: record.duration,
                isFinished: record.isFinished,
                updatedAt: record.updatedAt
            ) { adopted += 1 }
        }
        if adopted > 0 { SpokenWordStore.shared.persistLocally() }
    }

    /// 当前这本书在别的设备上(从服务端同步回来的)比本机最后一次动当前这一条更晚被听过的那一条,
    /// 连同要装的队列;nil 表示就该接着当前这一条。本机手动标的听完不算;播客不跟,各集是各听各的。
    ///
    /// `allowsUnanchored`:不知道本机什么时候动过当前这一条(升级前存下的会话)时也照最新的那条走。
    /// 只给照着显示的那一条开播的入口用(书架「继续」、小组件)。
    func spokenWordFollowTarget(allowsUnanchored: Bool = false) -> (songs: [Song], index: Int)? {
        let store = SpokenWordStore.shared
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio,
              !store.isPodcast(song),
              spokenWordLocalTouchAt != nil || allowsUnanchored,
              let book = currentSpokenWordBook, book.items.count > 1 else { return nil }
        let records = book.items.compactMap { item -> SpokenWordBookFollowPolicy.Record? in
            guard let record = SpokenWordBookFollowPolicy.Record(
                      itemID: item.id,
                      positionUpdatedAt: item.positionUpdatedAt,
                      finishedAt: item.finishedAt
                  ),
                  store.serverAdoptedChange(forSongID: item.id) == record.updatedAt else { return nil }
            return record
        }
        guard !records.isEmpty else { return nil }
        guard let targetID = SpokenWordBookFollowPolicy.target(
            itemIDs: book.items.map(\.id),
            currentItemID: song.id,
            anchor: spokenWordLocalTouchAt,
            records: records
        ) else { return nil }
        let queued = queueEntries.map(\.song)
        if let index = queued.firstIndex(where: { $0.id == targetID }) { return (queued, index) }
        // 队列里没有(只装了一段,或是从别处点进来的):整本书装进去。
        guard let library else { return nil }
        let bookID = spokenWordBookID(for: song)
        let members = Dictionary(
            library.spokenWordSongs.lazy
                .filter { library.spokenWordBookIDs[$0.id] == bookID }
                .map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let songs = book.items.compactMap { members[$0.id] }
        guard let index = songs.firstIndex(where: { $0.id == targetID }) else { return nil }
        return (songs, index)
    }

    /// 别的设备的进度同步进来后:播放器停在这本书上、而那边已经听到了另一条,就换过去,不出声。
    /// 正在放、正在加载、投放中,或用户刚从目录 / 书签点了起点的不动。
    func followSpokenWordBookIfPaused() {
        guard !isPlaying, !isLoading, !isCastingMode, !isAppleMusicMode,
              pendingSpokenWordSeekOverride == nil,
              let target = spokenWordFollowTarget() else { return }
        let song = target.songs[target.index]
        plog("🎧 Spoken word: the book continues at '\(song.title)' on another device; moving the paused player there")
        let reusesQueue = queueEntries.indices.contains(target.index)
            && queueEntries[target.index].song.id == song.id
        // 停着的这一条暂停时存过位置;别让 stop() 按「现在」再存一次,把它变成这本书最新的一条。
        lastSpokenWordPositionSave = currentTime
        stop()
        setQueue(target.songs, startAt: target.index, keepsContinuation: reusesQueue)
        // 停着换过去:智能回退等按下播放时再按停了多久算。
        stagePausedHandoff(
            song: song,
            at: spokenWordResumeTarget(for: song, rewinding: spokenWordSmartRewindLimit == nil) ?? 0
        )
        persistPlaybackSession()
    }

    /// 「继续」按在停着的当前这本书上(书架、小组件):这本书在别的设备上(或本机早先)已经听到了
    /// 另一条,就从那一条开播;否则原地接着播。
    func resumeCurrentSpokenWordBook() {
        guard !isLoading, !isCastingMode, !isAppleMusicMode,
              let target = spokenWordFollowTarget(allowsUnanchored: true) else {
            resume()
            return
        }
        lastSpokenWordPositionSave = currentTime
        Task { await play(queue: target.songs, startingAt: target.index) }
    }

    // MARK: - Intro and outro set on the server

    /// 服务端给这一条所在那本书设的片头 / 片尾秒数(Ting Reader);没有就是 nil。
    func serverSpokenWordIntroOutro(for song: Song) -> SpokenWordIntroOutro? {
        guard let reference = TingReaderAPIProtocol.trackReference(from: song.filePath) else { return nil }
        return SpokenWordServerIntroOutroCache.settings(sourceID: song.sourceID, bookID: reference.bookID)
    }

    /// 开始播一条时从哪里起:续播位置,再按这本书的片头往后挪(从片头里、或从头开始的,改从片头结束处开始)。
    /// 续播位置按设置往回退:固定几秒,或开着智能回退时按上次听到这里过了多久。`rewinding` 为 false
    /// 时不退 —— 暂停着落位,退多少等真正开播时再算。
    func spokenWordResumeTarget(for song: Song, rewinding: Bool = true) -> TimeInterval? {
        let rewind: SpokenWordStore.ResumeRewind
        if !rewinding {
            rewind = .unchanged
        } else if let limit = spokenWordSmartRewindLimit {
            rewind = .smart(limit: limit)
        } else {
            rewind = .fixed
        }
        let stored = SpokenWordStore.shared.resumePosition(for: song, rewind: rewind)
        guard let skip = serverSpokenWordIntroOutro(for: song) else { return stored }
        return SpokenWordIntroOutroPolicy.startPosition(resume: stored, duration: song.duration, skip: skip)
    }

    /// 开播后按这本书现取一次片头 / 片尾(网页端刚改过的也跟上)。变了就记下;片头变长、
    /// 而这一条还停在新片头里没听多久,就跳过去。
    private func refreshServerSpokenWordIntroOutro(for song: Song) async {
        guard let manager = sourceManager,
              let skip = await manager.fetchServerSpokenWordIntroOutro(for: song),
              currentSong?.id == song.id else { return }
        let refreshed = skip.isEmpty ? nil : skip
        guard refreshed != currentSpokenWordIntroOutro else { return }
        currentSpokenWordIntroOutro = refreshed
        let intro = TimeInterval(skip.introSeconds)
        guard intro > 0, pendingSpokenWordSeekOverride == nil,
              currentTime < min(intro, Self.serverSpokenWordResumeWindow),
              let target = spokenWordResumeTarget(for: song), target > currentTime + 1 else { return }
        plog("🎧 Spoken word: skipping the \(skip.introSeconds)s intro of '\(song.title)'")
        if isPlaying {
            seek(to: target, startPlaying: true)
        } else {
            applySyncedSpokenWordPosition(for: song)
        }
    }

    /// 播放时钟每拍调:这本书在服务端设了片尾,离结尾不到那么多秒就当这一条听完,接着放下一条。
    func applyServerSpokenWordOutroSkipIfNeeded() {
        guard isPlaying, let skip = currentSpokenWordIntroOutro, let song = currentSong,
              PodcastPlaybackState.shared.outroHandledEpisodeID != song.id else { return }
        let total = duration > 0 ? duration : song.duration
        guard SpokenWordIntroOutroPolicy.shouldSkipOutro(position: currentTime, duration: total, skip: skip) else { return }
        PodcastPlaybackState.shared.outroHandledEpisodeID = song.id
        PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID = song.id
        plog("🎧 Spoken word: skipping the last \(skip.outroSeconds)s of '\(song.title)'")
        SpokenWordStore.shared.markFinished(true, songIDs: [song.id])
        SpokenWordStore.shared.persistLocally()
        pushServerSpokenWordPosition(song: song, position: total, duration: total, force: true)
        // 定了「播完这一条就停」:片尾就是这一条的结尾,停在这里,不接下一条。
        if sleepStopAfterSongID == song.id {
            sleepStopAfterSongID = nil
            pause()
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let advanced = await self.next(isAutomaticAdvance: true)
            if !advanced { self.pause() }
        }
    }

    /// 把位置报给服务端。本机每 15 秒存一次,服务端 30 秒一次;暂停、切换、退后台那几次立刻报。
    /// 换条目后服务端那次读取回来之前不报:这时的位置可能还是本机的旧位置。
    func pushServerSpokenWordPosition(song: Song, position: TimeInterval, duration: TimeInterval, force: Bool) {
        guard let manager = sourceManager, serverSpokenWordStateSongID != song.id else { return }
        let isFinished = SpokenWordStore.shared.isFinished(songID: song.id)
        // 听完后重听:服务端仍记听完,重听到哪里只留在本机和 iCloud;听到结尾那一次照常报。
        if isFinished, duration > 0,
           position < duration - SpokenWordProgressPolicy.completionTailThreshold { return }
        if !force, abs(position - lastServerSpokenWordPositionPush) < Self.serverSpokenWordPushInterval { return }
        lastServerSpokenWordPositionPush = position
        Task {
            guard await manager.supportsServerListeningProgress(for: song) else { return }
            await manager.reportServerListeningProgress(
                for: song,
                position: position,
                duration: duration,
                isFinished: isFinished
            )
        }
    }

    /// Where the decoder opens the item that just became current: its
    /// remembered position (or the requested one), so the opening of the file
    /// is never heard before the jump. Nil leaves it at the top, as for a
    /// plain file played from the start, a CUE track, a medley slice or a
    /// playback range, which open where their own window says.
    func spokenWordOpeningPosition(for song: Song) -> TimeInterval? {
        guard pendingSpokenWordResumeSongID == song.id,
              song.cueStartTime == nil, song.cueEndTime == nil,
              song.appliedPlaybackRange == nil,
              !medleySongIDs.contains(song.id) else { return nil }
        let override = pendingSpokenWordSeekOverride.flatMap { $0.songID == song.id ? $0.position : nil }
        guard let target = override ?? spokenWordResumeTarget(for: song),
              target.isFinite, target >= Self.spokenWordOpeningMinimum else { return nil }
        if song.duration > 0, target >= song.duration - 1 { return nil }
        return target
    }

    /// Below this a resume starts from the top and jumps on the first tick:
    /// the opening is too short to be heard as a glitch.
    static let spokenWordOpeningMinimum: TimeInterval = 2

    /// Seeks to the remembered position once audio is actually running.
    ///
    /// The main playback path opens the decoder right at the position
    /// (`spokenWordOpeningPosition`), so the first tick already reads it and
    /// only clears the flag. The other paths (whole-file download, the
    /// fallback decoder, a gapless or crossfade hand-over) still build the
    /// decoder at zero, so the jump happens on the first clock tick. The guard
    /// on `currentTime` keeps a later tick — or the listener scrubbing away
    /// immediately — from pulling the play head back.
    func applyPendingSpokenWordResumeIfNeeded() {
        guard let songID = pendingSpokenWordResumeSongID,
              let song = currentSong,
              song.id == songID else { return }
        guard isPlaying, currentTime < 2 else {
            if currentTime >= 2 {
                pendingSpokenWordResumeSongID = nil
                // Opened at the requested position already; do not reuse it next time.
                if pendingSpokenWordSeekOverride?.songID == songID { pendingSpokenWordSeekOverride = nil }
            }
            return
        }
        let override = pendingSpokenWordSeekOverride.flatMap { $0.songID == song.id ? $0.position : nil }
        pendingSpokenWordSeekOverride = nil
        guard let target = override ?? spokenWordResumeTarget(for: song) else {
            pendingSpokenWordResumeSongID = nil
            return
        }
        pendingSpokenWordResumeSongID = nil
        plog("🎧 Spoken word: resuming '\(song.title)' at \(Int(target))s")
        seek(to: target, startPlaying: true)
    }

    /// 跳回服务端位置的窗口:开播后还停在起点这么近以内,才算「还没开始听」。
    static let serverSpokenWordResumeWindow: TimeInterval = 10

    /// 服务端更新的位置晚于开播才到时,在下一拍跳过去。本机的续播还没落地就先等它;
    /// 用户已经拖到别处、或者已经从起点听了一阵,就不拉回。
    func applyPendingServerSpokenWordResumeIfNeeded() {
        guard let pending = pendingServerSpokenWordResume else { return }
        guard let song = currentSong, song.id == pending.songID else {
            pendingServerSpokenWordResume = nil
            return
        }
        guard pendingSpokenWordResumeSongID == nil, isPlaying else { return }
        pendingServerSpokenWordResume = nil
        guard abs(currentTime - pending.anchor) <= Self.serverSpokenWordResumeWindow,
              let target = spokenWordResumeTarget(for: song),
              abs(target - currentTime) > 2 else { return }
        plog("🎧 Spoken word: moving '\(song.title)' from \(Int(currentTime))s to the server position \(Int(target))s")
        seek(to: target, startPlaying: true)
    }

    // MARK: - Position

    /// Stores where the listener is. `force` is used for the events that must
    /// not wait for the autosave window — pause, stop, track change and
    /// leaving the foreground.
    func rememberSpokenWordPosition(force: Bool = false) {
        guard currentItemIsSpokenWord, let song = currentSong else { return }
        // A resume seek has not landed yet, so the clock is still reporting
        // the opening of the file. Writing that would erase the position.
        guard pendingSpokenWordResumeSongID == nil else { return }
        guard PodcastPlaybackState.shared.positionSaveSuppressedEpisodeID != song.id else { return }
        let position = currentTime
        guard position.isFinite else { return }
        if !isPlaying, abs(position - lastSpokenWordPositionSave) < 0.001 { return }
        if !force {
            guard serverSpokenWordStateSongID != song.id else { return }
            let elapsed = position - lastSpokenWordPositionSave
            guard abs(elapsed) >= SpokenWordProgressPolicy.autosaveInterval else { return }
        }
        lastSpokenWordPositionSave = position
        let resolvedDuration = duration > 0 ? duration : song.duration
        SpokenWordStore.shared.rememberPosition(
            position,
            duration: resolvedDuration,
            forSongID: song.id
        )
        spokenWordLocalTouchAt = Date()
        // Straight to disk: a crash or a kill without a background transition
        // must not also lose the debounce window. One small write per
        // autosave interval, the same count the debounce would have made.
        SpokenWordStore.shared.persistLocally()
        pushServerSpokenWordPosition(song: song, position: position, duration: resolvedDuration, force: force)
    }

    /// Writes through to disk as well. Used when the app is backgrounded or
    /// terminated, where the debounced save would never run.
    func flushSpokenWordPosition() {
        rememberSpokenWordPosition(force: true)
        SpokenWordStore.shared.flush()
    }

    // MARK: - Skipping

    func skipSpokenWord(by offset: TimeInterval) {
        guard currentSong != nil, !isLiveRadio else { return }
        let target = SpokenWordSkipPolicy.position(
            from: currentTime,
            offset: offset,
            duration: duration
        )
        seek(to: target, startPlaying: isPlaying ? true : nil)
        rememberSpokenWordPosition(force: true)
    }

    /// 点了歌词或文字稿里的一行(全屏文稿里的一段、搜到的一处同样走这里)。
    ///
    /// 有声内容暂停着时从这一句开始播:点字幕就是想从这儿听,只跳过去不出声还得再去按播放。
    /// 音乐歌词照旧,只跳不改播放状态。
    func seekToTappedLine(at time: TimeInterval) {
        guard currentItemIsSpokenWord, !isLiveRadio, !isPlaying else {
            seek(to: time)
            if currentItemIsSpokenWord { rememberSpokenWordPosition(force: true) }
            return
        }
        if isCastingMode || isAppleMusicMode {
            // 这两条路的 seek 不管起播,跳完再走一次「继续播放」。
            seek(to: time)
            resume()
        } else {
            // 和「继续播放」一样先记下用户要播:暂停时的意图是停,不登记的话重建好的管线不会开声。
            registerPlayIntent()
            seek(to: time, startPlaying: true)
        }
        rememberSpokenWordPosition(force: true)
    }

    func skipSpokenWordForward() {
        skipSpokenWord(by: TimeInterval(spokenWordSkipForwardSeconds))
    }

    func skipSpokenWordBackward() {
        skipSpokenWord(by: -TimeInterval(spokenWordSkipBackwardSeconds))
    }

    var spokenWordSkipForwardSeconds: Int {
        SpokenWordSkipPolicy.clampedInterval(playbackSettings.spokenWordSkipForwardSeconds)
    }

    var spokenWordSkipBackwardSeconds: Int {
        SpokenWordSkipPolicy.clampedInterval(playbackSettings.spokenWordSkipBackwardSeconds)
    }

    /// `goforward.N` / `gobackward.N` for the configured intervals, shared by
    /// every transport that swaps track buttons for skips.
    var spokenWordSkipForwardSymbol: String {
        SpokenWordSkipPolicy.symbolName(forward: true, interval: spokenWordSkipForwardSeconds)
    }

    var spokenWordSkipBackwardSymbol: String {
        SpokenWordSkipPolicy.symbolName(forward: false, interval: spokenWordSkipBackwardSeconds)
    }

    // MARK: - Smart rewind

    /// 智能回退(#363)开着时的上限秒数;关着是 nil。
    var spokenWordSmartRewindLimit: TimeInterval? {
        guard playbackSettings.spokenWordSmartRewindEnabled else { return nil }
        return TimeInterval(SpokenWordSmartRewindPolicy.clampedLimit(playbackSettings.spokenWordSmartRewindLimitSeconds))
    }

    /// `isPlaying` 变了:有声内容停下记下时刻,继续播放时按停了多久往回退;开播了就作废。
    func noteSpokenWordPlayingChanged() {
        if isPlaying {
            spokenWordStoppedAt = nil
            spokenWordRepositionedWhilePaused = false
        } else if currentItemIsSpokenWord, let songID = currentSong?.id {
            spokenWordStoppedAt = (songID, Date())
        }
    }

    /// 停着的时候挪了位置(拖进度、跳章节、点书签或字幕):就从挑的地方开始。原地重建管线
    /// (换输出、恢复)那几次落点不变,不算。
    func noteSpokenWordSeekWhilePaused(to time: TimeInterval, isRecovery: Bool) {
        guard !isRecovery, !isPlaying, currentItemIsSpokenWord,
              time.isFinite, abs(time - currentTime) > 0.5 else { return }
        spokenWordRepositionedWhilePaused = true
    }

    /// 继续播放有声内容时从哪里接着放:停得越久往回退得越多。nil 表示原地接着放 —— 没开智能回退、
    /// 停了没几秒、停着时自己挪过位置,或要原地续播而这条流式解码还没下完、跳不了。
    ///
    /// 「停了多久」从本机停下的那一刻和这一条最后存位置的时间里取晚的:冷启动恢复出来的、别的设备
    /// 刚听过同步过来的,都按最后一次听到这里算。
    func spokenWordSmartRewindTarget(for song: Song, from position: TimeInterval, seeksInPlace: Bool) -> TimeInterval? {
        guard currentItemIsSpokenWord, !isPlaying, !isAtTrackEnd, !spokenWordRepositionedWhilePaused,
              let limit = spokenWordSmartRewindLimit, position.isFinite, position > 0 else { return nil }
        if seeksInPlace, activeDecoderKind == .streaming, completedFullDownloadURL(for: song) == nil { return nil }
        let stoppedAt = spokenWordStoppedAt.flatMap { $0.songID == song.id ? $0.at : nil }
        let storedAt = SpokenWordStore.shared.position(forSongID: song.id)?.updatedAt
        guard let lastHeard = [stoppedAt, storedAt].compactMap({ $0 }).max() else { return nil }
        let away = Date().timeIntervalSince(lastHeard)
        let target = SpokenWordSmartRewindPolicy.resumePosition(from: position, away: away, limit: limit)
        guard position - target >= 1 else { return nil }
        plog("🎧 Spoken word: smart rewind \(Int(position - target))s after \(Int(away))s away on '\(song.title)'")
        return target
    }

    // MARK: - Playback rate

    /// The render graph `song` plays through. Spoken word always takes the
    /// effects graph whatever the output setting: its speed is the graph's
    /// time-pitch unit, and a bit-exact path buys nothing for a voice. Music
    /// follows the setting.
    func outputMode(for song: Song?) -> AudioOutputMode {
        if let song, SpokenWordStore.shared.isSpokenWord(song) { return .effects }
        return playbackSettings.outputMode
    }

    /// The rate `song` should play at: its book's own speed (or the global
    /// spoken-word speed) for spoken word, the music rate otherwise, 1× where
    /// the output cannot time-stretch.
    func requestedPlaybackRate(for song: Song?) -> Float {
        if let practice = karaokePracticeRate, playbackSettings.outputMode == .effects {
            return practice
        }
        let isSpokenWord = song.map { SpokenWordStore.shared.isSpokenWord($0) } ?? false
        return SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: isSpokenWord,
            musicRate: playbackSettings.playbackRate,
            spokenWordRate: song.flatMap { song in
                isSpokenWord ? spokenWordRate(forBookID: spokenWordBookID(for: song)) : nil
            } ?? playbackSettings.spokenWordPlaybackRate,
            rateAllowed: outputMode(for: song) == .effects
        )
    }

    /// The rate for the item that is playing now.
    var requestedPlaybackRate: Float {
        if let practice = karaokePracticeRate, playbackSettings.outputMode == .effects {
            return practice
        }
        return SpokenWordPlaybackRatePolicy.effectiveRate(
            isSpokenWord: currentItemIsSpokenWord,
            musicRate: playbackSettings.playbackRate,
            spokenWordRate: currentSpokenWordRate,
            rateAllowed: currentItemIsSpokenWord || playbackSettings.outputMode == .effects
        )
    }

    /// The key shift next to the speed (#332) for `song`: music only, and
    /// only where the graph has its time-pitch unit.
    func requestedPitchSemitones(for song: Song?) -> Int {
        PlaybackPitchPolicy.effectiveSemitones(
            playbackSettings.pitchSemitones,
            isSpokenWord: song.map { SpokenWordStore.shared.isSpokenWord($0) } ?? false,
            isLiveRadio: isLiveRadio,
            outputAllowsPitch: outputMode(for: song) == .effects
        )
    }

    /// The key shift for the item that is playing now. The karaoke stage adds
    /// its own on top in the engine.
    var requestedPitchSemitones: Int {
        PlaybackPitchPolicy.effectiveSemitones(
            playbackSettings.pitchSemitones,
            isSpokenWord: currentItemIsSpokenWord,
            isLiveRadio: isLiveRadio,
            outputAllowsPitch: playbackSettings.outputMode == .effects
        )
    }

    // MARK: - Books

    /// The book `song` belongs to — the same id the bookshelf gives it
    /// (`SpokenWordBook.id`), so a per-book setting is found from the item
    /// that is playing. The library groups books once per change; an item it
    /// does not hold falls back to what its own tags and path say.
    func spokenWordBookID(for song: Song) -> String {
        if let bookID = library?.spokenWordBookIDs[song.id] ?? library?.localPodcastBookIDs[song.id] { return bookID }
        return SpokenWordBookGrouping.bookID(for: SpokenWordBookItem(song: song))
    }

    /// The book the current item belongs to; nil for music and radio.
    var currentBookID: String? {
        guard currentItemIsSpokenWord, let song = currentSong else { return nil }
        return spokenWordBookID(for: song)
    }

    /// The current book's items as they stand in the queue, in queue order
    /// (which is reading order: the shelf installs the book as the queue).
    /// Empty for music and radio.
    ///
    /// Cached per book, queue snapshot, classification and library content:
    /// the player's skip keys ask for it on every redraw (their long-press
    /// menu is built with the view), and collecting it classifies every
    /// queue entry — a thousand-item queue made each redraw of the
    /// audiobook player cost tens of milliseconds while it slid in and out.
    var currentBookItemIDs: [String] {
        guard let bookID = currentBookID else { return [] }
        // Reading the count keeps views that ask for this observing the
        // queue even when the answer comes from the cache.
        let key = "\(bookID)|\(queueEntries.count)|\(watchQueueSnapshotRevision)"
            + "|\(SpokenWordStore.shared.nonProgressRevision)|\(library?.spokenWordContentRevision ?? 0)"
        if let cache = currentBookItemIDsCache, cache.key == key { return cache.ids }
        let ids = queueEntries.compactMap { entry -> String? in
            let song = entry.song
            guard spokenWordBookID(for: song) == bookID,
                  SpokenWordStore.shared.isSpokenWord(song) else { return nil }
            return song.id
        }
        currentBookItemIDsCache = (key, ids)
        return ids
    }

    /// The playing item's book, grouped from that book's own items (so a
    /// publish never regroups the shelf for it). The player's progress rows
    /// ask for it on every clock tick, so the grouping is kept per book,
    /// classification and library content, and a saved position only reads
    /// the progress again (see `SpokenWordCurrentBookCache`).
    var currentSpokenWordBook: SpokenWordBook? {
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio else { return nil }
        let store = SpokenWordStore.shared
        let bookID = spokenWordBookID(for: song)
        var cache = spokenWordBookCache
        let book = cache.book(
            groupingKey: "\(bookID)|\(store.nonProgressRevision)|\(library?.spokenWordContentRevision ?? 0)",
            progressKey: "\(store.revision)",
            itemID: song.id,
            group: { groupCurrentBook(song) },
            progress: { store.progress(forSongID: $0) }
        )
        spokenWordBookCache = cache
        return book
    }

    /// `live: false` places the playing item at its stored position (written
    /// every few seconds), so a view showing whole-book progress does not
    /// redraw on every clock tick — the title block holds the More menu,
    /// which closes when its host redraws.
    func spokenWordNowPlayingSummary(live: Bool) -> SpokenWordNowPlayingSummary? {
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio else { return nil }
        let position = live
            ? currentTime
            : (SpokenWordStore.shared.position(forSongID: song.id)?.position ?? 0)
        let book = currentSpokenWordBook
        let itemDuration = duration > 0 ? duration : song.duration
        let chapterCount = spokenWordChapters.count
        let chapterIndex = currentChapterIndex
        // The chapter column asks on every redraw, and the player sliding in
        // or out redraws it every frame: adding up a book of a thousand parts
        // each time drops frames. The book is a function of its cache key.
        let key = "\(spokenWordBookCache.key ?? song.id)|\(position)|\(itemDuration)"
            + "|\(chapterCount)|\(chapterIndex ?? -1)"
        if let cache = spokenWordSummaryCache, cache.key == key { return cache.summary }
        let summary = SpokenWordNowPlayingPolicy.summary(
            book: book,
            currentItemID: song.id,
            position: position,
            duration: itemDuration,
            chapterCount: chapterCount,
            currentChapterIndex: chapterIndex
        )
        spokenWordSummaryCache = (key, summary)
        return summary
    }

    /// "第 12 / 120 章" alone, without the whole-book progress the summary
    /// adds up: the mini player shows it on a line that redraws with the clock.
    var spokenWordPartPosition: SpokenWordPartPosition? {
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio else { return nil }
        let book = currentSpokenWordBook
        let chapterCount = spokenWordChapters.count
        let chapterIndex = currentChapterIndex
        let key = "\(spokenWordBookCache.key ?? song.id)|\(chapterCount)|\(chapterIndex ?? -1)"
        if let cache = spokenWordPartPositionCache, cache.key == key { return cache.part }
        let part = SpokenWordNowPlayingPolicy.partPosition(
            bookItemIDs: book?.items.map(\.id),
            currentItemID: song.id,
            chapterCount: chapterCount,
            currentChapterIndex: chapterIndex
        )
        spokenWordPartPositionCache = (key, part)
        return part
    }

    /// The contents list of the playing book.
    ///
    /// Lists run to a thousand parts, so by default the playing item is
    /// placed at its stored position (written every few seconds) and the
    /// list does not observe the clock; the current chapter still follows
    /// `currentChapterIndex`. `live` reads the play head instead.
    func spokenWordContentsRows(live: Bool = false) -> [SpokenWordContentsRow] {
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio else { return [] }
        let position = live
            ? currentTime
            : (SpokenWordStore.shared.position(forSongID: song.id)?.position ?? 0)
        return SpokenWordContentsPolicy.rows(
            book: currentSpokenWordBook,
            currentItemID: song.id,
            currentItemTitle: song.title,
            position: position,
            duration: duration > 0 ? duration : song.duration,
            chapters: spokenWordChapters,
            currentChapterIndex: currentChapterIndex
        )
    }

    /// Every bookmark of the playing book, in reading order.
    var currentBookBookmarkEntries: [SpokenWordBookBookmarkPolicy.Entry] {
        guard let song = currentSong, currentItemIsSpokenWord, !isLiveRadio else { return [] }
        let itemIDs = currentSpokenWordBook?.items.map(\.id) ?? [song.id]
        let store = SpokenWordStore.shared
        return SpokenWordBookBookmarkPolicy.entries(itemIDs: itemIDs) { store.bookmarks(forSongID: $0) }
    }

    /// Content time left in the chapter (or item) being heard.
    var spokenWordPartRemaining: TimeInterval? {
        SpokenWordNowPlayingPolicy.partRemaining(
            position: currentTime,
            duration: duration > 0 ? duration : (currentSong?.duration ?? 0),
            chapters: spokenWordChapters,
            currentChapterIndex: currentChapterIndex
        )
    }

    // MARK: - Contents navigation

    /// Plays one item of the playing book from where it was left; a finished
    /// one stays finished and starts from where hearing it again stopped, or
    /// from the top. Installs the book as the queue when the item is not in
    /// it, the way the shelf starts a book.
    func playSpokenWordBookItem(id itemID: String, at position: TimeInterval? = nil) {
        guard currentSong?.id != itemID else {
            if let position {
                seek(to: position, startPlaying: isPlaying ? true : nil)
                rememberSpokenWordPosition(force: true)
            }
            return
        }
        rememberSpokenWordPosition(force: true)
        if let position {
            pendingSpokenWordSeekOverride = (itemID, position)
        }
        if let index = queueEntries.firstIndex(where: { $0.song.id == itemID }) {
            Task { await playFromQueue(at: index) }
            return
        }
        guard let library, let book = currentSpokenWordBook else { return }
        let byID = Dictionary(
            library.spokenWordSongs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let songs = book.items.compactMap { byID[$0.id] }
        guard let index = songs.firstIndex(where: { $0.id == itemID }) else { return }
        Task { await play(queue: songs, startingAt: index) }
    }

    /// Jumps to a bookmark anywhere in the playing book.
    func playSpokenWordBookmark(_ bookmark: SpokenWordBookmark) {
        if currentSong?.id == bookmark.songID {
            seekToSpokenWordBookmark(bookmark)
        } else {
            playSpokenWordBookItem(id: bookmark.songID, at: bookmark.position)
        }
    }

    /// Opens a contents row: a chapter mark seeks, an item plays.
    func openSpokenWordContentsRow(_ row: SpokenWordContentsRow) {
        switch row.kind {
        case let .chapter(index, startTime):
            if currentSong?.id == row.itemID {
                seekToChapter(at: index)
            } else {
                playSpokenWordBookItem(id: row.itemID, at: startTime)
            }
        case .item:
            playSpokenWordBookItem(id: row.itemID)
        }
    }

    /// The player's previous-chapter button: back to the start of the
    /// chapter, then to the previous chapter mark or the previous file.
    func goToPreviousSpokenWordPart() {
        switch SpokenWordPartNavigationPolicy.previous(
            position: currentTime,
            chapters: spokenWordChapters,
            currentChapterIndex: currentChapterIndex,
            hasPreviousItem: hasPreviousBookItem
        ) {
        case .seekToChapter(let index):
            seekToChapter(at: index)
        case .restartItem:
            seek(to: 0, startPlaying: isPlaying ? true : nil)
            rememberSpokenWordPosition(force: true)
        case .previousItem:
            moveWithinBook(by: -1)
        case .nextItem, .none:
            break
        }
    }

    /// The player's next-chapter button.
    func goToNextSpokenWordPart() {
        switch SpokenWordPartNavigationPolicy.next(
            chapters: spokenWordChapters,
            currentChapterIndex: currentChapterIndex,
            hasNextItem: hasNextBookItem
        ) {
        case .seekToChapter(let index):
            seekToChapter(at: index)
        case .nextItem:
            moveWithinBook(by: 1)
        case .restartItem, .previousItem, .none:
            break
        }
    }

    var canGoToNextSpokenWordPart: Bool {
        SpokenWordPartNavigationPolicy.canGoNext(
            chapters: spokenWordChapters,
            currentChapterIndex: currentChapterIndex,
            hasNextItem: hasNextBookItem
        )
    }

    // MARK: - Widgets

    /// What the now-playing widget draws for the item playing: the skip
    /// intervals, the book and where the listener is in it. Nil for music and
    /// radio, which the widget keeps drawing as songs.
    func widgetSpokenWordInfo() -> SpokenWordPlaybackInfo? {
        guard currentItemIsSpokenWord, !isLiveRadio, let song = currentSong else { return nil }
        var info = SpokenWordPlaybackInfo(
            skipBackwardSeconds: spokenWordSkipBackwardSeconds,
            skipForwardSeconds: spokenWordSkipForwardSeconds
        )
        info.bookID = spokenWordBookID(for: song)
        if let book = currentSpokenWordBook {
            info.bookTitle = book.title
            info.bookAuthor = book.author
            if let part = SpokenWordWidgetPolicy.partPosition(of: song.id, in: book) {
                info.partIndex = part.index
                info.partCount = part.count
            }
            info.bookFraction = book.fractionComplete
            info.bookRemaining = book.remainingDuration
        } else {
            info.bookTitle = song.albumTitle
            info.bookAuthor = song.albumArtistName ?? song.artistName
        }
        // A single-file book is divided by its chapter marks instead.
        if info.partIndex == nil, spokenWordChapters.count > 1, let chapter = currentChapterIndex {
            info.partIndex = chapter + 1
            info.partCount = spokenWordChapters.count
        }
        return info
    }

    /// The book the playing item belongs to, grouped only from its own items
    /// so a publish does not regroup the whole shelf.
    private func groupCurrentBook(_ song: Song) -> SpokenWordCurrentBookCache.Grouped {
        guard let library else { return .init(book: nil) }
        let bookID = spokenWordBookID(for: song)
        let members = library.spokenWordSongs.filter { library.spokenWordBookIDs[$0.id] == bookID }
        guard !members.isEmpty else { return .init(book: nil) }
        let store = SpokenWordStore.shared
        let books = SpokenWordBookGrouping.books(
            from: members.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
        return .init(
            book: books.first { book in book.items.contains { $0.id == song.id } },
            untimedItemIDs: Set(members.lazy.filter { !($0.duration > 0) }.map(\.id))
        )
    }

    // MARK: - Per-book speed

    /// The speed a book plays at: its own when the listener picked one for
    /// it, the global spoken-word speed otherwise.
    func spokenWordRate(forBookID bookID: String) -> Float {
        SpokenWordPlaybackRatePolicy.bookRate(
            stored: SpokenWordStore.shared.playbackRate(forBookID: bookID),
            globalSpokenWordRate: playbackSettings.spokenWordPlaybackRate
        )
    }

    /// The speed the current book plays at — what the player's speed chip
    /// shows while a book plays. Falls back to the global spoken-word speed
    /// when nothing spoken is playing.
    var currentSpokenWordRate: Float {
        guard let bookID = currentBookID else {
            return SpokenWordPlaybackRatePolicy.clamped(playbackSettings.spokenWordPlaybackRate)
        }
        return spokenWordRate(forBookID: bookID)
    }

    /// Whether the current book has a speed of its own (rather than
    /// following the global spoken-word speed).
    var currentBookHasOwnRate: Bool {
        guard let bookID = currentBookID else { return false }
        return SpokenWordStore.shared.playbackRate(forBookID: bookID) != nil
    }

    /// The player's speed chip while a book plays: the choice belongs to
    /// this book and takes effect at once. Picking the global speed makes the
    /// book follow the global speed again. With no book playing it sets the
    /// global spoken-word speed.
    func setSpokenWordRateForCurrentBook(_ rate: Float) {
        guard let bookID = currentBookID else {
            playbackSettings.spokenWordPlaybackRate = SpokenWordPlaybackRatePolicy.clamped(rate)
            return
        }
        setSpokenWordRate(rate, forBookID: bookID)
    }

    /// Sets (or with nil, forgets) one book's speed — the book page's speed
    /// control. Re-applies the engine rate when that book is playing.
    func setSpokenWordRate(_ rate: Float?, forBookID bookID: String) {
        let stored = rate.flatMap {
            SpokenWordPlaybackRatePolicy.storedBookRate(
                for: $0,
                globalSpokenWordRate: playbackSettings.spokenWordPlaybackRate
            )
        }
        SpokenWordStore.shared.setPlaybackRate(stored, forBookID: bookID)
        guard currentBookID == bookID else { return }
        applyPlaybackRate()
        updateNowPlayingInfo()
    }

    // MARK: - Moving between a book's items

    /// 「上一集」(快退键的长按菜单): 点的就是上一集, 直接过去。以前在这一集里放过
    /// 3 秒就先回到这一集开头, 菜单上写着上一集却从头重播(#349)。
    func skipToPreviousBookItem() {
        moveWithinBook(by: -1)
    }

    /// Long-press "next chapter" for a book without chapter marks.
    func skipToNextBookItem() {
        moveWithinBook(by: 1)
    }

    /// Whether the book has an item before / after the current one.
    var hasPreviousBookItem: Bool { adjacentBookQueueIndex(offset: -1) != nil }
    var hasNextBookItem: Bool { adjacentBookQueueIndex(offset: 1) != nil }

    private func adjacentBookQueueIndex(offset: Int) -> Int? {
        guard let song = currentSong else { return nil }
        // 播客单集不按节目划成书:队列里挨着的单集就是上一集 / 下一集,哪档节目都行。
        if PodcastPlaybackSong.isEpisode(song) {
            let index = queueEntries.indices.contains(currentIndex) && queueEntries[currentIndex].song.id == song.id
                ? currentIndex
                : queueEntries.firstIndex { $0.song.id == song.id }
            guard let index else { return nil }
            return PodcastQueueNavigationPolicy.adjacentEpisodeIndex(
                currentIndex: index,
                offset: offset,
                count: queueEntries.count
            ) { PodcastPlaybackSong.isEpisode(self.queueEntries[$0].song) }
        }
        guard let targetID = SpokenWordBookNavigationPolicy.adjacentItemID(
                  from: song.id,
                  offset: offset,
                  in: currentBookItemIDs
              ) else { return nil }
        return queueEntries.firstIndex { $0.song.id == targetID }
    }

    /// Plays the neighbouring item from where it was left off: the resume
    /// is armed by the item change (`handleSpokenWordItemChange`), and an
    /// item with nothing stored starts at the beginning.
    private func moveWithinBook(by offset: Int) {
        guard let index = adjacentBookQueueIndex(offset: offset) else { return }
        rememberSpokenWordPosition(force: true)
        Task { await playFromQueue(at: index) }
    }

    // MARK: - Bookmarks

    /// Marks where the listener is, titled after the chapter when there is
    /// one. Returns false when a mark already sits within two seconds.
    @discardableResult
    func addSpokenWordBookmark() -> Bool {
        guard let song = currentSong, !isLiveRadio else { return false }
        let position = max(0, currentTime)
        let time = ChapterTimeFormatter.string(from: position)
        let title = currentChapter.map { "\($0.title) · \(time)" } ?? time
        let added = SpokenWordStore.shared.addBookmark(SpokenWordBookmark(
            songID: song.id,
            position: position,
            title: title
        ))
        if added { rememberSpokenWordPosition(force: true) }
        return added
    }

    func seekToSpokenWordBookmark(_ bookmark: SpokenWordBookmark) {
        guard currentSong?.id == bookmark.songID else { return }
        seek(to: bookmark.position, startPlaying: isPlaying ? true : nil)
        rememberSpokenWordPosition(force: true)
    }

    // MARK: - Sleep at chapter end

    /// Arms "stop at the end of this chapter" on the chapter under the play
    /// head. Replaces any other sleep timer.
    func scheduleSleepAtChapterEnd() {
        guard let song = currentSong, let index = currentChapterIndex else { return }
        // The last chapter ends with the item, and the end of an item already
        // has a stop path through every transition (plain, gapless,
        // crossfade). Reuse it rather than racing it.
        guard index < spokenWordChapters.count - 1 else {
            scheduleSleepAtTrackEnd()
            return
        }
        cancelSleep()
        sleepStopAfterChapter = SpokenWordChapterSleepLock(songID: song.id, chapterIndex: index)
    }

    /// Called on every clock tick while the lock is armed.
    func enforceChapterSleepLockIfNeeded() {
        guard let lock = sleepStopAfterChapter else { return }
        // A different item means the listener chose something else; the
        // lock belonged to the book they left.
        guard let song = currentSong, song.id == lock.songID else {
            sleepStopAfterChapter = nil
            return
        }
        guard SpokenWordChapterSleepPolicy.shouldStop(
            lockedChapterIndex: lock.chapterIndex,
            currentChapterIndex: currentChapterIndex
        ) else { return }
        sleepStopAfterChapter = nil
        plog("🎧 Sleep: chapter \(lock.chapterIndex + 1) ended, pausing")
        pause()
    }

    // MARK: - Remote commands

    /// Republishes the transport so the lock screen, CarPlay and headphones
    /// offer ±15/30s for spoken word and the ordinary track buttons for music.
    /// Which pair is live is decided in one place — the Now Playing
    /// availability projection — because iOS gives both the same two slots.
    func updateSpokenWordRemoteCommands() {
        applySpokenWordSkipIntervals(to: MPRemoteCommandCenter.shared())
        updateNowPlayingInfo()
    }

    /// The lock screen draws the interval it is given, so it follows the
    /// setting. Written only when it changed: each write is an XPC.
    private func applySpokenWordSkipIntervals(to center: MPRemoteCommandCenter) {
        let forward = NSNumber(value: spokenWordSkipForwardSeconds)
        let backward = NSNumber(value: spokenWordSkipBackwardSeconds)
        if center.skipForwardCommand.preferredIntervals != [forward] {
            center.skipForwardCommand.preferredIntervals = [forward]
        }
        if center.skipBackwardCommand.preferredIntervals != [backward] {
            center.skipBackwardCommand.preferredIntervals = [backward]
        }
    }

    func setupSpokenWordRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        applySpokenWordSkipIntervals(to: center)
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self, self.currentSong != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? TimeInterval(self.spokenWordSkipForwardSeconds)
            self.skipSpokenWord(by: interval)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, self.currentSong != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? TimeInterval(self.spokenWordSkipBackwardSeconds)
            self.skipSpokenWord(by: -interval)
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }

    // MARK: - Chapters

    /// Reads chapter marks out of the file that is playing. Only a local file
    /// is opened — for a streamed item the marks live in `moov`, which may sit
    /// behind the whole media data, and no chapter list is worth pulling a
    /// several-hundred-megabyte book over the network for.
    func loadChaptersIfNeeded(for song: Song, fileURL: URL?) {
        guard chapterLoadedSongID != song.id else { return }
        guard let fileURL, fileURL.isFileURL else { return }
        // Only long items are worth mapping a file for. Spoken word always
        // qualifies; a long mix or a live set can carry marks too.
        guard SpokenWordStore.shared.isSpokenWord(song)
            || song.duration >= Self.chapterLookupMinimumDuration else { return }
        // Chapters exist in ISO base-media files and in the ID3 tag of an MP3.
        // Anything else would be a whole-file read that finds nothing.
        let fileExtension = fileURL.pathExtension.lowercased()
        let readsID3 = fileExtension == "mp3"
        guard readsID3 || ["m4a", "m4b", "mp4", "m4v", "mov", "alac"].contains(fileExtension) else { return }
        // A podcast episode's ID3 chapters come through `PodcastChapterLoader`,
        // after the ones its feed declares.
        if readsID3, PodcastPlaybackSong.isEpisode(song) { return }
        chapterLoadedSongID = song.id
        chapterLoadTask?.cancel()
        let songID = song.id
        chapterLoadTask = Task { [weak self] in
            let chapters = await Task.detached(priority: .utility) { () -> [MediaChapter] in
                // Only the tag at the head of an MP3 is read.
                if readsID3 { return ID3ChapterParser.chapters(fileURL: fileURL) }
                // Mapped rather than read: only the pages holding `moov` and
                // the title samples are ever touched.
                guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                    return []
                }
                return ISOBaseMediaChapterParser.chapters(in: data)
            }.value
            guard !Task.isCancelled, let self, self.currentSong?.id == songID else { return }
            guard !chapters.isEmpty else { return }
            self.spokenWordChapters = chapters
            self.refreshCurrentChapter()
            plog("🎧 Chapters: \(chapters.count) marks in '\(song.title)'")
        }
    }

    func refreshCurrentChapter() {
        guard !spokenWordChapters.isEmpty else {
            if currentChapterIndex != nil { currentChapterIndex = nil }
            return
        }
        let index = spokenWordChapters.chapterIndex(at: currentTime)
        if index != currentChapterIndex { currentChapterIndex = index }
    }

    func seekToChapter(at index: Int) {
        guard spokenWordChapters.indices.contains(index) else { return }
        seek(to: spokenWordChapters[index].startTime, startPlaying: isPlaying ? true : nil)
        currentChapterIndex = index
        rememberSpokenWordPosition(force: true)
    }

    /// Goes back to the start of the current chapter first, like every
    /// audiobook player: a second press within the opening seconds moves to
    /// the previous mark.
    /// 两侧的「上一章」键照有声书的习惯: 这一章放过 3 秒先回到章首。长按菜单里点「上一章」
    /// 是明说要去上一章, 传 `restartingCurrentChapter: false` 直接过去(#349)。
    func seekToPreviousChapter(restartingCurrentChapter: Bool = true) {
        guard let index = currentChapterIndex else { return }
        let chapterStart = spokenWordChapters[index].startTime
        if restartingCurrentChapter, currentTime - chapterStart > 3 {
            seekToChapter(at: index)
        } else {
            seekToChapter(at: max(0, index - 1))
        }
    }

    func seekToNextChapter() {
        let next = (currentChapterIndex ?? -1) + 1
        guard spokenWordChapters.indices.contains(next) else { return }
        seekToChapter(at: next)
    }

    var currentChapter: MediaChapter? {
        guard let currentChapterIndex,
              spokenWordChapters.indices.contains(currentChapterIndex) else { return nil }
        return spokenWordChapters[currentChapterIndex]
    }

    var hasChapters: Bool { !spokenWordChapters.isEmpty }

    /// Below 20 minutes an item is not something chapters are written for, and
    /// the lookup would map a file for nothing on every track change.
    static let chapterLookupMinimumDuration: TimeInterval = 20 * 60
}

/// "Stop after this chapter", armed on one chapter of one item.
struct SpokenWordChapterSleepLock: Equatable {
    let songID: String
    let chapterIndex: Int
}
