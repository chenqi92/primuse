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

    @Test("A dirty queue answers the wake requirement from the source set")
    func cachedCountWakeRequirementFallsBackToSources() {
        // 缓存是新的: 和原来的判定逐字一致 —— 混合队列先不要网络地唤醒,
        // 只剩远端行时才要求联网。
        #expect(!MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: false,
            hasPendingWork: true,
            pendingSourceIDs: ["copied", "file-provider"],
            backfillableSourceIDs: ["copied", "file-provider"],
            offlineReadableSourceIDs: ["copied"]
        ))
        #expect(MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: false,
            hasPendingWork: true,
            pendingSourceIDs: ["file-provider"],
            backfillableSourceIDs: ["copied", "file-provider"],
            offlineReadableSourceIDs: ["copied"]
        ))
        // 队列刚被标脏, 每源剩余数还是上一轮的 (这里退化成空集): 不能再用
        // "空集与任何集合 disjoint" 得出需要网络的结论。全部可回填的源都是
        // 离线可读时, 这次唤醒不要求网络, 本地导入的行在无网设备上也能排干。
        #expect(!MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: true,
            hasPendingWork: true,
            pendingSourceIDs: [],
            backfillableSourceIDs: ["copied"],
            offlineReadableSourceIDs: ["copied"]
        ))
        // 只要还有一个源不是离线可读, 脏队列就保守地按需要网络申请。
        #expect(MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: true,
            hasPendingWork: true,
            pendingSourceIDs: ["copied"],
            backfillableSourceIDs: ["copied", "webdav"],
            offlineReadableSourceIDs: ["copied"]
        ))
        // 没有可回填的源 / 没有待办工作时都不要求网络。
        #expect(!MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: true,
            hasPendingWork: true,
            pendingSourceIDs: [],
            backfillableSourceIDs: [],
            offlineReadableSourceIDs: []
        ))
        #expect(!MetadataBackfillNetworkPolicy.backgroundWakeRequiresNetworkFromCachedCounts(
            queueNeedsReconcile: true,
            hasPendingWork: false,
            pendingSourceIDs: [],
            backfillableSourceIDs: ["webdav"],
            offlineReadableSourceIDs: []
        ))
    }

    @Test("A superseded reconcile keeps the remaining-count throttle in force")
    func supersededReconcileDoesNotResetTheThrottle() {
        // 被顶替的那次刷新不回退节流时间戳, 否则接管者的 start() 会在主 actor
        // 上把整库对账再同步做一遍。
        #expect(!MetadataBackfillRemainingCountRefreshPolicy.throttleResetsAfterFailure(
            reason: .supersededComputation
        ))
        // 资料库/队列真的变了: 缓存的计数已经不可信, 下一次对账必须放行。
        #expect(MetadataBackfillRemainingCountRefreshPolicy.throttleResetsAfterFailure(
            reason: .inputsChanged
        ))
    }

    @Test("A song-generation move publishes the counts but keeps the queue dirty")
    func songGenerationMoveStillPublishesCounts() {
        // 扫描每 1.5 s 发布一次库, detached 计算几乎必然跨过一次歌曲代次变化。
        // 结果仍然是一份自洽的过去状态, 源卡片可以照它刷新。
        #expect(MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: false,
            songGenerationChanged: true,
            queueGenerationChanged: false,
            semanticInputsChanged: false
        ) == .applyKeepingQueueDirty)
    }

    @Test("Nothing moved reconciles the queue")
    func unchangedInputsReconcile() {
        #expect(MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: false,
            songGenerationChanged: false,
            queueGenerationChanged: false,
            semanticInputsChanged: false
        ) == .apply)
    }

    @Test("A superseded or semantically different snapshot is discarded")
    func supersededOrSemanticChangeDiscards() {
        #expect(MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: true,
            songGenerationChanged: false,
            queueGenerationChanged: false,
            semanticInputsChanged: false
        ) == .discard)
        // 队列代次动了: 结果回答的是另一批待办。
        #expect(MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: false,
            songGenerationChanged: true,
            queueGenerationChanged: true,
            semanticInputsChanged: false
        ) == .discard)
        // 源集合 / 禁用集合 / Wi-Fi 等待状态变了, 同理。
        #expect(MetadataBackfillRemainingCountRefreshPolicy.application(
            superseded: false,
            songGenerationChanged: false,
            queueGenerationChanged: false,
            semanticInputsChanged: true
        ) == .discard)
    }
}
