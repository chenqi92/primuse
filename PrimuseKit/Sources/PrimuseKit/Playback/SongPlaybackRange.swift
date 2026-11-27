import Foundation

/// The part of a song the listener chose to hear instead of the whole song
/// ("播放时间段"). Times are on the song's own timeline: seconds from the start
/// of the track, which for a CUE track is its start inside the image.
public struct SongPlaybackRange: Codable, Hashable, Sendable {
    public var start: TimeInterval
    public var end: TimeInterval
    /// Off keeps the range for later without applying it.
    public var isEnabled: Bool

    public init(start: TimeInterval, end: TimeInterval, isEnabled: Bool) {
        self.start = start
        self.end = end
        self.isEnabled = isEnabled
    }

    public var length: TimeInterval { max(0, end - start) }
}

/// A playback range as it applies to one song of known length: what a player
/// plays when it plays that song.
public struct AppliedSongPlaybackRange: Hashable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// The song's whole length, so a playing copy can be turned back into the
    /// whole song.
    public let songDuration: TimeInterval

    public init(start: TimeInterval, end: TimeInterval, songDuration: TimeInterval) {
        self.start = start
        self.end = end
        self.songDuration = songDuration
    }

    public var length: TimeInterval { max(0, end - start) }
}

/// Rules shared by the players and the editors for a song's playback range.
///
/// A range keeps the song's timeline: playback opens at the range start, the
/// clock and the lyrics read song time, and reaching the range end is the
/// song's end — the queue advances, repeat-one plays the range again.
public enum SongPlaybackRangePolicy {
    /// Shortest range the editors allow and the players honour.
    public static let minimumLength: TimeInterval = 2
    /// Handles snap to this while dragged; nudges and "here" are finer.
    public static let dragStep: TimeInterval = 1
    public static let nudgeStep: TimeInterval = 1
    /// A range edge this close to the song's edge counts as that edge.
    static let edgeTolerance: TimeInterval = 0.05

    /// What a player applies to a song `songDuration` long, or nil when it
    /// plays the whole song: the range is off, the length is unknown, or the
    /// range covers the whole song or does not fit in it.
    public static func applied(
        _ range: SongPlaybackRange?,
        songDuration: TimeInterval
    ) -> AppliedSongPlaybackRange? {
        guard let range, range.isEnabled,
              range.start.isFinite, range.end.isFinite,
              songDuration.isFinite, songDuration > 0 else { return nil }
        let start = min(max(0, range.start), songDuration)
        let end = min(range.end, songDuration)
        guard end - start >= minimumLength else { return nil }
        guard start > edgeTolerance || end < songDuration - edgeTolerance else { return nil }
        return AppliedSongPlaybackRange(start: start, end: end, songDuration: songDuration)
    }

    /// The range a new editor opens with: the whole song.
    public static func initialRange(songDuration: TimeInterval) -> SongPlaybackRange {
        SongPlaybackRange(start: 0, end: max(0, songDuration.isFinite ? songDuration : 0), isEnabled: false)
    }

    public enum Edge: Sendable {
        case start
        case end
    }

    /// Moves one edge to `value`, keeping both inside the song and at least
    /// `minimumLength` apart. The moved edge gives way, never the other one.
    public static func moving(
        _ edge: Edge,
        of range: SongPlaybackRange,
        to value: TimeInterval,
        songDuration: TimeInterval
    ) -> SongPlaybackRange {
        let duration = songDuration.isFinite ? max(0, songDuration) : 0
        let target = value.isFinite ? value : 0
        var result = range
        switch edge {
        case .start:
            let upper = max(0, min(range.end, duration) - minimumLength)
            result.start = min(max(0, target), upper)
        case .end:
            let lower = min(duration, max(0, range.start) + minimumLength)
            result.end = max(min(duration, target), lower)
        }
        return result
    }

    /// Where a seek lands in a ranged song: inside the range.
    public static func clampedSeekTarget(
        _ target: TimeInterval,
        in applied: AppliedSongPlaybackRange
    ) -> TimeInterval {
        let finite = target.isFinite ? target : applied.start
        return min(max(applied.start, finite), applied.end)
    }

    /// Where a ranged song starts when it is (re)opened at `requested`: a
    /// resume point inside the range is kept, anything else starts the range.
    public static func startPosition(
        requested: TimeInterval,
        in applied: AppliedSongPlaybackRange
    ) -> TimeInterval {
        guard requested.isFinite,
              requested >= applied.start,
              requested < applied.end - 1 else { return applied.start }
        return requested
    }

    /// "1:05", "1:02:03"; with `showsTenths`, "1:05.4" when the time is not
    /// on a whole second.
    public static func timeLabel(_ time: TimeInterval, showsTenths: Bool = false) -> String {
        let finite = time.isFinite ? max(0, time) : 0
        let tenths = Int((finite * 10).rounded())
        let wholeSeconds = showsTenths ? tenths / 10 : Int(finite.rounded(.down))
        let hours = wholeSeconds / 3600
        let minutes = (wholeSeconds % 3600) / 60
        let seconds = wholeSeconds % 60
        var label = hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
        if showsTenths, tenths % 10 != 0 {
            label += ".\(tenths % 10)"
        }
        return label
    }

    /// "0:30 – 2:45".
    public static func rangeLabel(_ range: SongPlaybackRange, showsTenths: Bool = false) -> String {
        "\(timeLabel(range.start, showsTenths: showsTenths)) – \(timeLabel(range.end, showsTenths: showsTenths))"
    }
}

// MARK: - Sync

/// One song's playback range in the synced document. A nil `range` records
/// that the range was cleared, so the clearing reaches devices that still
/// have it.
public struct SongPlaybackRangeRecord: Codable, Hashable, Sendable {
    public var range: SongPlaybackRange?
    public var updatedAt: Date
    /// Who the song is, for devices where the same file has another id
    /// (`Song.id` hashes a per-device source id).
    public var title: String
    public var artist: String
    public var songDuration: TimeInterval

    public init(
        range: SongPlaybackRange?,
        updatedAt: Date,
        title: String,
        artist: String,
        songDuration: TimeInterval
    ) {
        self.range = range
        self.updatedAt = updatedAt
        self.title = title
        self.artist = artist
        self.songDuration = songDuration
    }

    private enum CodingKeys: String, CodingKey {
        case range = "r"
        case updatedAt = "u"
        case title = "t"
        case artist = "a"
        case songDuration = "d"
    }
}

/// The document synced through the key-value store: records by song id.
public struct SongPlaybackRangeSyncState: Codable, Equatable, Sendable {
    public var records: [String: SongPlaybackRangeRecord]

    public init(records: [String: SongPlaybackRangeRecord] = [:]) {
        self.records = records
    }

    public static let empty = SongPlaybackRangeSyncState()
}

public enum SongPlaybackRangeSyncPolicy {
    /// Cleared ranges are remembered this long so the clearing propagates.
    public static let tombstoneLifetime: TimeInterval = 120 * 24 * 60 * 60
    /// The key-value store allows 1 MB for everything the app syncs there.
    public static let uploadByteBudget = 160 * 1024
    /// Songs whose same-file twin on another device counts as the same song
    /// when their lengths differ by no more than this.
    public static let durationMatchTolerance: TimeInterval = 1.5

    /// Last writer wins per song; on a tie a set range beats a clearing.
    public static func merge(
        _ lhs: SongPlaybackRangeSyncState,
        _ rhs: SongPlaybackRangeSyncState
    ) -> SongPlaybackRangeSyncState {
        var merged = lhs.records
        for (id, incoming) in rhs.records {
            guard let existing = merged[id] else {
                merged[id] = incoming
                continue
            }
            if wins(incoming, over: existing) { merged[id] = incoming }
        }
        return SongPlaybackRangeSyncState(records: merged)
    }

    static func wins(_ candidate: SongPlaybackRangeRecord, over existing: SongPlaybackRangeRecord) -> Bool {
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if (candidate.range == nil) != (existing.range == nil) {
            return candidate.range != nil
        }
        // Deterministic on every device for two different edits in the same instant.
        guard let lhs = candidate.range, let rhs = existing.range else { return false }
        return (lhs.start, lhs.end, lhs.isEnabled ? 1 : 0) > (rhs.start, rhs.end, rhs.isEnabled ? 1 : 0)
    }

    /// Forgets clearings older than `tombstoneLifetime`.
    public static func retained(_ state: SongPlaybackRangeSyncState, now: Date) -> SongPlaybackRangeSyncState {
        SongPlaybackRangeSyncState(records: state.records.filter { _, record in
            record.range != nil || now.timeIntervalSince(record.updatedAt) < tombstoneLifetime
        })
    }

    /// The part of `state` uploaded: everything when it fits, otherwise the
    /// oldest clearings go first, then the oldest ranges. The local copy keeps
    /// all of them.
    public static func uploadState(
        _ state: SongPlaybackRangeSyncState,
        byteBudget: Int = uploadByteBudget
    ) -> SongPlaybackRangeSyncState {
        guard let data = encode(state), data.count > byteBudget else { return state }
        let ordered = state.records.sorted { lhs, rhs in
            let lhsKeeps = lhs.value.range != nil
            let rhsKeeps = rhs.value.range != nil
            if lhsKeeps != rhsKeeps { return !lhsKeeps }
            if lhs.value.updatedAt != rhs.value.updatedAt { return lhs.value.updatedAt < rhs.value.updatedAt }
            return lhs.key < rhs.key
        }
        // Bytes per record, measured once; trimming then needs no re-encoding per step.
        let perRecord = max(1, data.count / max(1, state.records.count))
        let excess = data.count - byteBudget
        let dropCount = min(ordered.count, excess / perRecord + 1)
        var trimmed = state
        for (id, _) in ordered.prefix(dropCount) {
            trimmed.records.removeValue(forKey: id)
        }
        // The estimate can fall short when the dropped records were small.
        if let again = encode(trimmed), again.count > byteBudget, !trimmed.records.isEmpty {
            return uploadState(trimmed, byteBudget: byteBudget)
        }
        return trimmed
    }

    public static func encode(_ state: SongPlaybackRangeSyncState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(state)
    }

    public static func decode(_ data: Data?) -> SongPlaybackRangeSyncState? {
        guard let data, !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SongPlaybackRangeSyncState.self, from: data)
    }

    /// Folded title + artist used to find a song's twin under another id.
    public static func matchKey(title: String, artist: String?) -> String {
        func fold(_ value: String) -> String {
            value
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        return fold(title) + "\u{1}" + fold(artist ?? "")
    }

    /// The record that decides a song's range: its own id's record, or the
    /// newest record of a same-titled, same-artist song of about the same
    /// length (the same file reached through another device's source).
    /// Whichever of those was written last wins, so an edit on one device
    /// reaches the other even when both already had a record.
    public static func resolvedRecord(
        songID: String,
        songDuration: TimeInterval,
        records: [String: SongPlaybackRangeRecord],
        twinIDs: [String]
    ) -> SongPlaybackRangeRecord? {
        var best = records[songID]
        for twinID in twinIDs where twinID != songID {
            guard let twin = records[twinID] else { continue }
            if songDuration > 0, twin.songDuration > 0,
               abs(twin.songDuration - songDuration) > durationMatchTolerance { continue }
            if let current = best {
                if wins(twin, over: current) { best = twin }
            } else {
                best = twin
            }
        }
        return best
    }
}
