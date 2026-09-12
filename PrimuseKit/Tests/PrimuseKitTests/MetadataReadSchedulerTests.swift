import Foundation
import Testing
@testable import PrimuseKit

@Suite("Adaptive metadata reading")
struct MetadataReadSchedulerTests {
    @Test @MainActor func fullSpeedRecoversAfterEnergySavingWithoutRestartingQueue() async throws {
        let scheduler = MetadataReadScheduler<Int, Int>()
        let environment = MetadataReadingEnvironment(device: .init(
            platform: .mobile, activeProcessorCount: 6, physicalMemory: 8 * 1_024 * 1_024 * 1_024
        ))
        var mode = MetadataReadingMode.fast
        var started: [Int] = []
        var completed: [Int] = []
        var gates: [Int: CheckedContinuation<Int, Never>] = [:]
        let task = Task {
            await scheduler.run(
                items: Array(0..<8),
                limits: { MetadataBackfillExecutionPolicy.limits(
                    for: .userInitiated, preference: mode, environment: environment
                ) },
                read: { item in
                    started.append(item)
                    return await withCheckedContinuation { gates[item] = $0 }
                },
                completed: { item, _ in completed.append(item) }
            )
        }
        defer {
            task.cancel()
            for (item, gate) in gates { gate.resume(returning: item) }
        }
        try await waitUntil { started.count == 4 }
        mode = .energySaving
        scheduler.configurationChanged()
        for item in [0, 1, 2] { gates.removeValue(forKey: item)?.resume(returning: item) }
        try await waitUntil { completed.count == 3 }
        #expect(started.sorted() == [0, 1, 2, 3])
        gates.removeValue(forKey: 3)?.resume(returning: 3)
        try await waitUntil { started.count == 5 }
        #expect(scheduler.inFlightCount == 1)
        mode = .fast
        scheduler.configurationChanged()
        try await waitUntil { started.count == 8 }
        #expect(scheduler.inFlightCount == 4)
        for item in [4, 5, 6, 7] { gates.removeValue(forKey: item)?.resume(returning: item) }
        #expect(await task.value == false)
        #expect(completed.sorted() == Array(0..<8))
    }

    @Test @MainActor func failedFileDoesNotStopLaterReads() async {
        enum FileFailure: Error { case unreadable }
        let scheduler = MetadataReadScheduler<Int, Result<Int, FileFailure>>()
        var completed: [Int] = []
        var failed: [Int] = []
        let cancelled = await scheduler.run(
            items: [1, 2, 3],
            limits: { .init(workerCount: 1, snapshotLimit: 3, interRequestDelay: 0, flushInterval: 1) },
            read: { $0 == 2 ? .failure(.unreadable) : .success($0) }
        ) { item, result in
            completed.append(item)
            if case .failure = result { failed.append(item) }
        }
        #expect(!cancelled)
        #expect(completed == [1, 2, 3])
        #expect(failed == [2])
    }

    @Test func deviceBudgetsAccountForCoresMemoryAndPlatform() {
        let gib: UInt64 = 1_024 * 1_024 * 1_024
        let profiles: [(MetadataReadingDeviceProfile.Platform, Int, UInt64, Int)] = [
            (.mobile, 2, 2, 1), (.mobile, 6, 3, 3), (.mobile, 6, 8, 5),
            (.mobile, 10, 16, 6), (.desktop, 8, 8, 4), (.desktop, 16, 32, 8),
            (.television, 4, 2, 2), (.television, 6, 4, 4)
        ]
        for (platform, cores, memory, expected) in profiles {
            let profile = MetadataReadingDeviceProfile(
                platform: platform, activeProcessorCount: cores, physicalMemory: memory * gib
            )
            let environment = MetadataReadingEnvironment(offlineSource: true, device: profile)
            let fast = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .fast, environment: environment
            )
            let automatic = MetadataBackfillExecutionPolicy.limits(
                for: .standard, preference: .automatic, environment: environment
            )
            #expect(fast.workerCount == expected)
            #expect(automatic.workerCount <= fast.workerCount)
            #expect(automatic.workerCount >= 1)
            #expect(profile.maximumWorkers(offlineSource: false) == min(expected, 4))
        }
    }

    @Test func deviceBudgetDoesNotTrustLargeOrMissingHardwareValues() {
        for platform in [MetadataReadingDeviceProfile.Platform.mobile, .desktop, .television] {
            let missing = MetadataReadingDeviceProfile(platform: platform, activeProcessorCount: 0, physicalMemory: 0)
            #expect(missing.maximumWorkers(offlineSource: true) == 1)
            let large = MetadataReadingDeviceProfile(platform: platform, activeProcessorCount: Int.max, physicalMemory: UInt64.max)
            #expect(large.maximumWorkers(offlineSource: true) <= 8)
            #expect(large.maximumWorkers(offlineSource: false) <= 4)
        }
    }

    @Test func deviceCapacityNeverOverridesProtection() {
        for platform in [MetadataReadingDeviceProfile.Platform.mobile, .desktop, .television] {
            for preference in MetadataReadingMode.allCases {
                let device = MetadataReadingDeviceProfile(
                    platform: platform, activeProcessorCount: 64, physicalMemory: 128 * 1_024 * 1_024 * 1_024
                )
                var environment = MetadataReadingEnvironment(offlineSource: true, device: device)
                environment.thermalState = .critical
                #expect(MetadataBackfillExecutionPolicy.limits(for: .standard, preference: preference, environment: environment).workerCount == 0)
                environment.thermalState = .nominal
                environment.lowPowerMode = true
                #expect(MetadataBackfillExecutionPolicy.limits(for: .standard, preference: preference, environment: environment).workerCount == 1)
                environment.lowPowerMode = false
                environment.playbackActive = true
                let playing = MetadataBackfillExecutionPolicy.limits(for: .standard, preference: preference, environment: environment)
                #expect(playing.workerCount <= (platform == .television ? 1 : 2))
                #expect(MetadataBackfillExecutionPolicy.limits(for: .background, preference: preference, environment: environment).workerCount == 1)
            }
        }
    }

    @Test @MainActor func completionFailureStopsEvenWhenBudgetBecomesZero() async {
        let scheduler = MetadataReadScheduler<Int, Int>()
        var workers = 1
        var failed = false
        var reads: [Int] = []
        let cancelled = await scheduler.run(
            items: [1, 2, 3],
            limits: { .init(workerCount: workers, snapshotLimit: 3, interRequestDelay: 0, flushInterval: 5) },
            shouldContinue: { !failed },
            read: { item in reads.append(item); return item },
            completed: { _, _ in failed = true; workers = 0 }
        )
        #expect(cancelled)
        #expect(reads == [1])
    }

    @Test func preferencesMigrateWithoutOverridingExplicitSelection() {
        #expect(MetadataReadingMode.resolve(storedValue: nil, legacyFastEnabled: false) == .automatic)
        #expect(MetadataReadingMode.resolve(storedValue: nil, legacyFastEnabled: true) == .fast)
        #expect(MetadataReadingMode.resolve(storedValue: "energySaving", legacyFastEnabled: true) == .energySaving)
    }

    @Test func foregroundEntrypointsShareTheSelectedBudget() {
        for preference in MetadataReadingMode.allCases {
            let scan = MetadataBackfillExecutionPolicy.limits(for: .foregroundAfterSourceScan, preference: preference)
            #expect(scan == MetadataBackfillExecutionPolicy.limits(for: .userInitiated, preference: preference))
            #expect(scan == MetadataBackfillExecutionPolicy.limits(for: .standard, preference: preference))
        }
    }

    @Test func fullSpeedUsesHigherButBoundedConcurrency() {
        for offline in [false, true] {
            let environment = MetadataReadingEnvironment(offlineSource: offline)
            let automatic = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .automatic, environment: environment
            )
            let fast = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .fast, environment: environment
            )
            #expect(fast.workerCount > automatic.workerCount)
            #expect(fast.workerCount <= 4)
            #expect(fast.interRequestDelay == 0)
        }
    }

    @Test func everyModeReducesWorkAsSoonAsTemperatureRises() {
        for preference in MetadataReadingMode.allCases {
            let warm = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: preference,
                environment: .init(thermalState: .fair)
            )
            if preference == .fast {
                #expect(warm.workerCount == 2)
                #expect(warm.interRequestDelay == 0)
            } else {
                #expect(warm.workerCount == 1)
                #expect(warm.interRequestDelay >= 0.35)
            }
        }
    }

    @Test func speedNeverOverridesThermalOrPlaybackProtection() {
        for preference in MetadataReadingMode.allCases {
            let paused = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: preference,
                environment: .init(thermalState: .critical)
            )
            #expect(paused.workerCount == 0)
            let hot = MetadataBackfillExecutionPolicy.limits(
                for: .foregroundAfterSourceScan, preference: preference,
                environment: .init(thermalState: .serious)
            )
            #expect(hot.workerCount == 1)
            #expect(hot.interRequestDelay >= 1.5)
            let playback = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: preference,
                environment: .init(playbackActive: true)
            )
            // 全速在播放期间保留三个读取位；自动与省电仍是一个。
            #expect(playback.workerCount == (preference == .fast ? 3 : 1))
            let lowPower = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: preference,
                environment: .init(lowPowerMode: true)
            )
            #expect(lowPower.workerCount == 1)
            #expect(lowPower.interRequestDelay > 0)
            let background = MetadataBackfillExecutionPolicy.limits(for: .background, preference: preference)
            #expect(background.snapshotLimit == 24 && background.snapshotPassLimit == nil)
        }
    }

    @Test func fullSpeedThermalCooldownScalesWithMeasuredWorkWithoutRemovingProtection() {
        for cost in [0.0, 0.01, 0.1, 0.3, 0.5, 2.0, .nan, .infinity, -1.0] {
            let limits = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .fast,
                environment: .init(thermalState: .serious), recentProcessingDuration: cost
            )
            #expect(limits.workerCount == 1)
            #expect(limits.interRequestDelay >= 0.1)
            if cost.isFinite && cost >= 0 && cost <= 0.5 {
                #expect(cost / (cost + limits.interRequestDelay) <= 0.25)
            } else {
                #expect(limits.interRequestDelay == 1.5)
            }
            let critical = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .fast,
                environment: .init(thermalState: .critical), recentProcessingDuration: cost
            )
            #expect(critical.workerCount == 0)
        }
        let lowPower = MetadataBackfillExecutionPolicy.limits(
            for: .background, preference: .fast,
            environment: .init(thermalState: .serious, lowPowerMode: true),
            continuedProcessing: true, recentProcessingDuration: 0.01
        )
        #expect(lowPower.workerCount == 1)
        #expect(lowPower.interRequestDelay >= 0.35)
        let automatic = MetadataBackfillExecutionPolicy.limits(
            for: .standard, preference: .automatic,
            environment: .init(thermalState: .serious), recentProcessingDuration: 0.01
        )
        #expect(automatic.interRequestDelay == 1.5)
    }

    @Test func thermalWorkBudgetExcludesIOWaitButIncludesOtherAppCPUWork() {
        let light = MetadataBackfillExecutionPolicy.processingDuration(
            cpuTimeBefore: 10, cpuTimeAfter: 10.02, fallback: 1.2
        )
        #expect(abs(light - 0.02) < 0.000001)
        let idle = MetadataBackfillExecutionPolicy.limits(
            for: .userInitiated, preference: .fast,
            environment: .init(thermalState: .serious), recentProcessingDuration: light
        )
        #expect(idle.workerCount == 1)
        #expect(idle.interRequestDelay == 0.1)
        // CPU work on multiple threads may exceed elapsed wall time; retaining
        // all of it prevents playback/UI work from disappearing from the budget.
        let busy = MetadataBackfillExecutionPolicy.processingDuration(
            cpuTimeBefore: 10, cpuTimeAfter: 10.6, fallback: 0.4
        )
        #expect(abs(busy - 0.6) < 0.000001)
        let hot = MetadataBackfillExecutionPolicy.limits(
            for: .userInitiated, preference: .fast,
            environment: .init(thermalState: .serious), recentProcessingDuration: busy
        )
        #expect(hot.workerCount == 1)
        #expect(hot.interRequestDelay == 1.5)
    }

    @Test func unavailableCPUCountersKeepConservativeCooldown() {
        let invalid: [(Double?, Double?)] = [(nil, 10), (10, nil), (10, 9), (-1, 10),
                                             (.nan, 10), (10, .infinity)]
        for (before, after) in invalid {
            #expect(MetadataBackfillExecutionPolicy.processingDuration(
                cpuTimeBefore: before, cpuTimeAfter: after, fallback: 0.8
            ) == 0.8)
        }
        for fallback in [-1.0, .nan, .infinity] {
            let cost = MetadataBackfillExecutionPolicy.processingDuration(
                cpuTimeBefore: nil, cpuTimeAfter: nil, fallback: fallback
            )
            let limits = MetadataBackfillExecutionPolicy.limits(
                for: .userInitiated, preference: .fast,
                environment: .init(thermalState: .serious), recentProcessingDuration: cost
            )
            #expect(limits.interRequestDelay == 1.5)
        }
    }

    @Test func continuedProcessingKeepsSelectedSpeedAndAllDeviceProtections() {
        for platform in [MetadataReadingDeviceProfile.Platform.mobile, .desktop, .television] {
            for thermal in [MetadataReadingThermalState.nominal, .fair, .serious, .critical] {
                for lowPower in [false, true] {
                    for playing in [false, true] {
                        let environment = MetadataReadingEnvironment(
                            thermalState: thermal, lowPowerMode: lowPower, playbackActive: playing,
                            device: .init(platform: platform, activeProcessorCount: 6,
                                          physicalMemory: 8 * 1_024 * 1_024 * 1_024)
                        )
                        let foreground = MetadataBackfillExecutionPolicy.limits(
                            for: .userInitiated, preference: .fast, environment: environment
                        )
                        let background = MetadataBackfillExecutionPolicy.limits(
                            for: playing ? .backgroundDuringPlayback : .background,
                            preference: .fast, environment: environment, continuedProcessing: true
                        )
                        #expect(background == foreground)
                    }
                }
            }
        }
    }

    @Test @MainActor func liveResizeAndThermalPausePreserveExactlyOnceReads() async throws {
        let scheduler = MetadataReadScheduler<Int, Int>()
        var workers = 1
        var started: [Int] = []
        var completed: [Int] = []
        var gates: [Int: CheckedContinuation<Int, Never>] = [:]
        let task = Task {
            await scheduler.run(
                items: Array(0..<6),
                limits: { .init(workerCount: workers, snapshotLimit: 6, interRequestDelay: 0, flushInterval: 5) },
                read: { item in
                    started.append(item)
                    return await withCheckedContinuation { gates[item] = $0 }
                },
                completed: { item, _ in completed.append(item) }
            )
        }
        defer {
            task.cancel()
            for (item, gate) in gates { gate.resume(returning: item) }
        }
        try await waitUntil { started.count == 1 }
        workers = 3
        scheduler.configurationChanged()
        try await waitUntil { started.count == 3 }
        workers = 1
        scheduler.configurationChanged()
        for item in [0, 1] { gates.removeValue(forKey: item)?.resume(returning: item) }
        try await waitUntil { completed.count == 2 }
        #expect(started == [0, 1, 2])
        gates.removeValue(forKey: 2)?.resume(returning: 2)
        try await waitUntil { started.count == 4 }
        workers = 0
        scheduler.configurationChanged()
        gates.removeValue(forKey: 3)?.resume(returning: 3)
        try await waitUntil { completed.count == 4 }
        #expect(started.count == 4)
        workers = 2
        scheduler.configurationChanged()
        try await waitUntil { started.count == 6 }
        for item in [4, 5] { gates.removeValue(forKey: item)?.resume(returning: item) }
        await task.value
        #expect(completed.sorted() == Array(0..<6))
    }

    @Test @MainActor func cancellingPausedQueueDoesNotReadOrHang() async {
        let scheduler = MetadataReadScheduler<Int, Int>()
        var reads = 0
        let task = Task {
            await scheduler.run(
                items: [1, 2],
                limits: { .init(workerCount: 0, snapshotLimit: 2, interRequestDelay: 0, flushInterval: 5) },
                read: { item in reads += 1; return item },
                completed: { _, _ in }
            )
        }
        await Task.yield()
        task.cancel()
        await task.value
        #expect(reads == 0)
    }

    @Test @MainActor func delayedReadsWaitForThermalRecovery() async throws {
        let scheduler = MetadataReadScheduler<Int, Int>()
        var workers = 1
        var reads: [Int] = []
        let task = Task {
            await scheduler.run(
                items: [1, 2],
                limits: { .init(workerCount: workers, snapshotLimit: 2, interRequestDelay: 0.05, flushInterval: 5) },
                read: { item in reads.append(item); return item },
                completed: { _, _ in }
            )
        }
        defer { task.cancel() }
        try await waitUntil { scheduler.inFlightCount == 1 }
        workers = 0
        scheduler.configurationChanged()
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.isEmpty)
        #expect(scheduler.inFlightCount == 0)
        workers = 1
        scheduler.configurationChanged()
        await task.value
        #expect(reads == [1, 2])
    }

    @Test @MainActor func invalidatedDelayedItemNeverStartsReading() async throws {
        let scheduler = MetadataReadScheduler<Int, Int>()
        var valid = true
        var reads = 0
        let task = Task {
            await scheduler.run(
                items: [1],
                limits: { .init(workerCount: 1, snapshotLimit: 1, interRequestDelay: 0.05, flushInterval: 5) },
                shouldRead: { _ in valid },
                read: { item in reads += 1; return item },
                completed: { _, _ in Issue.record("Invalidated work must not produce a result") }
            )
        }
        defer { task.cancel() }
        try await waitUntil { scheduler.inFlightCount == 1 }
        valid = false
        await task.value
        #expect(reads == 0)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(condition())
    }
}
