import Foundation
import PrimuseKit

/// The music queue someone left to listen to a book or a station.
///
/// Music, radio and spoken word each keep their own "where was I". Radio has
/// no position and a book remembers itself per item (`SpokenWordStore`), so
/// only music needs a separate memory: opening a book installs the book as
/// the queue, and without this the album someone was halfway through would
/// be gone. It is a plain snapshot of the queue, persisted so the home page
/// can offer "back to music" after a relaunch too.
@MainActor
@Observable
final class MusicSessionMemoryStore {
    struct Memory: Codable, Equatable {
        var snapshot: PlaybackSessionSnapshot
        var title: String
        var subtitle: String?
        var coverRef: String?
        var songID: String
        var sourceID: String
        var savedAt: Date
    }

    static let shared = MusicSessionMemoryStore()

    private(set) var memory: Memory?

    private let defaults: UserDefaults
    private static let key = "primuse.listeningSpaces.musicMemory.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        memory = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Memory.self, from: $0) }
    }

    func save(_ memory: Memory) {
        self.memory = memory
        if let data = try? JSONEncoder().encode(memory) {
            defaults.set(data, forKey: Self.key)
        }
    }

    func clear() {
        guard memory != nil else { return }
        memory = nil
        defaults.removeObject(forKey: Self.key)
    }
}

extension AudioPlayerService {
    /// The space the current item belongs to, or nil when nothing is loaded.
    var currentListeningSpace: ListeningSpace? {
        guard let song = currentSong else { return nil }
        return listeningSpace(of: song)
    }

    func listeningSpace(of song: Song) -> ListeningSpace {
        if isRadioPlaybackSong(song) { return .radio }
        if SpokenWordStore.shared.isSpokenWord(song) { return .spokenWord }
        return .music
    }

    /// Radio plays a synthetic song standing in for the station.
    func isRadioPlaybackSong(_ song: Song) -> Bool {
        song.id.hasPrefix("radio:")
    }

    /// Called just before the current music item gives way to a book or a
    /// station: keeps the music queue so "back to music" can restore it.
    /// A medley is not a queue anyone wants back, and a music-to-music
    /// change needs no memory (the new queue simply is the music now).
    func rememberMusicSessionIfLeaving(from outgoing: Song?, to incoming: Song?) {
        guard let outgoing, let incoming,
              outgoing.id != incoming.id,
              listeningSpace(of: outgoing) == .music,
              listeningSpace(of: incoming) != .music,
              !isMedleyActive,
              outgoing.sourceID != AppleMusicLibraryService.systemSourceID else { return }
        // Installing a book's queue saves first, with the whole music queue;
        // the item change right after sees only the outgoing song and must
        // not overwrite that with a one-song queue.
        if let existing = MusicSessionMemoryStore.shared.memory,
           existing.songID == outgoing.id,
           Date().timeIntervalSince(existing.savedAt) < 10 {
            return
        }

        let queueIDs: [String]
        let index: Int
        if let position = queueEntries.firstIndex(where: { $0.song.id == outgoing.id }) {
            queueIDs = queueEntries.map(\.song.id)
            index = position
        } else {
            queueIDs = [outgoing.id]
            index = 0
        }
        let time = currentSong?.id == outgoing.id
            ? (isPlaying ? interpolatedTime() : currentTime)
            : currentTime
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: queueIDs,
            currentSongID: outgoing.id,
            currentIndex: index,
            currentTime: max(0, time.isFinite ? time : 0),
            duration: outgoing.duration,
            wasPlaying: false,
            shuffleEnabled: shuffleEnabled,
            shuffledIndices: shuffleEnabled ? shuffledIndices : [],
            shufflePosition: shuffleEnabled ? shufflePosition : 0,
            pendingNextShuffleIndices: nil,
            repeatMode: repeatMode,
            isAtTrackEnd: false
        )
        MusicSessionMemoryStore.shared.save(.init(
            snapshot: snapshot,
            title: outgoing.title,
            subtitle: outgoing.artistName,
            coverRef: outgoing.coverArtFileName,
            songID: outgoing.id,
            sourceID: outgoing.sourceID,
            savedAt: Date()
        ))
        plog("🎚️ Music memory kept: '\(outgoing.title)' queue=\(queueIDs.count) at \(Int(snapshot.currentTime))s")
    }

    /// A new music queue replaces whatever music was remembered.
    func forgetMusicSessionIfMusicStarts(_ incoming: Song?) {
        guard let incoming, listeningSpace(of: incoming) == .music else { return }
        MusicSessionMemoryStore.shared.clear()
    }

    /// Puts the remembered music queue back and plays it from where it was.
    /// - Returns: false when nothing is remembered or none of it is playable.
    @discardableResult
    func resumeMusicSession() async -> Bool {
        guard let memory = MusicSessionMemoryStore.shared.memory, let library else { return false }
        let snapshot = memory.snapshot
        var songs: [Song] = []
        var index = 0
        for (position, songID) in snapshot.queueSongIDs.enumerated() {
            guard let song = library.song(id: songID), song.isPlayable else { continue }
            if position == snapshot.currentIndex { index = songs.count }
            songs.append(song)
        }
        guard !songs.isEmpty else {
            MusicSessionMemoryStore.shared.clear()
            return false
        }
        let resumeAt = songs.indices.contains(index) && songs[index].id == snapshot.currentSongID
            ? snapshot.currentTime
            : 0
        repeatMode = snapshot.repeatMode
        shuffleEnabled = snapshot.shuffleEnabled
        await play(queue: songs, startingAt: index)
        MusicSessionMemoryStore.shared.clear()
        if resumeAt > 3 {
            seek(to: resumeAt, startPlaying: true)
        }
        return true
    }
}

/// "Stop at the end of the book": the book's items in the queue, and the one
/// that ends it.
struct SpokenWordBookSleepLock: Equatable {
    let songIDs: Set<String>
    let lastSongID: String
}

extension AudioPlayerService {
    /// Applies one of the sleep options `SleepTimerOptionPolicy` offers.
    func applySleepOption(_ option: SleepTimerOption) {
        switch option {
        case .minutes(let minutes): scheduleSleep(minutes: minutes)
        case .endOfTrack: scheduleSleepAtTrackEnd()
        case .endOfChapter: scheduleSleepAtChapterEnd()
        case .endOfBook: scheduleSleepAtBookEnd()
        }
    }

    /// Whether `option` is the one armed now. Timed options are shown by the
    /// countdown instead, so only the "end of" options answer here.
    func isSleepOptionArmed(_ option: SleepTimerOption) -> Bool {
        switch option {
        case .minutes: false
        case .endOfTrack: sleepStopAfterSongID != nil
        case .endOfChapter: sleepStopAfterChapter != nil
        case .endOfBook: sleepStopAfterBook != nil
        }
    }

    /// Arms "stop when this book ends". The book is its items in the queue
    /// (the queue a book installs is the book, in reading order); the last of
    /// them ends it. With nothing after the current item it is the same as
    /// stopping at the end of the item.
    func scheduleSleepAtBookEnd() {
        guard let song = currentSong, listeningSpace(of: song) == .spokenWord else { return }
        let itemIDs = currentBookItemIDs
        guard let lastID = itemIDs.last, lastID != song.id else {
            scheduleSleepAtTrackEnd()
            return
        }
        cancelSleep()
        sleepStopAfterBook = SpokenWordBookSleepLock(songIDs: Set(itemIDs), lastSongID: lastID)
        plog("🌙 Sleep armed for the end of the book: \(itemIDs.count) items")
    }

    /// Called on every item change. Leaving the book drops the lock; reaching
    /// its last item hands over to the end-of-track lock, which already has a
    /// stop path through every kind of transition.
    func advanceBookSleepLockIfNeeded() {
        guard let lock = sleepStopAfterBook else { return }
        guard let song = currentSong, lock.songIDs.contains(song.id) else {
            sleepStopAfterBook = nil
            return
        }
        if song.id == lock.lastSongID {
            sleepStopAfterBook = nil
            sleepStopAfterSongID = song.id
        }
    }
}

extension AudioPlayerService {
    /// "Back to music" offered as a book ends: the music someone left is
    /// queued after the book, from the song they were on, so the book's last
    /// chapter plays out and the music follows on its own.
    /// - Returns: false when nothing is remembered or none of it is playable.
    @discardableResult
    func queueRememberedMusicAfterCurrent() -> Bool {
        guard let memory = MusicSessionMemoryStore.shared.memory, let library else { return false }
        let snapshot = memory.snapshot
        let songs = snapshot.queueSongIDs
            .dropFirst(max(0, snapshot.currentIndex))
            .compactMap { library.song(id: $0) }
            .filter(\.isPlayable)
        MusicSessionMemoryStore.shared.clear()
        guard !songs.isEmpty else { return false }
        appendToQueue(songs)
        plog("🎚️ Music memory queued after the book: \(songs.count) songs")
        return true
    }
}
