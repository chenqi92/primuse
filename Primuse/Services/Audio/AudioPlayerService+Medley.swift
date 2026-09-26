import Foundation
import PrimuseKit

/// Medley ("串烧"): a run of songs where each plays only its recognisable
/// slice and neighbouring slices are joined by a short crossfade.
///
/// Each queue entry is a copy of the song carrying the slice as its segment
/// window (`cueStartTime` / `cueEndTime`), the same window CUE tracks use. The
/// decoders, the crossfade successor and seeking all already honour that
/// window, so the slice's length becomes the item's duration everywhere —
/// progress bar, Now Playing, end-of-track — without a second timeline. What
/// must not happen is the slice leaking into the library: `medleySongIDs`
/// guards the duration write-back and keeps a metadata refresh from widening
/// the entry back to the whole song.
extension AudioPlayerService {
    /// Songs that cannot be sliced: Apple Music (MusicKit plays them, not our
    /// decoder), real CUE tracks (already a window into an image) and spoken
    /// word.
    func canIncludeInMedley(_ song: Song) -> Bool {
        song.sourceID != AppleMusicLibraryService.systemSourceID
            && !song.isCueTrack
            && song.mvPath == nil
            && !SpokenWordStore.shared.isSpokenWord(song)
    }

    /// What "medley from the queue" plays: the current song and the rest of
    /// this round of the queue.
    var medleyCandidatesFromQueue: [Song] {
        guard let current = currentSong else { return [] }
        let upcoming = upcomingQueueEntries
            .filter { $0.id.roundOffset == 0 }
            .map(\.entry.song)
        return ([current] + upcoming).filter(canIncludeInMedley)
    }

    /// Whether "medley from the queue" has at least two songs to join. Menus
    /// ask this while they are drawn, so it stops at the second song instead
    /// of classifying the whole round of a library-sized queue.
    var canPlayMedleyFromQueue: Bool {
        guard let current = currentSong else { return false }
        let needed = canIncludeInMedley(current) ? 1 : 2
        return firstCurrentRoundUpcomingSongs(limit: needed, where: canIncludeInMedley).count == needed
    }

    /// Whether a medley of `songs` should first warn about mobile data: the
    /// connection is metered and some of its opening songs would be downloaded.
    func medleyNeedsDataUsageConfirmation(for songs: [Song]) -> Bool {
        let network = NetworkMonitor.shared
        let promptDisabled = UserDefaults.standard.bool(forKey: MedleyDataUsagePolicy.promptDisabledKey)
        guard network.hasDeterminedPath, !network.isOnUnmeteredNetwork, !promptDisabled else { return false }
        let hasSongToDownload = songs.prefix(MedleyDataUsagePolicy.inspectedSongCount).contains { song in
            canIncludeInMedley(song)
                && playbackMetadataSourceType?(song.sourceID) != .local
                && sourceManager?.hasUsableCachedAudioForPlayback(song) != true
        }
        return MedleyDataUsagePolicy.shouldConfirm(
            networkIsDetermined: network.hasDeterminedPath,
            isOnUnmeteredNetwork: network.isOnUnmeteredNetwork,
            promptDisabled: promptDisabled,
            hasSongToDownload: hasSongToDownload
        )
    }

    /// Builds the slices for `songs` and starts playing them.
    /// - Returns: false when none of the songs can be sliced.
    @discardableResult
    func playMedley(_ songs: [Song]) async -> Bool {
        // 从有声书切到串烧:先记下书听到哪里,原因同 `play(station:)`。
        rememberSpokenWordPosition(force: true)
        let slices = medleySlices(for: songs)
        guard !slices.isEmpty else { return false }
        installMedley(slices)
        // `setQueue` keeps a transport that is already playing the selected
        // song; a medley must restart it on its slice.
        await play(song: slices[0])
        return true
    }

    /// The queue entries a medley of `songs` plays: each song that can be
    /// sliced, once, carrying its slice as its segment window.
    func medleySlices(for songs: [Song]) -> [Song] {
        let length = playbackSettings.medleySegmentSeconds
        var seen = Set<String>()
        var slices: [Song] = []
        // A song whose source cannot be reached right now and has no copy on
        // this device would only stall the medley at its boundary.
        for song in songs where canIncludeInMedley(song)
            && isSongAvailableForNewPlayback(song)
            && seen.insert(song.id).inserted {
            // Structure analysis from Apple's music understanding covers the
            // complete file on its real timeline; the streaming analyser only
            // saw what was played, so its boundaries are not used.
            let sections = smartMixAnalyses[song.id].flatMap {
                $0.backend == .musicUnderstanding ? $0.sectionStartTimes : nil
            } ?? []
            guard let segment = MedleySegmentPolicy.segment(
                duration: song.duration,
                segmentLength: length,
                sectionStarts: sections
            ) else { continue }
            var slice = song
            slice.cueStartTime = segment.start
            slice.cueEndTime = segment.end
            slice.duration = segment.length
            slices.append(slice)
        }
        return slices
    }

    /// Enters medley mode with `slices` as the queue, without starting
    /// playback.
    func installMedley(_ slices: [Song]) {
        guard !slices.isEmpty else { return }
        plog("🎛️ Medley: \(slices.count) slices of \(playbackSettings.medleySegmentSeconds)s")
        isInstallingMedleyQueue = true
        endMedleyIfNeeded()
        medleySongIDs = Set(slices.map(\.id))
        isMedleyActive = true
        PlayHistoryStore.shared.endSession()
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        // Repeat-one would hold the first slice forever, and never crossfade.
        if repeatMode == .one { repeatMode = .off }
        setQueue(slices, startAt: 0)
        isInstallingMedleyQueue = false
    }

    /// Leaves medley mode. The queue itself is left alone: this runs when a
    /// new queue is being installed, which replaces it anyway.
    func endMedleyIfNeeded() {
        guard isMedleyActive || !medleySongIDs.isEmpty else { return }
        isMedleyActive = false
        medleySongIDs = []
        PlayHistoryStore.shared.isRecordingSuspended = false
        ScrobbleService.shared.isSuspended = false
        plog("🎛️ Medley ended")
    }

    /// "Keep listening to this one": leaves the medley and plays the current
    /// song whole, from where its slice has got to.
    func continueCurrentMedleySongInFull() async {
        guard isMedleyActive, let slice = currentSong else { return }
        let absolutePosition = (slice.cueStartTime ?? 0) + max(0, currentTime)
        let full = library?.song(id: slice.id) ?? {
            var restored = slice
            restored.cueStartTime = nil
            restored.cueEndTime = nil
            return restored
        }()
        // The rest of the medley becomes ordinary songs after this one.
        let upcoming = upcomingQueueEntries
            .filter { $0.id.roundOffset == 0 }
            .compactMap { presented -> Song? in library?.song(id: presented.entry.song.id) }
        setQueue([full] + upcoming, startAt: 0)
        await play(song: full)
        if absolutePosition > 1 {
            seek(to: absolutePosition, startPlaying: true)
        }
    }
}
