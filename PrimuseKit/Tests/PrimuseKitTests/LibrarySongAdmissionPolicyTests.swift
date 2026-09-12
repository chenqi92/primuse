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
