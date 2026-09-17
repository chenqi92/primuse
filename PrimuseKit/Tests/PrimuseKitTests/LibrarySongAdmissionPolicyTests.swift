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
