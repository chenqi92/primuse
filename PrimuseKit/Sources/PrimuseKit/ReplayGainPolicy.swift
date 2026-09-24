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
    public static func linearGain(gainDB: Double?, peak: Double?) -> Float {
        guard let gainDB, gainDB.isFinite else { return 1 }
        var linear = pow(10.0, gainDB / 20.0)
        if let peak, peak.isFinite, peak > 0 {
            linear = min(linear, 1.0 / peak)
        }
        let clamped = max(0.0, min(linear, Double(maximumLinearGain)))
        return Float(clamped)
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
