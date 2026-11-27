import Foundation

/// Stable identifiers for radio stations mirrored from a server-side music
/// source. The source-scoped prefix lets reconciliation and source cleanup
/// operate without touching manually-added stations or another server.
public enum ServerRadioStationIdentity {
    public static let stationIDPrefix = "primuse.system.serverRadio."
    public static let mediaServerPlaybackPathPrefix = "/live-radio/"

    public static func stationID(sourceID: String, serverStationID: String) -> String {
        "\(stationIDPrefix)\(sourceID).\(serverStationID)"
    }

    public static func stationIDPrefix(sourceID: String) -> String {
        "\(stationIDPrefix)\(sourceID)."
    }

    public static func isMirrorStation(_ stationID: String) -> Bool {
        stationID.hasPrefix(stationIDPrefix)
    }

    /// A credential-free marker understood by the media-server resolvers on
    /// every app target. It is not a server URL and is safe to synchronize.
    public static func mediaServerPlaybackPath(serverStationID: String) -> String {
        "\(mediaServerPlaybackPathPrefix)\(serverStationID).mp3"
    }

    public static func isMediaServerPlaybackPath(_ path: String) -> Bool {
        path.hasPrefix(mediaServerPlaybackPathPrefix)
    }
}

public enum ServerRadioReconciliationPolicy {
    public static func mirrorIDsToKeep(
        sourceID: String,
        serverStationIDs: [String],
        failedServerStationIDs: Set<String> = []
    ) -> Set<String> {
        Set(serverStationIDs)
            .union(failedServerStationIDs)
            .reduce(into: Set<String>()) { result, serverStationID in
                let serverStationID = serverStationID
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !serverStationID.isEmpty else { return }
                result.insert(ServerRadioStationIdentity.stationID(
                    sourceID: sourceID,
                    serverStationID: serverStationID
                ))
            }
    }

    /// 服务端下架的镜像留墓碑挡住快照复活,但不必永远留:镜像每次对账都从服务端
    /// 重新推出来,真被旧快照带回来也会在下一次对账时再被删掉。SHOUTcast 这种按收听
    /// 人数排的目录天天有台进出,墓碑不清就一直涨。
    public static let mirrorTombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    public static func shouldPurgeMirrorTombstone(deletedAt: Date?, now: Date) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) > mirrorTombstoneRetention
    }
}
