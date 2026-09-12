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

    private struct ReplayGainValues {
        var gain: Double?
        var peak: Double?

        var hasValue: Bool {
            gain != nil || peak != nil
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
        let storedValues = replayGainValues(from: song, mode: mode)
        if storedValues.hasValue {
            audioEngine.applyReplayGain(gain: storedValues.gain, peak: storedValues.peak)
            return
        }

        guard allowFileRead else {
            audioEngine.applyReplayGain(gain: nil, peak: nil)
            return
        }

        let metadata = await FileMetadataReader.read(from: url)
        guard expectedPlayID == nil || playID == expectedPlayID,
              expectedSongID == nil || currentSong?.id == expectedSongID else { return }
        let values = replayGainValues(from: metadata, mode: mode)
        audioEngine.applyReplayGain(gain: values.gain, peak: values.peak)
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
