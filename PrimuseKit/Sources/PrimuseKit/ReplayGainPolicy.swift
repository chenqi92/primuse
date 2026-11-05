import Foundation

public enum ReplayGainMode: String, Codable, Sendable, CaseIterable {
    case automatic, track, album

    public var localizationKey: String { "rg_mode_\(rawValue)" }
}

public struct ReplayGainAdjustment: Equatable, Sendable {
    public var gain: Double?
    public var peak: Double?

    public init(gain: Double? = nil, peak: Double? = nil) {
        self.gain = gain?.isFinite == true ? gain : nil
        self.peak = peak?.isFinite == true && (peak ?? 0) > 0 ? peak : nil
    }

    public var hasValue: Bool { gain != nil }
}

public struct ReplayGainPlaybackSnapshot: Equatable, Sendable {
    public enum Origin: Equatable, Sendable { case tags, analysis }
    public let mode: ReplayGainMode
    public let values: ReplayGainAdjustment
    public let origin: Origin

    public init(mode: ReplayGainMode, values: ReplayGainAdjustment, origin: Origin) {
        self.mode = mode
        self.values = values
        self.origin = origin
    }
}

public struct ReplayGainPlaybackInfo: Equatable, Sendable {
    public let enabled: Bool
    public let supported: Bool
    public let snapshot: ReplayGainPlaybackSnapshot?
    public let preampDB: Double

    public init(enabled: Bool, supported: Bool = true, snapshot: ReplayGainPlaybackSnapshot? = nil, preampDB: Double = 0) {
        self.enabled = enabled
        self.supported = supported
        self.snapshot = snapshot
        self.preampDB = ReplayGainPolicy.sanitizedPreamp(preampDB)
    }

    public var isActive: Bool { enabled && supported && snapshot?.values.hasValue == true }
    public var showsBadge: Bool { enabled && supported }

    /// This is the steady programme gain, independent of crossfade envelopes
    /// and the hardware volume. A newly cached analysis is not an active gain.
    public var appliedGainDB: Double? {
        guard isActive, let snapshot else { return nil }
        let linear = ReplayGainPolicy.linearGain(gainDB: snapshot.values.gain, peak: snapshot.values.peak, preampDB: preampDB)
        return linear > 0 ? 20 * log10(Double(linear)) : nil
    }

    public var isPeakLimited: Bool {
        guard isActive, let values = snapshot?.values, let gain = values.gain, let peak = values.peak else { return false }
        return pow(10, (gain + preampDB) / 20) > 1 / peak
    }
}

/// Turns ReplayGain tags into player-node volumes and keeps a crossfade on
/// those volumes, so a transition never passes through unity gain on either
/// side. Volumes are linear amplitude multipliers, the unit AVAudioPlayerNode
/// works in.
public enum ReplayGainPolicy {
    public static let preampRange = -12.0...12.0

    public static func sanitizedPreamp(_ value: Double) -> Double {
        value.isFinite ? min(preampRange.upperBound, max(preampRange.lowerBound, value)) : 0
    }

    public static func albumKey(for song: Song) -> String? {
        guard let title = song.albumTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return [song.sourceID, song.albumID ?? title, song.albumArtistName ?? ""].joined(separator: "\u{1f}")
    }

    public static func effectiveMode(_ mode: ReplayGainMode, song: Song, queue: [Song], shuffled: Bool) -> ReplayGainMode {
        guard mode == .automatic else { return mode }
        guard !shuffled, queue.count > 1, let key = albumKey(for: song),
              queue.allSatisfy({ albumKey(for: $0) == key }) else { return .track }
        return .album
    }

    public static func adjustment(for song: Song, mode: ReplayGainMode) -> ReplayGainAdjustment {
        if mode == .album, let gain = song.replayGainAlbumGain, gain.isFinite {
            return .init(gain: gain, peak: song.replayGainAlbumPeak ?? song.replayGainTrackPeak)
        }
        return .init(gain: song.replayGainTrackGain, peak: song.replayGainTrackPeak)
    }

    /// Prepare the imminent songs first; album completion must not hold up
    /// the next track. Keep CUE tracks distinct even when they share a file.
    public static func analysisPlan(current: Song, upcoming: [Song], album: [Song], mode: ReplayGainMode) -> [Song] {
        var seen = Set<String>()
        return (upcoming + [current] + (mode == .album ? album : [])).filter { song in
            let itemMode: ReplayGainMode = albumKey(for: song) == albumKey(for: current) ? mode : .track
            return seen.insert(ReplayGainAnalysisCache.key(for: song)).inserted
                && !song.isStreamDescriptor
                && !adjustment(for: song, mode: itemMode).hasValue
        }
    }

    /// +12 dB. No sane ReplayGain tag asks for more; the cap keeps a corrupt
    /// tag from turning the node into a distortion pedal.
    public static let maximumLinearGain: Float = 4

    /// Linear volume for a ReplayGain tag. No tag, or a non-finite one, means
    /// unity. A positive gain is capped at `1 / peak` so the loudest sample of
    /// the track still fits below full scale. The equalizer after the player
    /// node lowers its own level by its boost (`EqualizerHeadroomPolicy`), so
    /// no headroom is held back for it here.
    public static func linearGain(gainDB: Double?, peak: Double?, preampDB: Double = 0) -> Float {
        guard let gainDB, gainDB.isFinite else { return 1 }
        var linear = pow(10.0, (gainDB + sanitizedPreamp(preampDB)) / 20.0)
        if let peak, peak.isFinite, peak > 0 {
            linear = min(linear, 1.0 / peak)
        }
        let clamped = max(0.0, min(linear, Double(maximumLinearGain)))
        return Float(clamped)
    }

    /// Factor a gapless successor's decoded samples are multiplied by.
    ///
    /// A gapless successor shares the player node with the song before it, and
    /// the boundary is only observed after the old song's last buffer has been
    /// heard, so changing the node volume there lets the new song start at the
    /// old song's gain. Scaling the successor's samples by `target / nodeVolume`
    /// makes it sound at its own gain from its first sample while the node
    /// volume stays put. Returns nil when no scaling is needed.
    public static func gaplessSampleScale(
        targetVolume: Float,
        nodeVolume: Float
    ) -> Float? {
        guard targetVolume.isFinite, nodeVolume.isFinite, nodeVolume > 0 else { return nil }
        let scale = max(0, targetVolume) / nodeVolume
        guard abs(scale - 1) > 0.0005 else { return nil }
        return scale
    }

    public struct CrossfadeVolumes: Equatable, Sendable {
        public let outgoing: Float
        public let incoming: Float

        public init(outgoing: Float, incoming: Float) {
            self.outgoing = outgoing
            self.incoming = incoming
        }
    }

    /// One step of an equal-power crossfade, scaled by each side's own program
    /// volume. At progress 0 the outgoing song plays at its program volume and
    /// the incoming one is silent; at progress 1 the roles are reversed, so the
    /// node swap that follows changes nothing audible.
    public static func crossfadeVolumes(
        progress: Double,
        outgoingGain: Float,
        incomingGain: Float
    ) -> CrossfadeVolumes {
        let clamped = progress.isFinite ? max(0.0, min(progress, 1.0)) : 1.0
        let angle = clamped * .pi / 2
        return CrossfadeVolumes(
            outgoing: outgoingGain * Float(cos(angle)),
            incoming: incomingGain * Float(sin(angle))
        )
    }
}
