import Foundation
import Testing
@testable import PrimuseKit

struct SourceCatalogSnapshotPolicyTests {
    private func song(
        id: String,
        title: String = "Song",
        revision: String? = "r1"
    ) -> Song {
        Song(
            id: id,
            title: title,
            fileFormat: .mp3,
            filePath: "/\(id).mp3",
            sourceID: "source",
            fileSize: 1_024,
            dateAdded: Date(timeIntervalSince1970: 1),
            revision: revision
        )
    }

    @Test func reorderedEquivalentSnapshotIsNoOp() {
        let first = song(id: "one")
        let second = song(id: "two")
        #expect(!SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first, second],
            candidate: [second, first]
        ))
    }

    @Test func additionsAndContentChangesAreDetected() {
        let first = song(id: "one")
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [first, song(id: "two")]
        ))
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [song(id: "one", title: "Changed")]
        ))
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first],
            candidate: [song(id: "one", revision: "r2")]
        ))
    }

    @Test func duplicateIDsFailClosed() {
        let first = song(id: "one")
        let second = song(id: "two")
        #expect(SourceCatalogSnapshotPolicy.hasChanges(
            existing: [first, second],
            candidate: [first, first]
        ))
    }
}

struct ServerCatalogRefreshPolicyTests {
    private let localScan = Date(timeIntervalSince1970: 1_000)

    @Test func firstCheckUsesPersistedLocalScanAsBaseline() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .noChanges)
    }

    @Test func newerServerScanOrDifferentCountRequiresRefresh() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 900),
            lastAppliedItemCount: 2,
            serverLastScanAt: Date(timeIntervalSince1970: 1_100),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 1_100),
            lastAppliedItemCount: 2,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 2,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: 3,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .refresh)
    }

    @Test func activeServerScanDefersWithoutTreatingProgressAsTotal() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: true,
            lastAppliedServerScanAt: Date(timeIntervalSince1970: 900),
            lastAppliedItemCount: 2_000,
            serverLastScanAt: Date(timeIntervalSince1970: 900),
            serverItemCount: 12,
            localLastScannedAt: localScan,
            localSongCount: 2_000
        ) == .deferWhileScanning)
    }

    @Test func noRemoteSignalsOnlyRefreshesAnUninitializedSource() {
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: nil,
            localLastScannedAt: localScan,
            localSongCount: 2
        ) == .noChanges)
        #expect(ServerCatalogRefreshPolicy.decision(
            serverIsScanning: false,
            lastAppliedServerScanAt: nil,
            lastAppliedItemCount: nil,
            serverLastScanAt: nil,
            serverItemCount: nil,
            localLastScannedAt: nil,
            localSongCount: 0
        ) == .refresh)
    }
}

struct AutomaticOfflineDownloadPolicyTests {
    private func eligibility(
        applicationIsActive: Bool = true,
        hasDeterminedNetwork: Bool = true,
        isReachable: Bool = true,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        isLowPowerModeEnabled: Bool = false,
        hasSeriousThermalPressure: Bool = false,
        availableDiskBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        expectedDownloadBytes: Int64 = 10 * 1_024 * 1_024,
        isPlaybackBuffering: Bool = false
    ) -> AutomaticOfflineDownloadEligibility {
        AutomaticOfflineDownloadPolicy.eligibility(
            applicationIsActive: applicationIsActive,
            hasDeterminedNetwork: hasDeterminedNetwork,
            isReachable: isReachable,
            isExpensive: isExpensive,
            isConstrained: isConstrained,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            hasSeriousThermalPressure: hasSeriousThermalPressure,
            availableDiskBytes: availableDiskBytes,
            expectedDownloadBytes: expectedDownloadBytes,
            isPlaybackBuffering: isPlaybackBuffering
        )
    }

    @Test func automaticWorkRequiresHealthyUnmeteredConditions() {
        #expect(eligibility() == .allowed)
        #expect(eligibility(hasDeterminedNetwork: false) == .deferred(.networkUndetermined))
        #expect(eligibility(isReachable: false) == .deferred(.networkUnavailable))
        #expect(eligibility(isExpensive: true) == .deferred(.expensiveNetwork))
        #expect(eligibility(isConstrained: true) == .deferred(.constrainedNetwork))
        #expect(eligibility(isLowPowerModeEnabled: true) == .deferred(.lowPower))
        #expect(eligibility(hasSeriousThermalPressure: true) == .deferred(.thermalPressure))
        #expect(eligibility(availableDiskBytes: 128 * 1_024 * 1_024) == .deferred(.insufficientDiskSpace))
        #expect(eligibility(isPlaybackBuffering: true) == .deferred(.playbackBuffering))
        #expect(eligibility(applicationIsActive: false) == .deferred(.applicationInactive))
    }

    @Test func onlyMissingOrChangedContentIsQueued() {
        let desired = ["one": "r1", "two": "r2", "three": "r3"]
        let completed = ["one": "r1", "two": "old", "three": "r3"]
        #expect(AutomaticOfflineDownloadPolicy.requiredSongIDs(
            desiredSignatures: desired,
            completedSignatures: completed,
            missingSongIDs: ["three"]
        ) == ["two", "three"])
    }

    @Test func accountChangeCannotAdoptBytesFromAnOlderAutomaticTransfer() {
        #expect(AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: nil
        ))
        #expect(!AutomaticOfflineDownloadPolicy.canAdoptExistingFile(
            desiredSignature: "new-account",
            completedSignature: nil,
            lastKnownSignature: "old-account"
        ))
        #expect(AutomaticOfflineDownloadPolicy.requiresContentRefresh(
            desiredSignature: "new-account",
            completedSignature: "old-account",
            lastKnownSignature: "old-account"
        ))
    }
}
