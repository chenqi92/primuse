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
        await prepareOpeningMedleyHighlight(songs)
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
    ///
    /// The slice is the song's own playback range when the listener prefers
    /// those and set one, otherwise its highlight as far as it is already
    /// known on this device (see `MedleyHighlightStore`), otherwise a guess.
    /// Highlights still unknown are found while the medley plays
    /// (`refineUpcomingMedleySlices`).
    func medleySlices(for songs: [Song]) -> [Song] {
        let settings = playbackSettings
        let length = MedleySegmentPolicy.sliceLength(
            automatic: settings.medleyAutomaticLength,
            seconds: settings.medleySegmentSeconds
        )
        var seen = Set<String>()
        var slices: [Song] = []
        // A song whose source cannot be reached right now and has no copy on
        // this device would only stall the medley at its boundary.
        for candidate in songs where canIncludeInMedley(candidate)
            && isSongAvailableForNewPlayback(candidate)
            && seen.insert(candidate.id).inserted {
            // The playing copy of a song in its playback range is shortened to
            // the range end; slices are cut from the whole song.
            let song = candidate.withoutAppliedPlaybackRange
            let segment: MedleySegment?
            if settings.medleyPrefersPlaybackRange, let range = medleyChosenPlaybackRange(for: song) {
                segment = MedleySegmentPolicy.segment(playbackRange: range)
            } else {
                segment = MedleySegmentPolicy.segment(
                    duration: song.duration,
                    length: length,
                    highlight: MedleyHighlightStore.shared.highlight(for: song),
                    sectionStarts: medleySectionStarts(for: song.id),
                    // The opening slice starts on its chorus, with nothing to blend from.
                    leadsIn: !slices.isEmpty
                )
            }
            guard let segment else { continue }
            var slice = song
            slice.cueStartTime = segment.start
            slice.cueEndTime = segment.end
            slice.duration = segment.length
            slices.append(slice)
        }
        return slices
    }

    /// The opening slice cannot be re-cut once it plays, and the medley does
    /// not wait for audio analysis to start. A chorus the song's cached
    /// lyrics show is a file read away, so that much is looked up first.
    private func prepareOpeningMedleyHighlight(_ songs: [Song]) async {
        guard let opening = songs.first(where: { canIncludeInMedley($0) && isSongAvailableForNewPlayback($0) })?
            .withoutAppliedPlaybackRange,
              opening.duration.isFinite, opening.duration > 0,
              !(playbackSettings.medleyPrefersPlaybackRange && medleyChosenPlaybackRange(for: opening) != nil) else { return }
        let store = MedleyHighlightStore.shared
        let record = store.record(for: opening.id)
        guard MedleyHighlightRecordPolicy.highlight(from: record, songDuration: opening.duration) == nil else { return }
        let lyrics = await MedleyHighlightAnalysis.cachedLyricLines(songID: opening.id)
        guard !lyrics.isEmpty else { return }
        let found = MedleyHighlightAnalysis.record(
            songDuration: opening.duration,
            lyrics: lyrics,
            features: nil,
            sectionStarts: medleySectionStarts(for: opening.id)
        )
        if found.highlight != nil { store.store(found, for: opening.id) }
    }

    /// The playback range the listener set for `song`, when it is on.
    func medleyChosenPlaybackRange(for song: Song) -> AppliedSongPlaybackRange? {
        guard SongPlaybackRangeAvailability.supports(song) else { return nil }
        var measured = song
        // The library may have learned the real length since this copy was taken.
        if let latest = library?.song(id: song.id)?.duration, latest > 0 {
            measured.duration = latest
        }
        return SongPlaybackRangeStore.shared.applied(for: measured)
    }

    /// Structure analysis from Apple's music understanding covers the
    /// complete file on its real timeline; the streaming analyser only saw
    /// what was played, so its boundaries are not used.
    func medleySectionStarts(for songID: String) -> [TimeInterval] {
        smartMixAnalyses[songID].flatMap {
            $0.backend == .musicUnderstanding ? $0.sectionStartTimes : nil
        } ?? []
    }

    /// Enters medley mode with `slices` as the queue, without starting
    /// playback.
    func installMedley(_ slices: [Song]) {
        guard !slices.isEmpty else { return }
        let settings = playbackSettings
        plog("🎛️ Medley: \(slices.count) slices, "
            + (settings.medleyAutomaticLength ? "highlight length" : "\(settings.medleySegmentSeconds)s")
            + (settings.medleyPrefersPlaybackRange ? ", own ranges first" : ""))
        isInstallingMedleyQueue = true
        endMedleyIfNeeded()
        medleySongIDs = Set(slices.map(\.id))
        if settings.medleyPrefersPlaybackRange {
            // Judged on the library's whole song: a slice is shortened to its window.
            medleyChosenRangeSongIDs = Set(slices.compactMap { slice in
                library?.song(id: slice.id).flatMap { medleyChosenPlaybackRange(for: $0) } != nil ? slice.id : nil
            })
        }
        isMedleyActive = true
        PlayHistoryStore.shared.endSession()
        PlayHistoryStore.shared.isRecordingSuspended = true
        ScrobbleService.shared.isSuspended = true
        // Repeat-one would hold the first slice forever, and never crossfade.
        if repeatMode == .one { repeatMode = .off }
        setQueue(slices, startAt: 0)
        isInstallingMedleyQueue = false
        refineUpcomingMedleySlices()
    }

    /// Leaves medley mode. The queue itself is left alone: this runs when a
    /// new queue is being installed, which replaces it anyway.
    func endMedleyIfNeeded() {
        guard isMedleyActive || !medleySongIDs.isEmpty else { return }
        isMedleyActive = false
        medleySongIDs = []
        medleyChosenRangeSongIDs = []
        medleyLyricsCheckedSongIDs = []
        medleyAudioCheckedSongIDs = []
        medleyHighlightTask?.cancel()
        medleyHighlightTask = nil
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

    // MARK: - Finding highlights while the medley plays

    /// Starts finding the highlights of the next slices, unless that is
    /// already running. Called whenever the queue or the playing slice moves
    /// on; the work stops by itself once nothing near is left to find.
    func refineUpcomingMedleySlices() {
        guard isMedleyActive, medleyHighlightTask == nil else { return }
        medleyHighlightTask = Task { [weak self] in
            await self?.runMedleyHighlightRefinement()
            // A cancelled run was replaced by the next medley's; leave its handle.
            guard !Task.isCancelled else { return }
            self?.medleyHighlightTask = nil
        }
    }

    /// Slices this many ahead are looked at: the next one has to be ready in
    /// time, the two after it are cheap to have ready.
    private static let medleyHighlightLookahead = 3

    /// Waiting for a next song's download is given up after this long; the
    /// next change of slice looks again. Some sources are never prefetched.
    private static let medleyHighlightIdleRounds = 30

    private func runMedleyHighlightRefinement() async {
        var idleRounds = 0
        while isMedleyActive, !Task.isCancelled {
            let upcoming = nextSongsInQueue(count: Self.medleyHighlightLookahead).filter {
                medleySongIDs.contains($0.id) && !medleyChosenRangeSongIDs.contains($0.id)
            }
            var didWork = false
            // Lyrics and earlier findings first, for every slice: they cost a
            // file read, while the audio may still be downloading.
            for slice in upcoming where !medleyLyricsCheckedSongIDs.contains(slice.id) {
                medleyLyricsCheckedSongIDs.insert(slice.id)
                await refineMedleySliceWithoutAudio(slice)
                didWork = true
                guard isMedleyActive, !Task.isCancelled else { return }
            }
            for slice in upcoming where !medleyAudioCheckedSongIDs.contains(slice.id) {
                guard let whole = medleyWholeSong(for: slice),
                      let url = await medleyAnalysisAudioURL(for: whole) else { continue }
                guard isMedleyActive, !Task.isCancelled else { return }
                medleyAudioCheckedSongIDs.insert(slice.id)
                await refineMedleySlice(whole, readingAudioAt: url)
                didWork = true
                // The queue may have moved on during the analysis.
                break
            }
            guard !didWork else {
                idleRounds = 0
                continue
            }
            // Nothing to do until a prefetch brings a next song onto this
            // device or playback reaches the next slice.
            guard upcoming.contains(where: { !medleyAudioCheckedSongIDs.contains($0.id) }),
                  idleRounds < Self.medleyHighlightIdleRounds else { return }
            idleRounds += 1
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// The library's whole song behind a slice.
    private func medleyWholeSong(for slice: Song) -> Song? {
        guard let whole = library?.song(id: slice.id)?.withoutAppliedPlaybackRange,
              whole.duration.isFinite, whole.duration > 0 else { return nil }
        return whole
    }

    /// Applies what is known without the audio: a recorded highlight, or the
    /// chorus of the song's cached lyrics.
    private func refineMedleySliceWithoutAudio(_ slice: Song) async {
        guard let whole = medleyWholeSong(for: slice) else { return }
        let store = MedleyHighlightStore.shared
        let record = store.record(for: whole.id)
        let lyrics = await MedleyHighlightAnalysis.cachedLyricLines(songID: whole.id)
        if MedleyHighlightRecordPolicy.needsAnalysis(
            record, songDuration: whole.duration, audioAvailable: false, lyricsAvailable: !lyrics.isEmpty
        ), !lyrics.isEmpty {
            let found = MedleyHighlightAnalysis.record(
                songDuration: whole.duration,
                lyrics: lyrics,
                features: nil,
                sectionStarts: medleySectionStarts(for: whole.id)
            )
            // Keep an audio finding over a lyrics-only one that found nothing.
            if found.highlight != nil || record == nil {
                store.store(found, for: whole.id)
            }
        }
        if let highlight = store.highlight(for: whole) {
            applyMedleyHighlight(highlight, to: whole)
        }
    }

    private func refineMedleySlice(_ whole: Song, readingAudioAt url: URL) async {
        let store = MedleyHighlightStore.shared
        let lyrics = await MedleyHighlightAnalysis.cachedLyricLines(songID: whole.id)
        guard MedleyHighlightRecordPolicy.needsAnalysis(
            store.record(for: whole.id),
            songDuration: whole.duration,
            audioAvailable: true,
            lyricsAvailable: !lyrics.isEmpty
        ) else {
            if let highlight = store.highlight(for: whole) { applyMedleyHighlight(highlight, to: whole) }
            return
        }
        let began = ContinuousClock.now
        let features: MedleyAudioFeatures
        do {
            features = try await medleyAudioFeatures(of: whole, at: url)
        } catch {
            if !(error is CancellationError) {
                plog("🎛️ Medley highlight: could not read '\(whole.title)': \(error.localizedDescription)")
            }
            return
        }
        guard !Task.isCancelled else { return }
        let sections = medleySectionStarts(for: whole.id)
        let record = await Task.detached(priority: .utility) {
            MedleyHighlightAnalysis.record(
                songDuration: whole.duration,
                lyrics: lyrics,
                features: features,
                sectionStarts: sections
            )
        }.value
        store.store(record, for: whole.id)
        let elapsed = ContinuousClock.now - began
        if let highlight = record.highlight {
            plog(String(
                format: "🎛️ Medley highlight '%@': %.1f–%.1fs via %@ (%.1fs)",
                whole.title, highlight.start, highlight.end, highlight.basis.rawValue,
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            ))
            applyMedleyHighlight(highlight, to: whole)
        } else {
            plog("🎛️ Medley highlight '\(whole.title)': none found")
        }
    }

    /// The whole file of `song` on this device, or nil while it is not here:
    /// a local source's own file, otherwise a complete cached copy (a medley
    /// prefetches the next slices whole). Nothing is downloaded for this.
    private func medleyAnalysisAudioURL(for song: Song) async -> URL? {
        guard let manager = sourceManager else { return nil }
        if playbackMetadataSourceType?(song.sourceID) == .local {
            // Resolving a local song only opens its file; it is tried once.
            medleyAudioCheckedSongIDs.insert(song.id)
            guard let url = try? await manager.resolveURL(for: song, acquirePlaybackCacheLease: false),
                  url.isFileURL else { return nil }
            medleyAudioCheckedSongIDs.remove(song.id)
            return url
        }
        guard manager.hasUsableCachedAudioForPlayback(song) else { return nil }
        return manager.cachedPlaybackURL(for: song)
    }

    /// Decodes the file the way playback would, at the analysis rate in mono.
    private func medleyAudioFeatures(of song: Song, at url: URL) async throws -> MedleyAudioFeatures {
        guard song.duration <= MedleyAudioFeatureExtractor.maximumDuration,
              let format = MedleyHighlightAnalysis.analysisFormat else {
            throw AudioDecoderError.unsupportedFormat("medley analysis")
        }
        let stream = await usesFFmpegDecoder(for: song, url: url)
            ? ffmpegDecoder.decode(from: url, outputFormat: format)
            : nativeDecoder.decode(from: url, outputFormat: format)
        let sampleRate = format.sampleRate
        let expected = min(song.duration * 0.8, MedleyAudioFeatureExtractor.maximumDuration)
        // The buffers are read and transformed away from the main actor; the
        // decoder stops when the stream is dropped.
        let work = Task.detached(priority: .utility) { () async throws -> MedleyAudioFeatures in
            let extractor = MedleyAudioFeatureExtractor(sampleRate: sampleRate)
            for try await buffer in stream {
                try Task.checkCancellation()
                MedleyHighlightAnalysis.append(buffer, to: extractor)
                if extractor.isFull { break }
            }
            guard extractor.analyzedDuration >= expected else {
                throw AudioDecoderError.decodingFailed("medley analysis read \(Int(extractor.analyzedDuration))s")
            }
            return extractor.finish()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Re-cuts the queued slices of `whole` around `highlight`. The slice
    /// playing now, and the next one once its blend is being prepared, keep
    /// the window they were opened with.
    private func applyMedleyHighlight(_ highlight: MedleyHighlight, to whole: Song) {
        guard isMedleyActive, medleySongIDs.contains(whole.id),
              !medleyChosenRangeSongIDs.contains(whole.id) else { return }
        let settings = playbackSettings
        guard let segment = MedleySegmentPolicy.segment(
            duration: whole.duration,
            length: MedleySegmentPolicy.sliceLength(
                automatic: settings.medleyAutomaticLength,
                seconds: settings.medleySegmentSeconds
            ),
            highlight: highlight,
            sectionStarts: medleySectionStarts(for: whole.id)
        ) else { return }
        let lockedEntryID = crossfadeTriggered || isCrossfading ? nextQueueEntryInQueue()?.id : nil
        var changed = false
        for index in queueEntries.indices where queueEntries[index].song.id == whole.id {
            guard index != currentIndex, queueEntries[index].id != lockedEntryID else { continue }
            var slice = queueEntries[index].song
            guard slice.cueStartTime != segment.start || slice.cueEndTime != segment.end else { continue }
            slice.cueStartTime = segment.start
            slice.cueEndTime = segment.end
            slice.duration = segment.length
            queueEntries[index].song = slice
            changed = true
        }
        if changed {
            plog(String(format: "🎛️ Medley: '%@' now plays %.1f–%.1fs", whole.title, segment.start, segment.end))
        }
    }
}
