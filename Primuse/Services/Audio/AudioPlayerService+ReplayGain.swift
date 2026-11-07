import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import MediaPlayer
import PrimuseKit
import SFBAudioEngine
#if os(iOS)
import CarPlay
import UIKit
import WidgetKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
import WidgetKit
#endif

extension AudioPlayerService {
    // MARK: - ReplayGain

    typealias ReplayGainValues = ReplayGainAdjustment

    private func replayGainSnapshotKey(_ song: Song) -> String {
        song.sourceID + "\u{1f}" + song.id
    }

    var replayGainPlaybackInfo: ReplayGainPlaybackInfo {
        ReplayGainPlaybackInfo(
            enabled: playbackSettings.replayGainEnabled,
            supported: playbackSettings.outputMode == .effects && !isSystemMediaPlaybackActive
                && !isAppleMusicMode && !isLiveRadio && !isCastingMode
                && currentSong.map(ReplayGainAnalysisService.supports) == true,
            snapshot: currentSong.flatMap { replayGainSnapshots[replayGainSnapshotKey($0)] },
            preampDB: playbackSettings.replayGainPreampDB
        )
    }

    func retainReplayGainSnapshot(for song: Song?) {
        if song.map(ReplayGainAnalysisService.supports) != true { cancelReplayGainAnalysis() }
        replayGainSnapshotGeneration = UUID()
        replayGainSnapshots = replayGainSnapshots.filter { $0.key == song.map(replayGainSnapshotKey) }
    }

    func cancelReplayGainAnalysis() {
        replayGainAnalysisTask?.cancel()
        replayGainAnalysisTask = nil
        replayGainAnalysisIdentity = nil
    }

    /// The node volume a song should play at: its ReplayGain volume, or unity
    /// when the values carry no gain.
    func programVolume(for values: ReplayGainValues) -> Float {
        ReplayGainPolicy.linearGain(gainDB: values.gain, peak: values.peak, preampDB: playbackSettings.replayGainPreampDB)
    }

    /// Steady-state volume for a song under the current settings: unity when
    /// ReplayGain is off or the output mode bypasses it.
    func targetProgramVolume(for song: Song, url: URL, allowFileRead: Bool) async -> Float {
        let settings = playbackSettings.snapshot()
        guard shouldApplyReplayGain(settings) else { return 1 }
        let values = await resolveReplayGainValues(
            for: song,
            url: url,
            mode: settings.replayGainMode,
            allowFileRead: allowFileRead
        )
        return programVolume(for: values)
    }

    func applyReplayGain(
        for song: Song,
        url: URL,
        mode: ReplayGainMode,
        allowFileRead: Bool = true,
        expectedPlayID: UUID? = nil,
        expectedSongID: String? = nil
    ) async {
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        let resolution = Task {
            await self.resolveReplayGainValues(
                for: song,
                url: url,
                mode: mode,
                allowFileRead: allowFileRead
            )
        }
        if let expectedPlayID, let expectedSongID {
            ReplayGainResolutionLedger.shared.record(
                resolution,
                playID: expectedPlayID,
                songID: expectedSongID
            )
        }
        let values = await resolution.value
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        audioEngine.applyProgramVolume(ReplayGainAnalysisService.supports(song) ? programVolume(for: values) : 1)
    }

    /// The library row answers first. A local file is opened only when the
    /// row carries no ReplayGain tags at all (older scans, or tags written
    /// after the scan); streams never read the file. File reads are cached per
    /// file version, including the answer "no tags", so seeking an untagged
    /// song does not re-read it.
    func resolveReplayGainValues(
        for song: Song,
        url: URL,
        mode: ReplayGainMode,
        allowFileRead: Bool
    ) async -> ReplayGainValues {
        guard ReplayGainAnalysisService.supports(song) else { return .init() }
        let mode = ReplayGainPolicy.effectiveMode(mode, song: song, queue: queue, shuffled: shuffleEnabled)
        let key = replayGainSnapshotKey(song)
        let generation = replayGainSnapshotGeneration
        if let snapshot = replayGainSnapshots[key] { return snapshot.values }
        let storedValues = replayGainValues(from: song, mode: mode)
        var values: ReplayGainValues
        var origin: String
        var valueMode: ReplayGainMode = .track
        if storedValues.hasValue {
            values = storedValues
            origin = "library"
            if mode == .album, song.replayGainAlbumGain?.isFinite == true { valueMode = .album }
        } else if !allowFileRead {
            values = storedValues
            origin = "none (streamed; file not read)"
        } else {
            let tags = await ReplayGainFileTagCache.shared.tags(for: url)
            values = replayGainValues(from: tags, mode: mode)
            origin = values.hasValue ? "file" : "none (no tags in file)"
            if mode == .album, tags.albumGain?.isFinite == true { valueMode = .album }
        }
        if !values.hasValue {
            let album = replayGainAlbumSongs(for: song)
            if let cached = await ReplayGainAnalysisService.cachedSnapshot(for: song, mode: mode, album: album, url: url) {
                values = cached.values
                valueMode = cached.mode
                origin = "analysis"
            }
            if currentSong?.id == song.id, shouldApplyReplayGain(playbackSettings.snapshot()) {
                scheduleReplayGainAnalysis(for: song, mode: mode, album: album, url: allowFileRead ? url : nil)
            }
        }
        guard ReplayGainAnalysisService.supports(song) else { return .init() }
        // Answers "ReplayGain does nothing for this song" from a log: which
        // values were used, where they came from, and the volume they gave.
        let gain = values.gain.map { String(format: "%+.2f dB", $0) } ?? "-"
        let peak = values.peak.map { String(format: "%.6f", $0) } ?? "-"
        let volume = String(format: "%.3f", programVolume(for: values))
        plog("🎚️ ReplayGain '\(song.title)' mode=\(mode.rawValue) source=\(origin) gain=\(gain) peak=\(peak) volume=×\(volume)")
        if replayGainSnapshotGeneration == generation {
            // Concurrent resolution may have captured unity before analysis
            // finished. That first answer owns this playback, including seeks.
            if let snapshot = replayGainSnapshots[key] { return snapshot.values }
            replayGainSnapshots[key] = .init(mode: valueMode, values: values, origin: origin == "analysis" ? .analysis : .tags)
        }
        return values
    }

    /// The node volume a gapless successor's samples are scaled against.
    ///
    /// Past the first gapless boundary of a chain the node keeps the volume
    /// the chain started with. On the chain's first song, that song's own
    /// ReplayGain may still be resolving; wait for it and settle the node on
    /// it now, so a late landing cannot move the node under samples that were
    /// already scaled against it.
    func gaplessBaseNodeVolume(playID id: UUID) async -> Float {
        let isPastFirstBoundary = activeGaplessFeed?.playID == id
        guard !isPastFirstBoundary,
              let songID = currentSong?.id,
              let resolution = ReplayGainResolutionLedger.shared.resolution(
                  playID: id,
                  songID: songID
              ) else {
            return audioEngine.primaryProgramVolume
        }
        let values = await resolution.value
        guard playID == id, currentSong?.id == songID else {
            return audioEngine.primaryProgramVolume
        }
        let volume = programVolume(for: values)
        audioEngine.applyProgramVolume(volume)
        return audioEngine.primaryProgramVolume
    }

    /// ReplayGain on/off and Track/Album are read when a track starts. Apply a
    /// change to the audible track right away by rebuilding it at the current
    /// position, the same way an output-mode change does. The rebuild also
    /// discards a gapless successor whose samples were scaled for the old
    /// setting.
    func observeReplayGainSettings() {
        let oldSupported = currentSong.map(ReplayGainAnalysisService.supports)
        let oldSelection = currentSong.map(replayGainSnapshotKey)
        let oldEnabled = playbackSettings.replayGainEnabled
        let oldPreamp = playbackSettings.replayGainPreampDB
        let oldConfiguredMode = playbackSettings.replayGainMode
        let oldShuffled = shuffleEnabled
        let oldMode = currentSong.map { ReplayGainPolicy.effectiveMode(playbackSettings.replayGainMode, song: $0, queue: queue, shuffled: shuffleEnabled) }
        withObservationTracking {
            _ = playbackSettings.replayGainEnabled
            _ = playbackSettings.replayGainMode
            _ = playbackSettings.replayGainPreampDB
            _ = shuffleEnabled
            _ = queueEntries
            _ = currentSong.map(ReplayGainAnalysisService.supports)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newSupported = self.currentSong.map(ReplayGainAnalysisService.supports)
                let classificationChanged = oldSelection == self.currentSong.map(self.replayGainSnapshotKey)
                    && oldSupported != newSupported
                let newMode = self.currentSong.map { ReplayGainPolicy.effectiveMode(self.playbackSettings.replayGainMode, song: $0, queue: self.queue, shuffled: self.shuffleEnabled) }
                let changed = oldEnabled != self.playbackSettings.replayGainEnabled
                    || classificationChanged
                    || oldPreamp != self.playbackSettings.replayGainPreampDB
                    || oldConfiguredMode != self.playbackSettings.replayGainMode
                    || (oldShuffled != self.shuffleEnabled && oldMode != newMode)
                if changed {
                    self.retainReplayGainSnapshot(for: nil)
                    self.cancelReplayGainAnalysis()
                }
                if changed && (oldSupported == true || newSupported == true) && self.shouldRebuildForReplayGainChange {
                    self.seek(to: self.currentTime, startPlaying: self.isPlaying)
                } else if !changed {
                    // A queue refill may change the automatic mode. Keep the
                    // audible selection fixed; re-plan only its successors.
                    // Selection changes already invalidated the previous song
                    // synchronously, before the new gain resolution started.
                    if oldSelection == self.currentSong.map(self.replayGainSnapshotKey) {
                        self.retainReplayGainSnapshot(for: self.currentSong)
                    }
                    self.prefetchReplayGain()
                }
                self.observeReplayGainSettings()
            }
        }
    }

    private var shouldRebuildForReplayGainChange: Bool {
        currentSong != nil
            && !isLoading
            && playbackSettings.outputMode == .effects
            && !isSystemMediaPlaybackActive
            && !isAppleMusicMode
            && !isLiveRadio
            && !isCastingMode
            && castingController == nil
    }

    private func replayGainValues(from song: Song, mode: ReplayGainMode) -> ReplayGainValues {
        ReplayGainPolicy.adjustment(for: song, mode: mode)
    }

    private func replayGainValues(
        from tags: ReplayGainFileTagCache.Tags,
        mode: ReplayGainMode
    ) -> ReplayGainValues {
        switch mode {
        case .automatic, .track:
            return ReplayGainValues(gain: tags.trackGain, peak: tags.trackPeak)
        case .album:
            if let gain = tags.albumGain, gain.isFinite { return .init(gain: gain, peak: tags.albumPeak ?? tags.trackPeak) }
            return .init(gain: tags.trackGain, peak: tags.trackPeak)
        }
    }

    func replayGainAlbumSongs(for song: Song) -> [Song] {
        guard let key = ReplayGainPolicy.albumKey(for: song) else { return [song] }
        let candidates = song.albumID.flatMap { library?.songs(forAlbum: $0) } ?? queue
        let album = candidates.filter { ReplayGainAnalysisService.supports($0) && ReplayGainPolicy.albumKey(for: $0) == key }
        return album.isEmpty ? [song] : album
    }

    func analyzeReplayGainAfterTransition(song: Song, url: URL) {
        guard shouldApplyReplayGain(playbackSettings.snapshot()) else { return }
        let id = playID
        Task { [weak self] in
            guard let self, self.playID == id, self.currentSong?.id == song.id else { return }
            _ = await self.resolveReplayGainValues(for: song, url: url, mode: self.playbackSettings.replayGainMode, allowFileRead: url.isFileURL)
        }
    }

    func prefetchReplayGain(upcoming: [Song]? = nil) {
        guard let song = currentSong, ReplayGainAnalysisService.supports(song),
              shouldApplyReplayGain(playbackSettings.snapshot()) else {
            cancelReplayGainAnalysis()
            return
        }
        let mode = ReplayGainPolicy.effectiveMode(playbackSettings.replayGainMode, song: song, queue: queue, shuffled: shuffleEnabled)
        scheduleReplayGainAnalysis(for: song, mode: mode, album: replayGainAlbumSongs(for: song), url: nil, upcoming: upcoming)
    }

    private func scheduleReplayGainAnalysis(for song: Song, mode: ReplayGainMode, album: [Song], url: URL?, upcoming: [Song]? = nil) {
        guard let sourceManager, ReplayGainAnalysisService.supports(song),
              !isSystemMediaPlaybackActive, !isAppleMusicMode, !isLiveRadio, !isCastingMode else {
            cancelReplayGainAnalysis()
            return
        }
        let next = upcoming ?? nextSongsInQueue(count: UpcomingPlaybackPrefetchPolicy.plannedSongCount(
            configured: playbackSettings.prewarmQueueCount,
            isMeteredNetwork: NetworkMonitor.shared.isExpensive || NetworkMonitor.shared.isConstrained
        ))
        let songs = ReplayGainPolicy.analysisPlan(current: song, upcoming: next, album: album, mode: mode,
                                                 contentKind: { SpokenWordStore.shared.kind(for: $0) })
            .filter { $0.sourceID != AppleMusicLibraryService.systemSourceID }
        let identity = songs.map { ReplayGainAnalysisCache.key(for: $0) }.joined(separator: ":")
        guard replayGainAnalysisIdentity != identity else { return }
        replayGainAnalysisTask?.cancel()
        replayGainAnalysisIdentity = identity
        var knownFiles: [String: URL] = [:]
        for item in songs {
            if let local = sourceManager.cachedPlaybackURL(for: item) { knownFiles[ReplayGainAnalysisCache.key(for: item)] = local }
        }
        if let url, url.isFileURL { knownFiles[ReplayGainAnalysisCache.key(for: song)] = url }
        let files = knownFiles
        replayGainAnalysisTask = Task(priority: .utility) {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await ReplayGainAnalysisService.shared.prepare(songs, knownFiles: files) { item in
                    try Task.checkCancellation()
                    if item.id == song.id, let url, url.isFileURL { return KaraokeAudioFile(url: url) }
                    if let local = await sourceManager.cachedURLForBackgroundRead(for: item)
                        ?? sourceManager.cachedPlaybackURL(for: item) {
                        return KaraokeAudioFile(url: local)
                    }
                    if let local = await sourceManager.directLocalFileURL(for: item) { return KaraokeAudioFile(url: local) }
                    return nil
                }
            } catch {
                if !(error is CancellationError) { plog("ReplayGain analysis unavailable: \(type(of: error))") }
            }
            // Keep unavailable files from being retried on every gain resolution.
        }
    }
}

/// ReplayGain tags read from local files, keyed by path and invalidated when
/// the file's size or modification date changes. Songs whose library row has
/// no ReplayGain values otherwise pay a full metadata read on every start,
/// seek and transition.
@MainActor
final class ReplayGainFileTagCache {
    static let shared = ReplayGainFileTagCache()

    struct Tags: Sendable {
        var trackGain: Double?
        var trackPeak: Double?
        var albumGain: Double?
        var albumPeak: Double?
    }

    private struct FileVersion: Equatable {
        let size: Int64?
        let modified: Date?
    }

    private struct Entry {
        let version: FileVersion
        let tags: Tags
    }

    private struct PendingRead {
        let id: UUID
        let version: FileVersion
        let task: Task<Tags, Never>
    }

    private static let capacity = 1024
    private var entries: [String: Entry] = [:]
    private var pending: [String: PendingRead] = [:]

    func tags(for url: URL) async -> Tags {
        guard url.isFileURL else { return await Self.read(url) }
        let key = url.standardizedFileURL.path
        let version = Self.version(of: url)
        if let entry = entries[key], entry.version == version {
            return entry.tags
        }
        if let read = pending[key], read.version == version {
            return await read.task.value
        }
        let read = PendingRead(
            id: UUID(),
            version: version,
            task: Task { await Self.read(url) }
        )
        pending[key] = read
        let tags = await read.task.value
        if pending[key]?.id == read.id {
            pending[key] = nil
        }
        if entries.count >= Self.capacity {
            entries.removeAll(keepingCapacity: true)
        }
        entries[key] = Entry(version: version, tags: tags)
        return tags
    }

    private nonisolated static func read(_ url: URL) async -> Tags {
        let metadata = await FileMetadataReader.read(from: url)
        return Tags(
            trackGain: metadata.replayGainTrackGain,
            trackPeak: metadata.replayGainTrackPeak,
            albumGain: metadata.replayGainAlbumGain,
            albumPeak: metadata.replayGainAlbumPeak
        )
    }

    private static func version(of url: URL) -> FileVersion {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return FileVersion(
            size: (attributes?[.size] as? NSNumber)?.int64Value,
            modified: attributes?[.modificationDate] as? Date
        )
    }
}

/// The most recent ReplayGain resolution started for a play, so gapless
/// preparation can wait for the audible song's gain instead of reading a
/// node volume that is about to change.
@MainActor
final class ReplayGainResolutionLedger {
    static let shared = ReplayGainResolutionLedger()

    private struct Record {
        let playID: UUID
        let songID: String
        let task: Task<AudioPlayerService.ReplayGainValues, Never>
    }

    private var latest: Record?

    func record(
        _ task: Task<AudioPlayerService.ReplayGainValues, Never>,
        playID: UUID,
        songID: String
    ) {
        latest = Record(playID: playID, songID: songID, task: task)
    }

    func resolution(
        playID: UUID,
        songID: String
    ) -> Task<AudioPlayerService.ReplayGainValues, Never>? {
        guard let latest, latest.playID == playID, latest.songID == songID else { return nil }
        return latest.task
    }
}
