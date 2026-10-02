import Foundation
import PrimuseKit

/// "Keep playing similar songs" (#166). Once the song that is playing is the
/// last one of a music queue, songs like the queue's last few are worked out
/// off the main actor and appended, so they already sit in Up Next — and in
/// CarPlay's list — while that song plays, and the hand-over keeps gapless and
/// crossfade. A Siri or search request for one song therefore becomes "that
/// song, then similar ones" as soon as it starts. Shuffle keeps its own
/// library continuation (`extendExhaustedShuffleFromLibrary`); books, radio,
/// medleys and repeat never continue.
extension AudioPlayerService {
    func isAutoContinuationEntry(_ entry: QueueEntry) -> Bool {
        autoContinuationEntryIDs.contains(entry.id)
    }

    /// What the end of the queue calls for right now. Reads the selected
    /// queue entry rather than `currentSong`, which lags behind a queue that
    /// was just installed and whose first song is still loading.
    var autoContinuationDecision: QueueContinuationPolicy.Decision {
        guard queueEntries.indices.contains(currentIndex) else { return .none }
        let song = queueEntries[currentIndex].song
        guard !isDLNACast(song) else { return .none }
        return QueueContinuationPolicy.decision(
            isEnabled: playbackSettings.autoContinueSimilarEnabled,
            repeatMode: repeatMode,
            shuffleEnabled: shuffleEnabled,
            space: listeningSpace(of: song),
            isMedley: isMedleyActive || isInstallingMedleyQueue,
            isLiveRadio: isLiveRadio,
            hasUpcomingSongs: nextSongInQueue() != nil,
            hasPendingRequestSongs: queueContinuation != nil
        )
    }

    /// Starts working out the next similar songs when the queue is on its
    /// last song. Cheap to call often: it returns at once while a top-up is
    /// running, when the queue still has songs, or at a known dead end.
    func scheduleAutoContinuationIfNeeded() {
        guard autoContinuationTask == nil,
              let library,
              let lastEntryID = queueEntries.last?.id,
              autoContinuationDeadEndEntryID != lastEntryID,
              autoContinuationDecision == .similarSongs else { return }

        let queueIDs = queueEntries.map(\.song.id)
        let seedIDs = QueueContinuationPolicy.seedIDs(queueIDs: queueIDs, currentIndex: currentIndex)
        let seeds: [Song] = seedIDs.compactMap { id in
            queueEntries[...currentIndex].last(where: { $0.song.id == id })?.song
        }
        guard !seeds.isEmpty else { return }
        let excluded = Set(queueIDs).union(library.recentPlaybackSongIDsForSync)
        let recentIDs = Set(PlayHistoryStore.shared.entries(in: .month).map(\.songID))
        // Copy-on-write: the worker reads the library's own array.
        let songs = library.musicSongs
        let revision = library.musicSongsRevision
        let token = queueRequestToken
        let startedAt = ProcessInfo.processInfo.systemUptime

        autoContinuationTask = Task { @MainActor [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                MusicDiscoveryEngine.continuationSongIDs(
                    seeds: seeds,
                    songs: songs,
                    revision: revision,
                    recentIDs: recentIDs,
                    excluding: excluded,
                    limit: QueueContinuationPolicy.batchSize,
                    isCancelled: { Task.isCancelled }
                )
            }
            let ids = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // A cancelled top-up was already replaced by `resetAutoContinuation`.
            guard let self, !Task.isCancelled else { return }
            self.autoContinuationTask = nil
            // The queue moved on while the worker ran: a new request landed,
            // the listener added songs, or a setting changed.
            guard self.queueRequestToken == token,
                  self.queueEntries.last?.id == lastEntryID,
                  self.autoContinuationDecision == .similarSongs else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            if !self.appendAutoContinuation(ids) {
                self.autoContinuationDeadEndEntryID = lastEntryID
                plog("♾️ Auto continuation found nothing after \(seeds.count) seeds (\(elapsed)ms)")
            } else {
                plog("♾️ Auto continuation appended \(ids.count) similar songs seeds=\(seeds.count) (\(elapsed)ms)")
            }
        }
    }

    /// Track end found nothing after the current song: give a top-up that is
    /// still being worked out (or one never started, for a very short song)
    /// the chance to land before the queue is declared finished.
    func awaitAutoContinuationAtQueueEnd() async {
        scheduleAutoContinuationIfNeeded()
        guard let task = autoContinuationTask else { return }
        await task.value
    }

    /// Appends the songs and marks them as autoplay. False when none of the
    /// IDs still names a playable song.
    @discardableResult
    func appendAutoContinuation(_ ids: [String]) -> Bool {
        guard let library else { return false }
        let additions = ids.compactMap { id -> Song? in
            guard let song = library.unobservedVisibleSong(id: id), song.isPlayable else { return nil }
            return song
        }
        guard !additions.isEmpty else { return false }
        let entries = additions.map { QueueEntry(song: $0) }
        // The prepared successor was "none"; there is one now.
        invalidatePreparedQueueSuccessor()
        queueEntries.append(contentsOf: entries)
        autoContinuationEntryIDs.formUnion(entries.map(\.id))
        pendingNextShuffleIndices = nil
        if isAppleMusicMode {
            isPrimuseManagingAppleMusicQueue = true
            AppServices.shared.appleMusic.prepareForPrimuseManagedQueue()
        }
        persistPlaybackSession()
        if isPlaybackActuallyActive {
            prefetchNextSong()
        } else {
            synchronizeAppleMusicQueue()
        }
        return true
    }

    /// A new queue replaces the old one, autoplay songs included.
    func resetAutoContinuation() {
        autoContinuationTask?.cancel()
        autoContinuationTask = nil
        autoContinuationDeadEndEntryID = nil
        if !autoContinuationEntryIDs.isEmpty { autoContinuationEntryIDs = [] }
    }

    /// Where songs the listener adds to the end of the queue go: before the
    /// autoplay songs, so their own choices play first.
    func queueInsertionIndexBeforeAutoContinuation() -> Int? {
        guard !shuffleEnabled, !autoContinuationEntryIDs.isEmpty else { return nil }
        return QueueContinuationPolicy.insertionIndexBeforeAutoplay(
            queueCount: queueEntries.count,
            currentIndex: currentIndex,
            isAutoplay: { autoContinuationEntryIDs.contains(queueEntries[$0].id) }
        )
    }
}
