import Foundation
import PrimuseKit

/// Per-song playback ranges ("播放时间段") in the player.
///
/// A range keeps the song's timeline. The copy the player plays carries it
/// (`Song.appliedPlaybackRange`): the copy's length is the range end, the
/// decoders trim to `Song.playbackMediaWindow`, the engine clock starts at the
/// range start (`AudioEngine.timelineOrigin`) and seeks stay inside the range.
/// Lyrics, karaoke stems and Now Playing therefore keep reading song time, and
/// reaching the range end is the song's end: the queue advances, gapless and
/// crossfade prepare against it, repeat-one plays the range again.
extension AudioPlayerService {
    /// `song` as the player plays it: inside its playback range when one is
    /// on, otherwise whole. Idempotent — a copy that already carries a range
    /// is re-derived from the whole song.
    func songApplyingPlaybackRange(_ song: Song) -> Song {
        // A medley slice is already a window chosen by the medley.
        guard !medleySongIDs.contains(song.id) else { return song }
        let whole = song.withoutAppliedPlaybackRange
        guard canApplyPlaybackRange(to: whole) else { return whole }
        var measured = whole
        // The library may have learned the real length since this copy was taken.
        if let latest = library?.song(id: whole.id)?.duration, latest > 0 {
            measured.duration = latest
        }
        return whole.playing(SongPlaybackRangeStore.shared.applied(for: measured))
    }

    /// Ranges apply to songs this player decodes itself; a song's music
    /// video and casting play through players that know nothing of them.
    func canApplyPlaybackRange(to song: Song) -> Bool {
        SongPlaybackRangeAvailability.supports(song)
            && !(isMusicVideoModeEnabled && song.mvPath != nil)
            && !isCastingMode
    }

    /// Where the current song's timeline starts playing: its range start, or 0.
    var currentPlaybackRangeStart: TimeInterval {
        currentSong?.appliedPlaybackRange?.start ?? 0
    }

    /// Keeps a seek on the current song inside its playback range.
    func playbackRangeClampedSeekTarget(_ target: TimeInterval) -> TimeInterval {
        guard let applied = currentSong?.appliedPlaybackRange else { return target }
        return SongPlaybackRangePolicy.clampedSeekTarget(target, in: applied)
    }

    func observePlaybackRangeChanges() {
        NotificationCenter.default.addObserver(
            forName: .primuseSongPlaybackRangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let songIDs = notification.userInfo?["songIDs"] as? Set<String>
            Task { @MainActor [weak self] in
                guard let self, let current = self.currentSong else { return }
                if let songIDs, !songIDs.contains(current.id) { return }
                // The editor writes on every nudge; re-cutting the stream once
                // the listener pauses keeps the audio from stuttering per tap.
                self.playbackRangeRefreshTask?.cancel()
                self.playbackRangeRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    self?.refreshCurrentSongPlaybackRange()
                }
            }
        }
    }

    /// Re-applies the current song's range after it was edited, switched or
    /// cleared. The position is kept when it is still inside; otherwise the
    /// song continues from the range start. The seek rebuilds the decoder, so
    /// the new end takes effect at once.
    func refreshCurrentSongPlaybackRange() {
        guard let current = currentSong,
              !isLiveRadio, !isAppleMusicMode, !isCastingMode, !isSystemMediaPlaybackActive,
              !isMedleyActive else { return }
        let updated = songApplyingPlaybackRange(current)
        guard updated.appliedPlaybackRange != current.appliedPlaybackRange else { return }
        let position = currentTime
        currentSong = updated
        duration = updated.duration.sanitizedDuration
        let target: TimeInterval
        if let applied = updated.appliedPlaybackRange {
            target = SongPlaybackRangePolicy.startPosition(requested: position, in: applied)
        } else {
            target = position
        }
        plog("✂️ Playback range for '\(updated.title)' → \(updated.appliedPlaybackRange.map { "\(Int($0.start))-\(Int($0.end))s" } ?? "whole song"), resuming at \(Int(target))s")
        if isLoading && !hasPreparedLocalPlayback {
            // Still opening: restart on the new window instead of seeking a
            // decoder that does not exist yet.
            Task { await play(song: updated) }
            return
        }
        seek(to: target)
    }
}

/// Which songs can have a playback range: the ones the app decodes itself.
/// Apple Music plays through the system player and a standalone music video
/// through AVPlayer; spoken word keeps its own resume positions instead.
enum SongPlaybackRangeAvailability {
    @MainActor
    static func supports(_ song: Song) -> Bool {
        song.sourceID != AppleMusicLibraryService.systemSourceID
            && !song.isStandaloneMusicVideo
            && !PodcastPlaybackSong.isEpisode(song)
            && !SpokenWordStore.shared.isSpokenWord(song)
    }
}
