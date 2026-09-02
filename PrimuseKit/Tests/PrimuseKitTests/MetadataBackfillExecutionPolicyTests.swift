import Testing
@testable import PrimuseKit

@Suite("Metadata backfill execution")
struct MetadataBackfillExecutionPolicyTests {
    @Test("Bare-only sources stop after their initial detail read")
    func bareOnlyEligibility() {
        let pending = MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .flac,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true
        )
        let completed = MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true
        )
        let terminalIncomplete = MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .dts,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true,
            durationInspectionComplete: true
        )

        #expect(pending.contains(.duration))
        #expect(pending.contains(.title))
        #expect(completed.isEmpty)
        #expect(terminalIncomplete.isEmpty)
    }

    @Test("Background work is serial, throttled, and bounded per wake")
    func boundedBackgroundLimits() {
        let standard = MetadataBackfillExecutionPolicy.limits(for: .standard)
        let userInitiated = MetadataBackfillExecutionPolicy.limits(for: .userInitiated)
        let deviceLocal = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundDeviceLocal
        )
        let foreground = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan
        )
        let background = MetadataBackfillExecutionPolicy.limits(for: .background)
        let playback = MetadataBackfillExecutionPolicy.limits(for: .backgroundDuringPlayback)

        #expect(standard.workerCount == 3)
        #expect(standard.snapshotPassLimit == nil)
        #expect(userInitiated.workerCount == 1)
        #expect(userInitiated.snapshotLimit > foreground.snapshotLimit)
        #expect(userInitiated.interRequestDelay > 0)
        #expect(userInitiated.snapshotPassLimit == nil)
        #expect(deviceLocal.workerCount == 1)
        #expect(deviceLocal.snapshotLimit > foreground.snapshotLimit)
        #expect(deviceLocal.interRequestDelay < foreground.interRequestDelay)
        #expect(deviceLocal.snapshotPassLimit == nil)
        #expect(foreground.workerCount == 1)
        #expect(foreground.snapshotLimit <= background.snapshotLimit)
        #expect(foreground.interRequestDelay >= background.interRequestDelay)
        #expect(foreground.snapshotPassLimit == 1)
        #expect(background.workerCount == 1)
        #expect(background.snapshotPassLimit == 1)
        #expect(playback.workerCount == 1)
        #expect(playback.snapshotLimit < background.snapshotLimit)
        #expect(playback.interRequestDelay > background.interRequestDelay)
        #expect(playback.flushInterval >= background.flushInterval)
        #expect(playback.snapshotPassLimit == 1)
    }

    @Test("Foreground sandbox imports continue beyond the first snapshot")
    func foregroundSandboxImportDrainsLargeQueues() {
        let limits = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundDeviceLocal
        )
        var remaining = 241
        var processed = 0
        var passes = 0

        while remaining > 0,
              limits.snapshotPassLimit.map({ passes < $0 }) ?? true {
            let batch = min(remaining, limits.snapshotLimit)
            remaining -= batch
            processed += batch
            passes += 1
        }

        #expect(processed == 241)
        #expect(remaining == 0)
        #expect(passes > 1)
    }

    @Test("Only copied local music bypasses network gating")
    func copiedLocalSourceClassification() {
        #expect(DeviceLocalSourcePolicy.isManagedCopy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: "/private/container/Documents/LocalMusic"
        ))
        #expect(!DeviceLocalSourcePolicy.isManagedCopy(
            isLocalSource: true,
            sourceID: "file-provider",
            persistedImportSourceID: "copied",
            basePath: "/private/provider/Music"
        ))
        #expect(!DeviceLocalSourcePolicy.isManagedCopy(
            isLocalSource: false,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: "/private/container/Documents/LocalMusic"
        ))
    }

    @Test("Stream descriptors retain their enrichment path on bare sources")
    func streamDescriptorsAreNotRestrictedToBareAudioRules() {
        #expect(MetadataBackfillEligibilityPolicy.restrictsToBareRows(
            sourceUsesBareInventory: true,
            isStreamDescriptor: false
        ))
        #expect(!MetadataBackfillEligibilityPolicy.restrictsToBareRows(
            sourceUsesBareInventory: true,
            isStreamDescriptor: true
        ))
    }

    @Test("Mixed pending work wakes offline before requiring network")
    func backgroundNetworkRequirement() {
        #expect(!MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetwork(
            hasPendingWork: true,
            pendingSourceIDs: ["copied", "file-provider"],
            offlineReadableSourceIDs: ["copied"]
        ))
        #expect(MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetwork(
            hasPendingWork: true,
            pendingSourceIDs: ["file-provider"],
            offlineReadableSourceIDs: ["copied"]
        ))
        #expect(MetadataBackfillNetworkPolicy.allowedSourceIDs(
            networkIsBlocked: true,
            offlineReadableSourceIDs: ["copied"]
        ) == ["copied"])
        #expect(MetadataBackfillNetworkPolicy.allowedSourceIDs(
            networkIsBlocked: false,
            offlineReadableSourceIDs: ["copied"]
        ) == nil)
    }
}
