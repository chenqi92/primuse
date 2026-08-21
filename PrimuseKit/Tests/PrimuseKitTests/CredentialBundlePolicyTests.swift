import Testing
@testable import PrimuseKit

@Suite("Credential bundle synchronization policy")
struct CredentialBundlePolicyTests {
    @Test("Empty authoritative bundle deletes the cloud singleton")
    func emptyBundleDeletesSnapshot() {
        #expect(CredentialBundlePolicy.writeAction(for: CredentialBundle()) == .deleteRecord)

        let relayOnly = CredentialBundle(
            relay: RelayEndpoint(host: "192.0.2.1", port: 8765, token: "relay")
        )
        #expect(CredentialBundlePolicy.writeAction(for: relayOnly) == .saveRecord)

        let entryOnly = CredentialBundle(entries: ["source": CredentialEntry(password: "secret")])
        #expect(CredentialBundlePolicy.writeAction(for: entryOnly) == .saveRecord)
    }

    @Test("Merge retains active TV-only entries and prunes missing sources")
    func mergeRetainsOnlyActiveSources() {
        let oldRelay = RelayEndpoint(host: "192.0.2.1", port: 9000, token: "old")
        let current = CredentialBundle(
            version: 1,
            entries: [
                "tv-only": CredentialEntry(password: "tv"),
                "shared": CredentialEntry(password: "old"),
                "deleted": CredentialEntry(password: "stale"),
            ],
            relay: oldRelay
        )
        let incoming = CredentialBundle(
            version: 2,
            entries: [
                "shared": CredentialEntry(password: "new"),
                "unknown": CredentialEntry(password: "discard"),
            ]
        )

        let result = CredentialBundlePolicy.merging(
            current: current,
            incoming: incoming,
            activeSourceIDs: ["tv-only", "shared"]
        )

        #expect(result.version == 2)
        #expect(result.entries["tv-only"]?.password == "tv")
        #expect(result.entries["shared"]?.password == "new")
        #expect(result.entries["deleted"] == nil)
        #expect(result.entries["unknown"] == nil)
        #expect(result.relay == oldRelay)
    }

    @Test("Pruning an unavailable cloud download never removes active local credentials")
    func localCredentialsSurviveCloudUnavailability() {
        let local = CredentialBundle(entries: [
            "active": CredentialEntry(password: "keep"),
            "deleted": CredentialEntry(password: "drop"),
        ])

        // A failed download is deliberately nil rather than an incoming empty
        // authority. The local source list can still safely remove only the
        // known-deleted entry.
        let result = CredentialBundlePolicy.merging(
            current: local,
            incoming: nil,
            activeSourceIDs: ["active"]
        )

        #expect(result.entries["active"]?.password == "keep")
        #expect(result.entries["deleted"] == nil)
    }

    @Test("Targeted source removal preserves unrelated credentials and relay")
    func targetedRemovalIsNarrow() {
        let relay = RelayEndpoint(host: "192.0.2.2", port: 9100, token: "relay")
        let original = CredentialBundle(
            entries: [
                "remove": CredentialEntry(password: "gone"),
                "keep": CredentialEntry(token: "token"),
            ],
            relay: relay
        )

        let result = CredentialBundlePolicy.removing(sourceID: "remove", from: original)

        #expect(result.entries["remove"] == nil)
        #expect(result.entries["keep"]?.token == "token")
        #expect(result.relay == relay)
    }

    @Test("An empty first result rebases against a concurrent credential addition")
    func lastRemovalPreservesConcurrentAddition() {
        let observed = CredentialBundle(entries: [
            "deleted": CredentialEntry(password: "old"),
        ])
        let firstResult = CredentialBundlePolicy.removing(
            sourceIDs: Set(observed.entries.keys),
            relayIfMatching: observed.relay,
            from: observed
        )
        #expect(CredentialBundlePolicy.writeAction(for: firstResult) == .deleteRecord)

        let conflictWinner = CredentialBundle(entries: [
            "deleted": CredentialEntry(password: "old"),
            "concurrent": CredentialEntry(token: "new"),
        ])
        let rebased = CredentialBundlePolicy.removing(
            sourceIDs: Set(observed.entries.keys),
            relayIfMatching: observed.relay,
            from: conflictWinner
        )

        #expect(rebased.entries["deleted"] == nil)
        #expect(rebased.entries["concurrent"]?.token == "new")
        #expect(CredentialBundlePolicy.writeAction(for: rebased) == .saveRecord)
    }

    @Test("Relay removal only applies to the value observed before the conflict")
    func relayRemovalIsCompareAndSwap() {
        let oldRelay = RelayEndpoint(host: "192.0.2.1", port: 9000, token: "old")
        let newRelay = RelayEndpoint(host: "192.0.2.2", port: 9001, token: "new")
        let conflictWinner = CredentialBundle(relay: newRelay)

        let rebased = CredentialBundlePolicy.removing(
            sourceIDs: [],
            relayIfMatching: oldRelay,
            from: conflictWinner
        )

        #expect(rebased.relay == newRelay)
    }

    @Test("OAuth refresh updates one source without erasing unrelated secrets")
    func oauthRefreshIsTargeted() {
        let relay = RelayEndpoint(host: "192.0.2.9", port: 9200, token: "relay")
        let original = CredentialBundle(
            entries: [
                "cloud": CredentialEntry(
                    username: "account",
                    password: "keep-password",
                    token: "old-access",
                    refreshToken: "old-refresh",
                    clientID: "client",
                    clientSecret: "secret",
                    extra: ["drive_id": "drive", "keep": "value"]
                ),
                "other": CredentialEntry(token: "untouched"),
            ],
            relay: relay
        )

        let result = CredentialBundlePolicy.refreshingOAuthCredential(
            sourceID: "cloud",
            credential: SourceCredential(
                token: "new-access",
                refreshToken: "new-refresh",
                clientID: "client",
                extra: ["drive_id": "drive"]
            ),
            in: original
        )

        #expect(result.entries["cloud"]?.token == "new-access")
        #expect(result.entries["cloud"]?.refreshToken == "new-refresh")
        #expect(result.entries["cloud"]?.password == "keep-password")
        #expect(result.entries["cloud"]?.clientSecret == "secret")
        #expect(result.entries["cloud"]?.extra["keep"] == "value")
        #expect(result.entries["other"]?.token == "untouched")
        #expect(result.relay == relay)
    }

    @Test("Missing rotated refresh token preserves the last durable token")
    func absentRefreshTokenDoesNotEraseExistingValue() {
        let original = CredentialBundle(entries: [
            "dropbox": CredentialEntry(
                token: "old-access",
                refreshToken: "durable-refresh"
            ),
        ])

        let result = CredentialBundlePolicy.refreshingOAuthCredential(
            sourceID: "dropbox",
            credential: SourceCredential(token: "new-access", refreshToken: "  "),
            in: original
        )

        #expect(result.entries["dropbox"]?.token == "new-access")
        #expect(result.entries["dropbox"]?.refreshToken == "durable-refresh")
    }
}
