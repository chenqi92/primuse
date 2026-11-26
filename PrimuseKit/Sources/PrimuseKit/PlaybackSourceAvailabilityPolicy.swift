import Foundation

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
        /// verdict is not re-asked proactively; the playback path probes
        /// before it commits to a song once the verdict has aged.
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
    /// How long bytes the source just delivered vouch for it. Streaming reads
    /// ahead every few seconds to half a minute, so while a song plays from a
    /// source the next start from it needs no probe; a path change still
    /// discards the verdict at once.
    public static let transferEvidenceLifetime: Double = 45

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

    /// The source just delivered audio on this path. That proves it can be
    /// reached as well as a handshake does, so it renews a reachable verdict
    /// (or settles an unknown one) without a probe. An outage verdict is left
    /// to its own recheck; the next probe clears it.
    public mutating func recordTransfer(
        sourceID: String,
        networkGeneration: UInt64,
        sourceGeneration: Int,
        now: Double
    ) {
        let previous = currentEntry(
            sourceID: sourceID,
            networkGeneration: networkGeneration,
            sourceGeneration: sourceGeneration
        )
        if previous?.isUnreachable == true { return }
        entries = entries.filter { $0.value.networkGeneration == networkGeneration }
        entries[sourceID] = Entry(
            isUnreachable: false,
            networkGeneration: networkGeneration,
            sourceGeneration: sourceGeneration,
            expiresAt: max(previous?.expiresAt ?? now, now + Self.transferEvidenceLifetime),
            consecutiveOutages: 0
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

/// What a source card can tell the listener while the source is unreachable.
public enum PlaybackSourceOutageGuidance: Sendable, Equatable {
    /// Every configured address only exists on the listener's own network.
    /// Away from it nothing will answer, so the useful advice is another route.
    case addRemoteRoute
    /// A route that is meant to work from anywhere failed as well. There is
    /// nothing to configure; the source or the connection has to come back.
    case waitForConnection

    /// One entry per configured route; nil stands for a vendor relay such as
    /// QuickConnect, which has no address of its own. An overlay address
    /// (Tailscale and the like) follows the device, so it counts as a route
    /// for anywhere even though it is private.
    public static func resolve(routeHosts: [String?]) -> PlaybackSourceOutageGuidance {
        guard !routeHosts.isEmpty else { return .waitForConnection }
        let everyRouteIsOnTheLocalNetwork = routeHosts.allSatisfy { host in
            guard let host else { return false }
            return InsecureHTTPHostPolicy.isLocalNetworkHost(host)
                && !PrivateOverlayHostPolicy.isOverlayHost(host)
        }
        return everyRouteIsOnTheLocalNetwork ? .addRemoteRoute : .waitForConnection
    }
}

/// 主动离线模式状态（全局 + 单源）。
/// 与被动网络不可达（`PlaybackSourceAvailabilityPolicy`）独立：
/// 主动离线由用户显式控制，持久化保存在本机，启用期间不发起探活或自动刷新。
public struct OfflineModeState: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.offlineMode.v1"

    public var isGlobalOffline: Bool
    public var offlineSourceIDs: Set<String>

    public init(
        isGlobalOffline: Bool = false,
        offlineSourceIDs: Set<String> = []
    ) {
        self.isGlobalOffline = isGlobalOffline
        self.offlineSourceIDs = offlineSourceIDs
    }

    public static let inactive = OfflineModeState()

    /// 哪些音乐源类型支持主动离线模式。
    /// 本机文件夹与系统媒体库本身就在本地，Apple Music 下载不由 Primuse 管理，均不参与。
    public static func supportsOfflineMode(for type: MusicSourceType) -> Bool {
        switch type {
        case .local, .appleMusic, .appleMusicLibrary:
            return false
        default:
            return true
        }
    }

    /// 单个源当前是否处于主动离线状态（受全局开关或单源开关影响）。
    public func isSourceOffline(_ sourceID: String, type: MusicSourceType) -> Bool {
        guard Self.supportsOfflineMode(for: type) else { return false }
        return isGlobalOffline || offlineSourceIDs.contains(sourceID)
    }

    /// 当已知该源支持离线模式时的快速判定（避免反复查源表）。
    public func isRemoteSourceOffline(_ sourceID: String) -> Bool {
        isGlobalOffline || offlineSourceIDs.contains(sourceID)
    }

    /// 在给定的一组音乐源中，当前处于主动离线的源 ID 集合。
    public func activeOfflineSourceIDs(in sources: [MusicSource]) -> Set<String> {
        var result = Set<String>()
        for source in sources where !source.isDeleted && Self.supportsOfflineMode(for: source.type) {
            if isGlobalOffline || offlineSourceIDs.contains(source.id) {
                result.insert(source.id)
            }
        }
        return result
    }

    /// 给定远程源集合中是否存在任意主动离线限制（全局离线，或至少一个有效远程源被单源离线）。
    public func hasActiveRestriction(validRemoteSourceIDs: Set<String>) -> Bool {
        guard !validRemoteSourceIDs.isEmpty else { return false }
        return isGlobalOffline || !offlineSourceIDs.isDisjoint(with: validRemoteSourceIDs)
    }

    /// 当前实际生效的单源离线数量（不含已删除或不支持的源）。
    public func activeManualOfflineCount(validRemoteSourceIDs: Set<String>) -> Int {
        offlineSourceIDs.intersection(validRemoteSourceIDs).count
    }

    /// 清理已删除或不再存在的源 ID。
    public func pruned(keeping validRemoteSourceIDs: Set<String>) -> OfflineModeState {
        OfflineModeState(
            isGlobalOffline: isGlobalOffline,
            offlineSourceIDs: offlineSourceIDs.intersection(validRemoteSourceIDs)
        )
    }

    public mutating func setSourceOffline(_ offline: Bool, sourceID: String) {
        if offline {
            offlineSourceIDs.insert(sourceID)
        } else {
            offlineSourceIDs.remove(sourceID)
        }
    }

    public static func decode(_ data: Data?) -> OfflineModeState {
        guard let data,
              let decoded = try? JSONDecoder().decode(OfflineModeState.self, from: data) else {
            return .inactive
        }
        return decoded
    }

    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
