import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// One recent music queue. The UI keeps its lightweight snapshot in memory;
/// encoding and atomic file replacement run off the main actor only at queue
/// boundaries and lifecycle saves, not on every playback-clock update.
@MainActor
@Observable
final class MusicSessionMemoryStore {
    struct Memory: Codable, Equatable, Sendable {
        var snapshot: PlaybackSessionSnapshot
        var title: String
        var subtitle: String?
        var coverRef: String?
        var songID: String
        var sourceID: String
        var savedAt: Date
        var continuation: QueueContinuation? = nil
    }

    static let shared = MusicSessionMemoryStore()
    private(set) var memory: Memory?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let url: URL
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingWrite: Memory?
    @ObservationIgnored private var hasPendingWrite = false
    private static let key = "primuse.listeningSpaces.musicMemory.v1"
    #if os(iOS)
    @ObservationIgnored private var backgroundWrite: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(defaults: UserDefaults = .standard, url: URL? = nil) {
        self.defaults = defaults
        let url = url ?? PlaybackSessionStore().url.deletingLastPathComponent()
            .appendingPathComponent("recent-music-queue.json")
        self.url = url
        let legacy = defaults.data(forKey: Self.key)
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                let data = (try? Data(contentsOf: url)) ?? legacy
                return data.flatMap { try? JSONDecoder().decode(Memory.self, from: $0) }
            }.value
            guard let self, self.revision == 0 else { return }
            self.memory = loaded
            if legacy != nil, let loaded { self.save(loaded) }
        }
    }

    func save(_ memory: Memory, persist: Bool = true) {
        revision &+= 1
        self.memory = memory
        if persist { enqueueWrite(memory) }
    }

    func clear() {
        revision &+= 1
        memory = nil
        enqueueWrite(nil)
    }

    private func enqueueWrite(_ memory: Memory?) {
        pendingWrite = memory
        hasPendingWrite = true
        guard writeTask == nil else { return }
        #if os(iOS)
        backgroundWrite = UIApplication.shared.beginBackgroundTask(withName: "Recent music queue") { [weak self] in
            Task { @MainActor in self?.endBackgroundWrite() }
        }
        #endif
        // There is at most one in-flight write and one latest pending value.
        writeTask = Task { [weak self] in
            guard let self else { return }
            while self.hasPendingWrite {
                let value = self.pendingWrite
                self.pendingWrite = nil
                self.hasPendingWrite = false
                let url = self.url
                let succeeded = await Task.detached(priority: .utility) {
                    do {
                        if let value {
                            try FileManager.default.createDirectory(
                                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                            )
                            try JSONEncoder().encode(value).write(to: url, options: .atomic)
                        } else if FileManager.default.fileExists(atPath: url.path) {
                            try FileManager.default.removeItem(at: url)
                        }
                        return true
                    } catch {
                        plog("Music queue memory save failed: \(error.localizedDescription)")
                        return false
                    }
                }.value
                if succeeded { self.defaults.removeObject(forKey: Self.key) }
            }
            self.writeTask = nil
            #if os(iOS)
            self.endBackgroundWrite()
            #endif
        }
    }

    #if os(iOS)
    private func endBackgroundWrite() {
        guard backgroundWrite != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundWrite)
        backgroundWrite = .invalid
    }
    #endif

    func waitForPendingPersistence() async {
        await loadTask?.value
        while let writeTask { await writeTask.value }
    }
}

/// Which space holds the queue and the music shuffle/repeat parked while a
/// book does (`ListeningPlayModeLedger`). Persisted beside the playback
/// session, whose switches it explains after a relaunch.
@MainActor
final class ListeningPlayModeStore {
    static let shared = ListeningPlayModeStore()

    private(set) var ledger: ListeningPlayModeLedger

    private let defaults: UserDefaults
    private static let key = "primuse.listeningSpaces.playModes.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ledger = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ListeningPlayModeLedger.self, from: $0) }
            ?? ListeningPlayModeLedger()
    }

    @discardableResult
    func update<Result>(_ change: (inout ListeningPlayModeLedger) -> Result) -> Result {
        var next = ledger
        let result = change(&next)
        if next != ledger {
            ledger = next
            if let data = try? JSONEncoder().encode(next) {
                defaults.set(data, forKey: Self.key)
            }
        }
        return result
    }
}

extension AudioPlayerService {
    /// Gives a newly installed queue its space's shuffle and repeat: a book
    /// starts in reading order, and music replacing a book gets back what it
    /// had. Called with the new queue in place, before its shuffle order is
    /// built.
    func applyListeningPlayMode(forQueueStartingWith song: Song) {
        let current = ListeningPlayMode(shuffleEnabled: shuffleEnabled, repeatMode: repeatMode, eachTrackStop: eachTrackStop)
        let space = listeningSpace(of: song)
        guard let mode = ListeningPlayModeStore.shared.update({
            $0.queueInstalled(ownedBy: space, current: current)
        }) else { return }
        isApplyingListeningPlayMode = true
        defer { isApplyingListeningPlayMode = false }
        repeatBehavior = RepeatBehavior(repeatMode: mode.repeatMode, eachTrackStop: mode.eachTrackStop)
        shuffleEnabled = mode.shuffleEnabled
        plog("🎚️ Play mode for \(space.rawValue): shuffle=\(mode.shuffleEnabled) repeat=\(repeatBehavior.rawValue)")
    }

    /// The space the current item belongs to, or nil when nothing is loaded.
    var currentListeningSpace: ListeningSpace? {
        guard let song = currentSong else { return nil }
        return listeningSpace(of: song)
    }

    func listeningSpace(of song: Song) -> ListeningSpace {
        if isRadioPlaybackSong(song) { return .radio }
        if PodcastPlaybackSong.isEpisode(song) { return .podcast }
        switch SpokenWordStore.shared.kind(for: song) {
        case .podcast: return .podcast
        case .spokenWord: return .spokenWord
        case .ambient: return .ambient
        case .music: return .music
        }
    }

    /// Radio plays a synthetic song standing in for the station.
    func isRadioPlaybackSong(_ song: Song) -> Bool {
        song.id.hasPrefix(RadioStation.playbackSongIDPrefix)
    }

    func updateRecentMusicQueue(snapshot: PlaybackSessionSnapshot, song: Song, persist: Bool = false) {
        guard remembersMusicQueue, !isMedleyActive,
              listeningSpace(of: song) == .music,
              queueEntries.indices.contains(currentIndex),
              queueEntries[currentIndex].song.id == song.id else { return }
        musicSessionMemoryStore.save(.init(
            snapshot: snapshot, title: song.title, subtitle: song.artistName,
            coverRef: song.coverArtFileName, songID: song.id, sourceID: song.sourceID,
            savedAt: Date(), continuation: queueContinuation
        ), persist: persist || musicMemoryNeedsPersistence)
        musicMemoryNeedsPersistence = false
    }

    /// Capture before replacing either the window or its continuation. A
    /// single-song request and its automatic recommendations never own this slot.
    func rememberCurrentMusicQueue(outgoing: Song? = nil) {
        guard remembersMusicQueue, let song = outgoing ?? currentSong,
              queueEntries.indices.contains(currentIndex),
              queueEntries[currentIndex].song.id == song.id else { return }
        let time = isPlaying ? interpolatedTime() : currentTime
        let snapshot = PlaybackSessionSnapshot(
            queueSongIDs: queueEntries.map(\.song.id), currentSongID: song.id,
            currentIndex: currentIndex, currentTime: max(0, time.isFinite ? time : 0),
            duration: song.duration, wasPlaying: false, shuffleEnabled: shuffleEnabled,
            shuffledIndices: shuffleEnabled ? shuffledIndices : [],
            shufflePosition: shuffleEnabled ? (shuffleAnchorPosition ?? shufflePosition) : 0,
            pendingNextShuffleIndices: pendingNextShuffleIndices, repeatMode: repeatMode,
            isAtTrackEnd: isAtTrackEnd, queueContinuationToken: queueContinuation?.token,
            eachTrackStop: eachTrackStop, remembersMusicQueue: true
        )
        updateRecentMusicQueue(snapshot: snapshot, song: song, persist: true)
    }

    func prepareRecentMusicQueueForDirectPlayback(_ song: Song) {
        guard remembersMusicQueue,
              !queueEntries.indices.contains(currentIndex)
                || queueEntries[currentIndex].song.id != song.id else { return }
        rememberCurrentMusicQueue()
        remembersMusicQueue = false
    }

    func rememberMusicSessionIfLeaving(from outgoing: Song?, to incoming: Song?) {
        guard let outgoing, let incoming,
              listeningSpace(of: outgoing) == .music,
              listeningSpace(of: incoming) != .music else { return }
        rememberCurrentMusicQueue(outgoing: outgoing)
        remembersMusicQueue = false
    }

    /// Only the installed window is resolved for a card; a large request's
    /// remaining IDs are resolved when playback actually needs another window.
    var rememberedMusicSessionPlayableCount: Int {
        guard let memory = musicSessionMemoryStore.memory, let library else { return 0 }
        return memory.snapshot.queueSongIDs.reduce(0) { count, songID in
            library.visibleSong(id: songID)?.isPlayable == true ? count + 1 : count
        }
    }

    var hasPlayableRememberedMusicSession: Bool {
        guard let memory = musicSessionMemoryStore.memory, let library else { return false }
        return memory.snapshot.queueSongIDs.contains {
            library.visibleSong(id: $0)?.isPlayable == true
        }
    }

    /// 「接着上次」放停在那儿的音乐队列:当前这首的源还开着就接着放,
    /// 停用了就从它后面第一首源还开着的歌起播。
    /// - Returns: false when nothing is loaded, it is already playing, or every song's source is disabled.
    @discardableResult
    func resumeStoppedMusicQueue() async -> Bool {
        guard currentSong != nil, !isPlaying, queueEntries.indices.contains(currentIndex) else { return false }
        if isSourceEnabledForPlayback(queueEntries[currentIndex].song.sourceID) {
            resume()
            return true
        }
        let entries = queueEntries
        guard let enabledIndex = QueueTraversalPolicy.nextAvailableIndex(
            queueCount: entries.count,
            after: currentIndex,
            wraps: true,
            isAvailable: { isSourceEnabledForPlayback(entries[$0].song.sourceID) }
        ) else {
            showPlaybackError(String(localized: "playback_error_source_disabled"))
            return false
        }
        await playFromQueue(at: enabledIndex)
        return true
    }

    /// Restores the saved occurrences and shuffle traversal without rebuilding
    /// their order. Preparation cannot overwrite a newer transport request.
    @discardableResult
    func resumeMusicSession(startPlayback: Bool = true) async -> Bool {
        guard let memory = musicSessionMemoryStore.memory, let library else { return false }
        if remembersMusicQueue, currentListeningSpace == .music,
           queueEntries.indices.contains(currentIndex),
           queueEntries[currentIndex].song.id == currentSong?.id {
            if startPlayback, !isPlaying { return await resumeStoppedMusicQueue() }
            return true
        }
        let requestToken = queueRequestToken
        let advanceGeneration = playbackAdvancePolicy.generation
        let lookup = library.historySongLookup()
        let disabledSourceIDs = library.disabledSourceIDs
        let prepared = await Task.detached(priority: .userInitiated) { () -> (PlaybackSessionRestorationPlan, [Song], QueueContinuation?)? in
            let restored = QueueWindowPolicy.restoring(memory.snapshot, savedContinuation: memory.continuation)
            var snapshot = restored.snapshot
            let byID = Dictionary(snapshot.queueSongIDs.compactMap { id -> (String, Song)? in
                guard let song = lookup.song(id: id), song.isPlayable else { return nil }
                return (id, song)
            }, uniquingKeysWith: { first, _ in first })
            let canStart: (Int) -> Bool = { index in
                guard snapshot.queueSongIDs.indices.contains(index),
                      let song = byID[snapshot.queueSongIDs[index]] else { return false }
                return !disabledSourceIDs.contains(song.sourceID)
            }
            if !canStart(snapshot.currentIndex) {
                guard let index = QueueTraversalPolicy.nextAvailableIndex(
                    queueCount: snapshot.queueSongIDs.count, after: snapshot.currentIndex,
                    wraps: true, isAvailable: canStart
                ) else { return nil }
                snapshot.currentIndex = index
                snapshot.currentSongID = snapshot.queueSongIDs[index]
                snapshot.currentTime = 0
                snapshot.shufflePosition = snapshot.shuffledIndices.firstIndex(of: index) ?? 0
            }
            guard let plan = PlaybackSessionRestorationPolicy.plan(
                snapshot: snapshot, availableSongIDs: Set(byID.keys)
            ) else { return nil }
            return (plan, plan.queueSongIDs.compactMap { byID[$0] }, restored.continuation)
        }.value
        guard queueRequestToken == requestToken,
              playbackAdvancePolicy.generation == advanceGeneration else { return false }
        guard let (plan, songs, continuation) = prepared else {
            showPlaybackError(String(localized: "playback_error_source_disabled"))
            return false
        }
        stop()
        isRestoringPlaybackSession = true
        setQueue(songs, startAt: plan.currentIndex, keepsContinuation: true)
        setQueueContinuation(continuation)
        repeatBehavior = RepeatBehavior(repeatMode: plan.repeatMode, eachTrackStop: plan.eachTrackStop)
        shuffleEnabled = plan.shuffleEnabled
        shuffledIndices = plan.shuffledIndices
        shufflePosition = plan.shufflePosition
        pendingNextShuffleIndices = plan.pendingNextShuffleIndices
        remembersMusicQueue = true
        musicMemoryNeedsPersistence = true
        stagePausedHandoff(song: songs[plan.currentIndex], at: plan.currentTime)
        isRestoringPlaybackSession = false
        persistPlaybackSession()
        if startPlayback { resume() }
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
        case .endOfTrack: sleepStopAfterSongID != nil && selectedChapterSleep == nil
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
        guard let memory = musicSessionMemoryStore.memory, let library else { return false }
        let snapshot = memory.snapshot
        let songs = snapshot.queueSongIDs
            .dropFirst(max(0, snapshot.currentIndex))
            .compactMap { library.song(id: $0) }
            .filter(\.isPlayable)
        guard !songs.isEmpty else { return false }
        appendToQueue(songs)
        plog("🎚️ Music memory queued after the book: \(songs.count) songs")
        return true
    }
}
