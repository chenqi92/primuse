import Foundation

/// Every radio-station edit already syncs as its own record, and the account's
/// library snapshot carries `radio-stations.json` as part of the normal full
/// upload. The extra snapshot-only write is therefore a convenience for devices
/// that bootstrap from the snapshot — not the channel that carries the edit.
///
/// That makes it a poor fit for "once per notification": importing a station
/// list fires N notifications and serialises N fetch-modify-save round trips of
/// the shared snapshot record under the mutation lock, ahead of any concurrent
/// source write. Debouncing collapses the burst into one upload, and the gate
/// below keeps the upload owned by the service that armed it.
public enum RadioSnapshotUploadPolicy {
    /// How long a change waits for its neighbours before the snapshot is written.
    /// Long enough to collapse an import burst, short enough that a single edit
    /// still reaches other devices promptly.
    public static let debounce: Duration = .seconds(2)

    /// A steady stream of edits closer together than `debounce` would postpone
    /// the snapshot for as long as the user keeps editing. Once a change has
    /// been waiting this long the upload runs regardless, so a device that
    /// bootstraps from the snapshot is never starved by a long editing session.
    public static let maximumDelay: Duration = .seconds(20)

    /// How long the newly armed task should wait: the ordinary debounce, or the
    /// remainder of the maximum delay when an earlier change is already waiting.
    public static func delay(sinceFirstPendingChange elapsed: Duration?) -> Duration {
        guard let elapsed else { return debounce }
        let remaining = maximumDelay - elapsed
        return remaining < debounce ? max(remaining, .zero) : debounce
    }

    /// Whether a station change should arm (or re-arm) the debounced upload.
    /// A service that is not started has no business writing to the account.
    public static func shouldSchedule(isStarted: Bool, isChannelEnabled: Bool) -> Bool {
        isStarted && isChannelEnabled
    }

    /// Whether the armed upload may run once its debounce elapses. The last
    /// change always wins: re-arming replaces the token, so only the newest
    /// task passes, and it passes as long as the service is still running.
    public static func shouldUpload(
        isStarted: Bool,
        isCancelled: Bool,
        currentToken: UUID?,
        taskToken: UUID
    ) -> Bool {
        guard isStarted else { return false }
        return CloudFlushGate.shouldFlush(isCancelled: isCancelled, currentToken: currentToken, taskToken: taskToken)
    }
}

/// 外部整份改写 `radio-stations.json` 之后（Apple TV 的快照事务写入或恢复），
/// 把还没交给 CloudKit 的本机改动放回去 —— 文件里是别的设备的版本，
/// 本机这几行一旦被冲掉，补传时就只剩文件里的旧样子。
///
/// 逐行按修改时间判：
/// - 文件里同一台的修改时间**严格**更新：远端已经盖过了本机这次改动，保留文件里的，
///   id 记进 `supersededIDs`（本机已没有要传的）。
/// - 文件里没有这一台，或者两行内容不同：换成本机的，没有就追加到末尾，id 记进 `restoredIDs`。
/// - 两行完全相同：什么都不做。
///
/// 文件里原有的行保持原来的顺序。
public enum RadioPendingCloudUploadPolicy {
    public static func reapply<Row: Equatable>(
        pendingLocal: [Row],
        onto disk: [Row],
        id: (Row) -> String,
        modifiedAt: (Row) -> Date
    ) -> (rows: [Row], restoredIDs: [String], supersededIDs: [String]) {
        var rows = disk
        var indexByID: [String: Int] = [:]
        for (index, row) in rows.enumerated() where indexByID[id(row)] == nil {
            indexByID[id(row)] = index
        }
        var restoredIDs: [String] = []
        var supersededIDs: [String] = []
        var seen = Set<String>()
        for local in pendingLocal {
            let key = id(local)
            guard seen.insert(key).inserted else { continue }
            if let index = indexByID[key] {
                let current = rows[index]
                if modifiedAt(current) > modifiedAt(local) {
                    supersededIDs.append(key)
                    continue
                }
                guard current != local else { continue }
                rows[index] = local
            } else {
                indexByID[key] = rows.count
                rows.append(local)
            }
            restoredIDs.append(key)
        }
        return (rows, restoredIDs, supersededIDs)
    }
}
