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

        /// The player-node volume these tags ask for; unity without a gain.
        var linearGain: Float {
            ReplayGainPolicy.linearGain(gainDB: gain, peak: peak)
        }
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
        let values = await resolveReplayGainValues(
            for: song,
            url: url,
            mode: mode,
            allowFileRead: allowFileRead
        )
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        audioEngine.applyReplayGain(gain: values.gain, peak: values.peak)
    }

    /// The library row answers first. A local file is opened only when the
    /// row carries no ReplayGain tags at all (older scans, or tags written
    /// after the scan); streams never read the file.
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
        let metadata = await FileMetadataReader.read(from: url)
        return replayGainValues(from: metadata, mode: mode)
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

    private func replayGainValues(from metadata: FileMetadataReader.Metadata, mode: ReplayGainMode) -> ReplayGainValues {
        switch mode {
        case .track:
            return ReplayGainValues(
                gain: metadata.replayGainTrackGain,
                peak: metadata.replayGainTrackPeak
            )
        case .album:
            return ReplayGainValues(
                gain: metadata.replayGainAlbumGain ?? metadata.replayGainTrackGain,
                peak: metadata.replayGainAlbumPeak ?? metadata.replayGainTrackPeak
            )
        }
    }
}
