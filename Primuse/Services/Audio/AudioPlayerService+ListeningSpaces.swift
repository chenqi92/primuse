import Foundation
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// The music queue the listener last left. The active queue has its own playback session.
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
        /// 只在存盘的那份里有:单独存的续接的令牌(读回时对上才接回来,随即清掉)。
        var storedContinuationToken: String? = nil

        /// 这张队列请求的整张 id(续接在映射文件里时不读成数组)。
        var requestedSongs: QueueRequestedSongs {
            continuation.map(QueueRequestedSongs.continuation) ?? .ids(snapshot.queueSongIDs)
        }
    }

    static let shared = MusicSessionMemoryStore()
    private(set) var memory: Memory? {
        didSet { prepareStartupWindow() }
    }
    private(set) var startupPlayableCounts: [String: Int]?
    @ObservationIgnored private weak var startupLibrary: MusicLibrary?
    @ObservationIgnored private(set) var startupRead: Task<[String: Song]?, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let url: URL
    /// 续接单独存(`QueueContinuationStore`:整库请求的 id 在映射文件里),不嵌进上面那份 JSON。
    @ObservationIgnored private let continuationURL: URL
    @ObservationIgnored private var revision = 0
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var activeQueueWhileLoading: QueueRequestedSongs?
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
        let continuationURL = url.deletingPathExtension().appendingPathExtension("continuation.json")
        self.continuationURL = continuationURL
        let legacy = defaults.data(forKey: Self.key)
        loadTask = Task { [weak self] in
            let read = await Task.detached(priority: .utility) { () -> (memory: Memory, embedded: Bool)? in
                let data = (try? Data(contentsOf: url)) ?? legacy
                guard var memory = data.flatMap({ try? JSONDecoder().decode(Memory.self, from: $0) }) else { return nil }
                // 旧版把续接整张嵌在 JSON 里;新版单独存,按令牌对上才接回来。
                let embedded = memory.continuation != nil
                if !embedded, let token = memory.storedContinuationToken,
                   let stored = QueueContinuationStore(url: continuationURL).load(), stored.token == token {
                    memory.continuation = stored
                }
                memory.storedContinuationToken = nil
                return (memory, embedded)
            }.value
            guard let self else { return }
            defer {
                self.loadTask = nil
                self.activeQueueWhileLoading = nil
            }
            guard self.revision == 0, let read else { return }
            let loaded = read.memory
            if loaded.requestedSongs == self.activeQueueWhileLoading {
                self.clear()
                return
            }
            self.memory = loaded
            // 旧格式(存在偏好设置里,或续接嵌在 JSON 里)按新格式重存一次。
            if legacy != nil || read.embedded { self.save(loaded) }
        }
    }

    func save(_ memory: Memory) {
        revision &+= 1
        self.memory = memory
        enqueueWrite(memory)
    }

    func bindStartupLibrary(_ library: MusicLibrary?) {
        startupLibrary = library
        prepareStartupWindow()
        guard let library, !library.isReady else { return }
        library.onReady { [weak self, weak library] in
            if self?.startupLibrary === library { self?.prepareStartupWindow() }
        }
    }

    /// Until the saved window is resolved, the installed queue is only a possible fallback.
    var isPreparingResumeTarget: Bool {
        guard memory != nil else { return revision == 0 && loadTask != nil }
        return startupLibrary?.isReady == false && startupPlayableCounts == nil
    }

    func waitForStartupResumeTarget() async {
        if memory == nil { await loadTask?.value }
        _ = await startupRead?.value
    }

    private func prepareStartupWindow() {
        startupRead?.cancel()
        startupRead = nil
        startupPlayableCounts = nil
        guard let library = startupLibrary, !library.isReady, let memory else { return }
        startupRead = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) {
                QueueWindowPolicy.restoring(memory.snapshot, savedContinuation: memory.continuation).snapshot.queueSongIDs
            }.value
            guard !Task.isCancelled, let rows = await library.prepareStartupSavedQueue(ids: ids),
                  !Task.isCancelled else { return nil }
            var counts: [String: Int] = [:]
            for id in ids {
                if let song = rows[id] { counts[song.sourceID, default: 0] += 1 }
            }
            self?.startupPlayableCounts = counts
            return rows
        }
    }

    /// Older versions also saved the active queue here. It can arrive from disk
    /// before or after the player has installed the current playback session.
    func excludeActiveQueue(_ requested: QueueRequestedSongs) {
        if loadTask != nil { activeQueueWhileLoading = requested }
        if memory?.requestedSongs == requested { clear() }
    }

    func excludeActiveQueue(_ songIDs: [String]) {
        excludeActiveQueue(.ids(songIDs))
    }

    func clear() {
        revision &+= 1
        memory = nil
        enqueueWrite(nil)
    }

    /// Removes deleted songs from the remembered music queue (including its continuation).
    /// Clears the saved memory if no surviving songs remain.
    func removeSongs(withIDs songIDs: Set<String>, resolveSong: (String) -> Song? = { _ in nil }) {
        guard !songIDs.isEmpty, var current = memory else { return }
        let previousContinuation = current.continuation
        if var continuation = current.continuation {
            continuation.removeSongs(withIDs: songIDs)
            current.continuation = (continuation.isExhausted || continuation.requestedCount == 0) ? nil : continuation
        }
        let currentSongID = current.snapshot.currentSongID.isEmpty ? current.songID : current.snapshot.currentSongID
        let plan = QueueBatchRemovalPolicy.plan(
            queueSongIDs: current.snapshot.queueSongIDs,
            currentIndex: current.snapshot.currentIndex,
            currentSongID: currentSongID,
            removingSongIDs: songIDs
        )
        if plan.action == .unchanged {
            if current.continuation != previousContinuation {
                current.snapshot.queueContinuationToken = current.continuation?.token
                save(current)
            }
            return
        }

        var retainedIDs = plan.retainedIndices.map { current.snapshot.queueSongIDs[$0] }
        var startIndex: Int
        var replacedCurrent: Bool
        switch plan.action {
        case .unchanged:
            return
        case .replaceQueue(let index):
            startIndex = index
            replacedCurrent = false
        case .playReplacement(let index):
            startIndex = index
            replacedCurrent = true
        case .stopAndClearQueue:
            startIndex = 0
            replacedCurrent = true
        }

        if retainedIDs.isEmpty, var continuation = current.continuation {
            var pulled: [String] = []
            while pulled.count < QueueWindowPolicy.refillBatch {
                let batch = continuation.takeNext(
                    maxCount: QueueWindowPolicy.refillBatch,
                    repeatsAll: current.snapshot.repeatMode == .all
                )
                if batch.isEmpty { break }
                pulled.append(contentsOf: batch.filter { !songIDs.contains($0) })
            }
            current.continuation = (continuation.isExhausted || continuation.requestedCount == 0) ? nil : continuation
            retainedIDs = pulled
            startIndex = 0
            replacedCurrent = true
        }

        guard !retainedIDs.isEmpty else {
            clear()
            return
        }

        let boundedIndex = min(max(0, startIndex), retainedIDs.count - 1)
        current.snapshot.queueSongIDs = retainedIDs
        current.snapshot.currentIndex = boundedIndex
        current.snapshot.shuffledIndices = []
        current.snapshot.shufflePosition = 0
        current.snapshot.pendingNextShuffleIndices = nil
        current.snapshot.queueContinuationToken = current.continuation?.token
        if replacedCurrent {
            let nextID = retainedIDs[boundedIndex]
            current.snapshot.currentSongID = nextID
            current.snapshot.currentTime = 0
            current.snapshot.isAtTrackEnd = false
            current.songID = nextID
            if let song = resolveSong(nextID) {
                current.title = song.title
                current.subtitle = song.artistName
                current.coverRef = song.coverArtFileName
                current.sourceID = song.sourceID
                current.snapshot.duration = song.duration
            }
        }
        save(current)
    }

    /// Sweeps songs that no longer exist in `library` after an authoritative full-scan prune.
    func pruneStaleSongs(forSourceIDs sourceIDs: Set<String>, library: MusicLibrary) {
        guard !sourceIDs.isEmpty, library.isReady, let current = memory else { return }
        if current.sourceID == AppleMusicLibraryIdentity.sourceID,
           !sourceIDs.contains(AppleMusicLibraryIdentity.sourceID) {
            return
        }
        var candidates = Set(current.snapshot.queueSongIDs)
        if !current.snapshot.currentSongID.isEmpty {
            candidates.insert(current.snapshot.currentSongID)
        }
        if !current.songID.isEmpty {
            candidates.insert(current.songID)
        }
        func isStale(_ id: String) -> Bool {
            guard !id.hasPrefix(RadioStation.playbackSongIDPrefix),
                  !PodcastIdentity.isEpisodeID(id) else {
                return false
            }
            return library.storedSong(id: id) == nil
        }
        var stale = candidates.filter(isStale)
        // 续接欠着的(整库请求时在映射文件里)逐条看,不先并成一个整库的集合。
        if let continuation = current.continuation {
            for id in continuation.requestedIDList where !candidates.contains(id) && !stale.contains(id) && isStale(id) {
                stale.insert(id)
            }
        }
        guard !stale.isEmpty else { return }
        removeSongs(withIDs: stale, resolveSong: { library.storedSong(id: $0) })
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
                let continuationStore = QueueContinuationStore(url: self.continuationURL)
                let succeeded = await Task.detached(priority: .utility) {
                    do {
                        if let value {
                            try FileManager.default.createDirectory(
                                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                            )
                            // 续接先存(id 列表没变时只重写小状态文件),JSON 里只留它的令牌。
                            continuationStore.save(value.continuation)
                            var plain = value
                            plain.continuation = nil
                            plain.storedContinuationToken = value.continuation?.token
                            try JSONEncoder().encode(plain).write(to: url, options: .atomic)
                        } else {
                            continuationStore.save(nil)
                            if FileManager.default.fileExists(atPath: url.path) {
                                try FileManager.default.removeItem(at: url)
                            }
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

    /// Capture before replacing either the window or its continuation. A
    /// single-song request and its automatic recommendations never own this slot.
    /// 眼前这条队列的整张请求:有续接就是续接那张(整库请求时在映射文件里),否则是装着的这些歌。
    var activeQueueRequest: QueueRequestedSongs {
        queueContinuation.map(QueueRequestedSongs.continuation) ?? .ids(queueEntries.map(\.song.id))
    }

    func rememberCurrentMusicQueue(outgoing: Song? = nil) {
        guard remembersMusicQueue, let song = outgoing ?? currentSong,
              listeningSpace(of: song) == .music,
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
            eachTrackStop: eachTrackStop, remembersMusicQueue: true, queueIdentity: queueIdentity
        )
        musicSessionMemoryStore.save(.init(
            snapshot: snapshot, title: song.title, subtitle: song.artistName,
            coverRef: song.coverArtFileName, songID: song.id, sourceID: song.sourceID,
            savedAt: Date(), continuation: queueContinuation
        ))
    }

    func prepareRecentMusicQueueForDirectPlayback(_ song: Song) {
        guard remembersMusicQueue else { return }
        if queueEntries.indices.contains(currentIndex), queueEntries[currentIndex].song.id == song.id {
            // Stop can leave its queue installed with no current song.
            if currentSong == nil {
                musicSessionMemoryStore.excludeActiveQueue(activeQueueRequest)
            }
            return
        }
        rememberCurrentMusicQueue()
        queueIdentity = UUID()
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
        if !library.isReady {
            guard let counts = musicSessionMemoryStore.startupPlayableCounts else { return 0 }
            let disabled = library.disabledPlaybackSourceIDs
            return counts.reduce(0) { disabled.contains($1.key) ? $0 : $0 + $1.value }
        }
        return memory.snapshot.queueSongIDs.reduce(0) { count, songID in
            library.visibleSong(id: songID)?.isPlayable == true ? count + 1 : count
        }
    }

    var hasPlayableRememberedMusicSession: Bool {
        guard let memory = musicSessionMemoryStore.memory, let library else { return false }
        if !library.isReady { return rememberedMusicSessionPlayableCount > 0 }
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
        plog("▶️ Resume installed queue count=\(queueEntries.count) index=\(currentIndex) time=\(currentTime) libraryReady=\(library?.isReady == true)")
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
        guard let memory = musicSessionMemoryStore.memory else { return false }
        return await restoreMusicQueueMemory(memory, startPlayback: startPlayback)
    }

    @discardableResult
    func restoreMusicQueueMemory(_ memory: MusicSessionMemoryStore.Memory, startPlayback: Bool) async -> Bool {
        guard let library else { return false }
        let started = ContinuousClock.now
        registerPlayIntent()
        queueRequestToken &+= 1
        let requestToken = queueRequestToken
        let advanceGeneration = playbackAdvancePolicy.generation
        let commandGeneration = castingCommandGeneration
        let restored = await Task.detached(priority: .userInitiated) {
            QueueWindowPolicy.restoring(memory.snapshot, savedContinuation: memory.continuation)
        }.value
        var savedRows: [String: Song]?
        if !library.isReady {
            if let live = musicSessionMemoryStore.memory, live.snapshot.queueSongIDs == memory.snapshot.queueSongIDs,
               live.savedAt == memory.savedAt, let read = musicSessionMemoryStore.startupRead {
                savedRows = await read.value
            } else {
                savedRows = await library.prepareStartupSavedQueue(ids: restored.snapshot.queueSongIDs)
            }
            if savedRows == nil { await library.whenReady() }
        }
        guard !Task.isCancelled, queueRequestToken == requestToken, castingCommandGeneration == commandGeneration,
              playbackAdvancePolicy.generation == advanceGeneration else { return false }
        // P2:曲库就绪且目录可读时,队列里的歌按 id 从目录取(含停用源、只要能放的),
        // 结果与 `historySongLookup` 逐首查后再筛能放的相同;否则照旧查内存模型。
        var catalogRows: [String: Song]?
        if library.isReady {
            catalogRows = await Self.catalogPlayableSongs(
                ids: Set(restored.snapshot.queueSongIDs), library: library, visibility: .includingDisabledSources
            )
            guard !Task.isCancelled, queueRequestToken == requestToken, castingCommandGeneration == commandGeneration,
                  playbackAdvancePolicy.generation == advanceGeneration else { return false }
        }
        let lookup = library.isReady && catalogRows == nil ? library.historySongLookup() : nil
        let diskRows = catalogRows ?? savedRows
        let disabledSourceIDs = library.disabledPlaybackSourceIDs
        let prepared = await Task.detached(priority: .userInitiated) { () -> (PlaybackSessionRestorationPlan, [Song], QueueContinuation?)? in
            var snapshot = restored.snapshot
            let byID = Dictionary(snapshot.queueSongIDs.compactMap { id -> (String, Song)? in
                let resolved = lookup == nil ? diskRows?[id] : lookup?.song(id: id)
                guard let song = resolved, song.isPlayable else { return nil }
                return (id, song)
            }, uniquingKeysWith: { first, _ in first })
            let canStart: (Int) -> Bool = { index in
                guard snapshot.queueSongIDs.indices.contains(index),
                      let song = byID[snapshot.queueSongIDs[index]] else { return false }
                return !disabledSourceIDs.contains(song.sourceID)
            }
            if !canStart(snapshot.currentIndex) {
                let order = snapshot.shuffleEnabled && !snapshot.shuffledIndices.isEmpty
                    ? snapshot.shuffledIndices : Array(snapshot.queueSongIDs.indices)
                let position = order.firstIndex(of: snapshot.currentIndex) ?? 0
                let candidates = Array(order.dropFirst(position + 1)) + Array(order.prefix(position + 1))
                guard let index = candidates.first(where: canStart) else { return nil }
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
        guard !Task.isCancelled, queueRequestToken == requestToken, castingCommandGeneration == commandGeneration,
              library.disabledPlaybackSourceIDs == disabledSourceIDs,
              playbackAdvancePolicy.generation == advanceGeneration else { return false }
        guard let (plan, songs, continuation) = prepared else {
            showPlaybackError(String(localized: "playback_error_source_disabled"))
            return false
        }
        isRestoringPlaybackSession = true
        musicSessionMemoryStore.clear()
        stop()
        setQueue(songs, startAt: plan.currentIndex, keepsContinuation: true)
        setQueueContinuation(continuation)
        repeatBehavior = RepeatBehavior(repeatMode: plan.repeatMode, eachTrackStop: plan.eachTrackStop)
        shuffleEnabled = plan.shuffleEnabled
        shuffledIndices = plan.shuffledIndices
        shufflePosition = plan.shufflePosition
        pendingNextShuffleIndices = plan.pendingNextShuffleIndices
        remembersMusicQueue = plan.remembersMusicQueue ?? (songs.count > 1)
        queueIdentity = plan.queueIdentity ?? UUID()
        stagePausedHandoff(song: songs[plan.currentIndex], at: plan.currentTime)
        isRestoringPlaybackSession = false
        persistPlaybackSession()
        plog("▶️ Resume saved queue count=\(songs.count) index=\(plan.currentIndex) time=\(plan.currentTime) libraryReady=\(library.isReady) prepare=\(started.duration(to: .now))")
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

struct QueueBookmarkSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String?
    let coverRef: String?
    let songID: String
    let sourceID: String
    let position: TimeInterval
    let savedAt: Date
}

/// Only the small index is resident. Each checkpoint owns its continuation;
/// advancing the active queue cannot consume another bookmark's pending IDs.
private actor QueueBookmarkFiles {
    let directory: URL
    private var index: [QueueBookmarkSummary]?

    init(directory: URL) { self.directory = directory }

    func load() throws -> [QueueBookmarkSummary] {
        if let index { return index }
        let url = directory.appendingPathComponent("index.json")
        let loaded = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([QueueBookmarkSummary].self, from: Data(contentsOf: url)) : []
        index = loaded
        return loaded
    }

    func memory(id: UUID) throws -> MusicSessionMemoryStore.Memory {
        try JSONDecoder().decode(MusicSessionMemoryStore.Memory.self, from: Data(contentsOf: file(id)))
    }

    func save(_ memory: MusicSessionMemoryStore.Memory, id: UUID) throws -> [QueueBookmarkSummary] {
        var next = try load().filter { $0.id != id }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(memory).write(to: file(id), options: .atomic)
        next.insert(.init(id: id, title: memory.title, subtitle: memory.subtitle, coverRef: memory.coverRef,
                          songID: memory.songID, sourceID: memory.sourceID, position: memory.snapshot.currentTime,
                          savedAt: memory.savedAt), at: 0)
        try writeIndex(next)
        return next
    }

    func remove(id: UUID) throws -> [QueueBookmarkSummary] {
        let next = try load().filter { $0.id != id }
        try writeIndex(next)
        // An orphan after interrupted cleanup is harmless and never shown.
        try? FileManager.default.removeItem(at: file(id))
        return next
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }

    private func writeIndex(_ value: [QueueBookmarkSummary]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent("index.json"), options: .atomic)
        index = value
    }
}

@MainActor @Observable
final class QueueBookmarkStore {
    static let shared = QueueBookmarkStore()
    private(set) var bookmarks: [QueueBookmarkSummary] = []
    private(set) var isBusy = false
    @ObservationIgnored private let files: QueueBookmarkFiles
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    #if os(iOS)
    @ObservationIgnored private var backgroundWrite: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(directory: URL = PlaybackSessionStore().url.deletingLastPathComponent().appendingPathComponent("queue-bookmarks")) {
        let files = QueueBookmarkFiles(directory: directory)
        self.files = files
        loadTask = Task { [weak self] in
            do { self?.bookmarks = try await files.load() }
            catch { plog("Queue bookmark index load failed: \(error.localizedDescription)") }
        }
    }

    func whenReady() async { await loadTask?.value }

    func memory(id: UUID) async throws -> MusicSessionMemoryStore.Memory {
        await whenReady()
        return try await files.memory(id: id)
    }

    func save(_ memory: MusicSessionMemoryStore.Memory, id: UUID) async throws {
        await whenReady()
        guard !isBusy else { return }
        isBusy = true
        beginWrite()
        defer { isBusy = false; endWrite() }
        bookmarks = try await files.save(memory, id: id)
    }

    private func beginWrite() {
        #if os(iOS)
        backgroundWrite = UIApplication.shared.beginBackgroundTask(withName: "Queue bookmark") { [weak self] in
            Task { @MainActor in self?.endWrite() }
        }
        #endif
    }

    private func endWrite() {
        #if os(iOS)
        guard backgroundWrite != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundWrite)
        backgroundWrite = .invalid
        #endif
    }

    func remove(id: UUID) async throws {
        await whenReady()
        guard !isBusy else { return }
        isBusy = true
        beginWrite()
        defer { isBusy = false; endWrite() }
        bookmarks = try await files.remove(id: id)
    }
}

extension AudioPlayerService {
    var canBookmarkCurrentQueue: Bool {
        guard let song = currentSong, listeningSpace(of: song) == .music,
              queueEntries.indices.contains(currentIndex) else { return false }
        return queueEntries[currentIndex].song.id == song.id
    }

    var isCurrentQueueBookmarked: Bool { queueBookmarkStore.bookmarks.contains { $0.id == queueIdentity } }

    func toggleCurrentQueueBookmark() async {
        let requestedQueue = queueIdentity
        await queueBookmarkStore.whenReady()
        guard requestedQueue == queueIdentity, canBookmarkCurrentQueue,
              !queueBookmarkStore.isBusy, let song = currentSong else { return }
        do {
            if isCurrentQueueBookmarked {
                try await queueBookmarkStore.remove(id: queueIdentity)
                return
            }
            let time = isPlaying ? interpolatedTime() : currentTime
            let snapshot = PlaybackSessionSnapshot(
                queueSongIDs: queueEntries.map(\.song.id), currentSongID: song.id,
                currentIndex: currentIndex, currentTime: max(0, time.isFinite ? time : 0),
                duration: duration, wasPlaying: false, shuffleEnabled: shuffleEnabled,
                shuffledIndices: shuffleEnabled ? shuffledIndices : [],
                shufflePosition: shuffleEnabled ? (shuffleAnchorPosition ?? shufflePosition) : 0,
                pendingNextShuffleIndices: pendingNextShuffleIndices, repeatMode: repeatMode,
                isAtTrackEnd: isAtTrackEnd, queueContinuationToken: queueContinuation?.token,
                eachTrackStop: eachTrackStop, remembersMusicQueue: remembersMusicQueue, queueIdentity: queueIdentity
            )
            try await queueBookmarkStore.save(.init(
                snapshot: snapshot, title: song.title, subtitle: song.artistName,
                coverRef: song.coverArtFileName, songID: song.id, sourceID: song.sourceID,
                savedAt: Date(), continuation: queueContinuation
            ), id: queueIdentity)
        } catch { showPlaybackError(String(localized: "queue_bookmark_error")) }
    }

    func removeQueueBookmark(_ id: UUID) async {
        do { try await queueBookmarkStore.remove(id: id) }
        catch { showPlaybackError(String(localized: "queue_bookmark_error")) }
    }

    @discardableResult
    func resumeQueueBookmark(_ id: UUID, startPlayback: Bool = true) async -> Bool {
        queueRequestToken &+= 1
        let token = queueRequestToken
        let generation = playbackAdvancePolicy.generation
        do {
            let memory = try await queueBookmarkStore.memory(id: id)
            guard token == queueRequestToken, generation == playbackAdvancePolicy.generation else { return false }
            return await restoreMusicQueueMemory(memory, startPlayback: startPlayback)
        } catch {
            guard token == queueRequestToken else { return false }
            showPlaybackError(String(localized: "queue_bookmark_error"))
            return false
        }
    }
}
