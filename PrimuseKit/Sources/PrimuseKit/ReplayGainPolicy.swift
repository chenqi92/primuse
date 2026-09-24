import Foundation

/// Turns ReplayGain tags into player-node volumes and keeps a crossfade on
/// those volumes, so a transition never passes through unity gain on either
/// side. Volumes are linear amplitude multipliers, the unit AVAudioPlayerNode
/// works in.
public enum ReplayGainPolicy {
    /// +12 dB. No sane ReplayGain tag asks for more; the cap keeps a corrupt
    /// tag from turning the node into a distortion pedal.
    public static let maximumLinearGain: Float = 4

    /// Linear volume for a ReplayGain tag. No tag, or a non-finite one, means
    /// unity. A positive gain is capped at `1 / peak` so the loudest sample of
    /// the track still fits below full scale.
    ///
    /// `equalizerBoostDB` is the largest boost the equalizer after the player
    /// node adds. Tag gain above unity is additionally held back so that boost
    /// still fits below full scale, but it never pulls a track below unity:
    /// without ReplayGain the equalizer would clip that track just the same.
    public static func linearGain(
        gainDB: Double?,
        peak: Double?,
        equalizerBoostDB: Double = 0
    ) -> Float {
        guard let gainDB, gainDB.isFinite else { return 1 }
        var linear = pow(10.0, gainDB / 20.0)
        if let peak, peak.isFinite, peak > 0 {
            linear = min(linear, 1.0 / peak)
            if linear > 1, equalizerBoostDB.isFinite, equalizerBoostDB > 0 {
                let boost = pow(10.0, equalizerBoostDB / 20.0)
                linear = max(1, min(linear, 1.0 / (peak * boost)))
            }
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
