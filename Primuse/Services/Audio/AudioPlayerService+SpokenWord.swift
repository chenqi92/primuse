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
        skipSpokenWord(by: SpokenWordSkipPolicy.forwardInterval)
    }

    func skipSpokenWordBackward() {
        skipSpokenWord(by: -SpokenWordSkipPolicy.backwardInterval)
    }

    // MARK: - Remote commands

    /// Republishes the transport so the lock screen, CarPlay and headphones
    /// offer ±15/30s for spoken word and the ordinary track buttons for music.
    /// Which pair is live is decided in one place — the Now Playing
    /// availability projection — because iOS gives both the same two slots.
    func updateSpokenWordRemoteCommands() {
        updateNowPlayingInfo()
    }

    func setupSpokenWordRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: SpokenWordSkipPolicy.forwardInterval)
        ]
        center.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: SpokenWordSkipPolicy.backwardInterval)
        ]
        center.skipForwardCommand.addTarget { [weak self] event in
            guard let self, self.currentSong != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? SpokenWordSkipPolicy.forwardInterval
            self.skipSpokenWord(by: interval)
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] event in
            guard let self, self.currentSong != nil else {
                return .noActionableNowPlayingItem
            }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? SpokenWordSkipPolicy.backwardInterval
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
