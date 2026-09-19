public struct PlaybackSourceAvailabilityPolicy: Sendable {
    /// What traversal, presentation and probing may assume about one source on
    /// the current network path.
    public enum Standing: Sendable, Equatable {
        /// No verdict belongs to this network path and source configuration.
        case unknown
        case reachable
        case unreachable
        /// The outage verdict has aged. An aged outage is still the best
        /// evidence available, so songs stay skipped while a background probe
        /// asks again; letting it lapse into "available" made every other
        /// queue transition retry the dead source audibly.
        case unreachableAwaitingRecheck

        public var skipsUncachedSongs: Bool {
            self == .unreachable || self == .unreachableAwaitingRecheck
        }

        /// Whether a background probe has something to learn. A reachable
        /// verdict is not re-asked proactively; the playback path still probes
        /// before it commits to a song.
        public var wantsProbe: Bool {
            self == .unknown || self == .unreachableAwaitingRecheck
        }
    }

    /// Seconds until an outage is asked about again. The first recheck is
    /// early because a probe sent while an interface is still settling reports
    /// an outage that does not exist; later ones back off so a source that
    /// stays away costs one handshake every few minutes.
    public static let outageRecheckDelays: [Double] = [20, 60, 120, 300]
    public static let reachableVerdictLifetime: Double = 15

    private struct Entry: Sendable {
        let isUnreachable: Bool
        let networkGeneration: UInt64
        let sourceGeneration: Int
        var expiresAt: Double
        let consecutiveOutages: Int
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    /// The fresh verdict, or nil once it has aged and the caller should probe.
    public func cachedUnavailability(
        sourceID: String,
        networkGeneration: UInt64,
        sourceGeneration: Int,
        now: Double
    ) -> Bool? {
        guard let entry = currentEntry(
            sourceID: sourceID,
            networkGeneration: networkGeneration,
            sourceGeneration: sourceGeneration
        ), now < entry.expiresAt else { return nil }
        return entry.isUnreachable
    }

    public func standing(
        sourceID: String,
        networkGeneration: UInt64,
        sourceGeneration: Int,
        now: Double
    ) -> Standing {
        guard let entry = currentEntry(
            sourceID: sourceID,
            networkGeneration: networkGeneration,
            sourceGeneration: sourceGeneration
        ) else { return .unknown }
        guard entry.isUnreachable else { return .reachable }
        return now < entry.expiresAt ? .unreachable : .unreachableAwaitingRecheck
    }

    /// Probe results belong to a device network path and source configuration,
    /// never to the durable library. A server can recover without either one
    /// changing, so outages are asked about again and explicit reconnects can
    /// clear them.
    public mutating func record(
        isUnreachable: Bool,
        sourceID: String,
        networkGeneration: UInt64,
        sourceGeneration: Int,
        now: Double
    ) {
        // Verdicts from an earlier path can never match again.
        entries = entries.filter { $0.value.networkGeneration == networkGeneration }
        var consecutiveOutages = 0
        if isUnreachable {
            let previous = currentEntry(
                sourceID: sourceID,
                networkGeneration: networkGeneration,
                sourceGeneration: sourceGeneration
            )
            consecutiveOutages = (previous?.consecutiveOutages ?? 0) + 1
        }
        entries[sourceID] = Entry(
            isUnreachable: isUnreachable,
            networkGeneration: networkGeneration,
            sourceGeneration: sourceGeneration,
            expiresAt: now + Self.verdictLifetime(consecutiveOutages: consecutiveOutages),
            consecutiveOutages: consecutiveOutages
        )
    }

    public mutating func invalidate(sourceID: String) {
        entries.removeValue(forKey: sourceID)
    }

    /// A recheck that could not reach a verdict (cancelled, source list not
    /// readable) keeps the outage and waits one more interval instead of
    /// asking again immediately.
    public mutating func postponeRecheck(sourceID: String, now: Double) {
        guard var entry = entries[sourceID], entry.isUnreachable,
              entry.expiresAt <= now else { return }
        entry.expiresAt = now + Self.verdictLifetime(consecutiveOutages: entry.consecutiveOutages)
        entries[sourceID] = entry
    }

    public func unreachableSourceIDs(
        networkGeneration: UInt64,
        sourceGeneration: (String) -> Int
    ) -> Set<String> {
        Set(entries.compactMap { sourceID, entry in
            entry.isUnreachable
                && entry.networkGeneration == networkGeneration
                && entry.sourceGeneration == sourceGeneration(sourceID)
                ? sourceID : nil
        })
    }

    public func sourceIDsAwaitingRecheck(
        networkGeneration: UInt64,
        sourceGeneration: (String) -> Int,
        now: Double
    ) -> Set<String> {
        Set(entries.compactMap { sourceID, entry in
            entry.isUnreachable
                && entry.networkGeneration == networkGeneration
                && entry.sourceGeneration == sourceGeneration(sourceID)
                && entry.expiresAt <= now
                ? sourceID : nil
        })
    }

    /// When the earliest current outage wants its next probe, or nil while
    /// nothing is unreachable on this path.
    public func nextRecheckTime(
        networkGeneration: UInt64,
        sourceGeneration: (String) -> Int
    ) -> Double? {
        entries.compactMap { sourceID, entry in
            entry.isUnreachable
                && entry.networkGeneration == networkGeneration
                && entry.sourceGeneration == sourceGeneration(sourceID)
                ? entry.expiresAt : nil
        }.min()
    }

    public static func allowsPlayback(
        isSourceEnabled: Bool,
        isSourceUnreachable: Bool,
        hasUsableLocalAudio: Bool
    ) -> Bool {
        isSourceEnabled && (!isSourceUnreachable || hasUsableLocalAudio)
    }

    static func verdictLifetime(consecutiveOutages: Int) -> Double {
        guard consecutiveOutages > 0 else { return reachableVerdictLifetime }
        return outageRecheckDelays[min(consecutiveOutages, outageRecheckDelays.count) - 1]
    }

    private func currentEntry(
        sourceID: String,
        networkGeneration: UInt64,
        sourceGeneration: Int
    ) -> Entry? {
        guard let entry = entries[sourceID],
              entry.networkGeneration == networkGeneration,
              entry.sourceGeneration == sourceGeneration else { return nil }
        return entry
    }
}
