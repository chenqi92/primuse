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
        audioEngine.applyProgramVolume(programVolume(for: values))
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
        let mode = ReplayGainPolicy.effectiveMode(mode, song: song, queue: queue, shuffled: shuffleEnabled)
        let storedValues = replayGainValues(from: song, mode: mode)
        var values: ReplayGainValues
        var origin: String
        if storedValues.hasValue {
            values = storedValues
            origin = "library"
        } else if !allowFileRead {
            values = storedValues
            origin = "none (streamed; file not read)"
        } else {
            let tags = await ReplayGainFileTagCache.shared.tags(for: url)
            values = replayGainValues(from: tags, mode: mode)
            origin = values.hasValue ? "file" : "none (no tags in file)"
        }
        if !values.hasValue {
            let album = replayGainAlbumSongs(for: song)
            values = await ReplayGainAnalysisService.cachedAdjustment(for: song, mode: mode, album: album, url: url)
            if values.hasValue { origin = "analysis" }
            if currentSong?.id == song.id, shouldApplyReplayGain(playbackSettings.snapshot()) {
                scheduleReplayGainAnalysis(for: song, mode: mode, album: album, url: allowFileRead ? url : nil)
            }
        }
        // Answers "ReplayGain does nothing for this song" from a log: which
        // values were used, where they came from, and the volume they gave.
        let gain = values.gain.map { String(format: "%+.2f dB", $0) } ?? "-"
        let peak = values.peak.map { String(format: "%.6f", $0) } ?? "-"
        let volume = String(format: "%.3f", programVolume(for: values))
        plog("🎚️ ReplayGain '\(song.title)' mode=\(mode.rawValue) source=\(origin) gain=\(gain) peak=\(peak) volume=×\(volume)")
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
        let oldEnabled = playbackSettings.replayGainEnabled
        let oldPreamp = playbackSettings.replayGainPreampDB
        let oldMode = currentSong.map { ReplayGainPolicy.effectiveMode(playbackSettings.replayGainMode, song: $0, queue: queue, shuffled: shuffleEnabled) }
        withObservationTracking {
            _ = playbackSettings.replayGainEnabled
            _ = playbackSettings.replayGainMode
            _ = playbackSettings.replayGainPreampDB
            _ = shuffleEnabled
            _ = queueEntries
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newMode = self.currentSong.map { ReplayGainPolicy.effectiveMode(self.playbackSettings.replayGainMode, song: $0, queue: self.queue, shuffled: self.shuffleEnabled) }
                let changed = oldEnabled != self.playbackSettings.replayGainEnabled
                    || oldPreamp != self.playbackSettings.replayGainPreampDB || oldMode != newMode
                if changed {
                    self.replayGainAnalysisTask?.cancel()
                    self.replayGainAnalysisTask = nil
                    self.replayGainAnalysisIdentity = nil
                }
                if changed && self.shouldRebuildForReplayGainChange {
                    self.seek(to: self.currentTime, startPlaying: self.isPlaying)
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
        let album = candidates.filter { ReplayGainPolicy.albumKey(for: $0) == key }
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

    private func scheduleReplayGainAnalysis(for song: Song, mode: ReplayGainMode, album: [Song], url: URL?) {
        guard let sourceManager, !isSystemMediaPlaybackActive, !isAppleMusicMode,
              !isLiveRadio, !isCastingMode, song.duration > 0 else { return }
        let songs = mode == .album ? album : [song]
        let identity = songs.map { ReplayGainAnalysisCache.key(for: $0) }.joined(separator: ":")
        guard replayGainAnalysisIdentity != identity else { return }
        replayGainAnalysisTask?.cancel()
        replayGainAnalysisIdentity = identity
        let id = playID
        replayGainAnalysisTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                var changed = false
                for item in songs {
                    try Task.checkCancellation()
                    let local = item.id == song.id && url?.isFileURL == true ? url : nil
                    if await ReplayGainAnalysisCache.shared.measurement(for: item, fileURL: local) != nil { continue }
                    do {
                        let file: KaraokeAudioFile
                        if let local { file = KaraokeAudioFile(url: local) }
                        else { file = try await KaraokeSeparationService.sourceAudioFile(for: item, sourceManager: sourceManager) }
                        defer { if file.removeAfterDecoding { try? FileManager.default.removeItem(at: file.url) } }
                        _ = try await ReplayGainAnalysisService.shared.analyze(item, url: file.url)
                        changed = true
                    } catch {
                        try Task.checkCancellation()
                        plog("ReplayGain album member unavailable: \(type(of: error))")
                    }
                }
                try Task.checkCancellation()
                guard let self, self.playID == id, self.currentSong?.id == song.id,
                      self.shouldApplyReplayGain(self.playbackSettings.snapshot()) else { return }
                // Rebuild at the current position so prepared gapless samples
                // never retain the previous gain. A running crossfade finishes
                // on its captured gains; the cached result applies next time.
                if changed, !self.isLoading, !self.isCrossfading {
                    self.seek(to: self.currentTime, startPlaying: self.isPlaying)
                }
            } catch {
                if !(error is CancellationError) { plog("ReplayGain analysis unavailable: \(type(of: error))") }
            }
            // Retain the identity until selection/settings change: a failed
            // source must not be downloaded again on every gain resolution.
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
