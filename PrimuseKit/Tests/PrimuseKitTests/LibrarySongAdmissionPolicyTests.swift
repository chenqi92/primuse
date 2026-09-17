import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library song admission policy")
struct LibrarySongAdmissionPolicyTests {
    private static let path = "/Music/track.flac"

    @Test("A resolved account prefix keys the identity, an unresolved source falls back")
    func identityKeyShape() {
        #expect(
            LibrarySongAdmissionPolicy.identityKey(
                prefix: "account-1",
                sourceID: "mount-a",
                filePath: Self.path
            ) == "account-1:\(Self.path)"
        )
        #expect(
            LibrarySongAdmissionPolicy.identityKey(
                prefix: nil,
                sourceID: "mount-a",
                filePath: Self.path
            ) == "mount-a:\(Self.path)"
        )
    }

    @Test("Empty ledgers cannot reject anything")
    func emptyLedgersShortCircuit() {
        #expect(
            LibrarySongAdmissionPolicy.hasAdmissionFilters(
                tombstones: [],
                deviceExclusions: []
            ) == false
        )
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: ["mount-a": "account-1"],
                tombstones: [],
                deviceExclusions: []
            ) == false
        )
        #expect(
            LibrarySongAdmissionPolicy.hasAdmissionFilters(
                tombstones: ["account-1:\(Self.path)"],
                deviceExclusions: []
            )
        )
        #expect(
            LibrarySongAdmissionPolicy.hasAdmissionFilters(
                tombstones: [],
                deviceExclusions: ["mount-a:\(Self.path)"]
            )
        )
    }

    @Test("A tombstone recorded under the account prefix survives a new mount UUID")
    func tombstoneSurvivesRemount() {
        let tombstones: Set<String> = ["account-1:\(Self.path)"]
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: ["mount-a": "account-1"],
                tombstones: tombstones,
                deviceExclusions: []
            )
        )
        // Re-OAuth mints a fresh source UUID; the account identity is unchanged.
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-b",
                filePath: Self.path,
                prefixes: ["mount-b": "account-1"],
                tombstones: tombstones,
                deviceExclusions: []
            )
        )
        // A different account at the same path is a different song.
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-c",
                filePath: Self.path,
                prefixes: ["mount-c": "account-2"],
                tombstones: tombstones,
                deviceExclusions: []
            ) == false
        )
    }

    @Test("Device exclusions are accepted in both the prefixed and the raw shape")
    func deviceExclusionAcceptsBothKeyShapes() {
        let prefixes = ["mount-a": "account-1"]
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: prefixes,
                tombstones: [],
                deviceExclusions: ["account-1:\(Self.path)"]
            )
        )
        // Recorded before the account resolver was installed.
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: prefixes,
                tombstones: [],
                deviceExclusions: ["mount-a:\(Self.path)"]
            )
        )
        // A tombstone ledger is never matched by the raw fallback shape.
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: prefixes,
                tombstones: ["mount-a:\(Self.path)"],
                deviceExclusions: []
            ) == false
        )
    }

    @Test("A source without a resolved prefix uses the source ID for both ledgers")
    func unresolvedSourceUsesRawKey() {
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: [:],
                tombstones: ["mount-a:\(Self.path)"],
                deviceExclusions: []
            )
        )
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: [:],
                tombstones: [],
                deviceExclusions: ["mount-a:\(Self.path)"]
            )
        )
        #expect(
            LibrarySongAdmissionPolicy.isBlocked(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: [:],
                tombstones: ["account-1:\(Self.path)"],
                deviceExclusions: []
            ) == false
        )
    }

    @Test("Empty ledgers short-circuit the verdict too")
    func emptyLedgersAdmit() {
        let verdict = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-a",
            filePath: Self.path,
            prefixes: ["mount-a": "account-1"],
            tombstones: [],
            deviceExclusions: []
        )
        #expect(verdict == .admitted)
        // 零开销路径: 库里没有任何删除记录时, 连身份键都不该被构造出来。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: verdict,
                isDeviceLocalFilePresent: true
            ) == nil
        )
    }

    @Test("The verdict tells the two ledgers apart, in both key shapes")
    func verdictDistinguishesLedgers() {
        let prefixed = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-a",
            filePath: Self.path,
            prefixes: ["mount-a": "account-1"],
            tombstones: ["account-1:\(Self.path)"],
            deviceExclusions: []
        )
        #expect(prefixed == .blockedByTombstone(key: "account-1:\(Self.path)"))
        // 没有账号身份的源(本机源就是这一类)用裸 sourceID 做前缀。
        let bare = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-local",
            filePath: Self.path,
            prefixes: [:],
            tombstones: ["mount-local:\(Self.path)"],
            deviceExclusions: []
        )
        #expect(bare == .blockedByTombstone(key: "mount-local:\(Self.path)"))
        #expect(
            LibrarySongAdmissionPolicy.verdict(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: ["mount-a": "account-1"],
                tombstones: [],
                deviceExclusions: ["account-1:\(Self.path)"]
            ) == .blockedByDeviceExclusion
        )
        // 账号解析器装上之前记下的裸形态。
        #expect(
            LibrarySongAdmissionPolicy.verdict(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: ["mount-a": "account-1"],
                tombstones: [],
                deviceExclusions: ["mount-a:\(Self.path)"]
            ) == .blockedByDeviceExclusion
        )
    }

    @Test("Only a tombstone on a device-local source whose file is present gives way")
    func tombstoneGivesWayOnlyToAPresentLocalFile() {
        let localVerdict = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-local",
            filePath: Self.path,
            prefixes: [:],
            tombstones: ["mount-local:\(Self.path)"],
            deviceExclusions: []
        )
        // 文件确实回到磁盘上 = 用户重新放回来的, 放行并交出要撤销的键。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: localVerdict,
                isDeviceLocalFilePresent: true
            ) == "mount-local:\(Self.path)"
        )
        // 文件不在磁盘上(远端源, 或本机源但用户刚删掉): 维持原判。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: localVerdict,
                isDeviceLocalFilePresent: false
            ) == nil
        )
        // 远端源的探针恒为 false, 所以同一条规则天然把它们排除在外。
        let remoteVerdict = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-a",
            filePath: Self.path,
            prefixes: ["mount-a": "account-1"],
            tombstones: ["account-1:\(Self.path)"],
            deviceExclusions: []
        )
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: remoteVerdict,
                isDeviceLocalFilePresent: false
            ) == nil
        )
    }

    @Test("A device exclusion never gives way, even for a present local file")
    func deviceExclusionNeverGivesWay() {
        for exclusions in [
            ["account-1:\(Self.path)"],
            ["mount-a:\(Self.path)"],
        ] {
            let verdict = LibrarySongAdmissionPolicy.verdict(
                sourceID: "mount-a",
                filePath: Self.path,
                prefixes: ["mount-a": "account-1"],
                tombstones: [],
                deviceExclusions: Set(exclusions)
            )
            #expect(verdict == .blockedByDeviceExclusion)
            // 「从本机移除」的语义就是文件故意留在原处, 文件在不在都不放行。
            #expect(
                LibrarySongAdmissionPolicy.revocableTombstoneKey(
                    for: verdict,
                    isDeviceLocalFilePresent: true
                ) == nil
            )
        }
    }

    /// 用户选「从资料库移除」而源文件留在原处时, 两本账会同时记下这个身份。
    /// 排除账本更强, 所以"文件还在磁盘上"不能把它放回来。
    @Test("A song in both ledgers is reported as excluded, never as revocable")
    func deviceExclusionWinsOverTombstone() {
        let key = "mount-local:\(Self.path)"
        let verdict = LibrarySongAdmissionPolicy.verdict(
            sourceID: "mount-local",
            filePath: Self.path,
            prefixes: [:],
            tombstones: [key],
            deviceExclusions: [key]
        )
        #expect(verdict == .blockedByDeviceExclusion)
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: verdict,
                isDeviceLocalFilePresent: true
            ) == nil
        )
    }

    @Test("isBlocked stays a thin wrapper over the verdict")
    func isBlockedMatchesVerdict() {
        let rows: [(sourceID: String, filePath: String)] = [
            ("mount-a", "/Music/a.flac"),
            ("mount-a", "/Music/b.flac"),
            ("mount-local", "/Music/a.flac"),
            ("mount-local", "/Music/c.flac"),
        ]
        let prefixes = ["mount-a": "account-1"]
        let tombstones: Set<String> = ["account-1:/Music/a.flac", "mount-local:/Music/c.flac"]
        let exclusions: Set<String> = ["mount-a:/Music/b.flac"]
        for row in rows {
            let verdict = LibrarySongAdmissionPolicy.verdict(
                sourceID: row.sourceID,
                filePath: row.filePath,
                prefixes: prefixes,
                tombstones: tombstones,
                deviceExclusions: exclusions
            )
            let blocked = LibrarySongAdmissionPolicy.isBlocked(
                sourceID: row.sourceID,
                filePath: row.filePath,
                prefixes: prefixes,
                tombstones: tombstones,
                deviceExclusions: exclusions
            )
            #expect(blocked == (verdict != .admitted))
        }
    }

    @Test("A prefix map agrees with a per-song resolver closure on every row")
    func prefixMapMatchesResolverClosure() {
        let resolver: (String) -> String? = { sourceID in
            switch sourceID {
            case "mount-a": return "account-1"
            case "mount-b": return "account-2"
            default: return nil
            }
        }
        let rows: [(sourceID: String, filePath: String)] = [
            ("mount-a", "/Music/a.flac"),
            ("mount-a", "/Music/b.flac"),
            ("mount-b", "/Music/a.flac"),
            ("mount-local", "/Music/a.flac"),
            ("mount-local", "/Music/c.flac"),
        ]
        var prefixes: [String: String] = [:]
        for row in rows { prefixes[row.sourceID] = resolver(row.sourceID) }

        let tombstones: Set<String> = ["account-1:/Music/a.flac", "mount-local:/Music/c.flac"]
        let exclusions: Set<String> = ["account-2:/Music/a.flac", "mount-a:/Music/b.flac"]

        for row in rows {
            let referencePrefix = resolver(row.sourceID) ?? row.sourceID
            let referenceKey = "\(referencePrefix):\(row.filePath)"
            let expected = tombstones.contains(referenceKey)
                || exclusions.contains(referenceKey)
                || exclusions.contains("\(row.sourceID):\(row.filePath)")
            #expect(
                LibrarySongAdmissionPolicy.isBlocked(
                    sourceID: row.sourceID,
                    filePath: row.filePath,
                    prefixes: prefixes,
                    tombstones: tombstones,
                    deviceExclusions: exclusions
                ) == expected
            )
        }
    }
}

@Suite("Remote tombstone revival by signature")
struct LibrarySongTombstoneSignatureTests {
    private static let key = "account-1:/Music/track.flac"
    private static let deletedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let verdict = LibrarySongAdmissionPolicy.Verdict.blockedByTombstone(key: key)

    private static func detail(
        sourceFileDeleted: Bool = true,
        fileSize: Int64? = 5_000_000,
        lastModified: Date? = deletedAt,
        revision: String? = nil
    ) -> LibrarySongTombstoneDetail {
        LibrarySongTombstoneDetail(
            deletedAt: deletedAt,
            sourceFileDeleted: sourceFileDeleted,
            fileSize: fileSize,
            lastModified: lastModified,
            revision: revision
        )
    }

    @Test("An evidence-free legacy tombstone is never revoked by a remote scan")
    func legacyTombstoneNeverRevoked() {
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: nil,
                scannedFileSize: 9_999_999,
                scannedLastModified: Date(timeIntervalSince1970: 1_800_000_000),
                scannedRevision: "brand-new"
            ) == nil
        )
        // 本机源那条规则不依赖证据, 旧墓碑照样能放行(#134 的原始链路)。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                isDeviceLocalFilePresent: true,
                detail: nil
            ) == Self.key
        )
    }

    @Test("A removal that kept the source file is never revoked, whatever the signature")
    func retainedSourceFileNeverRevoked() {
        let retained = Self.detail(sourceFileDeleted: false)
        // 用户后来给整个文件夹批量重写标签: 大小和修改时间全变了。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: retained,
                scannedFileSize: 6_000_000,
                scannedLastModified: Date(timeIntervalSince1970: 1_800_000_000),
                scannedRevision: "rewritten"
            ) == nil
        )
        // 本机源那条规则也不放行 —— 文件本来就一直在。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                isDeviceLocalFilePresent: true,
                detail: retained
            ) == nil
        )
    }

    @Test("A stale directory page replaying the same signature does not revive anything")
    func staleDirectoryPageDoesNotRevive() {
        let recorded = Self.detail(revision: "rev-1")
        #expect(
            LibrarySongAdmissionPolicy.signatureComparison(
                recorded: recorded,
                fileSize: 5_000_000,
                lastModified: Self.deletedAt,
                revision: "rev-1"
            ) == .sameFile
        )
        // 续扫重放的陈旧目录页可以晚到几天之后才交上来, 但它带的是旧签名。
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: recorded,
                scannedFileSize: 5_000_000,
                scannedLastModified: Self.deletedAt,
                scannedRevision: "rev-1"
            ) == nil
        )
        // 修改时间只差 2 秒以内也算同一个文件(FAT32 / 服务端取整)。
        #expect(
            LibrarySongAdmissionPolicy.signatureComparison(
                recorded: Self.detail(revision: nil),
                fileSize: 5_000_000,
                lastModified: Self.deletedAt.addingTimeInterval(1.9),
                revision: nil
            ) == .sameFile
        )
    }

    @Test("Any comparable signature field that differs revives the identity")
    func changedSignatureRevives() {
        // 大小变了
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: Self.detail(),
                scannedFileSize: 5_100_000,
                scannedLastModified: Self.deletedAt
            ) == Self.key
        )
        // 修改时间差超过 2 秒
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: Self.detail(),
                scannedFileSize: 5_000_000,
                scannedLastModified: Self.deletedAt.addingTimeInterval(2.5)
            ) == Self.key
        )
        // revision 变了(服务端的 ETag / 修订标记)
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: Self.detail(fileSize: nil, lastModified: nil, revision: "rev-1"),
                scannedRevision: "rev-2"
            ) == Self.key
        )
    }

    @Test("Nothing comparable means no evidence, so the tombstone holds")
    func incomparableSignatureHolds() {
        #expect(
            LibrarySongAdmissionPolicy.signatureComparison(
                recorded: Self.detail(fileSize: nil, lastModified: nil, revision: nil),
                fileSize: 5_000_000,
                lastModified: Self.deletedAt,
                revision: "rev-9"
            ) == .notComparable
        )
        // 一侧有大小、另一侧没有, 也算不上可比。
        #expect(
            LibrarySongAdmissionPolicy.signatureComparison(
                recorded: Self.detail(fileSize: 5_000_000, lastModified: nil),
                fileSize: nil,
                lastModified: Self.deletedAt,
                revision: nil
            ) == .notComparable
        )
        // 大小记的是 0(取不到) 同样不可比, 不能当成"大小变了"。
        #expect(
            LibrarySongAdmissionPolicy.signatureComparison(
                recorded: Self.detail(fileSize: 0, lastModified: nil),
                fileSize: 5_000_000,
                lastModified: nil,
                revision: nil
            ) == .notComparable
        )
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: Self.verdict,
                detail: Self.detail(fileSize: nil, lastModified: nil, revision: nil),
                scannedFileSize: 5_000_000,
                scannedLastModified: Self.deletedAt
            ) == nil
        )
    }

    @Test("A device exclusion verdict never produces a revocable key")
    func deviceExclusionStillNeverRevoked() {
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: .blockedByDeviceExclusion,
                isDeviceLocalFilePresent: true,
                detail: Self.detail(),
                scannedFileSize: 9_000_000
            ) == nil
        )
        #expect(
            LibrarySongAdmissionPolicy.revocableTombstoneKey(
                for: .admitted,
                isDeviceLocalFilePresent: true
            ) == nil
        )
    }
}

@Suite("Tombstone ledger cross-device merge")
struct LibrarySongTombstoneLedgerMergePolicyTests {
    private static let key = "account-1:/Music/track.flac"
    private static let other = "account-1:/Music/other.flac"
    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A revoked identity is subtracted from the union instead of coming back")
    func revivalSurvivesTheUnion() {
        // 本机撤销了, 另一台设备的旧快照仍然带着这个键。
        let local = LibrarySongTombstoneDetail(
            deletedAt: Self.t0,
            sourceFileDeleted: true,
            revivedAt: Self.t0.addingTimeInterval(60)
        )
        let merged = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [],
            localDetails: [Self.key: local],
            incomingIdentities: [Self.key, Self.other],
            incomingDetails: nil,
            now: Self.t0.addingTimeInterval(120)
        )
        #expect(merged.identities == [Self.other])
        #expect(merged.details[Self.key]?.revivedAt == Self.t0.addingTimeInterval(60))
    }

    @Test("Deleting the same path again makes the tombstone effective once more")
    func redeletionReactivates() {
        let revived = LibrarySongTombstoneDetail(
            deletedAt: Self.t0,
            sourceFileDeleted: true,
            revivedAt: Self.t0.addingTimeInterval(60)
        )
        let redeleted = LibrarySongTombstoneDetail(
            deletedAt: Self.t0.addingTimeInterval(600),
            sourceFileDeleted: true,
            fileSize: 7_000_000,
            revivedAt: nil
        )
        let merged = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [Self.key],
            localDetails: [Self.key: redeleted],
            incomingIdentities: [],
            incomingDetails: [Self.key: revived],
            now: Self.t0.addingTimeInterval(700)
        )
        #expect(merged.identities == [Self.key])
        let detail = merged.details[Self.key]
        #expect(detail?.deletedAt == Self.t0.addingTimeInterval(600))
        #expect(detail?.revivedAt == Self.t0.addingTimeInterval(60))
        #expect(detail?.fileSize == 7_000_000)
        #expect(detail?.isActive == true)
    }

    @Test("Both timestamps take the later side, and the newer deletion owns the signature")
    func timestampsTakeTheLaterSide() {
        let older = LibrarySongTombstoneDetail(
            deletedAt: Self.t0,
            sourceFileDeleted: true,
            fileSize: 1_000,
            revision: "old",
            revivedAt: Self.t0.addingTimeInterval(30)
        )
        let newer = LibrarySongTombstoneDetail(
            deletedAt: Self.t0.addingTimeInterval(500),
            sourceFileDeleted: false,
            fileSize: 2_000,
            revision: "new",
            revivedAt: nil
        )
        let merged = LibrarySongTombstoneLedgerMergePolicy.merging(older, newer)
        #expect(merged.deletedAt == Self.t0.addingTimeInterval(500))
        // 签名和 sourceFileDeleted 跟着较新的那次删除走, 不能把旧签名配上去。
        #expect(merged.fileSize == 2_000)
        #expect(merged.revision == "new")
        #expect(merged.sourceFileDeleted == false)
        // 撤销时刻独立取较大者。
        #expect(merged.revivedAt == Self.t0.addingTimeInterval(30))
        #expect(merged.isActive == true)
        // 反过来合并结果一样。
        #expect(LibrarySongTombstoneLedgerMergePolicy.merging(newer, older) == merged)
    }

    @Test("A snapshot without the details table merges both ways without losing tombstones")
    func legacySnapshotsInteroperate() {
        let detail = LibrarySongTombstoneDetail(deletedAt: Self.t0, sourceFileDeleted: true)
        // 旧格式快照(只有数组)并进新格式。
        let fromLegacy = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [Self.key],
            localDetails: [Self.key: detail],
            incomingIdentities: [Self.other],
            incomingDetails: nil,
            now: Self.t0
        )
        #expect(fromLegacy.identities == [Self.key, Self.other].sorted())
        #expect(fromLegacy.details[Self.key] == detail)
        // 新格式并进旧格式: 证据表原样带过去, 旧墓碑保持无证据。
        let intoLegacy = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [Self.other],
            localDetails: nil,
            incomingIdentities: [Self.key],
            incomingDetails: [Self.key: detail],
            now: Self.t0
        )
        #expect(intoLegacy.identities == [Self.key, Self.other].sorted())
        #expect(intoLegacy.details[Self.other] == nil)
    }

    @Test("Revoked evidence is kept for the retention window and dropped afterwards")
    func revokedEvidenceExpires() {
        let revived = LibrarySongTombstoneDetail(
            deletedAt: Self.t0,
            sourceFileDeleted: true,
            revivedAt: Self.t0.addingTimeInterval(60)
        )
        let retention = LibrarySongTombstoneLedgerMergePolicy.revivedRetention
        let withinWindow = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [],
            localDetails: [Self.key: revived],
            incomingIdentities: [Self.key],
            incomingDetails: nil,
            now: Self.t0.addingTimeInterval(60 + retention - 1)
        )
        #expect(withinWindow.identities.isEmpty)
        #expect(withinWindow.details[Self.key] != nil)

        let afterWindow = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [],
            localDetails: [Self.key: revived],
            incomingIdentities: [],
            incomingDetails: nil,
            now: Self.t0.addingTimeInterval(60 + retention + 1)
        )
        #expect(afterWindow.identities.isEmpty)
        #expect(afterWindow.details.isEmpty)
    }

    @Test("Evidence for an identity nobody tombstones any more is dropped")
    func orphanEvidenceIsDropped() {
        let active = LibrarySongTombstoneDetail(deletedAt: Self.t0, sourceFileDeleted: true)
        let merged = LibrarySongTombstoneLedgerMergePolicy.merge(
            localIdentities: [],
            localDetails: [Self.key: active],
            incomingIdentities: [],
            incomingDetails: nil,
            now: Self.t0
        )
        #expect(merged.identities.isEmpty)
        #expect(merged.details.isEmpty)
    }
}
