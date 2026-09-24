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

    struct ReplayGainValues: Sendable {
        var gain: Double?
        var peak: Double?

        var hasValue: Bool {
            gain != nil || peak != nil
        }
    }

    /// The largest boost the equalizer currently adds, in dB. ReplayGain keeps
    /// that much headroom when it raises a quiet track. Read when a track
    /// starts, seeks or is prepared; dragging an EQ band mid-song does not
    /// re-evaluate the current track.
    var equalizerBoostDB: Double {
        guard equalizerService.isEnabled else { return 0 }
        return Double(max(0, equalizerService.bands.max() ?? 0))
    }

    /// The node volume a song should play at: its ReplayGain volume, or unity
    /// when the values carry no gain.
    func programVolume(for values: ReplayGainValues) -> Float {
        ReplayGainPolicy.linearGain(
            gainDB: values.gain,
            peak: values.peak,
            equalizerBoostDB: equalizerBoostDB
        )
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
        let storedValues = replayGainValues(from: song, mode: mode)
        if storedValues.hasValue || !allowFileRead {
            return storedValues
        }
        let tags = await ReplayGainFileTagCache.shared.tags(for: url)
        return replayGainValues(from: tags, mode: mode)
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
        withObservationTracking {
            _ = playbackSettings.replayGainEnabled
            _ = playbackSettings.replayGainMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.shouldRebuildForReplayGainChange {
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
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: song.replayGainTrackGain,
                peak: song.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: song.replayGainAlbumGain ?? song.replayGainTrackGain,
                peak: song.replayGainAlbumPeak ?? song.replayGainTrackPeak
            )
        }
    }

    private func replayGainValues(
        from tags: ReplayGainFileTagCache.Tags,
        mode: ReplayGainMode
    ) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(gain: tags.trackGain, peak: tags.trackPeak)
        case .album:
            return ReplayGainValues(
                gain: tags.albumGain ?? tags.trackGain,
                peak: tags.albumPeak ?? tags.trackPeak
            )
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
