import Foundation
import Testing
@testable import PrimuseKit

private final class FTPCancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCounts: [Int: Int] = [:]

    func record(_ id: Int) {
        lock.lock()
        recordedCounts[id, default: 0] += 1
        lock.unlock()
    }

    var ids: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(recordedCounts.keys)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return recordedCounts.values.reduce(0, +)
    }
}

@Suite("FTP transfer safety")
struct FTPTransferPolicyTests {
    @Test("Root FTP sources keep source and provider paths identical")
    func rootPathPolicy() {
        for configuredBasePath in [nil, "", "/"] as [String?] {
            let policy = FTPPathPolicy(basePath: configuredBasePath)

            #expect(FTPPathPolicy.providerBaseURLPath == "/")
            #expect(policy.basePath == "/")
            #expect(policy.providerPath(forSourcePath: "/") == "/")
            #expect(policy.providerPath(forSourcePath: "/Albums/song.flac") == "/Albums/song.flac")
            #expect(policy.sourcePath(forProviderPath: "/Albums/song.flac") == "/Albums/song.flac")
        }
    }

    @Test("Non-root FTP paths add and remove the configured base exactly once")
    func nonRootPathPolicy() {
        let policy = FTPPathPolicy(basePath: "music/library/")

        #expect(policy.basePath == "/music/library")
        #expect(policy.providerPath(forSourcePath: "/") == "/music/library")
        #expect(policy.providerPath(forSourcePath: "Albums") == "/music/library/Albums")
        #expect(policy.providerPath(forSourcePath: "/Albums/song.flac") == "/music/library/Albums/song.flac")
        #expect(policy.sourcePath(forProviderPath: "/music/library") == "/")
        #expect(policy.sourcePath(forProviderPath: "/music/library/Albums/song.flac") == "/Albums/song.flac")
        #expect(policy.sourcePath(forProviderPath: "/music/library-other/song.flac") == nil)
    }

    @Test("Selected FTP directories round-trip through the configured source root")
    func selectedDirectoriesUseSourceRelativePaths() {
        let policy = FTPPathPolicy(basePath: "/srv/music")
        let selectedDirectories = ["/", "/Albums", "/Live/2026"]
        let providerDirectories = selectedDirectories.map(policy.providerPath(forSourcePath:))

        #expect(providerDirectories == ["/srv/music", "/srv/music/Albums", "/srv/music/Live/2026"])
        #expect(providerDirectories.compactMap(policy.sourcePath(forProviderPath:)) == selectedDirectories)
    }

    @Test("FTP list metadata range and delete operations share one path namespace")
    func operationsUseConsistentProviderPaths() {
        let policy = FTPPathPolicy(basePath: "/srv/music")
        let sourceDirectory = "/Albums"
        let sourceFile = "/Albums/song.flac"
        let expectedProviderFile = "/srv/music/Albums/song.flac"

        let listDirectory = policy.providerPath(forSourcePath: sourceDirectory)
        let listedProviderFile = listDirectory + "/song.flac"
        let attributesFile = policy.providerPath(forSourcePath: sourceFile)
        let rangeFile = policy.providerPath(forSourcePath: sourceFile)
        let deleteFile = policy.providerPath(forSourcePath: sourceFile)

        #expect(listDirectory == "/srv/music/Albums")
        #expect(listedProviderFile == expectedProviderFile)
        #expect(attributesFile == expectedProviderFile)
        #expect(rangeFile == expectedProviderFile)
        #expect(deleteFile == expectedProviderFile)
        #expect(policy.sourcePath(forProviderPath: listedProviderFile) == sourceFile)
    }

    @Test("Attribute lookup disables the dependency's double-callback fallback")
    func attributesUseSingleCallbackListPath() {
        #expect(!FTPTransferPolicy.usesRFC3659ForAttributes)
    }

    @Test("Zero-byte downloads still require a successful transport callback")
    func zeroByteDownloadRejectsTransportError() {
        #expect(!FTPTransferPolicy.downloadPayloadIsValid(
            expectedSize: 0,
            actualSize: 0,
            errorOccurred: true
        ))
        #expect(FTPTransferPolicy.downloadPayloadIsValid(
            expectedSize: 0,
            actualSize: 0,
            errorOccurred: false
        ))
    }

    @Test("Mid-file ranges reject nonempty short reads")
    func midFileRangeRejectsShortRead() {
        let plan = FTPTransferPolicy.rangePlan(
            fileSize: 1_000,
            requestedOffset: 100,
            requestedLength: 400
        )
        #expect(plan == .init(offset: 100, expectedLength: 400))
        #expect(!FTPTransferPolicy.rangePayloadIsValid(
            expectedLength: plan.expectedLength,
            actualLength: 399,
            errorOccurred: false
        ))
        #expect(!FTPTransferPolicy.rangePayloadIsValid(
            expectedLength: plan.expectedLength,
            actualLength: 0,
            errorOccurred: false
        ))
        #expect(!FTPTransferPolicy.rangePayloadIsValid(
            expectedLength: plan.expectedLength,
            actualLength: 400,
            errorOccurred: true
        ))
        #expect(FTPTransferPolicy.rangePayloadIsValid(
            expectedLength: plan.expectedLength,
            actualLength: 400,
            errorOccurred: false
        ))
    }

    @Test("Ranges that cross EOF expect only the remaining bytes")
    func clipsRangeAtEOF() {
        let plan = FTPTransferPolicy.rangePlan(
            fileSize: 1_000,
            requestedOffset: 900,
            requestedLength: 400
        )
        #expect(plan == .init(offset: 900, expectedLength: 100))
        #expect(FTPTransferPolicy.rangePayloadIsValid(
            expectedLength: plan.expectedLength,
            actualLength: 100,
            errorOccurred: false
        ))
    }

    @Test("Short downloads are never promoted to the durable cache")
    func rejectsShortDownload() {
        #expect(FTPTransferPolicy.promotionDecision(
            expectedSize: 1_024,
            temporarySize: 768,
            existingTargetSize: nil
        ) == .rejectTemporary)
        #expect(FTPTransferPolicy.promotionDecision(
            expectedSize: 1_024,
            temporarySize: nil,
            existingTargetSize: nil
        ) == .rejectTemporary)
    }

    @Test("Exact downloads account for a concurrent cache target")
    func handlesConcurrentTarget() {
        #expect(FTPTransferPolicy.promotionDecision(
            expectedSize: 1_024,
            temporarySize: 1_024,
            existingTargetSize: nil
        ) == .promoteTemporary)
        #expect(FTPTransferPolicy.promotionDecision(
            expectedSize: 1_024,
            temporarySize: 1_024,
            existingTargetSize: 1_024
        ) == .useExistingTarget)
        #expect(FTPTransferPolicy.promotionDecision(
            expectedSize: 1_024,
            temporarySize: 1_024,
            existingTargetSize: 400
        ) == .replaceIncompleteTarget)
    }

    @Test("Duplicate transfer callbacks trigger one retry and one terminal result")
    func handlesDuplicateCallbacks() {
        #expect(FTPTransferPolicy.callbackDecision(
            attempt: 0,
            payloadIsValid: false,
            retryAlreadyStarted: false
        ) == .retry)
        #expect(FTPTransferPolicy.callbackDecision(
            attempt: 0,
            payloadIsValid: false,
            retryAlreadyStarted: true
        ) == .awaitRetry)
        #expect(FTPTransferPolicy.callbackDecision(
            attempt: 0,
            payloadIsValid: true,
            retryAlreadyStarted: true
        ) == .accept)
        #expect(FTPTransferPolicy.callbackDecision(
            attempt: 1,
            payloadIsValid: false,
            retryAlreadyStarted: true
        ) == .fail)
    }

    @Test("A late duplicate callback cannot resume a continuation twice")
    func resultRaceResolvesOnce() async throws {
        let race = CancellableResultRace<Int>()
        let task = Task<Int, any Error> {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        }

        #expect(race.resolve(.success(42)))
        #expect(!race.resolve(.failure(CancellationError())))
        #expect(try await task.value == 42)
    }

    @Test("Task cancellation wins before continuation installation")
    func cancellationBeforeInstall() async {
        let race = CancellableResultRace<Int>()
        #expect(race.cancel())

        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        }
        #expect(!race.resolve(.success(42)))
    }

    @Test("Task cancellation resumes an installed continuation")
    func taskCancellationResumesContinuation() async {
        let race = CancellableResultRace<Int>()
        let (installed, installedSignal) = AsyncStream<Void>.makeStream()
        let task = Task<Int, any Error> {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    race.install(continuation)
                    installedSignal.yield()
                    installedSignal.finish()
                }
            } onCancel: {
                race.cancel()
            }
        }

        for await _ in installed { break }
        task.cancel()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(!race.resolve(.success(42)))
    }

    @Test("Disconnect cancellation affects only active requests")
    func registryCancelsOnlyActiveRequests() {
        let registry = CancellableOperationRegistry()
        let recorder = FTPCancellationRecorder()
        let completedID = registry.register { recorder.record(0) }
        registry.unregister(completedID)
        _ = registry.register { recorder.record(1) }
        _ = registry.register { recorder.record(2) }

        #expect(registry.cancelAll() == 2)
        #expect(recorder.ids == [1, 2])
        #expect(registry.cancelAll() == 0)
        #expect(recorder.ids == [1, 2])
    }

    @Test("Progress registered after transport termination is cancelled immediately")
    func lateProgressRegistrationIsCancelled() {
        let registry = OneShotCancellationRegistry()
        let recorder = FTPCancellationRecorder()

        #expect(registry.register { recorder.record(1) })
        #expect(registry.cancelAll() == 1)
        #expect(!registry.register { recorder.record(2) })
        #expect(recorder.ids == [1, 2])
        #expect(registry.cancelAll() == 0)
    }

    @Test("Disconnect rejects late operations from the closed connection generation")
    func closedConnectionRejectsLateOperation() {
        let registry = ConnectionScopedOperationRegistry()
        let recorder = FTPCancellationRecorder()
        let generation = registry.open()

        let activeID = registry.register(for: generation) { recorder.record(1) }
        #expect(activeID != nil)
        #expect(registry.close(generation) == 1)

        let lateID = registry.register(for: generation) { recorder.record(2) }
        #expect(lateID == nil)
        #expect(recorder.ids == [1, 2])
        #expect(recorder.count == 2)
        #expect(registry.activeOperationCount == 0)
    }

    @Test("A completed metadata request cannot reopen range or download work after disconnect")
    func metadataCompletionBeforeDisconnectRejectsTransfers() {
        let registry = ConnectionScopedOperationRegistry()
        let recorder = FTPCancellationRecorder()
        let generation = registry.open()

        let metadataID = registry.register(for: generation) { recorder.record(0) }
        #expect(metadataID != nil)
        if let metadataID {
            registry.unregister(metadataID)
        }
        #expect(registry.close(generation) == 0)

        let downloadID = registry.register(for: generation) { recorder.record(1) }
        let rangeID = registry.register(for: generation) { recorder.record(2) }
        #expect(downloadID == nil)
        #expect(rangeID == nil)
        #expect(recorder.ids == [1, 2])
        #expect(recorder.count == 2)
        #expect(registry.activeOperationCount == 0)
    }

    @Test("A stale generation cannot register into or close a reconnected session")
    func staleGenerationCannotAffectReconnect() {
        let registry = ConnectionScopedOperationRegistry()
        let recorder = FTPCancellationRecorder()
        let staleGeneration = registry.open()
        #expect(registry.close(staleGeneration) == 0)

        let currentGeneration = registry.open()
        #expect(registry.register(for: staleGeneration) { recorder.record(1) } == nil)
        let currentID = registry.register(for: currentGeneration) { recorder.record(2) }
        #expect(currentID != nil)

        #expect(registry.close(staleGeneration) == 0)
        #expect(registry.activeOperationCount == 1)
        #expect(registry.close(currentGeneration) == 1)
        #expect(recorder.ids == [1, 2])
        #expect(recorder.count == 2)
    }

    @Test("Concurrent disconnect and registrations cancel every operation exactly once")
    func concurrentDisconnectAndRegistrations() async {
        let registry = ConnectionScopedOperationRegistry()
        let recorder = FTPCancellationRecorder()
        let generation = registry.open()
        let operationCount = 256

        await withTaskGroup(of: Void.self) { group in
            for id in 0..<operationCount {
                group.addTask {
                    _ = registry.register(for: generation) {
                        recorder.record(id)
                    }
                }
            }
            group.addTask {
                _ = registry.close(generation)
            }
        }

        #expect(registry.close(generation) == 0)
        #expect(registry.activeOperationCount == 0)
        #expect(recorder.ids == Set(0..<operationCount))
        #expect(recorder.count == operationCount)
    }
}
