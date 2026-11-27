import Foundation

/// How gapless playback crosses into the next song when the output may follow
/// each song's sample rate.
public enum ContinuousTransitionPlan: Equatable, Sendable {
    /// Queue the next song on the running graph, decoded at the graph's rate.
    case seamless
    /// Decode the start of the next song at the rate the device will switch
    /// to, then switch the device and rebuild the graph at the boundary.
    case sampleRateHandoff(targetSampleRate: Double)
    /// No continuous transition: the next song starts like any other play.
    case restart

    public var isSampleRateHandoff: Bool {
        if case .sampleRateHandoff = self { return true }
        return false
    }
}

/// Decides between a seamless join, a prepared sample-rate handoff and a full
/// restart. Switching the device always costs a short silence while it
/// reclocks, so the effects graph — which can resample — keeps one album
/// continuous unless the listener asks for a switch inside albums too. The
/// direct graph cannot resample and always switches.
public enum ContinuousTransitionSampleRatePolicy {
    public struct AlbumKey: Equatable, Sendable {
        public var albumID: String?
        public var albumTitle: String?
        public var albumArtist: String?

        public init(albumID: String?, albumTitle: String?, albumArtist: String?) {
            self.albumID = albumID
            self.albumTitle = albumTitle
            self.albumArtist = albumArtist
        }
    }

    /// Album ids decide when both rows have one; otherwise the album title
    /// and album artist must agree. A row without an album title belongs to
    /// no album.
    public static func isSameAlbum(_ lhs: AlbumKey, _ rhs: AlbumKey) -> Bool {
        if let lhsID = normalized(lhs.albumID), let rhsID = normalized(rhs.albumID) {
            return lhsID == rhsID
        }
        guard let lhsTitle = normalized(lhs.albumTitle),
              let rhsTitle = normalized(rhs.albumTitle),
              lhsTitle == rhsTitle else { return false }
        return normalized(lhs.albumArtist) == normalized(rhs.albumArtist)
    }

    /// - Parameters:
    ///   - followsSourceSampleRate: the output asks the device for each
    ///     song's rate (always on the direct graph).
    ///   - graphSampleRate: the rate the running graph renders at.
    ///   - nextHardwareSampleRate: the rate the device will report after the
    ///     next song's rate is requested; the current rate when no request
    ///     would be made (unsupported rate, wireless route).
    public static func plan(
        isHighFidelity: Bool,
        followsSourceSampleRate: Bool,
        involvesDSD: Bool,
        currentSourceSampleRate: Double?,
        nextSourceSampleRate: Double?,
        graphSampleRate: Double?,
        nextHardwareSampleRate: Double?,
        isSameAlbum: Bool,
        switchesWithinAlbum: Bool
    ) -> ContinuousTransitionPlan {
        // DoP carriers and DSD-to-PCM rates need the full start path on the
        // direct graph; the effects graph decodes DSD to its own rate.
        if involvesDSD { return isHighFidelity ? .restart : .seamless }
        guard followsSourceSampleRate else { return .seamless }
        guard let next = valid(nextSourceSampleRate) else {
            // Nothing to prepare for. The direct graph keeps its old rule:
            // only two equally unknown rates stay continuous.
            return isHighFidelity && valid(currentSourceSampleRate) != nil ? .restart : .seamless
        }
        guard let graph = valid(graphSampleRate),
              let hardware = valid(nextHardwareSampleRate) else {
            if let current = valid(currentSourceSampleRate),
               abs(current - next) < DirectPCMOutputSampleRatePolicy.matchTolerance {
                return .seamless
            }
            return isHighFidelity ? .restart : .seamless
        }
        // The device would stay where it is, so there is nothing to switch.
        if abs(hardware - graph) < DirectPCMOutputSampleRatePolicy.matchTolerance {
            return .seamless
        }
        if !isHighFidelity, isSameAlbum, !switchesWithinAlbum { return .seamless }
        return .sampleRateHandoff(targetSampleRate: hardware)
    }

    private static func valid(_ sampleRate: Double?) -> Double? {
        guard let sampleRate,
              sampleRate.isFinite,
              sampleRate >= DirectPCMOutputSampleRatePolicy.minimumSampleRate,
              sampleRate <= DirectPCMOutputSampleRatePolicy.maximumSampleRate else { return nil }
        return sampleRate
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let folded = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.isEmpty ? nil : folded
    }
}

/// Timing of a sample-rate handoff: how much of the next song is decoded
/// before the switch, and how far into the outgoing song's closing silence
/// the switch may begin so the device reclocks while nothing is audible.
public enum SampleRateHandoffTimingPolicy {
    /// Decoded audio held for the next song, so playback resumes from memory
    /// while its decoder catches up after the switch. All three limits stay
    /// under the player's decoded-buffer gate (8 s, 32 MiB, 384 buffers):
    /// the held audio is scheduled through that gate before playback starts,
    /// when nothing can be released yet.
    public static let prerollDuration: TimeInterval = 2
    public static let maximumPrerollBytes = 24 * 1024 * 1024
    public static let maximumPrerollBufferCount = 256
    /// Closing silence shorter than this is not worth moving the switch for.
    public static let minimumTrailingSilence: TimeInterval = 0.15
    /// Kept before the switch so a decay that only just fell below the
    /// silence threshold is not clipped.
    public static let silenceOnsetGuard: TimeInterval = 0.05
    /// Enough to cover a typical device reclock without trimming a long,
    /// deliberate silence at the end of a song.
    public static let maximumLead: TimeInterval = 1

    public static func prerollIsComplete(
        heldDuration: TimeInterval,
        heldBytes: Int,
        heldBufferCount: Int
    ) -> Bool {
        heldDuration >= prerollDuration
            || heldBytes >= maximumPrerollBytes
            || heldBufferCount >= maximumPrerollBufferCount
    }

    /// How long before the song's last sample the switch may start.
    public static func switchLead(trailingSilence: TimeInterval) -> TimeInterval {
        guard trailingSilence.isFinite, trailingSilence >= minimumTrailingSilence else { return 0 }
        return min(trailingSilence - silenceOnsetGuard, maximumLead)
    }

    /// The node-timeline frame at which the switch may start, or nil when it
    /// has to wait for the song to end.
    public static func switchFrame(
        boundaryFrame: Int64,
        trailingSilentFrames: Int64,
        sampleRate: Double
    ) -> Int64? {
        guard boundaryFrame > 0,
              trailingSilentFrames > 0,
              sampleRate.isFinite,
              sampleRate > 0 else { return nil }
        let silentFrames = min(trailingSilentFrames, boundaryFrame)
        let lead = switchLead(trailingSilence: Double(silentFrames) / sampleRate)
        let leadFrames = Int64((lead * sampleRate).rounded(.down))
        guard leadFrames > 0 else { return nil }
        return boundaryFrame - leadFrames
    }
}
