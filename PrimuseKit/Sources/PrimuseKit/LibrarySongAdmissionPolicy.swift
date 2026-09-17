import Foundation

/// A scan result is admitted into the library unless the user tombstoned that
/// identity globally or excluded it on this device only. Both ledgers are keyed
/// by a canonical identity — the source's account identity when one exists, the
/// mount UUID otherwise — so re-authorising the same upstream account on a fresh
/// source UUID does not silently resurrect a deleted row.
///
/// The prefix comes from a precomputed `[sourceID: String]` map rather than a
/// per-song closure: an intermediate scan flush re-passes the whole accumulated
/// catalogue, and resolving the prefix per song per pass turned the admission
/// check into a linear source-table scan for every incoming row.
public enum LibrarySongAdmissionPolicy {
    /// `"<identity prefix>:<file path>"`, falling back to the raw source ID
    /// when the source has no account identity.
    public nonisolated static func identityKey(
        prefix: String?,
        sourceID: String,
        filePath: String
    ) -> String {
        "\(prefix ?? sourceID):\(filePath)"
    }

    /// Neither ledger can reject anything when both are empty, which is the
    /// steady state of a library that has never deleted a song. Callers use
    /// this to skip key construction entirely for a whole batch.
    public nonisolated static func hasAdmissionFilters(
        tombstones: Set<String>,
        deviceExclusions: Set<String>
    ) -> Bool {
        !tombstones.isEmpty || !deviceExclusions.isEmpty
    }

    /// 为什么被拦下来。两本账的可撤销性完全不同, 所以准入判定必须能把它们
    /// 分开: 全局墓碑在"文件又回到磁盘上"时应当让路, 而「从本机移除」那本账
    /// 的语义就是文件故意留在原处, 永远不因为扫描又看见它而放行。
    public enum Verdict: Equatable, Sendable {
        case admitted
        /// 命中的那个键一并带出来, 撤销时不必再算一遍身份键。
        case blockedByTombstone(key: String)
        case blockedByDeviceExclusion
    }

    /// One identity key answers all three membership questions.
    ///
    /// The raw `"<sourceID>:<filePath>"` shape is accepted for device-local
    /// exclusions on purpose: the ledger records the account-prefixed key, but a
    /// snapshot load runs before the account resolver is installed, so the same
    /// song computes the raw form on that side of the load-order window. It is
    /// only consulted when the prefixed key differs and already missed.
    /// 排除账本先判, 两本账都命中时以它为准: 它是更强的那条声明 —— 源文件是
    /// 故意留在原处的, 所以"文件此刻在磁盘上"对它永远不构成放行的证据。
    /// `isBlocked` 的取值不受这个顺序影响(它是同样三个谓词的析取)。
    public nonisolated static func verdict(
        sourceID: String,
        filePath: String,
        prefixes: [String: String],
        tombstones: Set<String>,
        deviceExclusions: Set<String>
    ) -> Verdict {
        guard hasAdmissionFilters(tombstones: tombstones, deviceExclusions: deviceExclusions) else {
            return .admitted
        }
        let prefix = prefixes[sourceID]
        let key = identityKey(prefix: prefix, sourceID: sourceID, filePath: filePath)
        if deviceExclusions.contains(key) { return .blockedByDeviceExclusion }
        if let prefix, prefix != sourceID, deviceExclusions.contains(
            identityKey(prefix: nil, sourceID: sourceID, filePath: filePath)
        ) {
            return .blockedByDeviceExclusion
        }
        return tombstones.contains(key) ? .blockedByTombstone(key: key) : .admitted
    }

    /// 只关心"进不进得来"的调用方继续用这个。判定顺序与取值和 `verdict` 完全
    /// 一致, 它就是后者的薄封装。
    public nonisolated static func isBlocked(
        sourceID: String,
        filePath: String,
        prefixes: [String: String],
        tombstones: Set<String>,
        deviceExclusions: Set<String>
    ) -> Bool {
        verdict(
            sourceID: sourceID,
            filePath: filePath,
            prefixes: prefixes,
            tombstones: tombstones,
            deviceExclusions: deviceExclusions
        ) != .admitted
    }

    /// 墓碑的用途是挡住"陈旧的目录快照 / 其它设备的旧快照"把已删的歌带回来。
    /// 对本机文件源来说磁盘就是事实: 文件此刻确实躺在磁盘上, 就说明是用户
    /// 自己又把它放回来了(删掉标签不全的几首、改好标签后重新导入同名文件),
    /// 这时墓碑应当让路, 并且当场被撤销 —— 否则那几首永远进不了资料库。
    ///
    /// 证据取「文件现在存在」而不是「扫描看见过它」: 用户刚删掉一首、而一轮
    /// 更早开始的扫描随后才把结果交上来时, 文件已经不在磁盘上, 于是这批仍然
    /// 被墓碑挡住, 删除不会被一次迟到的扫描撤销。
    ///
    /// 返回应当撤销的键; nil 表示维持原判。「从本机移除」那本账不在这里放行,
    /// 它有自己的恢复界面。
    public nonisolated static func revocableTombstoneKey(
        for verdict: Verdict,
        isDeviceLocalFilePresent: Bool
    ) -> String? {
        guard case .blockedByTombstone(let key) = verdict, isDeviceLocalFilePresent else {
            return nil
        }
        return key
    }
}
