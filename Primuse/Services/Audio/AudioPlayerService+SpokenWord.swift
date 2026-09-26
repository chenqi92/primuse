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
        spokenWordChapters = []
        currentChapterIndex = nil
        chapterLoadedSongID = nil
        lastSpokenWordPositionSave = 0
        pendingSpokenWordResumeSongID = nil

        let wasSpokenWord = currentItemIsSpokenWord
        defer {
            // Spoken word runs at its own speed; switching between a book and a
            // song switches the rate with it.
            if wasSpokenWord != currentItemIsSpokenWord { applyPlaybackRate() }
        }
        guard let song else {
            currentItemIsSpokenWord = false
            updateSpokenWordRemoteCommands()
            return
        }
        currentItemIsSpokenWord = SpokenWordStore.shared.isSpokenWord(song)
        updateSpokenWordRemoteCommands()
        guard currentItemIsSpokenWord else { return }
        // Arm the resume even when nothing is stored: the seek is skipped, but
        // the flag also tells the position writer to ignore the opening zeroes.
        if SpokenWordStore.shared.resumePosition(for: song) != nil {
            pendingSpokenWordResumeSongID = song.id
        }
    }

    /// Seeks to the remembered position once audio is actually running.
    ///
    /// The decoder is built at zero by every playback path, and only a seek
    /// rebuilds it elsewhere, so the jump happens on the first clock tick
    /// rather than before playback starts. The guard on `currentTime` keeps a
    /// later tick — or the listener scrubbing away immediately — from pulling
    /// the play head back.
    func applyPendingSpokenWordResumeIfNeeded() {
        guard let songID = pendingSpokenWordResumeSongID,
              let song = currentSong,
              song.id == songID else { return }
        guard isPlaying, currentTime < 2 else {
            if currentTime >= 2 { pendingSpokenWordResumeSongID = nil }
            return
        }
        guard let target = SpokenWordStore.shared.resumePosition(for: song) else {
            pendingSpokenWordResumeSongID = nil
            return
        }
        pendingSpokenWordResumeSongID = nil
        plog("🎧 Spoken word: resuming '\(song.title)' at \(Int(target))s")
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
        let position = currentTime
        guard position.isFinite else { return }
        if !force {
            let elapsed = position - lastSpokenWordPositionSave
            guard abs(elapsed) >= SpokenWordProgressPolicy.autosaveInterval else { return }
        }
        lastSpokenWordPositionSave = position
        SpokenWordStore.shared.rememberPosition(
            position,
            duration: duration > 0 ? duration : song.duration,
            forSongID: song.id
        )
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

    // MARK: - Playback rate

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
            rateAllowed: playbackSettings.outputMode == .effects
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
            rateAllowed: playbackSettings.outputMode == .effects
        )
    }

    // MARK: - Books

    /// The book `song` belongs to — the same id the bookshelf gives it
    /// (`SpokenWordBook.id`), so a per-book setting is found from the item
    /// that is playing. The library groups books once per change; an item it
    /// does not hold falls back to what its own tags and path say.
    func spokenWordBookID(for song: Song) -> String {
        if let bookID = library?.spokenWordBookIDs[song.id] { return bookID }
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
    var currentBookItemIDs: [String] {
        guard let bookID = currentBookID else { return [] }
        return queueEntries.compactMap { entry in
            let song = entry.song
            guard spokenWordBookID(for: song) == bookID,
                  SpokenWordStore.shared.isSpokenWord(song) else { return nil }
            return song.id
        }
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
        if let book = currentBookForWidgets(song) {
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
    private func currentBookForWidgets(_ song: Song) -> SpokenWordBook? {
        guard let library else { return nil }
        let bookID = spokenWordBookID(for: song)
        let members = library.spokenWordSongs.filter { library.spokenWordBookIDs[$0.id] == bookID }
        guard !members.isEmpty else { return nil }
        let store = SpokenWordStore.shared
        let books = SpokenWordBookGrouping.books(
            from: members.map { SpokenWordBookSupport.item(for: $0, store: store) }
        )
        return books.first { book in book.items.contains { $0.id == song.id } }
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

    /// Long-press "previous chapter" for a book without chapter marks: back
    /// to the start of the item first, then to the previous item. Books with
    /// marks use `seekToPreviousChapter()`.
    func skipToPreviousBookItem() {
        if SpokenWordBookNavigationPolicy.previousRestartsCurrentItem(currentTime: currentTime) {
            seek(to: 0, startPlaying: isPlaying ? true : nil)
            rememberSpokenWordPosition(force: true)
            return
        }
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
        guard let song = currentSong,
              let targetID = SpokenWordBookNavigationPolicy.adjacentItemID(
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
        // Chapters exist in ISO base-media files. Anything else would be a
        // whole-file read that finds nothing.
        let fileExtension = fileURL.pathExtension.lowercased()
        guard ["m4a", "m4b", "mp4", "m4v", "mov", "alac"].contains(fileExtension) else { return }
        chapterLoadedSongID = song.id
        chapterLoadTask?.cancel()
        let songID = song.id
        chapterLoadTask = Task { [weak self] in
            let chapters = await Task.detached(priority: .utility) { () -> [MediaChapter] in
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
    func seekToPreviousChapter() {
        guard let index = currentChapterIndex else { return }
        let chapterStart = spokenWordChapters[index].startTime
        if currentTime - chapterStart > 3 {
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
