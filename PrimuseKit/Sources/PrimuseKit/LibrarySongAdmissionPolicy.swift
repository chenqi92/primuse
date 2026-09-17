import Foundation

/// 一条删除墓碑的证据。删除那一刻记下来, 用来回答后来在同一路径上看到的文件
/// 「是不是另一份」—— 远端源没有"文件还在不在磁盘上"可问, 只能比签名。
///
/// 本版本之前产生的墓碑没有这条记录, 它们退化成「无证据的旧墓碑」: 永远不因
/// 扫描撤销。旧版本的 App 写回快照时也会把这张表整个丢掉, 结果一样是安全退化。
public struct LibrarySongTombstoneDetail: Codable, Sendable, Equatable {
    /// 最后一次删除这条身份的时刻。跨设备合并取较大者。
    public var deletedAt: Date
    /// 删库记录的时候源文件确实被删掉了(并且删除已被确认)。
    /// 「从资料库移除、源文件保留」是 false —— 弹窗承诺过重新扫描不会把它们
    /// 加回来, 所以这种墓碑**永不**因扫描撤销, 哪怕签名后来变了(用户给整个
    /// 文件夹批量重写标签会改掉所有文件的大小和修改时间)。
    public var sourceFileDeleted: Bool
    /// 删除那一刻库里这一行的签名, 取不到的留 nil。
    public var fileSize: Int64?
    public var lastModified: Date?
    public var revision: String?
    /// 被撤销的时刻。撤销后这条记录还留着(而不是直接抹掉键), 否则别的设备
    /// 尚未同步的旧快照会在并集里把这个墓碑原样带回来。
    public var revivedAt: Date?

    public init(
        deletedAt: Date,
        sourceFileDeleted: Bool,
        fileSize: Int64? = nil,
        lastModified: Date? = nil,
        revision: String? = nil,
        revivedAt: Date? = nil
    ) {
        self.deletedAt = deletedAt
        self.sourceFileDeleted = sourceFileDeleted
        self.fileSize = fileSize
        self.lastModified = lastModified
        self.revision = revision
        self.revivedAt = revivedAt
    }

    /// 墓碑此刻是否仍然生效。重新删除同一路径会把 `deletedAt` 推到现在,
    /// 于是它自然重新生效, 不需要把 `revivedAt` 清掉。
    public var isActive: Bool {
        guard let revivedAt else { return true }
        return revivedAt < deletedAt
    }
}

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
    /// 远端源问不到"文件此刻在不在磁盘上", 只能比签名: 删除那一刻记下的那份
    /// 与现在扫描到的这一份不是同一个文件, 才说明用户在同一路径上放了新的。
    public enum SignatureComparison: Equatable, Sendable {
        case differentFile
        case sameFile
        /// 两边没有任何一项可比 —— 没有证据, 按维持原判处理。
        case notComparable
    }

    /// FAT32 的时间戳是 2 秒粒度, 各家服务器回报的修改时间也常被取整, 所以
    /// 修改时间要差过这个阈值才算"换过文件"。
    public nonisolated static let tombstoneModificationTimeTolerance: TimeInterval = 2

    public nonisolated static func signatureComparison(
        recorded: LibrarySongTombstoneDetail,
        fileSize: Int64?,
        lastModified: Date?,
        revision: String?
    ) -> SignatureComparison {
        var comparable = false
        if let recordedRevision = recorded.revision, !recordedRevision.isEmpty,
           let revision, !revision.isEmpty {
            comparable = true
            if recordedRevision != revision { return .differentFile }
        }
        if let recordedSize = recorded.fileSize, recordedSize > 0,
           let fileSize, fileSize > 0 {
            comparable = true
            if recordedSize != fileSize { return .differentFile }
        }
        if let recordedModified = recorded.lastModified, let lastModified {
            comparable = true
            if abs(recordedModified.timeIntervalSince(lastModified))
                > tombstoneModificationTimeTolerance {
                return .differentFile
            }
        }
        return comparable ? .sameFile : .notComparable
    }

    /// 墓碑的用途是挡住"陈旧的目录快照 / 其它设备的旧快照"把已删的歌带回来,
    /// 不是永久判决。两条放行规则并存, 命中任意一条就撤销:
    ///
    /// 1. **本机文件源**: 磁盘就是事实。文件此刻确实躺在磁盘上, 就说明是用户
    ///    自己又把它放回来了(删掉标签不全的几首、改好标签后重新导入同名文件)。
    ///    证据取「文件现在存在」而不是「扫描看见过它」: 用户刚删掉一首、而一轮
    ///    更早开始的扫描随后才把结果交上来时, 文件已经不在磁盘上, 仍然拦下。
    /// 2. **远端源**: 删除时记下的签名与扫描到的这一份不同。**刻意不拿"扫描
    ///    时间晚于删除时间"当证据** —— 断点续扫会重放删除之前暂存的目录页,
    ///    陈旧目录可以晚到几天之后才交上来; 它带的是旧签名, 所以按签名比才挡
    ///    得住。
    ///
    /// 两条规则都要求删除那一刻源文件确实被删掉了。「从资料库移除、源文件保留」
    /// 的弹窗承诺过重新扫描不会把它们加回来 —— 用户之后给整个文件夹批量重写
    /// 标签会改掉所有文件的大小与修改时间, 不能因此把他特意移出资料库的歌全
    /// 带回来。「从本机移除」那本账同样不在这里放行, 它有自己的恢复界面。
    ///
    /// 返回应当撤销的键; nil 表示维持原判。
    public nonisolated static func revocableTombstoneKey(
        for verdict: Verdict,
        isDeviceLocalFilePresent: Bool = false,
        detail: LibrarySongTombstoneDetail? = nil,
        scannedFileSize: Int64? = nil,
        scannedLastModified: Date? = nil,
        scannedRevision: String? = nil
    ) -> String? {
        guard case .blockedByTombstone(let key) = verdict else { return nil }
        // 有证据且证据说"源文件是故意留着的": 两条规则都不放行。
        if let detail, !detail.sourceFileDeleted { return nil }
        // 规则一。旧墓碑没有 detail, 这一条照样成立 —— 本机源不需要签名证据。
        if isDeviceLocalFilePresent { return key }
        // 规则二。无证据的旧墓碑走不到这里, 维持"永不因扫描撤销"。
        guard let detail else { return nil }
        guard signatureComparison(
            recorded: detail,
            fileSize: scannedFileSize,
            lastModified: scannedLastModified,
            revision: scannedRevision
        ) == .differentFile else { return nil }
        return key
    }
}

/// 墓碑账本的跨设备合并。历史实现对身份数组取并集, 于是本机刚撤销的键会被
/// 另一台设备尚未同步的旧快照原样带回来 —— 复活撑不过一次同步。改成按键的
/// last-writer-wins: 证据表里 `deletedAt` / `revivedAt` 各取较大者, 墓碑生效
/// 当且仅当 `revivedAt == nil || revivedAt < deletedAt`, 合并后的数组 = 两边
/// 并集再减去证据表判定已撤销的键。
public enum LibrarySongTombstoneLedgerMergePolicy {
    /// 撤销记录在键已经离开墓碑集合之后还要留一段时间, 好让尚未同步的设备把
    /// 它们的旧并集减掉。过了这个窗口才清, 免得证据表无限增长。
    public nonisolated static let revivedRetention: TimeInterval = 180 * 24 * 60 * 60

    public struct Merged: Equatable, Sendable {
        public var identities: [String]
        public var details: [String: LibrarySongTombstoneDetail]

        public init(identities: [String], details: [String: LibrarySongTombstoneDetail]) {
            self.identities = identities
            self.details = details
        }
    }

    /// 同一个键两边都有证据时, 以**较新的那次删除**为准: 签名和
    /// `sourceFileDeleted` 都取 `deletedAt` 大的那一侧, 否则会把旧签名配到新
    /// 删除上, 下一次扫描就误判成"换过文件"。`revivedAt` 独立取较大者 ——
    /// 撤销发生在哪一侧都算数。
    public nonisolated static func merging(
        _ local: LibrarySongTombstoneDetail,
        _ incoming: LibrarySongTombstoneDetail
    ) -> LibrarySongTombstoneDetail {
        var winner = incoming.deletedAt > local.deletedAt ? incoming : local
        winner.revivedAt = [local.revivedAt, incoming.revivedAt].compactMap { $0 }.max()
        return winner
    }

    public nonisolated static func merge(
        localIdentities: [String]?,
        localDetails: [String: LibrarySongTombstoneDetail]?,
        incomingIdentities: [String]?,
        incomingDetails: [String: LibrarySongTombstoneDetail]?,
        now: Date = Date()
    ) -> Merged {
        var details = localDetails ?? [:]
        for (key, incoming) in incomingDetails ?? [:] {
            details[key] = details[key].map { merging($0, incoming) } ?? incoming
        }
        var identities = Set(localIdentities ?? [])
        identities.formUnion(incomingIdentities ?? [])
        for (key, detail) in details where !detail.isActive {
            identities.remove(key)
        }
        // 已撤销且过了保留期的证据可以清掉; 仍然生效的证据要跟着它的键走,
        // 键都不在了(被别的设备真正清理掉)就没有留着的意义。
        details = details.filter { key, detail in
            guard detail.isActive else {
                guard let revivedAt = detail.revivedAt else { return false }
                return now.timeIntervalSince(revivedAt) < revivedRetention
            }
            return identities.contains(key)
        }
        return Merged(identities: identities.sorted(), details: details)
    }
}
