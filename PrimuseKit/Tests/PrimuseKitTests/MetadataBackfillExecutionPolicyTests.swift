import Testing
@testable import PrimuseKit

@Suite("Metadata backfill execution")
struct MetadataBackfillExecutionPolicyTests {
    @Test("Only a plain background window keeps an earlier expiration in force")
    func backgroundExpirationClearsForAudioBackedAndForegroundModes() {
        #expect(!MetadataBackfillExecutionPolicy.clearsBackgroundExpiration(entering: .background))
        #expect(MetadataBackfillExecutionPolicy.clearsBackgroundExpiration(entering: .backgroundDuringPlayback))
        #expect(MetadataBackfillExecutionPolicy.clearsBackgroundExpiration(entering: .standard))
        #expect(MetadataBackfillExecutionPolicy.clearsBackgroundExpiration(entering: .userInitiated))
    }

    @Test("Prewarm seeds never replace a sparse file owned by playback")
    func prewarmSeedRespectsPlaybackOwnership() {
        #expect(AudioCachePrewarmSeedPolicy.canReplaceSparseFile(isActiveSessionPath: false, activePlaybackUses: 0, hasPlaybackLease: false))
        #expect(!AudioCachePrewarmSeedPolicy.canReplaceSparseFile(isActiveSessionPath: true, activePlaybackUses: 0, hasPlaybackLease: false))
        #expect(!AudioCachePrewarmSeedPolicy.canReplaceSparseFile(isActiveSessionPath: false, activePlaybackUses: 1, hasPlaybackLease: false))
        #expect(!AudioCachePrewarmSeedPolicy.canReplaceSparseFile(isActiveSessionPath: false, activePlaybackUses: 0, hasPlaybackLease: true))
    }

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

    @Test("Background work drains bounded snapshots until its execution time expires")
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

        #expect(standard.workerCount == 2)
        #expect(standard.snapshotPassLimit == nil)
        #expect(userInitiated.workerCount == foreground.workerCount)
        #expect(userInitiated.snapshotLimit == foreground.snapshotLimit)
        #expect(userInitiated.interRequestDelay == 0)
        #expect(userInitiated.snapshotPassLimit == nil)
        #expect(deviceLocal.workerCount == 3)
        #expect(deviceLocal.snapshotLimit == foreground.snapshotLimit)
        #expect(deviceLocal.interRequestDelay == 0)
        #expect(deviceLocal.snapshotPassLimit == nil)
        #expect(foreground.workerCount == 2)
        #expect(foreground.snapshotLimit > background.snapshotLimit)
        #expect(foreground.interRequestDelay == 0)
        #expect(foreground.snapshotPassLimit == nil)
        #expect(background.workerCount == 1)
        #expect(background.snapshotPassLimit == nil)
        #expect(playback.workerCount == 1)
        #expect(playback.snapshotLimit < background.snapshotLimit)
        #expect(playback.interRequestDelay > background.interRequestDelay)
        #expect(playback.flushInterval >= background.flushInterval)
        #expect(playback.snapshotPassLimit == nil)
    }

    @Test("Background audio and processing do not stop after 8 or 24 songs")
    func backgroundDrainsMultipleSnapshots() {
        for mode in [MetadataBackfillExecutionMode.background, .backgroundDuringPlayback] {
            let limits = MetadataBackfillExecutionPolicy.limits(for: mode, preference: .fast)
            var remaining = 241
            var passes = 0
            while remaining > 0, limits.snapshotPassLimit.map({ passes < $0 }) ?? true {
                remaining -= min(remaining, limits.snapshotLimit)
                passes += 1
            }
            #expect(remaining == 0)
            #expect(passes > 1)
            #expect(limits.workerCount == 1)
            #expect(limits.interRequestDelay == 0)
        }
    }

    @Test("Foreground source scans continue beyond the first snapshot")
    func foregroundSourceScanDrainsLargeQueues() {
        let limits = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan
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

    @Test("High-performance scan reading increases foreground throughput only")
    func highPerformanceScanReadingIsForegroundOnly() {
        let gentle = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan
        )
        let fast = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan,
            highPerformanceAfterScanEnabled: true
        )
        let fastLocal = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundDeviceLocal,
            highPerformanceAfterScanEnabled: true
        )
        let background = MetadataBackfillExecutionPolicy.limits(
            for: .background,
            highPerformanceAfterScanEnabled: true
        )

        #expect(fast.workerCount > gentle.workerCount)
        #expect(fast.snapshotLimit > gentle.snapshotLimit)
        #expect(fast.interRequestDelay == 0)
        #expect(fast.snapshotPassLimit == nil)
        #expect(fastLocal == fast)
        #expect(background.workerCount == 1)
        #expect(background.snapshotLimit == 24)
        #expect(background.snapshotPassLimit == nil)
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

    @Test("Only the exact managed copy source owns files during removal")
    func copiedLocalSourceClassification() {
        let managedRoot = "/private/container/Documents/LocalMusic"

        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: managedRoot,
            managedRootPath: managedRoot
        ) == .deleteManagedCopies)
        #expect(DeviceLocalSourcePolicy.isManagedCopy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: managedRoot,
            managedRootPath: managedRoot
        ))

        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: true,
            sourceID: "file-provider",
            persistedImportSourceID: "copied",
            basePath: "/private/provider/Music",
            managedRootPath: managedRoot
        ) == .preserveReferencedFiles)
        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: "/private/provider/LocalMusic",
            managedRootPath: managedRoot
        ) == .preserveReferencedFiles)
        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: false,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: managedRoot,
            managedRootPath: managedRoot
        ) == .preserveReferencedFiles)
        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: nil,
            basePath: managedRoot,
            managedRootPath: managedRoot
        ) == .preserveReferencedFiles)
        #expect(DeviceLocalSourcePolicy.removalPolicy(
            isLocalSource: true,
            sourceID: "copied",
            persistedImportSourceID: "copied",
            basePath: nil,
            managedRootPath: managedRoot
        ) == .preserveReferencedFiles)
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

    @Test("A library publication reconciles off the main actor before starting")
    func automaticQueueRefreshDefersTheForcedReconcile() {
        // 扫描每提交一批歌就会走一次 refreshQueue。没有 worker、也没有在等
        // worker 的后台会话时, 那一次整库对账必须交给 off-main 变体, 不能占用
        // 调用方(scenePhase 回调 / songs.count onChange)这一个主 actor turn。
        #expect(MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: true,
            workerIsRunning: false,
            requiresSynchronousStart: false
        ) == .deferredOffMain)
        // BGProcessing 排干与 continued-processing 只看 worker != nil,
        // 推迟 start() 会让它们判定"没有工作"而提前结束。
        #expect(MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: true,
            workerIsRunning: false,
            requiresSynchronousStart: true
        ) == .synchronous)
        // 已经有 worker 在跑, 或调用方只要求标脏: 两种情况都不对账。
        #expect(MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: true,
            workerIsRunning: true,
            requiresSynchronousStart: false
        ) == .markDirtyOnly)
        #expect(MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: false,
            workerIsRunning: false,
            requiresSynchronousStart: false
        ) == .markDirtyOnly)
        #expect(MetadataBackfillQueueRefreshPolicy.reconciliation(
            startImmediately: false,
            workerIsRunning: false,
            requiresSynchronousStart: true
        ) == .markDirtyOnly)
    }
}
