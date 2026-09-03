import CryptoKit
import Darwin
import Foundation
import Network
import PrimuseKit

struct SongFileDeletionResult: Sendable {
    struct Failure: Sendable {
        let path: String
        let message: String
    }

    var deletedPaths: [String] = []
    var missingPaths: [String] = []
    var failedPaths: [Failure] = []
    var sidecarWarnings: [Failure] = []
    var audioStatus: SourceAudioDeletionStatus = .failed

    var hasFailures: Bool { !failedPaths.isEmpty }
    var shouldRemoveLibraryRecord: Bool {
        SourceFileDeletionPolicy.shouldRemoveLibraryRecord(
            after: audioStatus,
            sidecarWarningCount: sidecarWarnings.count
        )
    }

    mutating func merge(_ other: SongFileDeletionResult) {
        deletedPaths.append(contentsOf: other.deletedPaths)
        missingPaths.append(contentsOf: other.missingPaths)
        failedPaths.append(contentsOf: other.failedPaths)
        sidecarWarnings.append(contentsOf: other.sidecarWarnings)
        audioStatus = other.audioStatus
    }
}

struct SongFileDeletionOutcome: Sendable {
    let song: Song
    let result: SongFileDeletionResult
}

enum TagMetadataPersistenceMode: Sendable, Equatable {
    case embedded
    case serverAPI
    case sidecarOnly
    case localOnly
}

struct OfflineDownloadBatchResult: Sendable {
    let requestedCount: Int
    let completedCount: Int
    let failedCount: Int
    let inProgressCount: Int
    let byteCount: Int64

    var succeeded: Bool {
        requestedCount > 0 && completedCount == requestedCount && failedCount == 0 && inProgressCount == 0
    }
}

#if os(iOS) || os(macOS)
/// A capacity reservation for one incoming peer-to-peer cache file. The
/// staging path lives on the cache volume so the verified file can be moved
/// into place atomically without copying a second full payload.
struct AudioCacheSyncImportReservation: Sendable {
    let id: UUID
    let songID: String
    let sourceID: String
    let filePath: String
    let cacheFileName: String
    let relativePath: String
    let stagingURL: URL
    let targetURL: URL
    let expectedByteCount: Int64
    let maximumByteCount: Int64
    let lease: AudioCachePathLease
}

enum AudioCacheSyncImportError: Error, Sendable {
    case invalidRequest
    case songChanged
    case sourceUnavailable
    case alreadyCached
    case artifactBusy
    case incomplete
}
#endif

struct AlwaysDownloadDesiredSong: Sendable {
    let song: Song
    let playlistIDs: Set<String>
    let contentSignature: String
    let sourceIdentitySignature: String
    let artifactPath: String
    let artifactSignature: String
}

enum AutomaticOfflineRefreshDisposition: String, Codable, Sendable {
    case none
    case preserveExisting
    case discardUntrusted

    static func strongest(
        _ lhs: AutomaticOfflineRefreshDisposition,
        _ rhs: AutomaticOfflineRefreshDisposition
    ) -> AutomaticOfflineRefreshDisposition {
        if lhs == .discardUntrusted || rhs == .discardUntrusted { return .discardUntrusted }
        if lhs == .preserveExisting || rhs == .preserveExisting { return .preserveExisting }
        return .none
    }
}

enum AutomaticOfflineFailureKind: String, Sendable {
    case authentication
    case sourceAccessDenied
    case rateLimited
    case sourceUnavailable
    case resourceDeferred
    case transient

    var authenticationRequired: Bool { self == .authentication }
    var requiresSourceCooldown: Bool { self != .transient }
}

enum AutomaticOfflineFailureClassifier {
    static func classify(_ error: Error) -> AutomaticOfflineFailureKind {
        if let validationError = error as? OfflineTransferValidationError {
            switch validationError {
            case .invalidContentRange, .oversized:
                // A server that violates its advertised range or the hard
                // response bound will normally do so for every song. Stop the
                // rest of that source instead of probing thousands of jobs.
                return .sourceUnavailable
            case .insufficientCapacity:
                // Capacity is a device resource gate, not an authentication or
                // per-song integrity failure. A source-wide delay prevents the
                // queue from immediately repeating the same failed admission.
                return .resourceDeferred
            case .invalidChunk, .incomplete:
                return .transient
            }
        }
        if let deferral = error as? AutomaticOfflineTransferDeferralError {
            switch deferral {
            case .artifactLeased:
                return .transient
            case .unboundedAutomaticTransfer:
                return .sourceUnavailable
            }
        }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable:
                return .authentication
            case .connectionFailed, .timeout:
                return .sourceUnavailable
            case .pathNotFound, .fileNotFound:
                return .transient
            }
        }
        if error is SourceConnectionTerminalError { return .authentication }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .transient : .sourceUnavailable
        }
        guard let cloudError = error as? CloudDriveError else { return .transient }
        switch cloudError {
        case .notAuthenticated,
             .credentialTemporarilyUnavailable,
             .credentialReadFailed,
             .tokenExpired,
             .tokenRefreshFailed,
             .tokenPersistenceFailed:
            return .authentication
        case .permissionDenied:
            return .sourceAccessDenied
        case .apiError(let statusCode, _):
            switch statusCode {
            case 401: return .authentication
            case 403: return .sourceAccessDenied
            case 408, 500...599: return .sourceUnavailable
            case 429: return .rateLimited
            default: return .transient
            }
        case .rateLimited:
            return .rateLimited
        case .invalidResponse:
            return .sourceUnavailable
        case .fileNotFound:
            return .transient
        }
    }
}

enum AutomaticOfflineTaskJoinPolicy {
    static func canJoin(
        existingArtifactSignature: String?,
        existingDisposition: AutomaticOfflineRefreshDisposition,
        requestedArtifactSignature: String?,
        requestedDisposition: AutomaticOfflineRefreshDisposition
    ) -> Bool {
        // A manual request carries no scope provenance. It may coalesce only
        // with another manual transfer; joining any automatic task could keep
        // a superseded account-scoped transfer alive after its worker is
        // cancelled, even when its refresh disposition is `.none`.
        guard let requestedArtifactSignature else {
            return existingDisposition == .none
                && existingArtifactSignature == nil
        }
        // Automatic callers may only adopt a task bound to the exact desired
        // artifact and an equal or stronger refresh policy.
        return existingArtifactSignature == requestedArtifactSignature
            && AutomaticOfflineRefreshDisposition.strongest(
                existingDisposition,
                requestedDisposition
            ) == existingDisposition
    }
}

enum AutomaticOfflineCachedReadPolicy {
    static func allows(path: String, blockedPaths: Set<String>) -> Bool {
        !blockedPaths.contains(path)
    }
}

enum SourceAudioCacheScopePolicy {
    enum Reconciliation: Equatable {
        case allowExisting
        case adoptLegacy
        case quarantineExisting
    }

    static func reconciliation(
        recordedSignature: String?,
        currentSignature: String,
        legacyAdoptionAllowed: Bool
    ) -> Reconciliation {
        if recordedSignature == currentSignature {
            return .allowExisting
        }
        if recordedSignature == nil, legacyAdoptionAllowed {
            return .adoptLegacy
        }
        return .quarantineExisting
    }

    static func allowsRead(
        sourceID: String,
        validatedSourceIDs: Set<String>,
        blockedSourceIDs: Set<String>
    ) -> Bool {
        validatedSourceIDs.contains(sourceID) && !blockedSourceIDs.contains(sourceID)
    }
}

enum SourceConnectorScopePolicy {
    static func allows(
        requestedFingerprint: String,
        requiredFingerprint: String?,
        validationPending: Bool
    ) -> Bool {
        guard !validationPending else { return false }
        return requiredFingerprint.map { $0 == requestedFingerprint } ?? true
    }

    static func canReuse(
        cachedFingerprint: String?,
        requestedFingerprint: String,
        requiredFingerprint: String?,
        validationPending: Bool
    ) -> Bool {
        cachedFingerprint == requestedFingerprint
            && allows(
                requestedFingerprint: requestedFingerprint,
                requiredFingerprint: requiredFingerprint,
                validationPending: validationPending
            )
    }

    static func canEstablishDuringPendingValidation(
        previousModifiedAt: Date?,
        requestedModifiedAt: Date
    ) -> Bool {
        guard let previousModifiedAt else {
            // A newly added source has no reusable pre-notification connector
            // and may be used immediately by the scan kicked off by its save.
            return true
        }
        // Existing sources must present the post-notification value. This
        // keeps a caller holding the old model from repopulating the cache.
        return requestedModifiedAt > previousModifiedAt
    }
}

enum AutomaticOfflineContentChangePolicy {
    static func protectedPaths(
        candidates: Set<String>,
        livePlaylistPaths: Set<String>,
        persistedPlaylistPaths: Set<String>,
        blockedUntrustedPaths: Set<String>
    ) -> Set<String> {
        livePlaylistPaths
            .union(persistedPlaylistPaths)
            .intersection(candidates)
            .subtracting(blockedUntrustedPaths)
    }
}

enum OfflineTransferSizePolicy {
    static let oversizeToleranceBytes: Int64 = 4 * 1_024

    static func minimumAllowedBytes(expectedSize: Int64) -> Int64 {
        guard expectedSize > 0 else { return 0 }
        return expectedSize - (expectedSize / 20)
    }

    static func maximumAllowedBytes(expectedSize: Int64) -> Int64 {
        guard expectedSize > 0 else { return 0 }
        let result = expectedSize.addingReportingOverflow(oversizeToleranceBytes)
        return result.overflow ? .max : result.partialValue
    }

    static func maximumAllowedBytes(
        expectedSize: Int64,
        cacheLimitBytes: Int64,
        availableDiskBytes: Int64,
        otherReservedBytes: Int64 = 0,
        otherConfiguredCacheReservedBytes: Int64? = nil
    ) -> Int64 {
        let physicalReserved = max(0, otherReservedBytes)
        let configuredReserved = max(
            0,
            otherConfiguredCacheReservedBytes ?? physicalReserved
        )
        let physicalBudget = max(0, availableDiskBytes - physicalReserved)
        let diskBudget = max(
            0,
            physicalBudget - AutomaticOfflineDownloadPolicy.diskHeadroomBytes
        )
        let configuredBudget = cacheLimitBytes > 0
            ? max(0, cacheLimitBytes - configuredReserved)
            : diskBudget
        let metadataBound = expectedSize > 0
            ? maximumAllowedBytes(expectedSize: expectedSize)
            : configuredBudget
        return min(metadataBound, min(configuredBudget, diskBudget))
    }

    static func validate(
        actualSize: Int64,
        expectedSize: Int64,
        maximumBytes: Int64? = nil
    ) throws {
        guard actualSize > 0 else {
            throw OfflineTransferValidationError.incomplete(
                actual: actualSize,
                expected: max(1, expectedSize)
            )
        }
        let minimum = minimumAllowedBytes(expectedSize: expectedSize)
        guard actualSize >= minimum else {
            throw OfflineTransferValidationError.incomplete(
                actual: actualSize,
                expected: expectedSize
            )
        }
        let maximum = maximumBytes ?? maximumAllowedBytes(expectedSize: expectedSize)
        guard maximum > 0 || actualSize == 0 else {
            throw OfflineTransferValidationError.oversized(
                actual: actualSize,
                maximum: max(0, maximum)
            )
        }
        guard actualSize <= maximum else {
            throw OfflineTransferValidationError.oversized(
                actual: actualSize,
                maximum: maximum
            )
        }
    }
}

struct OfflineHTTPContentRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64
}

enum OfflineHTTPContentRangePolicy {
    static func parse(_ header: String?) -> OfflineHTTPContentRange? {
        guard let header else { return nil }
        let pieces = header.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard pieces.count == 2,
              pieces[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = pieces[1].split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
              rangeAndTotal[1] != "*",
              let total = Int64(rangeAndTotal[1]),
              total > 0 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total else { return nil }
        return OfflineHTTPContentRange(start: start, end: end, total: total)
    }

    static func validate(
        header: String?,
        expectedStart: Int64,
        contentLength: Int64,
        maximumBytes: Int64
    ) throws -> OfflineHTTPContentRange {
        guard let range = parse(header),
              range.start == expectedStart,
              range.end == range.total - 1,
              range.total <= maximumBytes else {
            throw OfflineTransferValidationError.invalidContentRange
        }
        let interval = range.end.subtractingReportingOverflow(range.start)
        guard !interval.overflow else {
            throw OfflineTransferValidationError.invalidContentRange
        }
        let bodyLength = interval.partialValue.addingReportingOverflow(1)
        guard !bodyLength.overflow,
              contentLength <= 0 || bodyLength.partialValue == contentLength else {
            throw OfflineTransferValidationError.invalidContentRange
        }
        return range
    }
}

enum OfflineDirectDownloadRetryPolicy {
    static func shouldRefreshSignedURL(after error: Error) -> Bool {
        guard let cloudError = error as? CloudDriveError,
              case .apiError(let statusCode, _) = cloudError else { return false }
        return statusCode == 401
            || statusCode == 403
            || statusCode == 404
            || statusCode == 410
    }
}

enum OfflineTransferValidationError: Error, LocalizedError {
    case invalidChunk(actual: Int, expected: Int64)
    case incomplete(actual: Int64, expected: Int64)
    case oversized(actual: Int64, maximum: Int64)
    case invalidContentRange
    case insufficientCapacity(required: Int64, available: Int64)

    var errorDescription: String? {
        String(localized: "offline_download_failed")
    }
}

enum AutomaticOfflineTransferDeferralError: Error, LocalizedError {
    case artifactLeased
    case unboundedAutomaticTransfer

    var errorDescription: String? {
        String(localized: "offline_download_failed")
    }
}

enum OfflineSTRMConnectorMaterializationPolicy {
    /// Connector materialization has no cross-connector byte-limit contract.
    /// Only an already-local source can be sized before the copy starts.
    /// Remote STRM targets must use the bounded external-HTTP route instead.
    static func permitsConnectorMaterialization(sourceType: MusicSourceType) -> Bool {
        sourceType == .local || sourceType == .appleMusicLibrary
    }
}

enum AutomaticOfflineUntrustedCleanupPolicy {
    static func canonicalURLs(for canonical: URL) -> [URL] {
        let partial = URL(fileURLWithPath: canonical.path + ".partial")
        return [
            canonical,
            URL(fileURLWithPath: canonical.path + ".installing"),
            partial,
            URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix),
            URL(fileURLWithPath: canonical.path + ".offline"),
        ]
    }


    static func recoverableAllocatedBytes(for canonical: URL) -> Int64 {
        canonicalURLs(for: canonical).reduce(into: Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [
                .totalFileAllocatedSizeKey,
                .fileAllocatedSizeKey,
            ])
            let allocated = Int64(
                values?.totalFileAllocatedSize
                    ?? values?.fileAllocatedSize
                    ?? 0
            )
            let result = total.addingReportingOverflow(max(0, allocated))
            total = result.overflow ? .max : result.partialValue
        }
    }
}

enum OfflineCacheAtomicReplacement {
    static func replace(staging: URL, canonical: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: canonical.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: canonical.path) {
            _ = try fileManager.replaceItemAt(
                canonical,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: staging, to: canonical)
        }
    }

    static func install(source: URL, target: URL, move: Bool) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard source.standardizedFileURL != target.standardizedFileURL else { return }

        let staging = URL(fileURLWithPath: target.path + ".installing")
        try? fileManager.removeItem(at: staging)
        do {
            if move {
                try fileManager.moveItem(at: source, to: staging)
            } else {
                try fileManager.copyItem(at: source, to: staging)
            }
            try replace(staging: staging, canonical: target)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }
}

enum AutomaticOfflineDownloadResult: Sendable {
    case completed
    case cancelled
    case failed(kind: AutomaticOfflineFailureKind, message: String)
}

private struct OfflineDownloadSongResult: Sendable {
    let snapshot: OfflineAudioCacheSnapshot
    let fallbackByteCount: Int64
}

private enum OfflineDownloadPinIntent: Sendable {
    case manual
    case playlists(Set<String>)
}

private enum OfflineDownloadTransferResult: Sendable {
    case completed(byteCount: Int64?)
    case cancelled
    case failed(kind: AutomaticOfflineFailureKind, message: String)
}

private struct OfflineDownloadTaskRecord {
    let id: UUID
    let task: Task<OfflineDownloadTransferResult, Never>
    var requesterIDs: Set<UUID>
    let refreshDisposition: AutomaticOfflineRefreshDisposition
    let artifactSignature: String?
}

private struct OfflineDownloadTaskHandle: Sendable {
    let task: Task<OfflineDownloadTransferResult, Never>
    let requesterID: UUID
    let taskKey: String
}

private struct BackgroundAudioCacheTaskRecord {
    let id: UUID
    let sourceID: String
    let taskKey: String
    let task: Task<Void, Never>
}

/// Per-song observation node for the offline badge. A single dictionary on
/// SourceManager caused every visible SongRowView to refresh whenever one
/// newly-visible song finished its disk probe or one download advanced.
@MainActor
@Observable
final class OfflineAudioSnapshotEntry {
    private(set) var snapshot: OfflineAudioCacheSnapshot

    init(snapshot: OfflineAudioCacheSnapshot) {
        self.snapshot = snapshot
    }

    fileprivate func update(_ snapshot: OfflineAudioCacheSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }
}

private final class OfflineDirectDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partial: URL
    private let initialBytes: Int64
    private let expectedTotalBytes: Int64?
    private let maximumBytes: Int64
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private let trustDelegate = SmartSSLDelegate()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var downloadedBytes: Int64
    private var totalBytes: Int64?
    private var expectedResponseEndExclusive: Int64?
    private var terminalError: Error?
    private var isFinished = false
    private var lastProgressAt = Date.distantPast

    init(
        partial: URL,
        initialBytes: Int64,
        expectedTotalBytes: Int64?,
        maximumBytes: Int64,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.partial = partial
        self.initialBytes = initialBytes
        self.expectedTotalBytes = expectedTotalBytes
        self.maximumBytes = maximumBytes
        self.onProgress = onProgress
        self.downloadedBytes = initialBytes
        self.totalBytes = expectedTotalBytes
    }

    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        try Task.checkCancellation()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.lock()
                guard !Task.isCancelled else {
                    lock.unlock()
                    cont.resume(throwing: CancellationError())
                    return
                }
                continuation = cont
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
                if Task.isCancelled {
                    cancelRequest()
                }
            }
        } onCancel: { [weak self] in
            self?.cancelRequest()
        }
    }

    private func cancelRequest() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trustDelegate.urlSession(session, didReceive: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await trustDelegate.urlSession(session, task: task, didReceive: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        trustDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: request,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            terminalError = SourceError.connectionFailed("Offline download returned a non-HTTP response")
            completionHandler(.cancel)
            return
        }

        guard http.statusCode == 200 || http.statusCode == 206 else {
            terminalError = CloudDriveError.apiError(http.statusCode, "Offline direct download failed")
            completionHandler(.cancel)
            return
        }

        do {
            let bodyLength = response.expectedContentLength
            let shouldAppend: Bool
            if http.statusCode == 206 {
                let range = try OfflineHTTPContentRangePolicy.validate(
                    header: http.value(forHTTPHeaderField: "Content-Range"),
                    expectedStart: initialBytes,
                    contentLength: bodyLength,
                    maximumBytes: maximumBytes
                )
                if let expectedTotalBytes {
                    try OfflineTransferSizePolicy.validate(
                        actualSize: range.total,
                        expectedSize: expectedTotalBytes,
                        maximumBytes: maximumBytes
                    )
                }
                shouldAppend = initialBytes > 0
                totalBytes = range.total
                expectedResponseEndExclusive = range.end + 1
            } else {
                if bodyLength > maximumBytes {
                    throw OfflineTransferValidationError.oversized(
                        actual: bodyLength,
                        maximum: maximumBytes
                    )
                }
                if bodyLength > 0, let expectedTotalBytes {
                    try OfflineTransferSizePolicy.validate(
                        actualSize: bodyLength,
                        expectedSize: expectedTotalBytes,
                        maximumBytes: maximumBytes
                    )
                }
                shouldAppend = false
                totalBytes = bodyLength > 0 ? bodyLength : expectedTotalBytes
                expectedResponseEndExclusive = bodyLength > 0 ? bodyLength : nil
            }
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            if shouldAppend {
                try handle.seekToEnd()
                downloadedBytes = initialBytes
            } else {
                try handle.truncate(atOffset: 0)
                downloadedBytes = 0
            }
            self.handle = handle
            self.response = http
            onProgress(downloadedBytes, totalBytes)
            completionHandler(.allow)
        } catch {
            if initialBytes > 0, error is OfflineTransferValidationError {
                try? FileManager.default.removeItem(at: partial)
            }
            terminalError = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard terminalError == nil else {
            dataTask.cancel()
            return
        }
        do {
            let nextSize = downloadedBytes.addingReportingOverflow(Int64(data.count))
            let responseLimit = min(expectedResponseEndExclusive ?? .max, maximumBytes)
            guard !nextSize.overflow, nextSize.partialValue <= responseLimit else {
                throw OfflineTransferValidationError.oversized(
                    actual: nextSize.overflow ? .max : nextSize.partialValue,
                    maximum: responseLimit
                )
            }
            try handle?.write(contentsOf: data)
            downloadedBytes = nextSize.partialValue
            let now = Date()
            if downloadedBytes >= totalBytes ?? Int64.max || now.timeIntervalSince(lastProgressAt) >= 0.25 {
                lastProgressAt = now
                onProgress(downloadedBytes, totalBytes)
            }
        } catch {
            terminalError = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        if let terminalError {
            finish(throwing: terminalError)
        } else if let error {
            finish(throwing: error)
        } else if let expectedResponseEndExclusive,
                  downloadedBytes != expectedResponseEndExclusive {
            finish(throwing: OfflineTransferValidationError.incomplete(
                actual: downloadedBytes,
                expected: expectedResponseEndExclusive
            ))
        } else if let response {
            onProgress(downloadedBytes, totalBytes)
            finish(returning: response)
        } else {
            finish(throwing: SourceError.connectionFailed("Offline download completed without a response"))
        }
    }

    private func finish(returning response: HTTPURLResponse) {
        finish { $0.resume(returning: response) }
    }

    private func finish(throwing error: Error) {
        finish { $0.resume(throwing: error) }
    }

    private func finish(_ resume: (CheckedContinuation<HTTPURLResponse, Error>) -> Void) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        lock.unlock()
        resume(continuation)
    }
}

enum SourceDiagnosticStatus: Sendable {
    case passed
    case warning
    case failed
}

struct SourceDiagnosticCheck: Identifiable, Sendable {
    let id: UUID
    let status: SourceDiagnosticStatus
    let title: String
    let message: String
    let suggestion: String

    init(status: SourceDiagnosticStatus, title: String, message: String, suggestion: String = "") {
        self.id = UUID()
        self.status = status
        self.title = title
        self.message = message
        self.suggestion = suggestion
    }
}

struct SourceDiagnosticReport: Identifiable, Sendable {
    let id: UUID
    let sourceID: String
    let sourceName: String
    let startedAt: Date
    let finishedAt: Date
    let checks: [SourceDiagnosticCheck]
    let wasCancelled: Bool

    init(
        source: MusicSource,
        startedAt: Date,
        checks: [SourceDiagnosticCheck],
        wasCancelled: Bool = false
    ) {
        self.id = UUID()
        self.sourceID = source.id
        self.sourceName = source.name
        self.startedAt = startedAt
        self.finishedAt = Date()
        self.checks = checks
        self.wasCancelled = wasCancelled
    }

    var blockingFailure: SourceDiagnosticCheck? {
        checks.first { $0.status == .failed }
    }

    var summaryStatus: SourceDiagnosticStatus {
        if checks.contains(where: { $0.status == .failed }) { return .failed }
        if checks.contains(where: { $0.status == .warning }) { return .warning }
        return .passed
    }
}

private struct SourceDiagnosticAdvice: Sendable {
    let title: String
    let message: String
    let suggestion: String
}

private struct RoutedConnectorCandidate: Sendable {
    let kind: SourceConnectionCandidateKind
    let endpoint: SourceConnectionEndpoint?
    let connector: any MusicSourceConnector
}

/// Completes a bounded TCP preflight exactly once. The preflight never sends
/// credentials or application bytes; a successful source-specific `connect()`
/// remains the service-identity proof before a route becomes active.
private final class SourceConnectionPreflightCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private let connection: NWConnection

    init(connection: NWConnection, continuation: CheckedContinuation<Bool, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        connection.cancel()
        continuation.resume(returning: result)
    }
}

private enum SourceConnectionPreflight {
    /// A private address on the correct WLAN normally completes ARP + TCP in a
    /// few milliseconds. One second leaves ample wake-up margin while keeping a
    /// colliding RFC1918 address from blocking the cover-art queue.
    static let timeout: TimeInterval = 1

    static func reaches(_ rawEndpoint: SourceConnectionEndpoint) async -> Bool {
        let endpoint = rawEndpoint.normalized
        guard endpoint.isUsable,
              let port = NWEndpoint.Port(rawValue: UInt16(endpoint.port)) else {
            return false
        }

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(endpoint.host),
                port: port,
                using: .tcp
            )
            let completion = SourceConnectionPreflightCompletion(
                connection: connection,
                continuation: continuation
            )
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(true)
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .userInitiated))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout
            ) {
                completion.finish(false)
            }
        }
    }
}

/// Owns route selection for one source. Read operations may move to the next
/// candidate after a transport failure. Mutations are never replayed because a
/// lost response cannot prove whether the remote write or deletion took effect.
private actor SourceConnectionRouter {
    private let sourceID: String
    private let candidates: [RoutedConnectorCandidate]
    private let routeDidChange: @MainActor @Sendable (SourceConnectionCandidateKind?) -> Void
    private var activeIndex: Int?
    private var routeGeneration: UInt64?

    init(
        sourceID: String,
        candidates: [RoutedConnectorCandidate],
        routeDidChange: @escaping @MainActor @Sendable (SourceConnectionCandidateKind?) -> Void
    ) {
        self.sourceID = sourceID
        self.candidates = candidates
        self.routeDidChange = routeDidChange
    }

    func connect() async throws {
        _ = try await connectedIndex()
    }

    func disconnect() async {
        activeIndex = nil
        await routeDidChange(nil)
        for candidate in candidates {
            await candidate.connector.disconnect()
        }
    }

    func withRead<T: Sendable>(
        _ operation: @Sendable (any MusicSourceConnector) async throws -> T
    ) async throws -> T {
        let routed = try await withReadAndRoute(operation)
        return routed.value
    }

    func withReadAndRoute<T: Sendable>(
        _ operation: @Sendable (any MusicSourceConnector) async throws -> T
    ) async throws -> (value: T, routeIndex: Int) {
        let initialIndex = try await connectedIndex()
        do {
            return (try await operation(candidates[initialIndex].connector), initialIndex)
        } catch {
            guard canFailOver(after: error, from: initialIndex) else { throw error }
            await retireFailedRoute(at: initialIndex)
            return try await attemptRead(
                operation,
                excluding: [initialIndex],
                initialError: error
            )
        }
    }

    func withMutation<T: Sendable>(
        _ operation: @Sendable (any MusicSourceConnector) async throws -> T
    ) async throws -> T {
        let index = try await connectedIndex()
        do {
            return try await operation(candidates[index].connector)
        } catch {
            if canFailOver(after: error, from: index) {
                await retireFailedRoute(at: index)
            }
            throw error
        }
    }

    /// AsyncThrowingStream errors occur after the method that created the
    /// stream has returned, so `withRead` cannot observe them. Never splice a
    /// second endpoint into a partially-consumed byte or scan stream; simply
    /// retire the failed route so the caller's next safe retry uses fallback.
    func noteDeferredReadFailure(_ error: Error, routeIndex: Int) async {
        guard candidates.indices.contains(routeIndex) else { return }
        guard canFailOver(after: error, from: routeIndex) else { return }
        await retireFailedRoute(at: routeIndex)
    }

    private func connectedIndex(excluding excluded: Set<Int> = []) async throws -> Int {
        let currentGeneration = await SourceConnectionRuntime.shared.routeGeneration()
        if routeGeneration != currentGeneration {
            // Do not disconnect a route here. A scanner may still be consuming
            // an AsyncThrowingStream from it; switching future reads is safe,
            // cancelling the partially-consumed stream is not.
            activeIndex = nil
            routeGeneration = currentGeneration
        }

        let preferredKind = await SourceConnectionRuntime.shared.preferredKind(
            for: sourceID,
            availableKinds: candidates.map(\.kind)
        )

        if let currentIndex = activeIndex,
           excluded.contains(currentIndex) == false {
            if let preferredKind,
               candidates[currentIndex].kind != preferredKind,
               let preferredIndex = candidates.firstIndex(where: { $0.kind == preferredKind }),
               excluded.contains(preferredIndex) == false {
                // Probe the newly preferred route while the known-good fallback
                // stays alive. This makes Wi-Fi fail back to LAN without risking
                // an active scan or playback stream.
                do {
                    try await connectCandidate(at: preferredIndex)
                    activeIndex = preferredIndex
                    await SourceConnectionRuntime.shared.record(
                        preferredKind,
                        for: sourceID
                    )
                    await routeDidChange(preferredKind)
                    return preferredIndex
                } catch {
                    // This is an opportunistic failback. The current route has
                    // already connected successfully, so preserve it even when
                    // the preferred probe reports a terminal/authentication error.
                    await candidates[preferredIndex].connector.disconnect()
                    await SourceConnectionRuntime.shared.recordFailure(
                        of: preferredKind,
                        for: sourceID
                    )
                    await SourceConnectionRuntime.shared.record(
                        candidates[currentIndex].kind,
                        for: sourceID
                    )
                }
            }
            return currentIndex
        }

        var lastError: Error?
        let orderedIndices = candidates.indices.sorted { lhs, rhs in
            if candidates[lhs].kind == preferredKind { return true }
            if candidates[rhs].kind == preferredKind { return false }
            return lhs < rhs
        }
        for index in orderedIndices where excluded.contains(index) == false {
            let kind = candidates[index].kind
            do {
                try await connectCandidate(at: index)
                activeIndex = index
                await SourceConnectionRuntime.shared.record(
                    kind,
                    for: sourceID
                )
                await routeDidChange(kind)
                return index
            } catch {
                lastError = error
                guard canFailOver(after: error, from: index) else { throw error }
                await candidates[index].connector.disconnect()
                await SourceConnectionRuntime.shared.recordFailure(
                    of: kind,
                    for: sourceID
                )
            }
        }
        throw lastError ?? SourceError.connectionFailed(
            String(localized: "source_connection_no_route")
        )
    }

    private func connectCandidate(at index: Int) async throws {
        let candidate = candidates[index]
        if candidate.kind == .localAddress,
           let endpoint = candidate.endpoint,
           await SourceConnectionPreflight.reaches(endpoint) == false {
            throw URLError(.cannotConnectToHost)
        }
        // TCP reachability is deliberately not treated as success. Each
        // connector must still complete its authenticated, protocol-specific
        // handshake before the route is recorded or shown as active.
        if let timeout = SourceConnectionHandshakePolicy.timeout(
            for: candidate.kind,
            availableKinds: candidates.map(\.kind)
        ) {
            do {
                try await Self.withHandshakeTimeout(seconds: timeout) {
                    try await candidate.connector.connect()
                }
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain,
                   nsError.code == NSURLErrorTimedOut {
                    plog(
                        "⏱️ Source route handshake timed out source="
                            + "\(sourceID.prefix(8))… kind=\(candidate.kind.rawValue)"
                    )
                }
                throw error
            }
        } else {
            try await candidate.connector.connect()
        }
    }

    /// A task-group timeout waits for a non-cooperative losing child before it
    /// can return. This one-shot race returns immediately, then cancellation and
    /// the router's normal `disconnect()` path tear down the losing connector.
    private nonisolated static func withHandshakeTimeout(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let race = CancellableResultRace<Void>()
        let operationTask = Task<Void, Never> {
            do {
                _ = race.resolve(.success(try await operation()))
            } catch {
                _ = race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            if race.resolve(.failure(URLError(.timedOut))) {
                operationTask.cancel()
            }
        }

        try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                if Task.isCancelled, race.cancel() {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            if race.cancel() {
                operationTask.cancel()
                timeoutTask.cancel()
            }
        }
    }

    private func attemptRead<T: Sendable>(
        _ operation: @Sendable (any MusicSourceConnector) async throws -> T,
        excluding initialExcluded: Set<Int>,
        initialError: Error
    ) async throws -> (value: T, routeIndex: Int) {
        var excluded = initialExcluded
        var lastError = initialError

        while excluded.count < candidates.count {
            let index: Int
            do {
                index = try await connectedIndex(excluding: excluded)
            } catch {
                throw error
            }

            do {
                return (try await operation(candidates[index].connector), index)
            } catch {
                lastError = error
                guard canFailOver(after: error, from: index) else { throw error }
                await retireFailedRoute(at: index)
                excluded.insert(index)
            }
        }
        throw lastError
    }

    private func retireFailedRoute(at index: Int) async {
        let kind = candidates[index].kind
        await candidates[index].connector.disconnect()
        if activeIndex == index {
            activeIndex = nil
        }
        await SourceConnectionRuntime.shared.recordFailure(
            of: kind,
            for: sourceID
        )
    }

    private static func canFailOver(after error: Error) -> Bool {
        if OperationCancellationPolicy.isCancellation(error) { return false }
        if error is SourceConnectionTerminalError { return false }
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed, .credentialUnavailable:
                return false
            case .pathNotFound, .fileNotFound, .connectionFailed, .timeout:
                return true
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           [Int(EACCES), Int(EPERM)].contains(nsError.code) {
            return false
        }
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorUserAuthenticationRequired,
                 NSURLErrorUserCancelledAuthentication:
                return false
            default:
                return true
            }
        }
        return true
    }

    /// Authentication is normally terminal, but not when it came from the LAN
    /// candidate of a multi-route source. The same private address can belong
    /// to an unrelated NAS on another Wi-Fi; treating that device's 401/login
    /// response as proof that the user's saved credentials are wrong would
    /// suppress a healthy public route. Mutations are still never replayed —
    /// this decision only retires the candidate so the next safe read can use
    /// the remote endpoint.
    private func canFailOver(after error: Error, from index: Int) -> Bool {
        if Self.canFailOver(after: error) { return true }
        guard candidates.indices.contains(index),
              candidates[index].kind == .localAddress else {
            return false
        }
        return candidates.contains { $0.kind != .localAddress }
    }
}

private protocol RoutedConnectorProxy: MusicSourceConnector {
    var routing: SourceConnectionRouter { get }
    var routedSupportsSidecarWriting: Bool { get }
    var routedPreferredDeleteBatchSize: Int { get }
}

private extension RoutedConnectorProxy {
    var supportsSidecarWriting: Bool { routedSupportsSidecarWriting }
    var preferredDeleteBatchSize: Int { routedPreferredDeleteBatchSize }

    func connect() async throws { try await routing.connect() }
    func disconnect() async { await routing.disconnect() }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await routing.withRead { try await $0.listFiles(at: path) }
    }

    func localURL(for path: String) async throws -> URL {
        try await routing.withRead { try await $0.localURL(for: path) }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let routed = try await routing.withReadAndRoute { try await $0.streamData(for: path) }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        let routed = try await routing.withReadAndRoute { try await $0.scanAudioFiles(from: path) }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func scanCueSheets(from path: String) async throws -> AsyncThrowingStream<RemoteCueSheetItem, Error> {
        let routed = try await routing.withReadAndRoute { try await $0.scanCueSheets(from: path) }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func streamingURL(for path: String) async throws -> URL? {
        try await routing.withRead { try await $0.streamingURL(for: path) }
    }

    func imageURL(for path: String) async throws -> URL? {
        try await routing.withRead { try await $0.imageURL(for: path) }
    }

    func originalArtworkURL(for path: String) async throws -> URL? {
        try await routing.withRead { try await $0.originalArtworkURL(for: path) }
    }

    func fetchArtworkData(
        for reference: String,
        maximumBytes: Int,
        purpose: ArtworkFetchPurpose
    ) async throws -> Data? {
        try await routing.withRead {
            try await $0.fetchArtworkData(
                for: reference,
                maximumBytes: maximumBytes,
                purpose: purpose
            )
        }
    }

    func writeFile(data: Data, to path: String) async throws {
        try await routing.withMutation { try await $0.writeFile(data: data, to: path) }
    }

    func writeFile(data: Data, to path: String, priority: RangeFetchPriority) async throws {
        try await routing.withMutation {
            try await $0.writeFile(data: data, to: path, priority: priority)
        }
    }

    func writeLyricsSidecar(
        data: Data,
        target: LyricsSidecarTarget,
        priority: RangeFetchPriority
    ) async throws -> LyricsSidecarWriteReceipt {
        try await routing.withMutation {
            try await $0.writeLyricsSidecar(
                data: data,
                target: target,
                priority: priority
            )
        }
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        try await routing.withRead {
            try await $0.verifySidecarWrite(data: data, at: path)
        }
    }

    func writeEmbeddedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> EmbeddedMetadataWritebackResult {
        try await routing.withMutation {
            try await $0.writeEmbeddedMetadata(
                original: original,
                updated: updated,
                coverData: coverData
            )
        }
    }

    func deleteFile(at path: String) async throws {
        try await routing.withMutation { try await $0.deleteFile(at: path) }
    }

    func deleteFiles(at paths: [String]) async throws {
        try await routing.withMutation { try await $0.deleteFiles(at: paths) }
    }

    func countAudioFiles(in path: String) async throws -> Int {
        try await routing.withRead { try await $0.countAudioFiles(in: path) }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await routing.withRead {
            try await $0.fetchRange(path: path, offset: offset, length: length)
        }
    }

    func fetchRange(
        path: String,
        offset: Int64,
        length: Int64,
        priority: RangeFetchPriority
    ) async throws -> Data {
        try await routing.withRead {
            try await $0.fetchRange(
                path: path,
                offset: offset,
                length: length,
                priority: priority
            )
        }
    }

    func fetchMetadataRange(
        path: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        try await routing.withRead {
            try await $0.fetchMetadataRange(
                path: path,
                offset: offset,
                length: length,
                intent: intent
            )
        }
    }

    func prefetchMetadata(paths: [String]) async {
        _ = try? await routing.withRead { connector in
            await connector.prefetchMetadata(paths: paths)
        }
    }

    func observingDeferredReadErrors<Element: Sendable>(
        in stream: AsyncThrowingStream<Element, Error>,
        routeIndex: Int
    ) -> AsyncThrowingStream<Element, Error> {
        let routing = routing
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await element in stream {
                        try Task.checkCancellation()
                        continuation.yield(element)
                    }
                    continuation.finish()
                } catch {
                    await routing.noteDeferredReadFailure(error, routeIndex: routeIndex)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private struct RoutedMusicSourceConnector: RoutedConnectorProxy, OpenListSTRMResolvingConnector,
    LyricsSidecarTargetResolving {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func lyricsSidecarTarget(for song: Song) async throws -> LyricsSidecarTarget {
        try await routing.withRead { connector in
            if let resolver = connector as? any LyricsSidecarTargetResolving {
                return try await resolver.lyricsSidecarTarget(for: song)
            }
            return try await LyricsSidecarTargetPolicy.resolve(for: song, using: connector)
        }
    }

    func openListSTRMURL(for reference: String) async throws -> URL? {
        try await routing.withRead { connector in
            guard let resolver = connector as? any OpenListSTRMResolvingConnector else {
                return nil
            }
            return try await resolver.openListSTRMURL(for: reference)
        }
    }

    func localOpenListSTRMURL(for reference: String) async throws -> URL {
        try await routing.withRead { connector in
            guard let resolver = connector as? any OpenListSTRMResolvingConnector else {
                throw SourceError.connectionFailed("OpenList STRM transport unavailable")
            }
            return try await resolver.localOpenListSTRMURL(for: reference)
        }
    }

    func downloadBoundedOpenListSTRM(
        for reference: String,
        maximumBytes: Int64
    ) async throws -> URL {
        try await routing.withRead { connector in
            guard let resolver = connector as? any OpenListSTRMResolvingConnector else {
                throw SourceError.connectionFailed("OpenList STRM transport unavailable")
            }
            return try await resolver.downloadBoundedOpenListSTRM(
                for: reference,
                maximumBytes: maximumBytes
            )
        }
    }

    func fetchOpenListSTRMMetadataRange(
        for reference: String,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        try await routing.withRead { connector in
            guard let resolver = connector as? any OpenListSTRMResolvingConnector else {
                throw SourceError.connectionFailed("OpenList STRM transport unavailable")
            }
            return try await resolver.fetchOpenListSTRMMetadataRange(
                for: reference,
                offset: offset,
                length: length,
                intent: intent
            )
        }
    }
}

private struct RoutedSubsonicConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    ServerCatalogChangeDetectingConnector, ServerCatalogScanRequestingConnector,
    ResumablePagedSongCatalogConnector,
    ServerScrobblingConnector, ServerLyricsConnector, ServerPlaylistConnector,
    ServerMediaSharingConnector, ServerFavoriteConnector,
    ServerRadioConnector, ServerListeningStatsConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func fetchServerCatalogScanStatus() async throws -> ServerCatalogScanStatus {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerCatalogChangeDetectingConnector else {
                throw SourceError.connectionFailed("Server catalogue status unavailable")
            }
            return try await provider.fetchServerCatalogScanStatus()
        }
    }

    func requestServerCatalogScan() async throws -> ServerCatalogScanRequestResult {
        try await routing.withMutation { connector in
            guard let provider = connector as? any ServerCatalogScanRequestingConnector else {
                return .unsupported
            }
            return try await provider.requestServerCatalogScan()
        }
    }

    func stableSongCatalogRevision() async throws -> String? {
        try await routing.withRead { connector in
            guard let scanner = connector as? any ResumablePagedSongCatalogConnector else {
                throw PagedSongCatalogError.unavailable
            }
            return try await scanner.stableSongCatalogRevision()
        }
    }

    func songCatalogPage(from path: String, offset: Int) async throws -> PagedSongCatalogPage {
        try await routing.withRead { connector in
            guard let scanner = connector as? any ResumablePagedSongCatalogConnector else {
                throw PagedSongCatalogError.unavailable
            }
            return try await scanner.songCatalogPage(from: path, offset: offset)
        }
    }

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerPlaylistConnector else {
                throw SourceError.connectionFailed("Server playlist connector unavailable")
            }
            return try await provider.fetchServerPlaylists()
        }
    }

    func serverMediaSharingAvailability() async throws -> ServerMediaSharingAvailability {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerMediaSharingConnector else {
                return .unsupported
            }
            return try await provider.serverMediaSharingAvailability()
        }
    }

    func createServerMediaShare(
        _ request: ServerMediaShareRequest
    ) async throws -> ServerMediaShare {
        try await routing.withMutation { connector in
            guard let provider = connector as? any ServerMediaSharingConnector else {
                throw ServerMediaSharingError.unsupported
            }
            return try await provider.createServerMediaShare(request)
        }
    }

    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerListeningStatsConnector else {
                throw SourceError.connectionFailed("Server listening statistics connector unavailable")
            }
            return try await provider.fetchServerListeningStats()
        }
    }

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerFavoriteConnector else {
                throw SourceError.connectionFailed("Server favorite connector unavailable")
            }
            return try await provider.fetchServerFavorites()
        }
    }

    func setServerFavorite(
        itemID: String,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot {
        try await routing.withMutation { connector in
            guard let provider = connector as? any ServerFavoriteConnector else {
                throw SourceError.connectionFailed("Server favorite connector unavailable")
            }
            return try await provider.setServerFavorite(
                itemID: itemID,
                isFavorite: isFavorite
            )
        }
    }

    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot? {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerRadioConnector else { return nil }
            return try await provider.fetchServerRadioStations()
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let routed = try await routing.withReadAndRoute { connector in
            guard let scanner = connector as? any SongScanningConnector else {
                throw SourceError.connectionFailed("Song scanner unavailable")
            }
            return try await scanner.scanSongs(from: path)
        }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func scrobble(songPath: String, submission: Bool) async {
        _ = try? await routing.withMutation { connector in
            guard let reporter = connector as? any ServerScrobblingConnector else { return }
            await reporter.scrobble(songPath: songPath, submission: submission)
        }
    }

    func fetchServerLyrics(for path: String) async -> String? {
        try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else { return nil }
            return await provider.fetchServerLyrics(for: path)
        }
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        (try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else {
                return .unavailable
            }
            return await provider.readServerLyrics(for: path)
        }) ?? .unavailable
    }
}

private struct RoutedFnMusicConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    ServerScrobblingConnector, ServerLyricsConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let routed = try await routing.withReadAndRoute { connector in
            guard let scanner = connector as? any SongScanningConnector else {
                throw SourceError.connectionFailed("Song scanner unavailable")
            }
            return try await scanner.scanSongs(from: path)
        }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func scrobble(songPath: String, submission: Bool) async {
        _ = try? await routing.withMutation { connector in
            guard let reporter = connector as? any ServerScrobblingConnector else { return }
            await reporter.scrobble(songPath: songPath, submission: submission)
        }
    }

    func fetchServerLyrics(for path: String) async -> String? {
        try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else { return nil }
            return await provider.fetchServerLyrics(for: path)
        }
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        (try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else {
                return .unavailable
            }
            return await provider.readServerLyrics(for: path)
        }) ?? .unavailable
    }
}

private struct RoutedDaoLiYuConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    ServerLyricsConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let routed = try await routing.withReadAndRoute { connector in
            guard let scanner = connector as? any SongScanningConnector else {
                throw SourceError.connectionFailed("Song scanner unavailable")
            }
            return try await scanner.scanSongs(from: path)
        }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func fetchServerLyrics(for path: String) async -> String? {
        try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else { return nil }
            return await provider.fetchServerLyrics(for: path)
        }
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        (try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else {
                return .unavailable
            }
            return await provider.readServerLyrics(for: path)
        }) ?? .unavailable
    }

}

private struct RoutedMediaServerConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    MediaServerWritebackConnector, ServerLyricsConnector, ServerPlaylistConnector,
    ServerFavoriteConnector,
    ServerRadioConnector, ServerRadioStreamResolvingConnector, ServerListeningStatsConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int
    let serverLyricsCapabilities: ServerLyricsCapabilities

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerPlaylistConnector else {
                throw SourceError.connectionFailed("Server playlist connector unavailable")
            }
            return try await provider.fetchServerPlaylists()
        }
    }

    func fetchServerListeningStats() async throws -> ServerListeningStatsPayload {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerListeningStatsConnector else {
                throw SourceError.connectionFailed("Server listening statistics connector unavailable")
            }
            return try await provider.fetchServerListeningStats()
        }
    }

    func fetchServerFavorites() async throws -> ServerFavoriteSnapshot {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerFavoriteConnector else {
                throw SourceError.connectionFailed("Server favorite connector unavailable")
            }
            return try await provider.fetchServerFavorites()
        }
    }

    func setServerFavorite(
        itemID: String,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot {
        try await routing.withMutation { connector in
            guard let provider = connector as? any ServerFavoriteConnector else {
                throw SourceError.connectionFailed("Server favorite connector unavailable")
            }
            return try await provider.setServerFavorite(
                itemID: itemID,
                isFavorite: isFavorite
            )
        }
    }

    func fetchServerRadioStations() async throws -> ServerRadioStationSnapshot? {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerRadioConnector else { return nil }
            return try await provider.fetchServerRadioStations()
        }
    }

    func resolveServerRadioStream(stationID: String, forceRefresh: Bool) async throws -> URL {
        try await routing.withRead { connector in
            guard let resolver = connector as? any ServerRadioStreamResolvingConnector else {
                throw SourceError.connectionFailed("Server radio resolver unavailable")
            }
            return try await resolver.resolveServerRadioStream(
                stationID: stationID,
                forceRefresh: forceRefresh
            )
        }
    }

    func scanSongs(from path: String) async throws -> AsyncThrowingStream<ConnectorScannedSong, Error> {
        let routed = try await routing.withReadAndRoute { connector in
            guard let scanner = connector as? any SongScanningConnector else {
                throw SourceError.connectionFailed("Song scanner unavailable")
            }
            return try await scanner.scanSongs(from: path)
        }
        return observingDeferredReadErrors(in: routed.value, routeIndex: routed.routeIndex)
    }

    func writeScrapedMetadata(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String?
    ) async -> MediaServerWritebackResult {
        do {
            return try await routing.withMutation { connector in
                guard let writer = connector as? any MediaServerWritebackConnector else {
                    throw SourceError.connectionFailed("Metadata writer unavailable")
                }
                return await writer.writeScrapedMetadata(
                    original: original,
                    updated: updated,
                    coverData: coverData,
                    lyricsLines: lyricsLines,
                    lyricsContent: lyricsContent
                )
            }
        } catch {
            var result = MediaServerWritebackResult()
            result.errors = [error.localizedDescription]
            return result
        }
    }

    func removeLyrics(for song: Song) async -> MediaServerWritebackResult {
        do {
            return try await routing.withMutation { connector in
                guard let writer = connector as? any MediaServerWritebackConnector else {
                    throw SourceError.connectionFailed("Metadata writer unavailable")
                }
                return await writer.removeLyrics(for: song)
            }
        } catch {
            var result = MediaServerWritebackResult()
            result.errors = [error.localizedDescription]
            return result
        }
    }

    func fetchServerLyrics(for path: String) async -> String? {
        try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else { return nil }
            return await provider.fetchServerLyrics(for: path)
        }
    }

    func readServerLyrics(for path: String) async -> ServerLyricsReadResult {
        (try? await routing.withRead { connector in
            guard let provider = connector as? any ServerLyricsConnector else {
                return .unavailable
            }
            return await provider.readServerLyrics(for: path)
        }) ?? .unavailable
    }

}

@MainActor
@Observable
final class SourceManager {
    private enum PlaybackAudioCacheReservationMode: Equatable {
        case readOnly
        case persistentCache
        case canonicalPhysical
        case temporaryPhysical

        var respectsConfiguredCacheLimit: Bool {
            self != .canonicalPhysical && self != .temporaryPhysical
        }

        var usesCanonicalStorage: Bool {
            self != .temporaryPhysical
        }
    }

    private struct PlaybackAudioCacheLeaseRecord {
        let lease: AudioCachePathLease
        let sourceID: String
        let relativePath: String
        var generation: UInt64
        var mode: PlaybackAudioCacheReservationMode
        var maximumTransferBytes: Int64?
    }

    private struct PlaybackAudioCacheLeaseFinalization {
        let id: UUID
        let generation: UInt64
        let sourceID: String
        let task: Task<Void, Never>
    }

    /// Connector lifecycle and scope validation are internal bookkeeping. Directory
    /// browser views resolve a connector while SwiftUI is evaluating `body`; tracking
    /// these mutations would invalidate that same body and create a render loop.
    @ObservationIgnored private var connectors: [String: any MusicSourceConnector] = [:]
    @ObservationIgnored private var connectorScopeFingerprints: [String: String] = [:]
    @ObservationIgnored private var requiredConnectorScopeFingerprints: [String: String] = [:]
    @ObservationIgnored private var connectorSourceModifiedAtByID: [String: Date] = [:]
    @ObservationIgnored private var connectorScopeValidationPendingSourceIDs: Set<String> = []
    @ObservationIgnored private var connectorScopeValidationGenerationBySourceID: [String: Int] = [:]
    private struct UnavailableConnectorCacheEntry {
        let connector: any MusicSourceConnector
        let capturedAt: Date
        let scopeFingerprint: String
    }
    /// Credential failures are intentionally not kept in the durable connector
    /// cache, but callers such as an artwork grid can request the same source
    /// many times in one render pass. Coalesce that short burst and retry after
    /// a bounded delay so unlocking the device still recovers automatically.
    @ObservationIgnored private var unavailableConnectors: [String: UnavailableConnectorCacheEntry] = [:]
    /// Sidecar I/O uses a connector separate from playback, but it must remain
    /// retained. AMSMB2 4.0.3 can crash in its C-context deinitializer after a
    /// server rejects a write; creating one throwaway connector per song made
    /// a read-only SMB scrape reliably hit that upstream lifetime bug.
    @ObservationIgnored private var sidecarConnectors: [String: any MusicSourceConnector] = [:]
    @ObservationIgnored private var sidecarConnectorScopeFingerprints: [String: String] = [:]
    /// A replaced SMB connector cannot be safely destroyed after a failed C
    /// request on AMSMB2 4.0.3. Keep the rare retired instance alive until the
    /// process exits; normal playback and scrape paths remain bounded at one
    /// active connector per source.
    @ObservationIgnored private var retiredSMBSidecarConnectors: [any MusicSourceConnector] = []
    private let sourcesProvider: @Sendable () async throws -> [MusicSource]
    private let songsProvider: @MainActor () -> [Song]
    @ObservationIgnored private var offlineAudioSnapshots: [String: OfflineAudioCacheSnapshot] = [:]
    @ObservationIgnored private var offlineAudioSnapshotEntries: [String: OfflineAudioSnapshotEntry] = [:]
    /// Lightweight aggregate used by the source cards. Download progress does
    /// not mutate this set; only entering/leaving the downloading state does.
    private(set) var offlineDownloadingSongIDs: Set<String> = []
    /// Only user-confirmed whole-source offline batches appear here. Playback
    /// recovery and per-song downloads share the same downloader, but must not
    /// make a source card claim that the complete source is being cached.
    private(set) var activeOfflineSourceCacheSourceIDs: Set<String> = []
    /// Changes only when a song enters or leaves the fully downloaded set.
    /// Song-list filters can observe this aggregate without subscribing to
    /// every row-level progress entry.
    private(set) var offlineAudioSnapshotRevision = 0
    /// The route that most recently completed a real connection. Kept separate
    /// from the persisted source so cards can show what is in use without
    /// syncing device-local network state through iCloud.
    private(set) var activeConnectionRoutes: [String: SourceConnectionCandidateKind] = [:]
    /// Retains the most recently confirmed route after a transient read
    /// failure or network-path refresh. Cards can keep the endpoint selected
    /// as "last used" until a replacement route actually connects, avoiding a
    /// misleading selected/unselected flash during automatic retries.
    private(set) var lastSuccessfulConnectionRoutes: [String: SourceConnectionCandidateKind] = [:]
    private var offlineDownloadTasks: [String: OfflineDownloadTaskRecord] = [:]
    @ObservationIgnored var automaticOfflineDownloadRemovedHandler: ((String) -> Void)?
    @ObservationIgnored private var automaticPlaylistPinnedSongsByID: [String: Song] = [:]
    private var backgroundAudioCacheTasks: [String: BackgroundAudioCacheTaskRecord] = [:]
    @ObservationIgnored private var playbackAudioCacheLeases: [String: PlaybackAudioCacheLeaseRecord] = [:]
    @ObservationIgnored private var playbackAudioCacheLeaseFinalizations: [String: PlaybackAudioCacheLeaseFinalization] = [:]
    @ObservationIgnored private var activePlaybackAudioCachePaths: [String: Int] = [:]
    @ObservationIgnored private var preservingAutomaticRefreshPaths: Set<String> = []
    @ObservationIgnored private var contentChangeProtectionPendingPaths: Set<String> = []
    @ObservationIgnored private var contentChangeInvalidationGenerationByPath: [String: Int] = [:]
    @ObservationIgnored private var contentChangeInvalidationGeneration = 0
    @ObservationIgnored private var blockedUntrustedAudioCachePaths: Set<String> = []
    @ObservationIgnored private var automaticOfflineReconciliationGeneration = 0
    @ObservationIgnored private var recordedAudioCacheScopeSignatures: [String: String]
    @ObservationIgnored private var legacyAudioCacheAdoptionSourceIDs: Set<String>
    @ObservationIgnored private var needsLegacyAudioCacheAdoptionDiscovery: Bool
    @ObservationIgnored private var validatedAudioCacheSourceIDs: Set<String> = []
    @ObservationIgnored private var blockedAudioCacheSourceIDs: Set<String> = []
    @ObservationIgnored private var audioCacheScopeGenerationBySourceID: [String: Int] = [:]
    @ObservationIgnored private var audioCacheScopeValidationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var audioCacheScopeReconciliationsInProgress: Set<String> = []
    @ObservationIgnored private var credentialChangesInProgress: Set<String> = []
    @ObservationIgnored private var automaticAudioCachingEnabled = true
    private var musicVideoCacheTasks: [String: Task<URL, Error>] = [:]
    private var musicVideoCacheTargets: [String: URL] = [:]

    init(database: LibraryDatabase) {
        let initialCacheScopeState = Self.loadInitialAudioCacheScopeState()
        self.recordedAudioCacheScopeSignatures = initialCacheScopeState.signatures
        self.legacyAudioCacheAdoptionSourceIDs = initialCacheScopeState.legacyAdoptionSourceIDs
        self.needsLegacyAudioCacheAdoptionDiscovery = initialCacheScopeState.needsLegacyDiscovery
        self.sourcesProvider = {
            try await database.allSources()
        }
        self.songsProvider = { [] }
        observeLibraryInvalidations()
        scheduleInitialAudioCacheScopeValidation()
    }

    init(
        sourcesProvider: @escaping @Sendable () async throws -> [MusicSource],
        songsProvider: @escaping @MainActor () -> [Song] = { [] }
    ) {
        let initialCacheScopeState = Self.loadInitialAudioCacheScopeState()
        self.recordedAudioCacheScopeSignatures = initialCacheScopeState.signatures
        self.legacyAudioCacheAdoptionSourceIDs = initialCacheScopeState.legacyAdoptionSourceIDs
        self.needsLegacyAudioCacheAdoptionDiscovery = initialCacheScopeState.needsLegacyDiscovery
        self.sourcesProvider = sourcesProvider
        self.songsProvider = songsProvider
        observeLibraryInvalidations()
        scheduleInitialAudioCacheScopeValidation()
    }

    private func observeLibraryInvalidations() {
        NotificationCenter.default.addObserver(
            forName: .primuseSourcesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let sourceIDs = note.userInfo?["ids"] as? [String],
                  !sourceIDs.isEmpty else { return }
            let currentScopeFingerprints = note.userInfo?["scopeFingerprints"]
                as? [String: String]
            MainActor.assumeIsolated {
                self.classifySourceConfigurationChanges(
                    Set(sourceIDs),
                    currentScopeFingerprints: currentScopeFingerprints
                )
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSongLocationChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let previousSongs = (note.userInfo?["previousSongs"] as? [Song]) ?? []
            let currentSongs = (note.userInfo?["songs"] as? [Song]) ?? []
            MainActor.assumeIsolated {
                self.reconcilePathKeyedCaches(
                    previousSongs: previousSongs,
                    currentSongs: currentSongs
                )
            }
        }

        // When a re-scan detects that the bytes behind a known path
        // changed (user replaced the file on the cloud drive), the old
        // local cache files are now stale. Wipe them so the next play or
        // artwork/lyrics load uses the fresh remote bytes.
        NotificationCenter.default.addObserver(
            forName: .primuseSongContentChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            MainActor.assumeIsolated {
                self.invalidateLocalCachesForContentChanges(songs)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSongsRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            let sourceIDs = Set((note.userInfo?["sourceIDs"] as? [String]) ?? [])
            let songIDs = (note.userInfo?["songIDs"] as? Set<String>)
                ?? Set(songs.map(\.id))
            MainActor.assumeIsolated {
                if sourceIDs.isEmpty {
                    self.deleteLocalCaches(for: songs)
                } else {
                    self.deleteLocalCachesForRemovedSources(
                        sourceIDs,
                        songs: songs,
                        songIDs: songIDs
                    )
                }
            }
        }
    }

    func connector(for source: MusicSource) -> any MusicSourceConnector {
        return connector(for: source, cache: true)
    }

    func serverCatalogScanStatus(for source: MusicSource) async throws -> ServerCatalogScanStatus {
        let connector = connector(for: source)
        guard let provider = connector as? any ServerCatalogChangeDetectingConnector else {
            throw SourceError.connectionFailed("Server catalogue status unavailable")
        }
        try await connector.connect()
        return try await provider.fetchServerCatalogScanStatus()
    }

    func requestServerCatalogScan(for source: MusicSource) async throws -> ServerCatalogScanRequestResult {
        let connector = connector(for: source)
        guard let provider = connector as? any ServerCatalogScanRequestingConnector else {
            return .unsupported
        }
        return try await provider.requestServerCatalogScan()
    }

    private func connector(for source: MusicSource, cache: Bool) -> any MusicSourceConnector {
        let scopeFingerprint = Self.audioCacheScopeSignature(for: source)
        guard !credentialChangesInProgress.contains(source.id),
              !MusicSourceSecurityRevision.hasPendingChange(for: source.id) else {
            return NoAvailableConnectionSourceConnector(sourceID: source.id)
        }
        if connectorScopeValidationPendingSourceIDs.contains(source.id),
           SourceConnectorScopePolicy.canEstablishDuringPendingValidation(
               previousModifiedAt: connectorSourceModifiedAtByID[source.id],
               requestedModifiedAt: source.modifiedAt
           ) {
            requiredConnectorScopeFingerprints[source.id] = scopeFingerprint
            connectorSourceModifiedAtByID[source.id] = source.modifiedAt
            connectorScopeValidationPendingSourceIDs.remove(source.id)
        }
        let validationPending = connectorScopeValidationPendingSourceIDs.contains(source.id)
        let requiredFingerprint = requiredConnectorScopeFingerprints[source.id]
        guard SourceConnectorScopePolicy.allows(
            requestedFingerprint: scopeFingerprint,
            requiredFingerprint: requiredFingerprint,
            validationPending: validationPending
        ) else {
            return NoAvailableConnectionSourceConnector(sourceID: source.id)
        }
        if requiredFingerprint == nil {
            requiredConnectorScopeFingerprints[source.id] = scopeFingerprint
        }
        let latestModifiedAt = max(
            connectorSourceModifiedAtByID[source.id] ?? .distantPast,
            source.modifiedAt
        )
        if connectorSourceModifiedAtByID[source.id] != latestModifiedAt {
            connectorSourceModifiedAtByID[source.id] = latestModifiedAt
        }
        do {
            try MusicSourceSecurityRevision.registerCacheNamespace(
                sourceID: source.id,
                scopedFingerprint: scopeFingerprint
            )
        } catch {
            plog("⚠️ Source cache namespace could not be persisted: \(error.localizedDescription)")
            return NoAvailableConnectionSourceConnector(sourceID: source.id)
        }

        if cache, let existing = connectors[source.id] {
            if SourceConnectorScopePolicy.canReuse(
                cachedFingerprint: connectorScopeFingerprints[source.id],
                requestedFingerprint: scopeFingerprint,
                requiredFingerprint: requiredConnectorScopeFingerprints[source.id],
                validationPending: false
            ) {
                return existing
            }
            connectors[source.id] = nil
            connectorScopeFingerprints[source.id] = nil
            retireConnectorAsynchronously(existing)
        }
        if cache, let unavailable = unavailableConnectors[source.id] {
            if unavailable.scopeFingerprint == scopeFingerprint,
               NetworkCredentialPolicy.shouldReuseUnavailableConnector(
                capturedAt: unavailable.capturedAt,
                now: Date()
            ) {
                return unavailable.connector
            }
            unavailableConnectors.removeValue(forKey: source.id)
            retireConnectorAsynchronously(unavailable.connector)
        }

        let connector = routedConnector(for: source)
        if cache {
            if connector is CredentialUnavailableSourceConnector {
                unavailableConnectors[source.id] = UnavailableConnectorCacheEntry(
                    connector: connector,
                    capturedAt: Date(),
                    scopeFingerprint: scopeFingerprint
                )
            } else if !(connector is NoAvailableConnectionSourceConnector) {
                connectors[source.id] = connector
                connectorScopeFingerprints[source.id] = scopeFingerprint
            }
        }
        return connector
    }

    private func routedConnector(for source: MusicSource) -> any MusicSourceConnector {
        guard source.type.supportsAdaptiveConnections,
              source.connectionConfiguration != nil else {
            return directConnector(for: source)
        }

        let configuredCandidates = source.connectionCandidates
        guard configuredCandidates.isEmpty == false else {
            return NoAvailableConnectionSourceConnector(sourceID: source.id)
        }

        let routedCandidates = configuredCandidates.map { candidate in
            RoutedConnectorCandidate(
                kind: candidate.kind,
                endpoint: candidate.endpoint,
                connector: directConnector(for: source.applyingConnectionCandidate(candidate))
            )
        }
        guard routedCandidates.count > 1 else {
            return routedCandidates[0].connector
        }
        if let unavailable = routedCandidates.lazy.map(\.connector).first(where: {
            $0 is CredentialUnavailableSourceConnector
        }) {
            return unavailable
        }

        let routing = SourceConnectionRouter(
            sourceID: source.id,
            candidates: routedCandidates
        ) { [weak self] kind in
            self?.setActiveConnectionRoute(kind, for: source.id)
        }
        let supportsSidecarWriting = routedCandidates[0].connector.supportsSidecarWriting
        let preferredDeleteBatchSize = routedCandidates[0].connector.preferredDeleteBatchSize
        let mediaServerLyricsCapabilities: ServerLyricsCapabilities
        switch source.type {
        case .jellyfin:
            mediaServerLyricsCapabilities = ServerLyricsCapabilities(
                canRead: true,
                canWrite: true,
                canDelete: true,
                supportsSiblingSidecarLookup: false
            )
        case .emby:
            mediaServerLyricsCapabilities = .readOnlyDocument
        default:
            mediaServerLyricsCapabilities = .unavailable
        }

        switch source.type {
        case .jellyfin, .emby, .plex:
            return RoutedMediaServerConnector(
                sourceID: source.id,
                routing: routing,
                routedSupportsSidecarWriting: supportsSidecarWriting,
                routedPreferredDeleteBatchSize: preferredDeleteBatchSize,
                serverLyricsCapabilities: mediaServerLyricsCapabilities
            )
        case .subsonic, .navidrome, .airsonic, .gonic:
            return RoutedSubsonicConnector(
                sourceID: source.id,
                routing: routing,
                routedSupportsSidecarWriting: supportsSidecarWriting,
                routedPreferredDeleteBatchSize: preferredDeleteBatchSize
            )
        case .fnMusic:
            return RoutedFnMusicConnector(
                sourceID: source.id,
                routing: routing,
                routedSupportsSidecarWriting: supportsSidecarWriting,
                routedPreferredDeleteBatchSize: preferredDeleteBatchSize
            )
        case .daoliyu:
            return RoutedDaoLiYuConnector(
                sourceID: source.id,
                routing: routing,
                routedSupportsSidecarWriting: supportsSidecarWriting,
                routedPreferredDeleteBatchSize: preferredDeleteBatchSize
            )
        default:
            return RoutedMusicSourceConnector(
                sourceID: source.id,
                routing: routing,
                routedSupportsSidecarWriting: supportsSidecarWriting,
                routedPreferredDeleteBatchSize: preferredDeleteBatchSize
            )
        }
    }

    private func directConnector(for source: MusicSource) -> any MusicSourceConnector {
        let connector: any MusicSourceConnector
        switch source.type {
        case .synology:
            plog("🔧 SourceManager creating SynologySource id=\(source.id) host=\(source.host ?? "?") userLen=\(source.username?.count ?? 0)")
            connector = SynologySource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl,
                connectionMode: source.effectiveSynologyConnectionMode,
                username: source.username ?? "",
                rememberDevice: source.rememberDevice,
                deviceId: source.deviceId,
                alternateTLSValidationHostname: source.alternateTLSValidationHostname
            )
        case .local:
            connector = LocalFileSource(
                sourceID: source.id,
                basePath: URL(fileURLWithPath: source.basePath ?? "/")
            )
        case .appleMusicLibrary:
            #if os(macOS)
            connector = AppleMusicLibrarySource(sourceID: source.id)
            #else
            // appleMusicLibrary is filtered out of the iOS source picker; if
            // a CloudKit-synced source row of this type ever lands on iOS we
            // surface a stub that errors gracefully instead of crashing.
            connector = UnsupportedSourceConnector(sourceID: source.id, sourceType: .appleMusicLibrary)
            #endif
        case .smb:
            connector = credentialProtectedConnector(for: source) { password in
                SMBSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port ?? 445,
                    sharePath: source.shareName ?? "",
                    username: source.username ?? "",
                    password: password
                )
            }
        case .webdav:
            connector = credentialProtectedConnector(for: source) { password in
                WebDAVSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port,
                    useSsl: source.useSsl,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .ftp:
            connector = credentialProtectedConnector(for: source) { password in
                FTPSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    password: password,
                    encryption: source.ftpEncryption ?? .none
                )
            }
        case .sftp:
            connector = credentialProtectedConnector(for: source) { secret in
                SFTPSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    secret: secret,
                    authType: source.authType
                )
            }
        case .nfs:
            connector = NFSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                exportPath: source.exportPath,
                nfsVersion: source.nfsVersion ?? .auto
            )
        case .upnp:
            connector = UPnPSource(sourceID: source.id)
        case .jellyfin, .emby, .plex:
            connector = credentialProtectedConnector(for: source) { secret in
                MediaServerSource(
                    sourceID: source.id,
                    kind: MediaServerSource.Kind(sourceType: source.type)!,
                    host: source.host ?? "",
                    port: source.port,
                    useSsl: source.useSsl,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    secret: secret,
                    authType: source.authType,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .subsonic, .navidrome, .airsonic, .gonic:
            connector = credentialProtectedConnector(for: source) { password in
                SubsonicSource(
                    sourceID: source.id,
                    sourceType: source.type,
                    host: source.host ?? "",
                    port: source.port,
                    useSsl: source.useSsl,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .qnap:
            connector = credentialProtectedConnector(for: source) { password in
                QnapSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port ?? 8080,
                    useSsl: source.useSsl,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .ugreen:
            connector = credentialProtectedConnector(for: source) { password in
                UgreenSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port ?? 9999,
                    useSsl: source.useSsl,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .fnos:
            // Historical fnOS records represented an unpublished generic NAS
            // file API. Keep them fail-closed instead of silently changing
            // their meaning to the new Feiniu Music catalogue.
            connector = UnsupportedSourceConnector(sourceID: source.id, sourceType: .fnos)
        case .fnMusic:
            connector = credentialProtectedConnector(for: source) { password -> any MusicSourceConnector in
                let accessCode = KeychainService.getPassword(
                    for: FnMusicAPIProtocol.fnConnectAccessCodeAccount(sourceID: source.id)
                )
                return FnMusicSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port,
                    useSSL: source.useSsl,
                    basePath: source.basePath,
                    connectionMode: source.effectiveFnMusicConnectionMode,
                    accessCode: accessCode,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .daoliyu:
            connector = credentialProtectedConnector(for: source) { password in
                DaoLiYuSource(
                    sourceID: source.id,
                    host: source.host ?? "",
                    port: source.port,
                    useSSL: source.useSsl,
                    basePath: source.basePath,
                    username: source.username ?? "",
                    password: password,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .baiduPan:
            connector = BaiduPanSource(sourceID: source.id)
        case .aliyunDrive:
            connector = AliyunDriveSource(sourceID: source.id)
        case .googleDrive:
            connector = GoogleDriveSource(sourceID: source.id)
        case .oneDrive:
            connector = OneDriveSource(sourceID: source.id)
        case .dropbox:
            connector = DropboxSource(sourceID: source.id)
        case .drime:
            connector = DrimeSource(sourceID: source.id)
        case .pan115:
            connector = U115Source(sourceID: source.id)
        case .pan123:
            connector = Pan123Source(sourceID: source.id)
        case .s3:
            // S3 uses host=endpoint, basePath=bucket, and extraConfig holds
            // {"region":..., "dirs":[...]} — read region S3-aware so the dir
            // list sharing the slot doesn't break the lookup.
            connector = credentialProtectedConnector(for: source) { secretKey in
                S3Source(
                    sourceID: source.id,
                    endpoint: source.host ?? "s3.amazonaws.com",
                    port: source.port,
                    region: source.s3Region ?? "us-east-1",
                    bucket: source.basePath ?? "",
                    accessKey: source.username ?? "",
                    secretKey: secretKey,
                    useSsl: source.useSsl,
                    alternateTLSValidationHostname: source.alternateTLSValidationHostname
                )
            }
        case .appleMusic:
            // Apple Music 在系统侧 ApplicationMusicPlayer 播放, 不需要 connector
            // 扫文件 / 解析。给个 unsupported 占位让 switch 完整, 实际 scan
            // 走 AppleMusicLibraryService, play 由 AudioPlayerService 路由。
            connector = UnsupportedSourceConnector(sourceID: source.id, sourceType: .appleMusic)
        }

        return connector
    }

    func diagnose(source: MusicSource, directories explicitDirectories: [String]? = nil) async -> SourceDiagnosticReport {
        let startedAt = Date()
        var checks = configurationChecks(for: source, explicitDirectories: explicitDirectories)
        if checks.contains(where: { $0.status == .failed }) {
            return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
        }

        let connector = connector(for: source)
        do {
            try await Self.withTimeout(seconds: 15) {
                try await connector.connect()
            }
            checks.append(SourceDiagnosticCheck(
                status: .passed,
                title: String(localized: "source_diag_connection_title"),
                message: String(localized: "source_diag_connection_ok")
            ))
        } catch {
            if OperationCancellationPolicy.isCancellation(error) {
                retireDiagnosticConnector(connector, sourceID: source.id)
                checks.append(diagnosticCheck(
                    for: error,
                    source: source,
                    title: String(localized: "source_diag_connection_title")
                ))
                return SourceDiagnosticReport(
                    source: source,
                    startedAt: startedAt,
                    checks: checks,
                    wasCancelled: true
                )
            }
            let recovered = await SSLTrustStore.shared.handleSSLErrorIfNeeded(error)
            if recovered {
                do {
                    try await Self.withTimeout(seconds: 15) {
                        try await connector.connect()
                    }
                    checks.append(SourceDiagnosticCheck(
                        status: .passed,
                        title: String(localized: "source_diag_connection_title"),
                        message: String(localized: "source_diag_connection_ok")
                    ))
                } catch {
                    if OperationCancellationPolicy.isCancellation(error) {
                        retireDiagnosticConnector(connector, sourceID: source.id)
                        checks.append(diagnosticCheck(
                            for: error,
                            source: source,
                            title: String(localized: "source_diag_connection_title")
                        ))
                        return SourceDiagnosticReport(
                            source: source,
                            startedAt: startedAt,
                            checks: checks,
                            wasCancelled: true
                        )
                    }
                    retireDiagnosticConnector(connector, sourceID: source.id)
                    checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_connection_title")))
                    return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
                }
            } else {
                retireDiagnosticConnector(connector, sourceID: source.id)
                checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_connection_title")))
                return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
            }
        }

        // Feiniu Music is a server catalogue, not a directory tree. Probe the
        // real track-list route through its synthetic root, then stop before
        // the generic folder diagnostics can suggest choosing a NAS path.
        if source.type == .fnMusic {
            do {
                _ = try await Self.withTimeout(seconds: 20) {
                    try await connector.listFiles(at: "/")
                }
                checks.append(SourceDiagnosticCheck(
                    status: .passed,
                    title: source.type.displayName,
                    message: String(localized: "source_diag_scan_ready_ok")
                ))
            } catch {
                retireDiagnosticConnector(connector, sourceID: source.id)
                checks.append(diagnosticCheck(
                    for: error,
                    source: source,
                    title: source.type.displayName
                ))
                if OperationCancellationPolicy.isCancellation(error) {
                    return SourceDiagnosticReport(
                        source: source,
                        startedAt: startedAt,
                        checks: checks,
                        wasCancelled: true
                    )
                }
            }
            return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
        }

        let roots = diagnosticProbeRoots(for: source, explicitDirectories: explicitDirectories)
        if roots.isEmpty {
            checks.append(SourceDiagnosticCheck(
                status: .warning,
                title: String(localized: "source_diag_directory_title"),
                message: String(localized: "source_diag_select_dirs"),
                suggestion: String(localized: "source_diag_select_dirs_suggestion")
            ))
        } else {
            do {
                var visibleItems = 0
                for root in roots.prefix(3) {
                    let items = try await Self.withTimeout(seconds: 20) {
                        try await connector.listFiles(at: root)
                    }
                    visibleItems += items.count
                }

                checks.append(SourceDiagnosticCheck(
                    status: visibleItems == 0 ? .warning : .passed,
                    title: String(localized: "source_diag_directory_title"),
                    message: visibleItems == 0
                        ? String(format: String(localized: "source_diag_directory_empty_format"), visibleItems)
                        : String(format: String(localized: "source_diag_directory_ok_format"), visibleItems),
                    suggestion: visibleItems == 0 ? String(localized: "source_diag_directory_empty_suggestion") : ""
                ))
            } catch {
                retireDiagnosticConnector(connector, sourceID: source.id)
                checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_directory_title")))
                return SourceDiagnosticReport(
                    source: source,
                    startedAt: startedAt,
                    checks: checks,
                    wasCancelled: OperationCancellationPolicy.isCancellation(error)
                )
            }
        }

        checks.append(SourceDiagnosticCheck(
            status: checks.contains(where: { $0.status == .warning }) ? .warning : .passed,
            title: String(localized: "source_diag_scan_ready_title"),
            message: String(localized: checks.contains(where: { $0.status == .warning }) ? "source_diag_scan_ready_warning" : "source_diag_scan_ready_ok")
        ))
        return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
    }

    /// A failed or timed-out preflight must never leave its connector in the
    /// reusable cache. Disconnect asynchronously because the same transport
    /// that ignored operation cancellation may also delay cleanup.
    private func retireDiagnosticConnector(
        _ connector: any MusicSourceConnector,
        sourceID: String
    ) {
        if let cached = connectors[sourceID], Self.isSameConnector(cached, connector) {
            connectors.removeValue(forKey: sourceID)
            connectorScopeFingerprints.removeValue(forKey: sourceID)
            activeConnectionRoutes.removeValue(forKey: sourceID)
        }
        if let cached = unavailableConnectors[sourceID],
           Self.isSameConnector(cached.connector, connector) {
            unavailableConnectors.removeValue(forKey: sourceID)
        }
        retireConnectorAsynchronously(connector)
    }

    private func retireConnectorAsynchronously(_ connector: any MusicSourceConnector) {
        Task.detached(priority: .utility) {
            await connector.disconnect()
        }
    }

    private func retireSidecarConnector(_ connector: any MusicSourceConnector) {
        if connector is SMBSource {
            retiredSMBSidecarConnectors.append(connector)
        } else {
            retireConnectorAsynchronously(connector)
        }
    }

    private nonisolated static func isSameConnector(
        _ lhs: any MusicSourceConnector,
        _ rhs: any MusicSourceConnector
    ) -> Bool {
        if let lhs = lhs as? any RoutedConnectorProxy,
           let rhs = rhs as? any RoutedConnectorProxy {
            return lhs.routing === rhs.routing
        }
        return (lhs as AnyObject) === (rhs as AnyObject)
    }

    func scanFailureMessage(for error: Error, source: MusicSource) -> String {
        let advice = Self.advice(for: error, source: source)
        let actualMessage = Self.actualErrorMessage(for: error)
        let message = actualMessage.isEmpty ? advice.message : actualMessage
        guard !advice.suggestion.isEmpty else {
            return "\(advice.title): \(message)"
        }
        return "\(advice.title): \(message) · \(advice.suggestion)"
    }

    func scanFailureMessage(for report: SourceDiagnosticReport) -> String {
        guard let failure = report.blockingFailure else {
            return String(localized: "source_diag_scan_ready_warning")
        }
        if failure.suggestion.isEmpty {
            return "\(failure.title): \(failure.message)"
        }
        return "\(failure.title): \(failure.message) · \(failure.suggestion)"
    }

    private func configurationChecks(
        for source: MusicSource,
        explicitDirectories: [String]?
    ) -> [SourceDiagnosticCheck] {
        var checks: [SourceDiagnosticCheck] = []

        let hasUsableConnection = source.type.supportsAdaptiveConnections
            && source.connectionConfiguration != nil
            ? source.connectionCandidates.isEmpty == false
            : trimmed(source.host).isEmpty == false
        if source.type.requiresHost, hasUsableConnection == false {
            checks.append(SourceDiagnosticCheck(
                status: .failed,
                title: String(localized: "source_diag_config_title"),
                message: String(localized: "source_diag_config_missing_host"),
                suggestion: String(localized: "source_diag_config_missing_host_suggestion")
            ))
        }

        switch source.type {
        case .local:
            if trimmed(source.basePath).isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .failed,
                    title: String(localized: "source_diag_config_title"),
                    message: String(localized: "source_diag_config_missing_local_path"),
                    suggestion: String(localized: "source_diag_config_missing_local_path_suggestion")
                ))
            }
        case .smb:
            if trimmed(source.shareName).isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .warning,
                    title: String(localized: "source_diag_config_title"),
                    message: String(localized: "source_diag_config_missing_share"),
                    suggestion: String(localized: "source_diag_config_missing_share_suggestion")
                ))
            }
        case .nfs:
            if trimmed(source.exportPath).isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .warning,
                    title: String(localized: "source_diag_config_title"),
                    message: String(localized: "source_diag_config_missing_export"),
                    suggestion: String(localized: "source_diag_config_missing_export_suggestion")
                ))
            }
        case .s3:
            if trimmed(source.basePath).isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .failed,
                    title: String(localized: "source_diag_config_title"),
                    message: String(localized: "source_diag_config_missing_bucket"),
                    suggestion: String(localized: "source_diag_config_missing_bucket_suggestion")
                ))
            }
        default:
            break
        }

        checks.append(contentsOf: credentialChecks(for: source))

        let selectedDirectories = explicitDirectories ?? source.scannedDirectories
        if source.type.scansEntireLibrary == false, selectedDirectories.isEmpty {
            checks.append(SourceDiagnosticCheck(
                status: .warning,
                title: String(localized: "source_diag_directory_title"),
                message: String(localized: "source_diag_select_dirs"),
                suggestion: String(localized: "source_diag_select_dirs_suggestion")
            ))
        }

        if checks.contains(where: { $0.title == String(localized: "source_diag_config_title") }) == false {
            checks.append(SourceDiagnosticCheck(
                status: .passed,
                title: String(localized: "source_diag_config_title"),
                message: String(localized: "source_diag_config_ok")
            ))
        }
        if checks.contains(where: { $0.title == String(localized: "source_diag_auth_title") }) == false {
            checks.append(SourceDiagnosticCheck(
                status: .passed,
                title: String(localized: "source_diag_auth_title"),
                message: String(localized: "source_diag_auth_ok")
            ))
        }

        return checks
    }

    private func credentialChecks(for source: MusicSource) -> [SourceDiagnosticCheck] {
        guard source.type.requiresCredentials, source.authType != .none else { return [] }

        let secret: String
        switch KeychainService.connectorCredential(for: source) {
        case .ready(let value):
            secret = value
        case .temporarilyUnavailable(let status):
            plog("⏳ Source diagnostic deferred: credential temporarily unavailable status=\(status)")
            return [SourceDiagnosticCheck(
                status: .failed,
                title: String(localized: "source_diag_auth_title"),
                message: String(localized: "credential_temporarily_unavailable")
            )]
        case .failed(let status):
            plog("⛔ Source diagnostic stopped: credential read failed status=\(status)")
            return [SourceDiagnosticCheck(
                status: .failed,
                title: String(localized: "source_diag_auth_title"),
                message: String(localized: "credential_read_failed")
            )]
        }
        let username = trimmed(source.username)
        var checks: [SourceDiagnosticCheck] = []

        switch source.authType {
        case .password:
            if source.type.supportsAnonymous, username.isEmpty, secret.isEmpty {
                return []
            }
            if username.isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .failed,
                    title: String(localized: "source_diag_auth_title"),
                    message: String(localized: "source_diag_auth_missing_username"),
                    suggestion: String(localized: "source_diag_auth_missing_username_suggestion")
                ))
            }
            if secret.isEmpty, source.type != .jellyfin, source.type != .emby {
                checks.append(SourceDiagnosticCheck(
                    status: .failed,
                    title: String(localized: "source_diag_auth_title"),
                    message: String(localized: "source_diag_auth_missing_secret"),
                    suggestion: String(localized: "source_diag_auth_missing_secret_suggestion")
                ))
            }
        case .sshKey, .apiKey, .cookie:
            if secret.isEmpty {
                checks.append(SourceDiagnosticCheck(
                    status: .failed,
                    title: String(localized: "source_diag_auth_title"),
                    message: String(localized: "source_diag_auth_missing_secret"),
                    suggestion: String(localized: "source_diag_auth_missing_secret_suggestion")
                ))
            }
        case .oauth, .none:
            break
        }

        return checks
    }

    private func diagnosticProbeRoots(for source: MusicSource, explicitDirectories: [String]?) -> [String] {
        let selectedDirectories = explicitDirectories ?? source.scannedDirectories
        if selectedDirectories.isEmpty == false {
            return selectedDirectories
        }

        switch source.type {
        case .s3:
            return [""]
        default:
            return ["/"]
        }
    }

    private func diagnosticCheck(for error: Error, source: MusicSource, title: String) -> SourceDiagnosticCheck {
        let advice = Self.advice(for: error, source: source)
        return SourceDiagnosticCheck(
            status: .failed,
            title: title,
            message: advice.message,
            suggestion: advice.suggestion
        )
    }

    private static func advice(for error: Error, source: MusicSource) -> SourceDiagnosticAdvice {
        if let cloudError = error as? CloudDriveError {
            switch cloudError {
            case .credentialTemporarilyUnavailable:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_auth_title"),
                    message: String(localized: "credential_temporarily_unavailable"),
                    suggestion: ""
                )
            case .credentialReadFailed:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_auth_title"),
                    message: String(localized: "credential_read_failed"),
                    suggestion: ""
                )
            case .notAuthenticated, .tokenExpired, .tokenRefreshFailed(_), .tokenPersistenceFailed:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_advice_oauth_title"),
                    message: String(localized: "source_diag_advice_oauth_message"),
                    suggestion: String(localized: "source_diag_advice_oauth_suggestion")
                )
            case .permissionDenied:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_advice_permission_title"),
                    message: cloudError.localizedDescription,
                    suggestion: String(localized: "source_diag_advice_permission_suggestion")
                )
            case .rateLimited:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_advice_rate_title"),
                    message: String(localized: "source_diag_advice_rate_message"),
                    suggestion: String(localized: "source_diag_advice_rate_suggestion")
                )
            case .fileNotFound(let path):
                return pathAdvice(path: path)
            case .apiError(let code, let message):
                if code == 401 { return authAdvice() }
                if code == 403, source.type == .drime {
                    return SourceDiagnosticAdvice(
                        title: String(localized: "source_diag_advice_permission_title"),
                        message: String(localized: "cloud_permission_file_read"),
                        suggestion: String(localized: "source_diag_advice_permission_suggestion")
                    )
                }
                if code == 403 { return authAdvice() }
                if code == 404 { return pathAdvice(path: message) }
                if code == 429 { return Self.advice(for: CloudDriveError.rateLimited, source: source) }
                return serverAdvice(message: "HTTP \(code) \(message)")
            case .invalidResponse:
                return serverAdvice(message: String(localized: "source_diag_advice_invalid_response"))
            }
        }

        if let sourceError = error as? SourceError {
            switch sourceError {
            case .authenticationFailed:
                return authAdvice()
            case .timeout:
                return timeoutAdvice()
            case .pathNotFound(let path), .fileNotFound(let path):
                return source.type == .fnMusic
                    ? serverAdvice(message: path)
                    : pathAdvice(path: path)
            case .credentialUnavailable(let message):
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_auth_title"),
                    message: message,
                    suggestion: ""
                )
            case .connectionFailed(let message):
                return advice(forMessage: message, source: source)
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication:
                return authAdvice()
            case NSURLErrorTimedOut:
                return timeoutAdvice()
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorInternationalRoamingOff,
                 NSURLErrorDataNotAllowed:
                return networkAdvice()
            case NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorSecureConnectionFailed:
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_advice_certificate_title"),
                    message: String(localized: "source_diag_advice_certificate_message"),
                    suggestion: String(localized: "source_diag_advice_certificate_suggestion")
                )
            default:
                break
            }
        }

        if nsError.domain == NSPOSIXErrorDomain {
            switch nsError.code {
            case Int(EACCES), Int(EPERM):
                return authAdvice()
            case Int(ETIMEDOUT):
                return timeoutAdvice()
            case Int(ECONNREFUSED), Int(EHOSTUNREACH), Int(ENETUNREACH), Int(ENOTCONN), Int(ECONNRESET):
                return networkAdvice()
            case Int(ENOENT):
                return pathAdvice(path: nsError.localizedDescription)
            default:
                break
            }
        }

        return advice(forMessage: error.localizedDescription, source: source)
    }

    private static func actualErrorMessage(for error: Error) -> String {
        if let sourceError = error as? SourceError {
            switch sourceError {
            case .connectionFailed(let message), .credentialUnavailable(let message):
                return message.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                break
            }
        }
        return error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func advice(forMessage message: String, source: MusicSource) -> SourceDiagnosticAdvice {
        let lower = message.lowercased()
        if lower.contains("auth")
            || lower.contains("password")
            || lower.contains("credential")
            || lower.contains("401")
            || lower.contains("403")
            || lower.contains("登录")
            || lower.contains("密码") {
            return authAdvice()
        }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("超时") {
            return timeoutAdvice()
        }
        if lower.contains("not found")
            || lower.contains("no such file")
            || lower.contains("404")
            || lower.contains("path")
            || lower.contains("不存在") {
            return source.type == .fnMusic
                ? serverAdvice(message: message)
                : pathAdvice(path: message)
        }
        if lower.contains("refused")
            || lower.contains("unreachable")
            || lower.contains("offline")
            || lower.contains("cannot connect")
            || lower.contains("no upnp")
            || lower.contains("不可达")
            || lower.contains("拒绝") {
            return networkAdvice()
        }
        if lower.contains("rate") || lower.contains("limit") || lower.contains("限流") {
            return SourceDiagnosticAdvice(
                title: String(localized: "source_diag_advice_rate_title"),
                message: String(localized: "source_diag_advice_rate_message"),
                suggestion: String(localized: "source_diag_advice_rate_suggestion")
            )
        }
        return serverAdvice(message: message.isEmpty ? source.type.displayName : message)
    }

    private static func authAdvice() -> SourceDiagnosticAdvice {
        SourceDiagnosticAdvice(
            title: String(localized: "source_diag_advice_auth_title"),
            message: String(localized: "source_diag_advice_auth_message"),
            suggestion: String(localized: "source_diag_advice_auth_suggestion")
        )
    }

    private static func timeoutAdvice() -> SourceDiagnosticAdvice {
        SourceDiagnosticAdvice(
            title: String(localized: "source_diag_advice_timeout_title"),
            message: String(localized: "source_diag_advice_timeout_message"),
            suggestion: String(localized: "source_diag_advice_timeout_suggestion")
        )
    }

    private static func networkAdvice() -> SourceDiagnosticAdvice {
        SourceDiagnosticAdvice(
            title: String(localized: "source_diag_advice_network_title"),
            message: String(localized: "source_diag_advice_network_message"),
            suggestion: String(localized: "source_diag_advice_network_suggestion")
        )
    }

    private static func pathAdvice(path: String) -> SourceDiagnosticAdvice {
        let detail = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty
            ? String(localized: "source_diag_advice_path_message")
            : String(format: String(localized: "source_diag_advice_path_message_format"), detail)
        return SourceDiagnosticAdvice(
            title: String(localized: "source_diag_advice_path_title"),
            message: message,
            suggestion: String(localized: "source_diag_advice_path_suggestion")
        )
    }

    private static func serverAdvice(message: String) -> SourceDiagnosticAdvice {
        SourceDiagnosticAdvice(
            title: String(localized: "source_diag_advice_server_title"),
            message: message,
            suggestion: String(localized: "source_diag_advice_server_suggestion")
        )
    }

    private func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = CancellableResultRace<T>()
        let operationTask = Task<Void, Never> {
            do {
                _ = race.resolve(.success(try await operation()))
            } catch {
                _ = race.resolve(.failure(error))
            }
        }
        let timeoutTask = Task<Void, Never> {
            do {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            if race.resolve(.failure(SourceError.timeout)) {
                operationTask.cancel()
            }
        }

        return try await withTaskCancellationHandler {
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                if Task.isCancelled, race.cancel() {
                    operationTask.cancel()
                    timeoutTask.cancel()
                }
            }
        } onCancel: {
            if race.cancel() {
                operationTask.cancel()
                timeoutTask.cancel()
            }
        }
    }

    /// Custom URL scheme that signals "play this song via streaming
    /// SFBInputSource" — AudioPlayerService intercepts it and routes to
    /// CloudPlaybackSource instead of doing a full download.
    static let cloudStreamingScheme = "primuse-stream"

    /// Query 参数标记: 服务端转码流(大小未知)。AudioPlayerService 看到它就
    /// 不走"按已知大小做 HTTP Range"那条路, 改用 AVAssetReader 渐进解码,
    /// 且不做按 fileSize 校验的持久缓存。Subsonic WMA 转码流会带上。
    /// nonisolated: SubsonicSource(独立 actor)与下面的 nonisolated 静态方法都要读它。
    nonisolated static let transcodedStreamQueryKey = "primuse_transcoded"

    /// `url` 是否是服务端转码流(带 transcoded 标记)。
    nonisolated static func isTranscodedStreamURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.queryItems?.contains(where: { $0.name == transcodedStreamQueryKey }) ?? false
    }

    private enum ResolvedSTRMTarget: Sendable {
        case remote(URL)
        case sourcePath(String)
        case openListSourcePath(String, URL)
    }

    private func resolveSTRMTarget(
        for song: Song,
        connector: any MusicSourceConnector,
        playbackScope: (expectedScope: String, streamEpoch: UInt64)? = nil
    ) async throws -> ResolvedSTRMTarget {
        let descriptor = try await connector.readSTRMDescriptor(path: song.filePath)
        if let playbackScope {
            try await ensureCurrentPlaybackResolutionScope(
                sourceID: song.sourceID,
                expectedScope: playbackScope.expectedScope,
                streamEpoch: playbackScope.streamEpoch
            )
        }
        switch descriptor.target {
        case .remote(let url):
            return .remote(url)
        case .sourcePath(let reference):
            guard let path = STRMSourcePathResolver.resolve(reference, relativeTo: song.filePath) else {
                throw STRMDescriptorError.invalidTarget
            }
            if let webDAV = connector as? any OpenListSTRMResolvingConnector,
               let originURL = try await webDAV.openListSTRMURL(for: path) {
                if let playbackScope {
                    try await ensureCurrentPlaybackResolutionScope(
                        sourceID: song.sourceID,
                        expectedScope: playbackScope.expectedScope,
                        streamEpoch: playbackScope.streamEpoch
                    )
                }
                return .openListSourcePath(path, originURL)
            }
            return .sourcePath(path)
        }
    }

    func resolveURL(
        for song: Song,
        acquirePlaybackCacheLease: Bool = true
    ) async throws -> URL {
        _ = await ensureAudioCacheScopeValidated(for: song.sourceID)
        // Priority 1: Cached local file (instant playback). 必须在 connect() 之前判断:
        // 源不可达(断网 / NAS 关机 / 登录态失效)时 connect() 会抛错。连本地
        // sourcesProvider 都不应挡在缓存前面，让完整离线文件成为真正的零网络路径。
        if acquirePlaybackCacheLease,
           let cached = await cachedURLWithPlaybackLease(for: song) {
            return cached
        }

        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: source.id)
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )

        let conn = connector(for: source)
        try await conn.connect()
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )

        let prefersAuthenticatedSubsonicWANStream =
            shouldPreferAuthenticatedSubsonicWANStream(source: source, song: song)

        if song.isStreamDescriptor {
            let target = try await resolveSTRMTarget(
                for: song,
                connector: conn,
                playbackScope: (expectedScope, streamEpoch)
            )
            try await ensureCurrentPlaybackResolutionScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            switch target {
            case .remote(let url):
                return url
            case .openListSourcePath(let path, let url):
                if permitsConfiguredDirectURL(for: source, song: song),
                   !requiresConnectorBackedHTTPTransport(for: source) {
                    return url
                }
                guard let webDAV = conn as? any OpenListSTRMResolvingConnector else {
                    throw SourceError.connectionFailed("OpenList STRM transport unavailable")
                }
                let local = try await webDAV.localOpenListSTRMURL(for: path)
                try await ensureCurrentPlaybackResolutionScope(
                    sourceID: source.id,
                    expectedScope: expectedScope,
                    streamEpoch: streamEpoch
                )
                return local
            case .sourcePath(let path):
                if permitsConfiguredDirectURL(for: source, song: song) {
                    let streamURL = try await conn.streamingURL(for: path)
                    try await ensureCurrentPlaybackResolutionScope(
                        sourceID: source.id,
                        expectedScope: expectedScope,
                        streamEpoch: streamEpoch
                    )
                    if let streamURL {
                        return streamURL
                    }
                }
                let local = try await conn.localURL(for: path)
                try await ensureCurrentPlaybackResolutionScope(
                    sourceID: source.id,
                    expectedScope: expectedScope,
                    streamEpoch: streamEpoch
                )
                return local
            }
        }

        // Priority 2: connector-backed Range streaming via CloudPlaybackSource —
        // 边下边播, ~500ms 出首个 PCM buffer。AudioPlayerService 看到
        // cloud-stream:// scheme 后会调 makeStreamingInputSource 走 sparse cache。
        // 对高延迟 WAN NAS, Priority 3 的 plain HTTP URL 更稳: 播放层会直接
        // 对这个 URL 做 Range, 避免每个 chunk 都回到 connector/API。
        if shouldUseRangeStreamingForPlayback(source: source, song: song) {
            var components = URLComponents()
            components.scheme = Self.cloudStreamingScheme
            components.host = song.sourceID
            components.path = song.filePath.hasPrefix("/") ? song.filePath : "/" + song.filePath
            if let url = components.url {
                return url
            }
        }

        // Complete-file formats and projected LAN endpoints cannot safely
        // escape to a generic player session: the former would repeat the
        // download there, while the latter would lose its public TLS identity.
        // Subsonic-family formats that are deliberately transcoded to a
        // progressive MP3 stream retain that existing direct-stream behavior
        // unless their endpoint needs connector-owned TLS handling.
        if !prefersAuthenticatedSubsonicWANStream,
           !permitsConfiguredDirectURL(for: source, song: song) {
            let local = try await conn.localURL(for: song.filePath)
            try await ensureCurrentPlaybackResolutionScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            return local
        }

        // Priority 3: plain HTTP streaming URL. For known-size audio the
        // player now wraps it in an HTTP Range InputSource; unknown-size
        // legacy rows still fall back to StreamingDownloadDecoder.
        let streamURL = try await conn.streamingURL(for: song.filePath)
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        if let streamURL {
            return streamURL
        }
        // Priority 4: Download to local (sources without streaming URL).
        let local = try await conn.localURL(for: song.filePath)
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        return local
    }

    /// Resolves a complete-file playback source without losing connector
    /// transport context. Only a genuinely external STRM target may remain an
    /// HTTP(S) URL; configured source paths are materialized by their connector.
    func resolveFullDownloadSourceURL(for song: Song) async throws -> URL {
        if let cached = await cachedURLWithPlaybackLease(for: song) {
            return cached
        }

        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == song.sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: source.id)
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        let connector = connector(for: source)
        try await connector.connect()
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        if song.isStreamDescriptor {
            let target = try await resolveSTRMTarget(
                for: song,
                connector: connector,
                playbackScope: (expectedScope, streamEpoch)
            )
            try await ensureCurrentPlaybackResolutionScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            switch target {
            case .remote(let url):
                return url
            case .openListSourcePath(let path, _):
                guard CompleteFileTransferPolicy.route(for: .connectorResolvedURL) == .connector,
                      let webDAV = connector as? any OpenListSTRMResolvingConnector else {
                    throw SourceError.connectionFailed("OpenList STRM transport unavailable")
                }
                let local = try await webDAV.localOpenListSTRMURL(for: path)
                try await ensureCurrentPlaybackResolutionScope(
                    sourceID: source.id,
                    expectedScope: expectedScope,
                    streamEpoch: streamEpoch
                )
                return local
            case .sourcePath(let path):
                let local = try await connector.localURL(for: path)
                try await ensureCurrentPlaybackResolutionScope(
                    sourceID: source.id,
                    expectedScope: expectedScope,
                    streamEpoch: streamEpoch
                )
                return local
            }
        }

        let local = try await connector.localURL(for: song.filePath)
        try await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        return local
    }

    func resolveVideoAsset(for song: Song) async throws -> MusicVideoPlaybackAsset? {
        guard let mvPath = normalizedMusicVideoPath(for: song) else { return nil }

        // 独立 MV(mvPath == filePath): 文件本体已离线下载时直接本地播,
        // 不再经视频缓存重复下载同一份字节。
        if song.isStandaloneMusicVideo,
           let cached = await cachedURLWithPlaybackLease(for: song) {
            return .url(cached)
        }

        // Resolve the authoritative local source row before deriving a cache
        // path. A process-local sourceID mapping can be stale after an endpoint
        // or account edit and would otherwise return the previous scope's bytes.
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID && !$0.isDeleted }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: source.id)
        let sourceNamespace = MusicSourceSecurityRevision.cacheNamespace(
            scopedFingerprint: expectedScope
        )
        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )

        if let url = URL(string: mvPath), let scheme = url.scheme, !scheme.isEmpty {
            return .url(url)
        }

        // 视频缓存命中同样必须完全脱离源连接。旧路径先 connect()，NAS 关机或
        // 飞行模式时会在本地文件检查前等待超时，连已经缓存的视频也播不了。
        let target = videoCacheURL(
            sourceID: song.sourceID,
            path: mvPath,
            namespace: sourceNamespace
        )
        if FileManager.default.fileExists(atPath: target.path) {
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            recordVideoCacheAccess(target)
            revalidateCachedVideoIfReachable(
                path: mvPath,
                sourceID: song.sourceID,
                target: target
            )
            return .url(target)
        }

        // 缓存音频是完整的、但 sidecar MV 不在本地时，未知或不可达的网络
        // 都直接回落音频。这样冷启动后立刻断网播放也不会卡在远端 MV 超时；
        // 已缓存 MV 已在上方优先命中，不会被这个回落误伤。
        if OfflinePlaybackPolicy.shouldSkipRemoteMusicVideo(
            hasUsableCachedAudio: cachedURL(for: song) != nil,
            isStandaloneMusicVideo: song.isStandaloneMusicVideo,
            hasDeterminedNetworkPath: NetworkMonitor.shared.hasDeterminedPath,
            isNetworkReachable: NetworkMonitor.shared.isReachable
        ) {
            return nil
        }

        let conn = connector(for: source)
        try await conn.connect()
        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )

        if !requiresConnectorBackedHTTPTransport(for: source) {
            let streamURL = try await conn.streamingURL(for: mvPath)
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            if let streamURL {
                return .url(streamURL)
            }
        }

        if source.type.category == .local {
            let localURL = try await conn.localURL(for: mvPath)
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            return .url(localURL)
        }

        // 完整缓存直接本地播, 远端 size 校验放到后台 —— 命中路径不付
        // listFiles 的网络往返, 远端文件被替换时删缓存让下次播放重下。
        // 边下边播: 知道远端大小的 range 源用 resource loader 即点即播,
        // 后台顺序下载并行把完整文件落进缓存(loader 读已覆盖的前缀省流量)。
        if source.supportsRangeStreaming {
            let expectedSize = try? await Self.musicVideoFileSize(path: mvPath, connector: conn)
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            if let expectedSize, expectedSize > 0 {
            let loader = MusicVideoStreamingLoader(
                connector: conn,
                sourceID: source.id,
                streamEpoch: streamEpoch,
                scopeIsCurrent: { [weak self] in
                    guard let self else { return false }
                    return await self.sourceScopeIsCurrent(
                        sourceID: source.id,
                        expectedScope: expectedScope
                    )
                },
                path: mvPath,
                contentLength: expectedSize,
                cacheTarget: target,
                chunkBytes: Self.videoCacheChunkBytes
            )
            if let asset = loader.makeAsset() {
                ensureMusicVideoCacheDownload(for: mvPath, source: source, connector: conn, expectedSize: expectedSize)
                return .streaming(asset, loader)
            }
            }
        }

        // 兜底(拿不到远端大小 / 无 range 能力): 全量下载进缓存后播放。
        return .url(try await cachedMusicVideoURL(for: mvPath, source: source, connector: conn))
    }

    private func normalizedMusicVideoPath(for song: Song) -> String? {
        guard let raw = song.mvPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.isEmpty == false else { return nil }
        if URL(string: raw)?.scheme != nil { return raw }
        if raw.hasPrefix("/") || raw.contains("/") { return raw }

        let dir = (song.filePath as NSString).deletingLastPathComponent
        guard dir.isEmpty == false, dir != "." else { return raw }
        return (dir as NSString).appendingPathComponent(raw)
    }

    // MARK: - Music Video Cache

    private nonisolated static let videoCacheDirName = "primuse_video_cache"
    private nonisolated static let videoCacheLimitBytes: Int64 = 10 * 1024 * 1024 * 1024
    private nonisolated static let videoCacheChunkBytes: Int64 = 4 * 1024 * 1024

    private func videoCacheDirectory(
        for sourceID: String,
        namespace explicitNamespace: String? = nil
    ) -> URL {
        let dir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.videoCacheDirName)
            .appendingPathComponent(sourceID)
            .appendingPathComponent(
                explicitNamespace
                    ?? MusicSourceSecurityRevision.cacheNamespace(for: sourceID)
            )
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func videoCacheURL(
        sourceID: String,
        path: String,
        namespace: String? = nil
    ) -> URL {
        videoCacheDirectory(for: sourceID, namespace: namespace)
            .appendingPathComponent(Self.videoCacheFileName(sourceID: sourceID, path: path))
    }

    private static func videoCacheFileName(sourceID: String, path: String) -> String {
        let digest = SHA256.hash(data: Data("\(sourceID):\(path)".utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    /// 取消所有不再需要的 MV 后台下载。切歌/停播时调用: 被取消的任务
    /// 保留 .partial 支持断点续传, 同时把并发压回最多一个活跃下载,
    /// 避免连续切歌积累多个全量下载抢带宽、击穿缓存限额。
    func cancelMusicVideoDownloads(keeping song: Song?) {
        var keepKey: String?
        if let song, let mvPath = normalizedMusicVideoPath(for: song) {
            keepKey = Self.musicVideoCacheKey(sourceID: song.sourceID, path: mvPath)
        }
        for (key, task) in musicVideoCacheTasks where key != keepKey {
            task.cancel()
        }
    }

    private static func musicVideoCacheKey(sourceID: String, path: String) -> String {
        "\(sourceID):\(path)"
    }

    private func cachedMusicVideoURL(for path: String, source: MusicSource, connector: any MusicSourceConnector) async throws -> URL {
        try await ensureMusicVideoCacheDownload(for: path, source: source, connector: connector, expectedSize: nil).value
    }

    /// 启动(或复用)后台顺序缓存下载。写盘在全局执行器上进行, 只有
    /// task 字典的登记/清理留在 MainActor。
    @discardableResult
    private func ensureMusicVideoCacheDownload(
        for path: String,
        source: MusicSource,
        connector: any MusicSourceConnector,
        expectedSize: Int64?
    ) -> Task<URL, Error> {
        let cacheKey = Self.musicVideoCacheKey(sourceID: source.id, path: path)
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: source.id)
        let target = videoCacheURL(
            sourceID: source.id,
            path: path,
            namespace: MusicSourceSecurityRevision.cacheNamespace(
                scopedFingerprint: expectedScope
            )
        )
        if let task = musicVideoCacheTasks[cacheKey],
           musicVideoCacheTargets[cacheKey] == target {
            return task
        }
        musicVideoCacheTasks[cacheKey]?.cancel()
        musicVideoCacheTasks[cacheKey] = nil
        musicVideoCacheTargets[cacheKey] = nil

        let task = Task { [self] in
            defer {
                self.musicVideoCacheTasks[cacheKey] = nil
                self.musicVideoCacheTargets[cacheKey] = nil
            }
            return try await self.materializeCachedMusicVideoURL(
                for: path,
                source: source,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch,
                connector: connector,
                target: target,
                expectedSize: expectedSize
            )
        }
        musicVideoCacheTasks[cacheKey] = task
        musicVideoCacheTargets[cacheKey] = target
        return task
    }

    /// nonisolated —— 文件 IO(写盘/复制/校验)不占主线程; 需要 MainActor
    /// 状态(in-flight 保护名单)时单点 hop 回去取快照。
    private nonisolated func materializeCachedMusicVideoURL(
        for path: String,
        source: MusicSource,
        expectedScope: String,
        streamEpoch: UInt64,
        connector: any MusicSourceConnector,
        target: URL,
        expectedSize knownSize: Int64?
    ) async throws -> URL {
        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        let expectedSize: Int64?
        if let knownSize, knownSize > 0 {
            expectedSize = knownSize
        } else {
            expectedSize = try? await Self.musicVideoFileSize(path: path, connector: connector)
        }
        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        if FileManager.default.fileExists(atPath: target.path) {
            if let expectedSize, expectedSize > 0, byteSize(at: target) != expectedSize {
                plog("🗑 MV cache: stale/incomplete cached video source=\(source.id.prefix(8)) path=\((path as NSString).lastPathComponent) actual=\(byteSize(at: target) / 1024)KB expected=\(expectedSize / 1024)KB")
                Self.removeCacheFileFamily(at: target)
            } else {
                recordVideoCacheAccess(target)
                return target
            }
        }

        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        evictVideoCache(reserveBytes: expectedSize ?? 0, protectedPaths: await protectedVideoCachePaths(including: target))
        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )

        if source.supportsRangeStreaming {
            try await downloadMusicVideoByRanges(
                path: path,
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch,
                connector: connector,
                target: target,
                expectedSize: expectedSize
            )
        } else {
            let localURL = try await connector.localURL(for: path)
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            let staged = URL(
                fileURLWithPath: target.path + ".scope-\(UUID().uuidString).partial"
            )
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: localURL, to: staged)
            try await ensureCurrentMusicVideoScope(
                sourceID: source.id,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            guard try CloudPlaybackSource.withCurrentStreamEpoch(
                sourceID: source.id,
                epoch: streamEpoch,
                {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: staged, to: target)
                    return ()
                }
            ) != nil else { throw CancellationError() }
        }

        try await ensureCurrentMusicVideoScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        recordVideoCacheAccess(target)
        evictVideoCache(reserveBytes: 0, protectedPaths: await protectedVideoCachePaths(including: target))
        return target
    }

    /// 缓存命中后的后台校验: 远端文件被同名替换(大小变化)时删掉本地
    /// 缓存, 本次播放不受影响(已打开的文件句柄仍可读), 下次播放重下。
    private nonisolated func scheduleVideoCacheRevalidation(
        path: String,
        connector: any MusicSourceConnector,
        target: URL
    ) {
        Task.detached(priority: .utility) { [self] in
            guard let expected = try? await Self.musicVideoFileSize(path: path, connector: connector),
                  expected > 0, byteSize(at: target) != expected else { return }
            plog("🗑 MV cache: remote size changed, invalidating \(target.lastPathComponent)")
            Self.removeCacheFileFamily(at: target)
        }
    }

    private func revalidateCachedVideoIfReachable(
        path: String,
        sourceID: String,
        target: URL
    ) {
        guard NetworkMonitor.shared.isReachable else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let sources = try? await self.sourcesProvider(),
                  let source = sources.first(where: { $0.id == sourceID }) else { return }
            let connector = self.connector(for: source)
            guard (try? await connector.connect()) != nil else { return }
            self.scheduleVideoCacheRevalidation(path: path, connector: connector, target: target)
        }
    }

    private nonisolated static func musicVideoFileSize(path: String, connector: any MusicSourceConnector) async throws -> Int64? {
        let nsPath = path as NSString
        let parent = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent
        let listPath = parent.isEmpty || parent == "." ? "/" : parent
        let siblings = try await connector.listFiles(at: listPath)
        return siblings.first {
            $0.isDirectory == false
                && ($0.path == path || $0.name.caseInsensitiveCompare(fileName) == .orderedSame)
                && $0.size > 0
        }?.size
    }

    private nonisolated func downloadMusicVideoByRanges(
        path: String,
        sourceID: String,
        expectedScope: String,
        streamEpoch: UInt64,
        connector: any MusicSourceConnector,
        target: URL,
        expectedSize: Int64?
    ) async throws {
        try await ensureCurrentMusicVideoScope(
            sourceID: sourceID,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )
        let partial = URL(fileURLWithPath: target.path + ".partial")
        var offset = byteSize(at: partial)
        if let expectedSize, expectedSize > 0 {
            if offset > expectedSize {
                try? FileManager.default.removeItem(at: partial)
                offset = 0
            } else if offset == expectedSize {
                guard try CloudPlaybackSource.withCurrentStreamEpoch(
                    sourceID: sourceID,
                    epoch: streamEpoch,
                    {
                        try? FileManager.default.removeItem(at: target)
                        try FileManager.default.moveItem(at: partial, to: target)
                        return ()
                    }
                ) != nil else { throw CancellationError() }
                return
            }
        }

        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        try handle.seek(toOffset: UInt64(offset))

        do {
            while expectedSize.map({ offset < $0 }) ?? true {
                try Task.checkCancellation()
                let remaining = expectedSize.map { max(0, $0 - offset) } ?? Self.videoCacheChunkBytes
                let length = min(Self.videoCacheChunkBytes, remaining)
                guard length > 0 else { break }

                let data: Data
                do {
                    data = try await connector.fetchRange(path: path, offset: offset, length: length)
                } catch {
                    if expectedSize == nil, offset > 0, Self.isRangeEndError(error) {
                        break
                    }
                    throw error
                }
                try await ensureCurrentMusicVideoScope(
                    sourceID: sourceID,
                    expectedScope: expectedScope,
                    streamEpoch: streamEpoch
                )
                if data.isEmpty {
                    guard offset > 0 else {
                        throw SourceError.fileNotFound("Music video file is empty: \(path)")
                    }
                    break
                }

                guard try CloudPlaybackSource.withCurrentStreamEpoch(
                    sourceID: sourceID,
                    epoch: streamEpoch,
                    {
                        try handle.write(contentsOf: data)
                        return ()
                    }
                ) != nil else { throw CancellationError() }
                offset += Int64(data.count)
                if expectedSize == nil, Int64(data.count) < length {
                    break
                }
            }
            try handle.close()

            let finalSize = byteSize(at: partial)
            if let expectedSize, expectedSize > 0, finalSize < expectedSize {
                throw SourceError.connectionFailed("Music video download incomplete: \(finalSize)/\(expectedSize)")
            }
            try await ensureCurrentMusicVideoScope(
                sourceID: sourceID,
                expectedScope: expectedScope,
                streamEpoch: streamEpoch
            )
            guard try CloudPlaybackSource.withCurrentStreamEpoch(
                sourceID: sourceID,
                epoch: streamEpoch,
                {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: partial, to: target)
                    return ()
                }
            ) != nil else { throw CancellationError() }
        } catch {
            try? handle.close()
            throw error
        }
    }

    private nonisolated func ensureCurrentMusicVideoScope(
        sourceID: String,
        expectedScope: String,
        streamEpoch: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: sourceID,
                ticket: streamEpoch
              ), await sourceScopeIsCurrent(
            sourceID: sourceID,
            expectedScope: expectedScope
        ) else {
            throw CancellationError()
        }
    }

    private nonisolated static func isRangeEndError(_ error: Error) -> Bool {
        if case CloudDriveError.apiError(let code, _) = error {
            return code == 416
        }
        return false
    }

    private nonisolated func recordVideoCacheAccess(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// in-flight 下载的 target/.partial 不参与驱逐 —— MainActor 上取快照,
    /// 枚举删除的重活交给 nonisolated 的 evictVideoCache 在后台执行器做。
    private func protectedVideoCachePaths(including url: URL?) -> Set<String> {
        var paths: Set<String> = []
        func add(_ u: URL) {
            paths.insert(u.standardizedFileURL.path)
            paths.insert(URL(fileURLWithPath: u.path + ".partial").standardizedFileURL.path)
        }
        if let url { add(url) }
        for target in musicVideoCacheTargets.values { add(target) }
        return paths
    }

    private nonisolated func evictVideoCache(reserveBytes: Int64, protectedPaths: Set<String>) {
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.videoCacheDirName)
        guard let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var total: Int64 = 0
        var entries: [(url: URL, modified: Date)] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            total += size
            if protectedPaths.contains(url.standardizedFileURL.path) == false {
                entries.append((url, values.contentModificationDate ?? .distantPast))
            }
        }

        var bytesToFree = total + reserveBytes - Self.videoCacheLimitBytes
        guard bytesToFree > 0 else { return }
        var removedPaths: Set<String> = []
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            let candidates = entry.url.lastPathComponent.hasSuffix(".partial")
                ? [entry.url]
                : [entry.url, URL(fileURLWithPath: entry.url.path + ".partial")]
            for candidate in candidates {
                let path = candidate.standardizedFileURL.path
                guard protectedPaths.contains(path) == false, removedPaths.contains(path) == false else { continue }
                let size = fileSize(at: candidate) ?? byteSize(at: candidate)
                if (try? FileManager.default.removeItem(at: candidate)) != nil {
                    removedPaths.insert(path)
                    bytesToFree -= size
                }
            }
            if bytesToFree <= 0 { break }
        }
    }

    private func deleteMusicVideoCache(for song: Song) {
        guard let mvPath = normalizedMusicVideoPath(for: song),
              URL(string: mvPath)?.scheme == nil else { return }
        musicVideoCacheTasks[Self.musicVideoCacheKey(sourceID: song.sourceID, path: mvPath)]?.cancel()
        Self.removeCacheFileFamily(at: videoCacheURL(sourceID: song.sourceID, path: mvPath))
    }

    // MARK: - Audio Cache

    private nonisolated static let audioCacheDirName = "primuse_audio_cache"
    private nonisolated static let audioCacheScopeStateFileName = "audio_cache_source_scopes.json"
    private nonisolated static let legacyAudioCacheAdoptionStateFileName =
        "audio_cache_legacy_adoption.json"
    private static let offlineBatchConcurrency = 2
    private static let offlineSnapshotProbeConcurrency = 16
    private static let directDownloadUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private enum AudioCacheScopeReconciliationResult: Equatable {
        case validated
        case retry
        case finishedBlocked
    }

    private struct LegacyAudioCacheAdoptionState: Codable {
        var version = 1
        var pendingSourceIDs: Set<String>
    }

    private struct InitialAudioCacheScopeState {
        var signatures: [String: String]
        var legacyAdoptionSourceIDs: Set<String>
        var needsLegacyDiscovery: Bool
    }

    private nonisolated static var audioCacheScopeStateURL: URL {
        #if os(tvOS)
        let root = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        #else
        let root = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
        #endif
        return root.appendingPathComponent(audioCacheScopeStateFileName)
    }

    private nonisolated static var legacyAudioCacheAdoptionStateURL: URL {
        audioCacheScopeStateURL
            .deletingLastPathComponent()
            .appendingPathComponent(legacyAudioCacheAdoptionStateFileName)
    }

    private nonisolated static func loadInitialAudioCacheScopeState()
        -> InitialAudioCacheScopeState {
        let fileManager = FileManager.default
        let scopeStateExists = fileManager.fileExists(atPath: audioCacheScopeStateURL.path)
        let signatures: [String: String]
        if let data = try? Data(contentsOf: audioCacheScopeStateURL),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            signatures = decoded
        } else {
            signatures = [:]
        }

        let adoptionStateExists = fileManager.fileExists(
            atPath: legacyAudioCacheAdoptionStateURL.path
        )
        if let data = try? Data(contentsOf: legacyAudioCacheAdoptionStateURL),
           let state = try? JSONDecoder().decode(
               LegacyAudioCacheAdoptionState.self,
               from: data
           ),
           state.version == 1 {
            return InitialAudioCacheScopeState(
                signatures: signatures,
                legacyAdoptionSourceIDs: state.pendingSourceIDs,
                needsLegacyDiscovery: false
            )
        }

        // Only the complete absence of both files identifies an installation
        // upgrading from a version that predates source-scoped cache state.
        // A corrupt/unreadable state stays fail-closed and is quarantined.
        return InitialAudioCacheScopeState(
            signatures: signatures,
            legacyAdoptionSourceIDs: [],
            needsLegacyDiscovery: !scopeStateExists && !adoptionStateExists
        )
    }

    @discardableResult
    private func persistAudioCacheScopeSignatures() -> Bool {
        guard let data = try? JSONEncoder().encode(recordedAudioCacheScopeSignatures) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: Self.audioCacheScopeStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.audioCacheScopeStateURL, options: .atomic)
            return true
        } catch {
            plog("⚠️ Audio cache source-scope state could not be persisted: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func persistLegacyAudioCacheAdoptionState() -> Bool {
        let state = LegacyAudioCacheAdoptionState(
            pendingSourceIDs: legacyAudioCacheAdoptionSourceIDs
        )
        guard let data = try? JSONEncoder().encode(state) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: Self.legacyAudioCacheAdoptionStateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: Self.legacyAudioCacheAdoptionStateURL, options: .atomic)
            return true
        } catch {
            plog("⚠️ Legacy audio-cache adoption state could not be persisted: \(error.localizedDescription)")
            return false
        }
    }

    private nonisolated static func existingAudioCacheSourceIDs() -> Set<String> {
        let baseDirectory = FileManager.default
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(audioCacheDirName, isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return Set(entries.compactMap { entry in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !entry.lastPathComponent.isEmpty else {
                return nil
            }
            return entry.lastPathComponent
        })
    }

    private func discoverLegacyAudioCacheAdoptionCandidatesIfNeeded(
        from sources: [MusicSource]
    ) {
        guard needsLegacyAudioCacheAdoptionDiscovery else { return }
        legacyAudioCacheAdoptionSourceIDs = Set(
            sources.lazy.filter { !$0.isDeleted }.map(\.id)
        )
        legacyAudioCacheAdoptionSourceIDs.formUnion(Self.existingAudioCacheSourceIDs())
        // Persist the complete candidate set before reconciling any one source.
        // If the process stops mid-upgrade, the remaining sources can resume
        // adoption instead of becoming indistinguishable from a new source.
        needsLegacyAudioCacheAdoptionDiscovery = !persistLegacyAudioCacheAdoptionState()
    }

    private func finishLegacyAudioCacheAdoption(for sourceID: String) {
        guard legacyAudioCacheAdoptionSourceIDs.remove(sourceID) != nil else { return }
        if !persistLegacyAudioCacheAdoptionState() {
            legacyAudioCacheAdoptionSourceIDs.insert(sourceID)
        }
    }

    private nonisolated static func audioCacheScopeSignature(for source: MusicSource) -> String {
        MusicSourceSecurityRevision.scopedFingerprint(for: source)
    }

    private func audioCacheReadsAreAllowed(for sourceID: String) -> Bool {
        SourceAudioCacheScopePolicy.allowsRead(
            sourceID: sourceID,
            validatedSourceIDs: validatedAudioCacheSourceIDs,
            blockedSourceIDs: blockedAudioCacheSourceIDs
        )
    }

    private func scheduleInitialAudioCacheScopeValidation() {
        Task { @MainActor [weak self] in
            guard let self, let sources = try? await self.sourcesProvider() else { return }
            self.discoverLegacyAudioCacheAdoptionCandidatesIfNeeded(from: sources)
            for source in sources where !source.isDeleted {
                if MusicSourceSecurityRevision.hasPendingChange(for: source.id) {
                    self.requiredConnectorScopeFingerprints[source.id] =
                        Self.audioCacheScopeSignature(for: source)
                    self.connectorSourceModifiedAtByID[source.id] = source.modifiedAt
                    self.connectorScopeValidationPendingSourceIDs.insert(source.id)
                    self.validatedAudioCacheSourceIDs.remove(source.id)
                    self.blockedAudioCacheSourceIDs.insert(source.id)
                    continue
                }
                if !self.connectorScopeValidationPendingSourceIDs.contains(source.id) {
                    self.requiredConnectorScopeFingerprints[source.id] =
                        Self.audioCacheScopeSignature(for: source)
                    self.connectorSourceModifiedAtByID[source.id] = source.modifiedAt
                }
                self.scheduleAudioCacheScopeValidation(for: source.id)
            }
        }
    }

    private func classifySourceConfigurationChanges(
        _ sourceIDs: Set<String>,
        currentScopeFingerprints: [String: String]?
    ) {
        var securityScopeChanges = Set<String>()
        for sourceID in sourceIDs {
            let previousFingerprint = requiredConnectorScopeFingerprints[sourceID]
                ?? connectorScopeFingerprints[sourceID]
                ?? sidecarConnectorScopeFingerprints[sourceID]
                ?? recordedAudioCacheScopeSignatures[sourceID]
            let currentFingerprint = currentScopeFingerprints?[sourceID]
            switch SourceConfigurationInvalidationPolicy.action(
                previousScopeFingerprint: previousFingerprint,
                currentScopeFingerprint: currentFingerprint
            ) {
            case .ignoreNonSecurityChange:
                plog("🛡️ Source row update kept active transport source=\(sourceID.prefix(8)) scope=unchanged")
            case .invalidateSecurityScope:
                securityScopeChanges.insert(sourceID)
            }
        }

        guard !securityScopeChanges.isEmpty else { return }
        audioCacheSourceConfigurationsDidChange(securityScopeChanges)
    }

    private func audioCacheSourceConfigurationsDidChange(
        _ sourceIDs: Set<String>,
        scheduleConnectorValidation: Bool = true
    ) {
        invalidateConnectorCachesForSourceConfigurationChange(
            sourceIDs,
            scheduleValidation: scheduleConnectorValidation
        )
        for sourceID in sourceIDs {
            NotificationCenter.default.post(
                name: .primuseSourceSecurityScopeWillChange,
                object: nil,
                userInfo: ["sourceID": sourceID]
            )
            let nextGeneration = (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) &+ 1
            audioCacheScopeGenerationBySourceID[sourceID] = nextGeneration
            validatedAudioCacheSourceIDs.remove(sourceID)
            blockedAudioCacheSourceIDs.insert(sourceID)
            cancelAudioCacheWorkForScopeChange(sourceID: sourceID)
            scheduleAudioCacheScopeValidation(
                for: sourceID,
                generation: nextGeneration
            )
        }
    }

    /// The notification callback runs synchronously on MainActor. Remove every
    /// reusable connector before yielding, then keep the source blocked until
    /// its authoritative post-edit fingerprint has been read from the source
    /// store. A stale caller holding the pre-edit `MusicSource` therefore cannot
    /// repopulate the cache during the notification-to-refresh window.
    private func invalidateConnectorCachesForSourceConfigurationChange(
        _ sourceIDs: Set<String>,
        scheduleValidation: Bool = true
    ) {
        for sourceID in sourceIDs {
            CloudPlaybackSource.cancelSessions(sourceID: sourceID)
            let generation = (connectorScopeValidationGenerationBySourceID[sourceID] ?? 0) &+ 1
            connectorScopeValidationGenerationBySourceID[sourceID] = generation
            connectorScopeValidationPendingSourceIDs.insert(sourceID)
            activeConnectionRoutes[sourceID] = nil
            lastSuccessfulConnectionRoutes[sourceID] = nil

            if let connector = connectors.removeValue(forKey: sourceID) {
                retireConnectorAsynchronously(connector)
            }
            connectorScopeFingerprints[sourceID] = nil
            if let unavailable = unavailableConnectors.removeValue(forKey: sourceID) {
                retireConnectorAsynchronously(unavailable.connector)
            }
            if let sidecar = sidecarConnectors.removeValue(forKey: sourceID) {
                retireSidecarConnector(sidecar)
            }
            sidecarConnectorScopeFingerprints[sourceID] = nil

            guard scheduleValidation else { continue }
            Task { [weak self] in
                guard let self else { return }
                // An edit completion normally queues `refreshConnector` in the
                // same MainActor turn. Let that security-revision bump win the
                // generation race before an older public fingerprint can open
                // the gate again.
                await Task.yield()
                await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
                guard self.connectorScopeValidationGenerationBySourceID[sourceID] == generation,
                      !self.credentialChangesInProgress.contains(sourceID),
                      !MusicSourceSecurityRevision.hasPendingChange(for: sourceID),
                      let sources = try? await self.sourcesProvider(),
                      self.connectorScopeValidationGenerationBySourceID[sourceID] == generation,
                      let source = sources.first(where: { $0.id == sourceID && !$0.isDeleted }) else {
                    return
                }
                self.requiredConnectorScopeFingerprints[sourceID] = Self.audioCacheScopeSignature(
                    for: source
                )
                self.connectorSourceModifiedAtByID[sourceID] = source.modifiedAt
                self.connectorScopeValidationPendingSourceIDs.remove(sourceID)
            }
        }
    }

    private func cancelAudioCacheWorkForScopeChange(sourceID: String) {
        let prefix = "\(sourceID)/"
        let offlineKeys = offlineDownloadTasks.keys.filter { $0.hasPrefix(prefix) }
        for taskKey in offlineKeys {
            offlineDownloadTasks[taskKey]?.task.cancel()
            offlineDownloadTasks[taskKey] = nil
        }
        let backgroundSongIDs = backgroundAudioCacheTasks.compactMap { songID, record in
            record.sourceID == sourceID ? songID : nil
        }
        for songID in backgroundSongIDs {
            backgroundAudioCacheTasks[songID]?.task.cancel()
            backgroundAudioCacheTasks[songID] = nil
        }
        let videoKeys = musicVideoCacheTasks.keys.filter { $0.hasPrefix("\(sourceID):") }
        for key in videoKeys {
            musicVideoCacheTasks[key]?.cancel()
            musicVideoCacheTasks[key] = nil
        }
        releasePlaybackAudioCacheLeases(sourceID: sourceID)
    }

    private func scheduleAudioCacheScopeValidation(
        for sourceID: String,
        generation: Int? = nil
    ) {
        let expectedGeneration = generation
            ?? (audioCacheScopeGenerationBySourceID[sourceID] ?? 0)
        audioCacheScopeValidationTasks[sourceID]?.cancel()
        audioCacheScopeValidationTasks[sourceID] = Task { @MainActor [weak self] in
            guard let self else { return }
            // See the connector validation fence above. A synchronous source
            // notification blocks reads immediately; the one-turn yield lets a
            // credential-save refresh advance the durable security epoch before
            // this generation decides whether existing bytes are trustworthy.
            await Task.yield()
            while !Task.isCancelled,
                  (self.audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == expectedGeneration {
                let result = await self.runAudioCacheScopeReconciliation(
                    sourceID: sourceID,
                    generation: expectedGeneration
                )
                switch result {
                case .validated, .finishedBlocked:
                    self.finishAudioCacheScopeValidation(
                        sourceID: sourceID,
                        generation: expectedGeneration
                    )
                    return
                case .retry:
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func finishAudioCacheScopeValidation(sourceID: String, generation: Int) {
        guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else { return }
        audioCacheScopeValidationTasks[sourceID] = nil
    }

    private func ensureAudioCacheScopeValidated(for sourceID: String) async -> Bool {
        if audioCacheReadsAreAllowed(for: sourceID) { return true }
        let generation = audioCacheScopeGenerationBySourceID[sourceID] ?? 0
        let result = await runAudioCacheScopeReconciliation(
            sourceID: sourceID,
            generation: generation
        )
        if result == .retry,
           audioCacheScopeValidationTasks[sourceID] == nil {
            scheduleAudioCacheScopeValidation(for: sourceID, generation: generation)
        }
        return result == .validated && audioCacheReadsAreAllowed(for: sourceID)
    }

    private func runAudioCacheScopeReconciliation(
        sourceID: String,
        generation: Int
    ) async -> AudioCacheScopeReconciliationResult {
        guard audioCacheScopeReconciliationsInProgress.insert(sourceID).inserted else {
            return .retry
        }
        defer { audioCacheScopeReconciliationsInProgress.remove(sourceID) }
        return await reconcileAudioCacheScope(
            sourceID: sourceID,
            generation: generation
        )
    }

    private func reconcileAudioCacheScope(
        sourceID: String,
        generation: Int
    ) async -> AudioCacheScopeReconciliationResult {
        guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
            return .finishedBlocked
        }
        guard !MusicSourceSecurityRevision.hasPendingChange(for: sourceID) else {
            blockedAudioCacheSourceIDs.insert(sourceID)
            return .finishedBlocked
        }
        guard let sources = try? await sourcesProvider() else { return .retry }
        discoverLegacyAudioCacheAdoptionCandidatesIfNeeded(from: sources)
        guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
            return .finishedBlocked
        }
        guard let source = sources.first(where: { $0.id == sourceID && !$0.isDeleted }) else {
            validatedAudioCacheSourceIDs.remove(sourceID)
            blockedAudioCacheSourceIDs.insert(sourceID)
            // A temporarily incomplete source snapshot must never destroy an
            // offline library. Explicit source deletion has its own user-driven
            // purge path; automatic reconciliation only closes the read gate.
            return .finishedBlocked
        }

        let currentSignature = Self.audioCacheScopeSignature(for: source)
        switch SourceAudioCacheScopePolicy.reconciliation(
            recordedSignature: recordedAudioCacheScopeSignatures[sourceID],
            currentSignature: currentSignature,
            legacyAdoptionAllowed: legacyAudioCacheAdoptionSourceIDs.contains(sourceID)
        ) {
        case .allowExisting:
            finishLegacyAudioCacheAdoption(for: sourceID)
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            validatedAudioCacheSourceIDs.insert(sourceID)
            blockedAudioCacheSourceIDs.remove(sourceID)
            await AudioCacheManager.shared.endSourcePurge(
                prefix: "\(sourceID)/",
                generation: generation
            )
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            return .validated
        case .adoptLegacy:
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            let previousSignature = recordedAudioCacheScopeSignatures[sourceID]
            recordedAudioCacheScopeSignatures[sourceID] = currentSignature
            guard persistAudioCacheScopeSignatures() else {
                recordedAudioCacheScopeSignatures[sourceID] = previousSignature
                return .retry
            }
            finishLegacyAudioCacheAdoption(for: sourceID)
            validatedAudioCacheSourceIDs.insert(sourceID)
            blockedAudioCacheSourceIDs.remove(sourceID)
            await AudioCacheManager.shared.endSourcePurge(
                prefix: "\(sourceID)/",
                generation: generation
            )
            plog("🛡️ Adopted legacy audio cache without deleting source=\(sourceID.prefix(8))")
            return .validated
        case .quarantineExisting:
            blockedAudioCacheSourceIDs.insert(sourceID)
            cancelAudioCacheWorkForScopeChange(sourceID: sourceID)
            let quarantined = await quarantineAudioCacheDirectoryIfUnleased(
                sourceID: sourceID,
                generation: generation,
                recordedSignature: recordedAudioCacheScopeSignatures[sourceID],
                currentSignature: currentSignature
            )
            guard quarantined else { return .retry }
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            await purgeNonAudioSourceCaches(sourceID: sourceID)
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            let previousSignature = recordedAudioCacheScopeSignatures[sourceID]
            recordedAudioCacheScopeSignatures[sourceID] = currentSignature
            guard persistAudioCacheScopeSignatures() else {
                recordedAudioCacheScopeSignatures[sourceID] = previousSignature
                return .retry
            }
            finishLegacyAudioCacheAdoption(for: sourceID)
            validatedAudioCacheSourceIDs.insert(sourceID)
            blockedAudioCacheSourceIDs.remove(sourceID)
            await AudioCacheManager.shared.endSourcePurge(
                prefix: "\(sourceID)/",
                generation: generation
            )
            guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
                return .finishedBlocked
            }
            return .validated
        }
    }

    private func purgeNonAudioSourceCaches(sourceID: String) async {
        let paths = Array(Self.perSourceCacheDirs(sourceID: sourceID).dropFirst())
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            for path in paths {
                try? fileManager.removeItem(at: path)
            }
        }.value
    }

    private func quarantineAudioCacheDirectoryIfUnleased(
        sourceID: String,
        generation: Int,
        recordedSignature: String?,
        currentSignature: String
    ) async -> Bool {
        let prefix = "\(sourceID)/"
        guard await AudioCacheManager.shared.beginSourcePurge(
            prefix: prefix,
            generation: generation
        ) else {
            return false
        }
        guard await AudioCacheManager.shared.quarantineSourceCacheDirectoryIfReady(
            prefix: prefix,
            generation: generation,
            recordedSignature: recordedSignature,
            replacementSignature: currentSignature
        ) else {
            return false
        }
        guard (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) == generation else {
            return false
        }
        preservingAutomaticRefreshPaths = preservingAutomaticRefreshPaths.filter {
            !$0.hasPrefix(prefix)
        }
        contentChangeProtectionPendingPaths = contentChangeProtectionPendingPaths.filter {
            !$0.hasPrefix(prefix)
        }
        contentChangeInvalidationGenerationByPath = contentChangeInvalidationGenerationByPath.filter {
            !$0.key.hasPrefix(prefix)
        }
        blockedUntrustedAudioCachePaths = blockedUntrustedAudioCachePaths.filter {
            !$0.hasPrefix(prefix)
        }
        automaticPlaylistPinnedSongsByID = automaticPlaylistPinnedSongsByID.filter {
            $0.value.sourceID != sourceID
        }
        for song in songsProvider() where song.sourceID == sourceID {
            removeOfflineAudioSnapshot(for: song.id)
        }
        return true
    }

    private nonisolated static func audioCacheDirectoryURL(for sourceID: String) -> URL {
        FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(audioCacheDirName)
            .appendingPathComponent(sourceID)
    }

    private func audioCacheDirectory(for sourceID: String) -> URL {
        let dir = Self.audioCacheDirectoryURL(for: sourceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pure URL construction for read-only probes and cache-sync manifests.
    /// Unlike `cacheURL(for:)`, this does not create directories, stat files,
    /// or run legacy migration on the main actor.
    func audioCacheTargetURL(for song: Song) -> URL {
        Self.audioCacheDirectoryURL(for: song.sourceID)
            .appendingPathComponent(cacheFileName(for: song))
    }

    /// 缓存文件名使用 filePath 的稳定哈希，并补音频格式扩展名。OneDrive 等的 filePath
    /// 是无扩展名的 item id,缓存文件没扩展名时命中后 file:// 播放会因 pathExtension 为空
    /// 被判 "Unsupported format" 而秒退(表现为"播放后瞬间消失")。
    private func cacheFileName(for song: Song) -> String {
        CacheFileNamePolicy.make(
            path: song.filePath,
            preferredExtension: song.fileFormat.rawValue
        )
    }

    private func audioCacheRelativePath(for song: Song) -> String {
        "\(song.sourceID)/\(cacheFileName(for: song))"
    }

    private func legacyAudioCacheFileName(for song: Song) -> String {
        let sanitized = CacheFileNamePolicy.legacySanitized(path: song.filePath)
        let ext = song.fileFormat.rawValue.lowercased()
        if ext.isEmpty || sanitized.lowercased().hasSuffix(".\(ext)") { return sanitized }
        return "\(sanitized).\(ext)"
    }

    private func migrateLegacyAudioCacheIfUnambiguous(for song: Song, destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let legacyName = legacyAudioCacheFileName(for: song)
        let legacyURL = audioCacheDirectory(for: song.sourceID).appendingPathComponent(legacyName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        let matchingSongs = songsProvider().lazy.filter {
            $0.sourceID == song.sourceID && self.legacyAudioCacheFileName(for: $0) == legacyName
        }.prefix(2)
        guard matchingSongs.count == 1 else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: legacyURL.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value
            ?? attributes?[.size] as? Int64
        if song.fileSize > 0, let byteCount {
            let tolerance = max(Int64(4 * 1024), song.fileSize / 100)
            guard abs(byteCount - song.fileSize) <= tolerance else { return }
        }
        do {
            try FileManager.default.moveItem(at: legacyURL, to: destination)
            let oldPath = "\(song.sourceID)/\(legacyName)"
            let newPath = audioCacheRelativePath(for: song)
            Task { await AudioCacheManager.shared.migrateEntry(from: oldPath, to: newPath, byteCount: byteCount) }
        } catch {
            plog("⚠️ Legacy audio cache migration failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    func cachedURL(for song: Song) -> URL? {
        let sanitized = cacheFileName(for: song)
        let relativePath = "\(song.sourceID)/\(sanitized)"
        guard audioCacheReadsAreAllowed(for: song.sourceID),
              !blockedUntrustedAudioCachePaths.contains(relativePath) else { return nil }
        let fileURL = audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
        migrateLegacyAudioCacheIfUnambiguous(for: song, destination: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // 完整性校验: 云盘断流 / 用户中途切歌时会留下 partial 文件
        // (比如 1MB 但实际应该 9MB)。命中后 SFBDecoder 只能解码前面那段,
        // 引擎播完触发 gapless boundary → 队列死循环。这里把不完整的
        // 缓存当作未命中, 删掉强制重下。 song.fileSize<=0 表示元数据没拿到,
        // 跳过校验避免误删。
        let preservesExistingArtifact = preservingAutomaticRefreshPaths.contains(relativePath)
            || contentChangeProtectionPendingPaths.contains(relativePath)
            || (activePlaybackAudioCachePaths[relativePath] ?? 0) > 0
        if !preservesExistingArtifact,
           song.fileSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let actual = attrs[.size] as? Int64 {
            // 5% tolerance: 部分 sidecar / tag 改写后大小会差几 KB
            let minAcceptable = Int64(Double(song.fileSize) * 0.95)
            if actual < minAcceptable {
                plog("🗑 cachedURL: 缓存不完整 '\(song.title)' actual=\(actual / 1024)KB expected=\(song.fileSize / 1024)KB — 删除并强制重下")
                try? FileManager.default.removeItem(at: fileURL)
                Task {
                    await AudioCacheManager.shared.refreshPathFamily(path: relativePath)
                }
                return nil
            }
        }
        Task { await AudioCacheManager.shared.recordAccess(path: relativePath) }
        return fileURL
    }

    /// A sparse range cache is excellent for linear playback, but some
    /// decoders (notably multi-channel FLAC) cannot seek reliably through a
    /// custom InputSource. Materialize one complete cache file on explicit
    /// user seek so the decoder can use true random access without decoding
    /// and discarding minutes of PCM at 100% CPU.
    func materializeCachedURLForSeeking(for song: Song) async -> URL? {
        if let cached = cachedURL(for: song) { return cached }

        let wasPinned = offlineAudioSnapshot(for: song).state == .pinned
        let target = cacheURL(for: song)
        let partialPath = target.path + ".partial"
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(
            sourceID: song.sourceID
        )
        guard await CloudPlaybackSource.retireSessionForMaterialization(
            sourceID: song.sourceID,
            streamEpoch: streamEpoch,
            partialPath: partialPath
        ), CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: streamEpoch
        ) else { return nil }

        let result = await downloadForOfflineBatch(songs: [song])
        guard result.succeeded, let cached = cachedURL(for: song) else { return nil }

        // Seeking is normal playback cache behavior, not an explicit offline
        // pin. Preserve a user's pre-existing pin, otherwise return the file
        // to the ordinary LRU-managed cache after the shared downloader exits.
        if !wasPinned {
            let relativePath = audioCacheRelativePath(for: song)
            await AudioCacheManager.shared.unpin(path: relativePath)
            await refreshOfflineAudioSnapshot(for: song)
        }
        return cached
    }

    func cacheURL(for song: Song) -> URL {
        let url = audioCacheDirectory(for: song.sourceID).appendingPathComponent(cacheFileName(for: song))
        if audioCacheReadsAreAllowed(for: song.sourceID) {
            migrateLegacyAudioCacheIfUnambiguous(for: song, destination: url)
        }
        return url
    }

    #if os(iOS) || os(macOS)
    /// Reserves the canonical cache path and enough disk/cache-budget capacity
    /// before a peer starts sending bytes. The current library row is looked
    /// up again here so a stale discovery plan cannot install into a source
    /// that was edited or removed in the meantime.
    func beginAudioCacheSyncImport(
        for requestedSong: Song,
        expectedByteCount: Int64
    ) async throws -> AudioCacheSyncImportReservation {
        guard expectedByteCount > 0,
              let currentSong = songsProvider().first(where: {
                  $0.id == requestedSong.id
                      && $0.sourceID == requestedSong.sourceID
              }),
              currentSong.filePath == requestedSong.filePath,
              currentSong.fileFormat == requestedSong.fileFormat else {
            throw AudioCacheSyncImportError.invalidRequest
        }
        if currentSong.fileSize > 0 {
            do {
                try OfflineTransferSizePolicy.validate(
                    actualSize: expectedByteCount,
                    expectedSize: currentSong.fileSize
                )
            } catch {
                throw AudioCacheSyncImportError.invalidRequest
            }
        }
        guard await ensureAudioCacheScopeValidated(for: currentSong.sourceID),
              audioCacheReadsAreAllowed(for: currentSong.sourceID) else {
            throw AudioCacheSyncImportError.sourceUnavailable
        }
        if cachedURL(for: currentSong) != nil {
            throw AudioCacheSyncImportError.alreadyCached
        }

        let relativePath = audioCacheRelativePath(for: currentSong)
        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
            path: relativePath,
            reserveBytes: 0
        ) else {
            throw AudioCacheSyncImportError.artifactBusy
        }

        do {
            let maximumByteCount = try await prepareOfflineTransferCapacity(
                expectedSize: expectedByteCount,
                lease: lease
            )
            guard audioCacheReadsAreAllowed(for: currentSong.sourceID) else {
                throw AudioCacheSyncImportError.sourceUnavailable
            }

            let targetURL = audioCacheTargetURL(for: currentSong)
            let incomingDirectory = targetURL.deletingLastPathComponent()
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(
                    at: incomingDirectory,
                    withIntermediateDirectories: true
                )
            }.value
            let stagingURL = incomingDirectory
                .appendingPathComponent("\(UUID().uuidString).cache-sync")
                .appendingPathExtension("partial")
            setOfflineAudioSnapshot(
                OfflineAudioCacheSnapshot(
                    state: .downloading,
                    progress: 0,
                    byteCount: nil,
                    errorMessage: nil
                ),
                for: currentSong.id
            )
            return AudioCacheSyncImportReservation(
                id: UUID(),
                songID: currentSong.id,
                sourceID: currentSong.sourceID,
                filePath: currentSong.filePath,
                cacheFileName: cacheFileName(for: currentSong),
                relativePath: relativePath,
                stagingURL: stagingURL,
                targetURL: targetURL,
                expectedByteCount: expectedByteCount,
                maximumByteCount: maximumByteCount,
                lease: lease
            )
        } catch {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            throw error
        }
    }

    /// Verifies the exact peer-advertised length and installs the staging file
    /// through the same atomic path used by ordinary offline downloads.
    func finishAudioCacheSyncImport(
        _ reservation: AudioCacheSyncImportReservation
    ) async throws {
        do {
            guard let currentSong = songsProvider().first(where: {
                $0.id == reservation.songID
                    && $0.sourceID == reservation.sourceID
            }),
                  currentSong.filePath == reservation.filePath,
                  cacheFileName(for: currentSong) == reservation.cacheFileName,
                  audioCacheReadsAreAllowed(for: reservation.sourceID) else {
                throw AudioCacheSyncImportError.songChanged
            }

            let targetAlreadyUsable = await Task.detached(priority: .utility) {
                Self.isUsableCacheFile(
                    at: reservation.targetURL,
                    expectedSize: currentSong.fileSize
                )
            }.value
            if targetAlreadyUsable {
                try? await Task.detached(priority: .utility) {
                    try FileManager.default.removeItem(at: reservation.stagingURL)
                }.value
            } else {
                try await Task.detached(priority: .utility) {
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: reservation.stagingURL.path
                    )
                    let actual = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    guard actual == reservation.expectedByteCount else {
                        throw AudioCacheSyncImportError.incomplete
                    }
                    try Self.validateCompleteCacheFile(
                        at: reservation.stagingURL,
                        expectedSize: reservation.expectedByteCount,
                        maximumBytes: reservation.maximumByteCount
                    )
                    try Self.installCacheFile(
                        from: reservation.stagingURL,
                        to: reservation.targetURL,
                        move: true
                    )
                }.value
            }

            await AudioCacheManager.shared.markDownloaded(
                path: reservation.relativePath,
                byteCount: reservation.expectedByteCount,
                pinned: true
            )
            setOfflineAudioSnapshot(
                OfflineAudioCacheSnapshot(
                    state: .pinned,
                    progress: nil,
                    byteCount: reservation.expectedByteCount,
                    errorMessage: nil
                ),
                for: reservation.songID
            )
            await AudioCacheManager.shared.releasePathFamilyLease(reservation.lease)
        } catch {
            await AudioCacheManager.shared.releasePathFamilyLease(reservation.lease)
            throw error
        }
    }

    func cancelAudioCacheSyncImport(
        _ reservation: AudioCacheSyncImportReservation
    ) async {
        try? await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: reservation.stagingURL)
        }.value
        await AudioCacheManager.shared.releasePathFamilyLease(reservation.lease)
        if let currentSong = songsProvider().first(where: {
            $0.id == reservation.songID && $0.sourceID == reservation.sourceID
        }) {
            await refreshOfflineAudioSnapshot(for: currentSong)
        } else {
            setOfflineAudioSnapshot(.notCached, for: reservation.songID)
        }
    }
    #endif

    /// Read-only cache lookup for artwork and other scrolling-adjacent work.
    /// Legacy migration remains on explicit playback/cache paths; a recycled
    /// list row must never create directories or synchronously touch disk on
    /// the main actor.
    func cachedURLForBackgroundRead(for song: Song) async -> URL? {
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else { return nil }
        let relativePath = audioCacheRelativePath(for: song)
        guard AutomaticOfflineCachedReadPolicy.allows(
            path: relativePath,
            blockedPaths: blockedUntrustedAudioCachePaths
        ) else { return nil }
        let target = audioCacheTargetURL(for: song)
        let preservesExistingArtifact = preservingAutomaticRefreshPaths.contains(relativePath)
            || contentChangeProtectionPendingPaths.contains(relativePath)
        let expectedSize = preservesExistingArtifact ? 0 : song.fileSize
        let isUsable = await Task.detached(priority: .utility) {
            Self.isUsableCacheFile(at: target, expectedSize: expectedSize)
        }.value
        guard isUsable,
              audioCacheReadsAreAllowed(for: song.sourceID),
              AutomaticOfflineCachedReadPolicy.allows(
                path: relativePath,
                blockedPaths: blockedUntrustedAudioCachePaths
              ) else { return nil }
        Task {
            await AudioCacheManager.shared.recordAccess(path: relativePath)
        }
        return target
    }

    func offlineAudioSnapshot(for song: Song) -> OfflineAudioCacheSnapshot {
        guard audioCacheReadsAreAllowed(for: song.sourceID) else { return .notCached }
        if let snapshot = offlineAudioSnapshots[song.id] {
            return snapshot
        }
        let url = cacheURL(for: song)
        let relativePath = audioCacheRelativePath(for: song)
        let preservesExistingArtifact = preservingAutomaticRefreshPaths.contains(relativePath)
            || contentChangeProtectionPendingPaths.contains(relativePath)
        let snapshot: OfflineAudioCacheSnapshot
        if Self.isUsableCacheFile(
            at: url,
            expectedSize: preservesExistingArtifact ? 0 : song.fileSize
        ) {
            snapshot = OfflineAudioCacheSnapshot(
                state: .cached,
                progress: nil,
                byteCount: fileSize(at: url),
                errorMessage: nil
            )
        } else {
            snapshot = .notCached
        }
        // Source-level cache estimates may inspect thousands of songs once.
        // Persist positive and negative results so progress redraws never
        // repeat those synchronous file-system stats.
        setOfflineAudioSnapshot(snapshot, for: song.id)
        return snapshot
    }

    /// Returns a stable observation node scoped to one song. Reading this
    /// entry from SongRowView does not make that row depend on the complete
    /// SourceManager cache dictionary.
    func offlineAudioSnapshotEntry(for song: Song) -> OfflineAudioSnapshotEntry {
        guard audioCacheReadsAreAllowed(for: song.sourceID) else {
            if let entry = offlineAudioSnapshotEntries[song.id] {
                entry.update(.notCached)
                return entry
            }
            let entry = OfflineAudioSnapshotEntry(snapshot: .notCached)
            offlineAudioSnapshotEntries[song.id] = entry
            return entry
        }
        if let entry = offlineAudioSnapshotEntries[song.id] {
            return entry
        }
        let entry = OfflineAudioSnapshotEntry(
            snapshot: offlineAudioSnapshots[song.id] ?? .notCached
        )
        offlineAudioSnapshotEntries[song.id] = entry
        return entry
    }

    private func setOfflineAudioSnapshot(
        _ snapshot: OfflineAudioCacheSnapshot,
        for songID: String
    ) {
        let previousSnapshot = offlineAudioSnapshots[songID]
        guard previousSnapshot != snapshot else { return }
        offlineAudioSnapshots[songID] = snapshot
        offlineAudioSnapshotEntries[songID]?.update(snapshot)
        if (previousSnapshot?.isDownloaded ?? false) != snapshot.isDownloaded {
            offlineAudioSnapshotRevision &+= 1
        }
        let wasDownloading = offlineDownloadingSongIDs.contains(songID)
        if snapshot.isDownloading != wasDownloading {
            if snapshot.isDownloading {
                offlineDownloadingSongIDs.insert(songID)
            } else {
                offlineDownloadingSongIDs.remove(songID)
            }
        }
    }

    private func removeOfflineAudioSnapshot(for songID: String) {
        let wasDownloaded = offlineAudioSnapshots[songID]?.isDownloaded == true
        offlineAudioSnapshots.removeValue(forKey: songID)
        offlineAudioSnapshotEntries[songID]?.update(.notCached)
        offlineAudioSnapshotEntries.removeValue(forKey: songID)
        offlineDownloadingSongIDs.remove(songID)
        if wasDownloaded {
            offlineAudioSnapshotRevision &+= 1
        }
    }

    /// Removing a complete source can invalidate thousands of downloaded rows.
    /// Publish the aggregate revision once instead of once per song; retained
    /// row observers still receive their individual terminal snapshot.
    private func removeOfflineAudioSnapshots(forSongIDs songIDs: Set<String>) {
        guard !songIDs.isEmpty else { return }
        var removedDownloadedSong = false
        for songID in songIDs {
            removedDownloadedSong = removedDownloadedSong
                || offlineAudioSnapshots[songID]?.isDownloaded == true
            offlineAudioSnapshots.removeValue(forKey: songID)
            offlineAudioSnapshotEntries[songID]?.update(.notCached)
            offlineAudioSnapshotEntries.removeValue(forKey: songID)
            offlineDownloadingSongIDs.remove(songID)
        }
        if removedDownloadedSong {
            offlineAudioSnapshotRevision &+= 1
        }
    }

    /// Populate a row's first snapshot lazily. Negative results are cached as
    /// well, preventing repeated disk stats when the same row is recycled.
    func ensureOfflineAudioSnapshot(for song: Song) async {
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else {
            setOfflineAudioSnapshot(.notCached, for: song.id)
            return
        }
        guard offlineAudioSnapshots[song.id] == nil else { return }
        let url = audioCacheTargetURL(for: song)
        let relativePath = audioCacheRelativePath(for: song)
        let info = await Task.detached(priority: .utility) {
            Self.offlineFileInfo(at: url, expectedSize: song.fileSize)
        }.value
        let snapshot = await AudioCacheManager.shared.snapshot(
            path: relativePath,
            fileExists: info.exists,
            byteCount: info.byteCount
        )
        // A download may have started while the disk probe was in flight.
        guard audioCacheReadsAreAllowed(for: song.sourceID),
              offlineAudioSnapshots[song.id] == nil else { return }
        setOfflineAudioSnapshot(snapshot, for: song.id)
    }

    func refreshOfflineAudioSnapshot(for song: Song) async {
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else {
            setOfflineAudioSnapshot(.notCached, for: song.id)
            return
        }
        let url = cacheURL(for: song)
        let info = await Task.detached(priority: .utility) {
            Self.offlineFileInfo(at: url, expectedSize: song.fileSize)
        }.value
        guard audioCacheReadsAreAllowed(for: song.sourceID) else {
            setOfflineAudioSnapshot(.notCached, for: song.id)
            return
        }
        let snapshot = await AudioCacheManager.shared.snapshot(
            path: audioCacheRelativePath(for: song),
            fileExists: info.exists,
            byteCount: info.byteCount
        )
        setOfflineAudioSnapshot(snapshot, for: song.id)
    }

    private nonisolated static func offlineFileInfo(
        at url: URL,
        expectedSize: Int64
    ) -> (exists: Bool, byteCount: Int64?) {
        guard isUsableCacheFile(at: url, expectedSize: expectedSize) else {
            return (false, nil)
        }
        let size = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
            .totalFileAllocatedSize
            .map(Int64.init)
        return (true, size)
    }

    /// Warms the in-memory snapshot table without performing one synchronous
    /// file-system stat per song on the main actor. The source screen uses this
    /// before presenting its confirmation so the tap receives immediate visual
    /// feedback even for libraries containing thousands of tracks.
    func prepareOfflineAudioSnapshots(for songs: [Song]) async {
        let pending = songs.filter { offlineAudioSnapshots[$0.id] == nil }
        guard !pending.isEmpty else { return }

        let maxConcurrent = min(Self.offlineSnapshotProbeConcurrency, pending.count)
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < pending.count else { return }
                let song = pending[nextIndex]
                nextIndex += 1
                group.addTask {
                    await self.ensureOfflineAudioSnapshot(for: song)
                }
            }

            for _ in 0..<maxConcurrent { enqueueNext() }
            while await group.next() != nil {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                enqueueNext()
            }
        }
    }

    /// Resolves the filter membership after the bounded background probe has
    /// populated missing cache states. Both ordinary complete cache files and
    /// explicitly pinned downloads are playable without network access.
    func downloadedSongIDs(in songs: [Song]) async -> Set<String> {
        await prepareOfflineAudioSnapshots(for: songs)
        return Set(songs.compactMap { song in
            offlineAudioSnapshots[song.id]?.isDownloaded == true ? song.id : nil
        })
    }

    private nonisolated static func isUsableCacheFile(
        at url: URL,
        expectedSize: Int64
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard expectedSize > 0 else { return true }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let actualSize = (attributes[.size] as? NSNumber)?.int64Value
        else { return false }
        return actualSize >= Int64(Double(expectedSize) * 0.95)
    }

    func downloadForOffline(song: Song) {
        Task { [weak self] in
            _ = await self?.waitForOfflineDownload(song, pinIntent: .manual)
        }
    }

    func downloadForOffline(songs: [Song]) {
        Task { [weak self] in
            _ = await self?.downloadForOfflineBatch(songs: songs)
        }
    }

    func downloadSourceForOffline(
        sourceID: String,
        songs: [Song]
    ) async -> OfflineDownloadBatchResult {
        activeOfflineSourceCacheSourceIDs.insert(sourceID)
        defer { activeOfflineSourceCacheSourceIDs.remove(sourceID) }
        return await downloadForOfflineBatch(songs: songs)
    }

    func downloadForOfflineBatch(songs: [Song]) async -> OfflineDownloadBatchResult {
        let playableSongs = songs.filteredPlayable()
        var completedCount = 0
        var failedCount = 0
        var inProgressCount = 0
        var byteCount: Int64 = 0
        let maxConcurrent = min(Self.offlineBatchConcurrency, max(playableSongs.count, 1))

        plog("⬇️ Offline batch start songs=\(playableSongs.count) concurrency=\(maxConcurrent)")

        await withTaskGroup(of: OfflineDownloadSongResult.self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < playableSongs.count else { return }
                let song = playableSongs[nextIndex]
                nextIndex += 1
                group.addTask {
                    _ = await self.waitForOfflineDownload(song, pinIntent: .manual)
                    return OfflineDownloadSongResult(
                        snapshot: await self.offlineAudioSnapshot(for: song),
                        fallbackByteCount: max(song.fileSize, 0)
                    )
                }
            }

            for _ in 0..<maxConcurrent { enqueueNext() }

            while let result = await group.next() {
                let snapshot = result.snapshot
                switch snapshot.state {
                case .cached, .pinned:
                    completedCount += 1
                    byteCount += snapshot.byteCount ?? result.fallbackByteCount
                case .failed:
                    failedCount += 1
                case .downloading:
                    inProgressCount += 1
                case .notCached:
                    failedCount += 1
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                enqueueNext()
            }
        }

        plog("⬇️ Offline batch done requested=\(playableSongs.count) completed=\(completedCount) failed=\(failedCount) inProgress=\(inProgressCount) bytes=\(byteCount / 1024 / 1024)MB")

        return OfflineDownloadBatchResult(
            requestedCount: playableSongs.count,
            completedCount: completedCount,
            failedCount: failedCount,
            inProgressCount: inProgressCount,
            byteCount: byteCount
        )
    }

    func removeOfflineDownload(song: Song) {
        let taskKey = audioCacheRelativePath(for: song)
        offlineDownloadTasks[taskKey]?.task.cancel()
        offlineDownloadTasks[taskKey] = nil
        deleteAudioCache(for: song)
        setOfflineAudioSnapshot(.notCached, for: song.id)
        automaticOfflineDownloadRemovedHandler?(song.id)
    }

    func reconcileAutomaticPlaylistPins(
        _ desiredSongs: [AlwaysDownloadDesiredSong],
        generation: Int,
        excludedArtifactPaths: Set<String> = []
    ) async -> Set<String>? {
        guard generation >= automaticOfflineReconciliationGeneration else { return nil }
        automaticOfflineReconciliationGeneration = generation
        let nextDesired = Dictionary(
            desiredSongs.map { ($0.song.id, $0.song) },
            uniquingKeysWith: { _, latest in latest }
        )
        let prepared = await Task.detached(priority: .utility) {
            Self.prepareAutomaticOfflinePinReconciliation(desiredSongs)
        }.value
        guard generation == automaticOfflineReconciliationGeneration else { return nil }
        guard let missingPaths = await AudioCacheManager.shared.reconcileAutomaticPlaylistPins(
            prepared.requests,
            generation: generation,
            excludedPaths: excludedArtifactPaths
        ) else { return nil }
        guard generation == automaticOfflineReconciliationGeneration else { return nil }
        let previousDesired = automaticPlaylistPinnedSongsByID
        automaticPlaylistPinnedSongsByID = nextDesired
        var missingSongIDs = Set<String>()
        for (index, desired) in desiredSongs.enumerated() {
            guard generation == automaticOfflineReconciliationGeneration else { return nil }
            let path = prepared.pathBySongID[desired.song.id]
                ?? audioCacheRelativePath(for: desired.song)
            if missingPaths.contains(path) {
                missingSongIDs.insert(desired.song.id)
                if offlineAudioSnapshots[desired.song.id]?.isDownloading != true {
                    setOfflineAudioSnapshot(.notCached, for: desired.song.id)
                }
            } else {
                setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                    state: .pinned,
                    progress: nil,
                    byteCount: desired.song.fileSize > 0 ? desired.song.fileSize : nil,
                    errorMessage: nil
                ), for: desired.song.id)
            }
            if index.isMultiple(of: 128) {
                await Task.yield()
                guard generation == automaticOfflineReconciliationGeneration else { return nil }
            }
        }
        for song in previousDesired.values
        where automaticPlaylistPinnedSongsByID[song.id] == nil {
            guard generation == automaticOfflineReconciliationGeneration else { return nil }
            if offlineAudioSnapshots[song.id]?.isDownloading != true {
                await refreshOfflineAudioSnapshot(for: song)
                guard generation == automaticOfflineReconciliationGeneration else { return nil }
            }
        }
        return missingSongIDs
    }

    func reconcileAutomaticRefreshProtections(
        _ artifactPaths: Set<String>,
        generation: Int
    ) -> Bool {
        guard generation == automaticOfflineReconciliationGeneration else { return false }
        preservingAutomaticRefreshPaths = artifactPaths
        return true
    }

    func reconcileAutomaticOfflineProvenance(
        _ dispositionsByArtifactPath: [String: AutomaticOfflineRefreshDisposition],
        generation: Int
    ) async -> Set<String>? {
        guard generation >= automaticOfflineReconciliationGeneration else { return nil }
        automaticOfflineReconciliationGeneration = generation
        let untrustedPaths = Set(dispositionsByArtifactPath.compactMap { path, disposition in
            disposition == .discardUntrusted ? path : nil
        })
        let preservingPaths = Set(
            dispositionsByArtifactPath.compactMap { path, disposition in
                disposition == .preserveExisting ? path : nil
            }
        )
        preservingAutomaticRefreshPaths = preservingPaths

        // A newer reconciliation can immediately trust a path again. Older
        // generations are fenced after every suspension point and cannot later
        // delete a path that this generation accepted.
        let staleBlockedPaths = blockedUntrustedAudioCachePaths.filter {
            dispositionsByArtifactPath[$0] == nil
        }
        blockedUntrustedAudioCachePaths = staleBlockedPaths.union(untrustedPaths)

        // Current untrusted artifacts are isolated from every read immediately,
        // but their canonical inode is left in place until a verified staging
        // download atomically replaces it. This lets an already-open playback
        // lease finish without ever making the old account's bytes adoptable.
        let cleanupCandidates = staleBlockedPaths
        var remainingBlocked = untrustedPaths
        for path in cleanupCandidates {
            let isLeased = await AudioCacheManager.shared.isPathFamilyLeased(path: path)
            guard generation == automaticOfflineReconciliationGeneration else { return nil }
            if isLeased {
                remainingBlocked.insert(path)
                continue
            }
            guard generation == automaticOfflineReconciliationGeneration else { return nil }
            let target = FileManager.default
                .primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent(Self.audioCacheDirName)
                .appendingPathComponent(path)
            Self.removeCacheFileFamily(at: target)
            await AudioCacheManager.shared.refreshPathFamily(path: path)
            guard generation == automaticOfflineReconciliationGeneration else { return nil }
            if untrustedPaths.contains(path) {
                // Keep blocking reads until a verified replacement completes.
                remainingBlocked.insert(path)
            }
        }
        guard generation == automaticOfflineReconciliationGeneration else { return nil }
        preservingAutomaticRefreshPaths = preservingPaths
        blockedUntrustedAudioCachePaths = remainingBlocked
        return untrustedPaths
    }

    private nonisolated static func prepareAutomaticOfflinePinReconciliation(
        _ desiredSongs: [AlwaysDownloadDesiredSong]
    ) -> (requests: [AutomaticOfflinePinRequest], pathBySongID: [String: String]) {
        var pathBySongID: [String: String] = [:]
        var ownersByPath: [String: Set<String>] = [:]
        var expectedBytesByPath: [String: Int64] = [:]
        for desired in desiredSongs {
            let fileName = CacheFileNamePolicy.make(
                path: desired.song.filePath,
                preferredExtension: desired.song.fileFormat.rawValue
            )
            let path = "\(desired.song.sourceID)/\(fileName)"
            pathBySongID[desired.song.id] = path
            ownersByPath[path, default: []].formUnion(desired.playlistIDs)
            expectedBytesByPath[path] = max(
                expectedBytesByPath[path] ?? 0,
                desired.song.fileSize
            )
        }
        return (
            ownersByPath.map { path, playlistIDs in
                AutomaticOfflinePinRequest(
                    path: path,
                    playlistIDs: playlistIDs,
                    expectedByteCount: expectedBytesByPath[path] ?? 0
                )
            },
            pathBySongID
        )
    }

    func prepareAutomaticOfflineDownload(
        song: Song,
        forceRedownload: Bool,
        refreshDisposition: AutomaticOfflineRefreshDisposition = .none
    ) async -> Bool {
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else { return false }
        let relativePath = audioCacheRelativePath(for: song)
        if refreshDisposition == .preserveExisting {
            preservingAutomaticRefreshPaths.insert(relativePath)
        } else if refreshDisposition == .discardUntrusted {
            blockedUntrustedAudioCachePaths.insert(relativePath)
        }
        guard forceRedownload else { return true }
        // Never relabel bytes owned by an in-flight manual request as a newer
        // content revision. Let that shared transfer finish, then the serial
        // worker will retry this preparation and replace the stale file.
        guard offlineDownloadTasks[relativePath] == nil else { return false }
        let conflictingBackgroundTasks = backgroundAudioCacheTasks.values.filter {
            $0.taskKey == relativePath
        }
        if !conflictingBackgroundTasks.isEmpty {
            for record in conflictingBackgroundTasks { record.task.cancel() }
            return false
        }
        let target = cacheURL(for: song)
        Self.removeRefreshCacheFiles(at: target)
        if refreshDisposition == .discardUntrusted {
            setOfflineAudioSnapshot(.notCached, for: song.id)
        }
        return !Self.refreshCacheFilesExist(at: target)
    }

    func automaticOfflineRecoverableBytes(
        song: Song,
        refreshDisposition: AutomaticOfflineRefreshDisposition
    ) async -> Int64 {
        guard refreshDisposition == .discardUntrusted,
              await ensureAudioCacheScopeValidated(for: song.sourceID) else { return 0 }
        let relativePath = audioCacheRelativePath(for: song)
        guard !(await AudioCacheManager.shared.isPathFamilyLeased(path: relativePath)) else {
            return 0
        }
        let target = cacheURL(for: song)
        return AutomaticOfflineUntrustedCleanupPolicy.recoverableAllocatedBytes(
            for: target
        )
    }

    func downloadAutomaticallyForOffline(
        song: Song,
        playlistIDs: Set<String>,
        refreshDisposition: AutomaticOfflineRefreshDisposition = .none,
        artifactSignature: String
    ) async -> AutomaticOfflineDownloadResult {
        guard !playlistIDs.isEmpty else { return .cancelled }
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else {
            return .failed(
                kind: .sourceUnavailable,
                message: String(localized: "offline_download_failed")
            )
        }
        await waitForBackgroundAudioCache(for: song)
        guard !Task.isCancelled else { return .cancelled }
        let result = await waitForOfflineDownload(
            song,
            pinIntent: .playlists(playlistIDs),
            refreshDisposition: refreshDisposition,
            artifactSignature: artifactSignature
        )
        switch result {
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .failed(let kind, let message):
            if kind.authenticationRequired {
                SourceAuthAlert.report(sourceID: song.sourceID, message: message)
            }
            return .failed(
                kind: kind,
                message: message
            )
        }
    }

    private func waitForOfflineDownload(
        _ song: Song,
        pinIntent: OfflineDownloadPinIntent,
        refreshDisposition: AutomaticOfflineRefreshDisposition = .none,
        artifactSignature: String? = nil
    ) async -> OfflineDownloadTransferResult {
        guard await ensureAudioCacheScopeValidated(for: song.sourceID) else {
            return .failed(
                kind: .sourceUnavailable,
                message: String(localized: "offline_download_failed")
            )
        }
        let handle = offlineDownloadTask(
            for: song,
            refreshDisposition: refreshDisposition,
            artifactSignature: artifactSignature
        )
        return await withTaskCancellationHandler {
            let result = await handle.task.value
            guard !Task.isCancelled else { return .cancelled }
            if case .completed(let byteCount) = result {
                await applyOfflinePin(
                    pinIntent,
                    song: song,
                    byteCount: byteCount
                )
            }
            return result
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelOfflineDownloadRequest(
                    taskKey: handle.taskKey,
                    requesterID: handle.requesterID
                )
            }
        }
    }

    private func offlineDownloadTask(
        for song: Song,
        refreshDisposition: AutomaticOfflineRefreshDisposition = .none,
        artifactSignature: String? = nil
    ) -> OfflineDownloadTaskHandle {
        let requesterID = UUID()
        let taskKey = audioCacheRelativePath(for: song)
        if artifactSignature != nil,
           backgroundAudioCacheTasks.values.contains(where: { $0.taskKey == taskKey }) {
            let deferred = Task<OfflineDownloadTransferResult, Never> {
                .failed(
                    kind: .transient,
                    message: "Waiting for a background cache transfer to finish"
                )
            }
            return OfflineDownloadTaskHandle(
                task: deferred,
                requesterID: requesterID,
                taskKey: taskKey
            )
        }
        if var record = offlineDownloadTasks[taskKey] {
            guard AutomaticOfflineTaskJoinPolicy.canJoin(
                existingArtifactSignature: record.artifactSignature,
                existingDisposition: record.refreshDisposition,
                requestedArtifactSignature: artifactSignature,
                requestedDisposition: refreshDisposition
            ) else {
                let deferred = Task<OfflineDownloadTransferResult, Never> {
                    .failed(
                        kind: .transient,
                        message: "Waiting for an incompatible cache transfer to finish"
                    )
                }
                return OfflineDownloadTaskHandle(
                    task: deferred,
                    requesterID: requesterID,
                    taskKey: taskKey
                )
            }
            record.requesterIDs.insert(requesterID)
            offlineDownloadTasks[taskKey] = record
            plog("↩️ Offline: join existing download '\(song.title)'")
            return OfflineDownloadTaskHandle(
                task: record.task,
                requesterID: requesterID,
                taskKey: taskKey
            )
        }

        let runID = UUID()
        let task: Task<OfflineDownloadTransferResult, Never> = Task { @MainActor [weak self] in
            guard let self else { return .cancelled }
            let result = await self.performOfflineDownload(
                song,
                refreshDisposition: refreshDisposition
            )
            self.finishOfflineDownloadTask(taskKey: taskKey, runID: runID)
            return result
        }
        offlineDownloadTasks[taskKey] = OfflineDownloadTaskRecord(
            id: runID,
            task: task,
            requesterIDs: [requesterID],
            refreshDisposition: refreshDisposition,
            artifactSignature: artifactSignature
        )
        return OfflineDownloadTaskHandle(
            task: task,
            requesterID: requesterID,
            taskKey: taskKey
        )
    }

    private func cancelOfflineDownloadRequest(
        taskKey: String,
        requesterID: UUID
    ) {
        guard var record = offlineDownloadTasks[taskKey] else { return }
        record.requesterIDs.remove(requesterID)
        guard !record.requesterIDs.isEmpty else {
            record.task.cancel()
            offlineDownloadTasks[taskKey] = nil
            return
        }
        offlineDownloadTasks[taskKey] = record
    }

    private func applyOfflinePin(
        _ pinIntent: OfflineDownloadPinIntent,
        song: Song,
        byteCount: Int64?
    ) async {
        let relativePath = audioCacheRelativePath(for: song)
        switch pinIntent {
        case .manual:
            await AudioCacheManager.shared.pin(
                path: relativePath,
                byteCount: byteCount
            )
        case .playlists(let playlistIDs):
            await AudioCacheManager.shared.pin(
                path: relativePath,
                byteCount: byteCount,
                forPlaylistIDs: playlistIDs
            )
        }
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .pinned,
            progress: nil,
            byteCount: byteCount,
            errorMessage: nil
        ), for: song.id)
    }

    private func finishOfflineDownloadTask(taskKey: String, runID: UUID) {
        guard offlineDownloadTasks[taskKey]?.id == runID else { return }
        offlineDownloadTasks[taskKey] = nil
    }

    private func performOfflineDownload(
        _ song: Song,
        refreshDisposition: AutomaticOfflineRefreshDisposition = .none
    ) async -> OfflineDownloadTransferResult {
        let startedAt = Date()
        let relativePath = audioCacheRelativePath(for: song)
        let canonicalTarget = cacheURL(for: song)
        let target = refreshDisposition != .none
            ? Self.refreshCacheURL(for: canonicalTarget)
            : canonicalTarget
        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
            path: relativePath,
            reserveBytes: 0
        ) else {
            return .failed(
                kind: .sourceUnavailable,
                message: String(localized: "offline_download_failed")
            )
        }
        guard audioCacheReadsAreAllowed(for: song.sourceID) else {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            return .failed(
                kind: .sourceUnavailable,
                message: String(localized: "offline_download_failed")
            )
        }
        defer {
            Task {
                await AudioCacheManager.shared.releasePathFamilyLease(lease)
            }
        }

        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: 0,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        ), for: song.id)

        do {
            try Task.checkCancellation()
            var expectedTransferSize = song.isStreamDescriptor ? 0 : song.fileSize
            var maximumTransferBytes: Int64 = 0
            if refreshDisposition == .discardUntrusted {
                let hasOtherLeases = await AudioCacheManager.shared.pathFamilyHasOtherLeases(
                    path: relativePath,
                    excluding: lease
                )
                guard !hasOtherLeases else {
                    throw AutomaticOfflineTransferDeferralError.artifactLeased
                }
                for url in AutomaticOfflineUntrustedCleanupPolicy.canonicalURLs(
                    for: canonicalTarget
                ) {
                    try? FileManager.default.removeItem(at: url)
                }
                await AudioCacheManager.shared.refreshPathFamily(path: relativePath)
            }
            if refreshDisposition == .none, let cached = cachedURL(for: song) {
                let size = fileSize(at: cached)
                setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                    state: .cached,
                    progress: nil,
                    byteCount: size,
                    errorMessage: nil
                ), for: song.id)
                return .completed(byteCount: size)
            }
            guard !NetworkMonitor.shared.hasDeterminedPath || NetworkMonitor.shared.isReachable else {
                throw SourceError.connectionFailed(String(localized: "status_network_unavailable"))
            }

            let sources = try await sourcesProvider()
            guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                throw SourceError.fileNotFound("Source not found for song: \(song.title)")
            }

            let connector = connector(for: source)
            try await connector.connect()
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            if song.isStreamDescriptor {
                switch try await resolveSTRMTarget(for: song, connector: connector) {
                case .remote(let url):
                    maximumTransferBytes = try await prepareOfflineTransferCapacity(
                        expectedSize: 0,
                        lease: lease
                    )
                    try await downloadOfflineFromURL(
                        url,
                        song: song,
                        target: target,
                        maximumBytes: maximumTransferBytes
                    )
                case .openListSourcePath(let path, _):
                    guard let webDAV = connector as? any OpenListSTRMResolvingConnector else {
                        throw SourceError.connectionFailed("OpenList STRM transport unavailable")
                    }
                    maximumTransferBytes = try await prepareOfflineTransferCapacity(
                        expectedSize: 0,
                        lease: lease
                    )
                    let localURL = try await webDAV.downloadBoundedOpenListSTRM(
                        for: path,
                        maximumBytes: maximumTransferBytes
                    )
                    defer { try? FileManager.default.removeItem(at: localURL) }
                    let boundedMaximum = maximumTransferBytes
                    try await Task.detached(priority: .utility) {
                        try Self.validateCompleteCacheFile(
                            at: localURL,
                            expectedSize: 0,
                            maximumBytes: boundedMaximum
                        )
                        try Self.installCacheFile(from: localURL, to: target, move: true)
                    }.value
                case .sourcePath(let path):
                    if OfflineSTRMConnectorMaterializationPolicy
                        .permitsConnectorMaterialization(sourceType: source.type) {
                        let localURL = try await connector.localURL(for: path)
                        expectedTransferSize = byteSize(at: localURL)
                        maximumTransferBytes = try await prepareOfflineTransferCapacity(
                            expectedSize: expectedTransferSize,
                            lease: lease
                        )
                        let localExpectedSize = expectedTransferSize
                        let localMaximum = maximumTransferBytes
                        try await Task.detached(priority: .utility) {
                            try Self.validateCompleteCacheFile(
                                at: localURL,
                                expectedSize: localExpectedSize,
                                maximumBytes: localMaximum
                            )
                            try Self.installCacheFile(from: localURL, to: target, move: false)
                        }.value
                    } else {
                        guard source.supportsRangeStreaming || source.type == .upnp else {
                            throw AutomaticOfflineTransferDeferralError.unboundedAutomaticTransfer
                        }
                        expectedTransferSize = try await remoteFileSize(
                            at: path,
                            connector: connector
                        )
                        maximumTransferBytes = try await prepareOfflineTransferCapacity(
                            expectedSize: expectedTransferSize,
                            lease: lease
                        )
                        try await downloadOfflineByRanges(
                            song: song,
                            connector: connector,
                            target: target,
                            maximumBytes: maximumTransferBytes,
                            sourcePath: path,
                            expectedSize: expectedTransferSize
                        )
                    }
                }
            } else if let oneDrive = connector as? OneDriveSource {
                maximumTransferBytes = try await prepareOfflineTransferCapacity(
                    expectedSize: expectedTransferSize,
                    lease: lease
                )
                do {
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath)
                    try await downloadOfflineFromDirectURL(
                        directURL,
                        song: song,
                        target: target,
                        expectedSize: expectedTransferSize,
                        maximumBytes: maximumTransferBytes
                    )
                } catch {
                    try Task.checkCancellation()
                    guard OfflineDirectDownloadRetryPolicy.shouldRefreshSignedURL(after: error) else {
                        throw error
                    }
                    await oneDrive.invalidateCachedDownloadURL(path: song.filePath)
                    plog("↩️ Offline direct retry with fresh OneDrive URL for '\(song.title)': \(error.localizedDescription)")
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath, forceRefresh: true)
                    try Task.checkCancellation()
                    try await downloadOfflineFromDirectURL(
                        directURL,
                        song: song,
                        target: target,
                        expectedSize: expectedTransferSize,
                        maximumBytes: maximumTransferBytes
                    )
                }
            } else if (source.supportsRangeStreaming || source.type == .upnp),
                      song.fileSize > 0 {
                maximumTransferBytes = try await prepareOfflineTransferCapacity(
                    expectedSize: expectedTransferSize,
                    lease: lease
                )
                try await downloadOfflineByRanges(
                    song: song,
                    connector: connector,
                    target: target,
                    maximumBytes: maximumTransferBytes
                )
            } else if source.type != .local,
                      source.type != .appleMusicLibrary {
                throw AutomaticOfflineTransferDeferralError.unboundedAutomaticTransfer
            } else {
                let localURL = try await connector.localURL(for: song.filePath)
                expectedTransferSize = byteSize(at: localURL)
                maximumTransferBytes = try await prepareOfflineTransferCapacity(
                    expectedSize: expectedTransferSize,
                    lease: lease
                )
                let localExpectedSize = expectedTransferSize
                let localMaximum = maximumTransferBytes
                try await Task.detached(priority: .utility) {
                    try Self.validateCompleteCacheFile(
                        at: localURL,
                        expectedSize: localExpectedSize,
                        maximumBytes: localMaximum
                    )
                    try Self.installCacheFile(from: localURL, to: target, move: false)
                }.value
            }

            try Task.checkCancellation()
            try Self.validateCompleteCacheFile(
                at: target,
                expectedSize: expectedTransferSize,
                maximumBytes: maximumTransferBytes
            )
            if refreshDisposition != .none {
                try await Task.detached(priority: .utility) {
                    try OfflineCacheAtomicReplacement.replace(
                        staging: target,
                        canonical: canonicalTarget
                    )
                }.value
            }
            let size = fileSize(at: canonicalTarget)
            preservingAutomaticRefreshPaths.remove(relativePath)
            contentChangeProtectionPendingPaths.remove(relativePath)
            contentChangeInvalidationGenerationByPath[relativePath] = nil
            blockedUntrustedAudioCachePaths.remove(relativePath)
            await AudioCacheManager.shared.markDownloaded(path: relativePath, byteCount: size, pinned: false)
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .cached,
                progress: nil,
                byteCount: size,
                errorMessage: nil
            ), for: song.id)
            plog(String(format: "✅ Offline: '%@' downloaded size=%lldKB elapsed=%.1fs", song.title, (size ?? 0) / 1024, Date().timeIntervalSince(startedAt)))
            return .completed(byteCount: size)
        } catch {
            if Task.isCancelled {
                await restoreUsableSnapshotAfterRefreshFailure(
                    song: song,
                    canonicalTarget: canonicalTarget,
                    refreshDisposition: refreshDisposition,
                    errorMessage: nil
                )
                plog(String(format: "↩️ Offline download cancelled for '%@' after %.1fs", song.title, Date().timeIntervalSince(startedAt)))
                return .cancelled
            }
            let partial = URL(fileURLWithPath: target.path + ".offline")
            let partialSize = byteSize(at: partial)
            await restoreUsableSnapshotAfterRefreshFailure(
                song: song,
                canonicalTarget: canonicalTarget,
                refreshDisposition: refreshDisposition,
                errorMessage: error.localizedDescription,
                partialSize: partialSize
            )
            plog(String(format: "⚠️ Offline download failed for '%@' after %.1fs partial=%lldKB: %@", song.title, Date().timeIntervalSince(startedAt), partialSize / 1024, error.localizedDescription))
            let failureKind = AutomaticOfflineFailureClassifier.classify(error)
            return .failed(
                kind: failureKind,
                message: error.localizedDescription
            )
        }
    }

    private func restoreUsableSnapshotAfterRefreshFailure(
        song: Song,
        canonicalTarget: URL,
        refreshDisposition: AutomaticOfflineRefreshDisposition,
        errorMessage: String?,
        partialSize: Int64 = 0
    ) async {
        let relativePath = audioCacheRelativePath(for: song)
        if refreshDisposition == .preserveExisting,
           FileManager.default.fileExists(atPath: canonicalTarget.path) {
            let size = fileSize(at: canonicalTarget)
            let snapshot = await AudioCacheManager.shared.snapshot(
                path: relativePath,
                fileExists: true,
                byteCount: size
            )
            setOfflineAudioSnapshot(snapshot, for: song.id)
            return
        }
        if errorMessage == nil {
            setOfflineAudioSnapshot(.notCached, for: song.id)
        } else {
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .failed,
                progress: nil,
                byteCount: partialSize > 0 ? partialSize : nil,
                errorMessage: errorMessage
            ), for: song.id)
        }
    }

    private func downloadOfflineByRanges(
        song: Song,
        connector: any MusicSourceConnector,
        target: URL,
        maximumBytes: Int64,
        sourcePath: String? = nil,
        expectedSize: Int64? = nil
    ) async throws {
        let transferPath = sourcePath ?? song.filePath
        let transferSize = expectedSize ?? song.fileSize
        guard transferSize > 0 else {
            throw AutomaticOfflineTransferDeferralError.unboundedAutomaticTransfer
        }
        let partial = URL(fileURLWithPath: target.path + ".offline")
        let existingSize = byteSize(at: partial)
        if existingSize > transferSize {
            await Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: partial)
            }.value
        } else if existingSize == transferSize {
            try await Task.detached(priority: .utility) {
                try Self.validateCompleteCacheFile(
                    at: partial,
                    expectedSize: transferSize,
                    maximumBytes: maximumBytes
                )
                try OfflineCacheAtomicReplacement.replace(
                    staging: partial,
                    canonical: target
                )
            }.value
            return
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(
                    at: partial.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }.value
        }
        let chunkSize: Int64 = 2 * 1024 * 1024
        var offset: Int64 = max(0, min(byteSize(at: partial), transferSize))
        if offset > 0 {
            plog("↩️ Offline resume '\(song.title)' from \(offset / 1024)KB / \(transferSize / 1024)KB")
        }
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: min(0.99, Double(offset) / Double(transferSize)),
            byteCount: transferSize,
            errorMessage: nil
        ), for: song.id)

        while offset < transferSize {
            try Task.checkCancellation()
            let length = min(chunkSize, transferSize - offset)
            let chunkOffset = offset
            let data = try await connector.fetchRange(
                path: transferPath,
                offset: chunkOffset,
                length: length
            )
            guard Int64(data.count) == length else {
                throw OfflineTransferValidationError.invalidChunk(
                    actual: data.count,
                    expected: length
                )
            }
            try await Task.detached(priority: .utility) {
                try Self.writeOfflineChunk(data, to: partial, offset: chunkOffset)
            }.value
            offset += Int64(data.count)
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .downloading,
                progress: min(0.99, Double(offset) / Double(transferSize)),
                byteCount: transferSize,
                errorMessage: nil
            ), for: song.id)
        }
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try Self.validateCompleteCacheFile(
                at: partial,
                expectedSize: transferSize,
                maximumBytes: maximumBytes
            )
            try OfflineCacheAtomicReplacement.replace(
                staging: partial,
                canonical: target
            )
        }.value
    }

    private func downloadOfflineFromDirectURL(
        _ url: URL,
        song: Song,
        target: URL,
        expectedSize: Int64,
        maximumBytes: Int64
    ) async throws {
        let partial = URL(fileURLWithPath: target.path + ".offline")
        let existingSize = byteSize(at: partial)
        if existingSize > expectedSize, expectedSize > 0 {
            try? FileManager.default.removeItem(at: partial)
        } else if existingSize == expectedSize, expectedSize > 0 {
            try Self.validateCompleteCacheFile(
                at: partial,
                expectedSize: expectedSize,
                maximumBytes: maximumBytes
            )
            try OfflineCacheAtomicReplacement.replace(
                staging: partial,
                canonical: target
            )
            return
        }
        if existingSize > maximumBytes {
            try? FileManager.default.removeItem(at: partial)
        }

        let resumeOffset = max(0, min(byteSize(at: partial), maximumBytes))
        if resumeOffset > 0 {
            plog("↩️ Offline direct resume '\(song.title)' from \(resumeOffset / 1024)KB / \(song.fileSize / 1024)KB")
        } else {
            plog("⬇️ Offline direct download '\(song.title)' via \(url.host ?? "?")")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(Self.directDownloadUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if resumeOffset > 0 {
            request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        let songID = song.id
        let expectedTotal = expectedSize > 0 ? expectedSize : nil
        let delegate = OfflineDirectDownloadDelegate(
            partial: partial,
            initialBytes: resumeOffset,
            expectedTotalBytes: expectedTotal,
            maximumBytes: maximumBytes
        ) { [weak self] downloadedBytes, totalBytes in
            Task { @MainActor [weak self] in
                let total = totalBytes ?? expectedTotal
                self?.setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                    state: .downloading,
                    progress: total.map { $0 > 0 ? min(0.99, Double(downloadedBytes) / Double($0)) : 0 },
                    byteCount: total,
                    errorMessage: nil
                ), for: songID)
            }
        }

        let startedAt = Date()
        let response = try await delegate.run(request: request, configuration: config)
        guard response.statusCode == 200 || response.statusCode == 206 else {
            throw CloudDriveError.apiError(response.statusCode, "Offline direct download failed")
        }

        let finalSize = byteSize(at: partial)
        try Self.validateCompleteCacheFile(
            at: partial,
            expectedSize: expectedSize,
            maximumBytes: maximumBytes
        )
        try OfflineCacheAtomicReplacement.replace(
            staging: partial,
            canonical: target
        )
        plog(String(format: "✅ Offline direct download '%@' size=%lldKB elapsed=%.1fs", song.title, finalSize / 1024, Date().timeIntervalSince(startedAt)))
    }

    private func downloadOfflineFromURL(
        _ url: URL,
        song: Song,
        target: URL,
        maximumBytes: Int64
    ) async throws {
        guard CompleteFileTransferPolicy.route(for: .externalURL) == .genericHTTP else {
            throw SourceError.connectionFailed("External stream transfer route unavailable")
        }
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: nil,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        ), for: song.id)
        guard TrustedHTTPTransport.requiresPlainSocket(for: url) else {
            try await downloadOfflineFromDirectURL(
                url,
                song: song,
                target: target,
                expectedSize: 0,
                maximumBytes: maximumBytes
            )
            return
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue(Self.directDownloadUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (tempURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: session,
            maximumRangedBodyBytes: Int(clamping: maximumBytes),
            wholeResponsePrefixLimit: nil
        )
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CloudDriveError.apiError(
                http.statusCode,
                "Offline URL download failed"
            )
        }
        try Self.validateCompleteCacheFile(
            at: tempURL,
            expectedSize: 0,
            maximumBytes: maximumBytes
        )
        try OfflineCacheAtomicReplacement.install(
            source: tempURL,
            target: target,
            move: true
        )
    }

    private nonisolated static func writeOfflineChunk(
        _ data: Data,
        to partial: URL,
        offset: Int64
    ) throws {
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        try handle.write(contentsOf: data)
    }

    private nonisolated func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let size = values.totalFileAllocatedSize else { return nil }
        return Int64(size)
    }

    private nonisolated func byteSize(at url: URL) -> Int64 {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else {
            return 0
        }
        return size
    }

    @discardableResult
    func deleteSourceFilesAndCaches(for song: Song, deleteSidecars: Bool = true) async -> SongFileDeletionResult {
        let result = await deleteSourceFiles(for: song, deleteSidecars: deleteSidecars)
        if result.shouldRemoveLibraryRecord {
            deleteLocalCaches(for: song)
        }
        return result
    }

    @discardableResult
    func deleteSourceFiles(for song: Song, deleteSidecars: Bool = true) async -> SongFileDeletionResult {
        do {
            let sources = try await sourcesProvider()
            guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                let result = Self.sourceNotFoundDeletionResult(for: song)
                Self.logDeletionFailures(result, song: song)
                return result
            }
            let conn = connector(for: source)
            return await Self.performSourceFileDeletion(
                for: song,
                connector: conn,
                deleteSidecars: deleteSidecars
            )
        } catch {
            var result = SongFileDeletionResult()
            result.failedPaths.append(.init(path: song.filePath, message: error.localizedDescription))
            Self.logDeletionFailures(result, song: song)
            return result
        }
    }

    /// Delete a collection without reloading the complete source list for every
    /// song. The operation remains serial per call so stateful NAS/cloud
    /// connectors keep their existing ordering, while every actual file
    /// operation runs on the connector's executor and yields the main actor.
    func deleteSourceFiles(
        for songs: [Song],
        deleteSidecarsForSongIDs: Set<String>,
        onProgress: (Int) -> Void
    ) async -> [SongFileDeletionOutcome] {
        guard !songs.isEmpty else { return [] }

        let sourceByID: [String: MusicSource]
        do {
            sourceByID = Dictionary(
                try await sourcesProvider().map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
        } catch {
            let message = error.localizedDescription
            plog("⚠️ Batch source deletion could not load sources: \(message)")
            let outcomes = songs.map { song in
                var result = SongFileDeletionResult()
                result.failedPaths.append(.init(path: song.filePath, message: message))
                return SongFileDeletionOutcome(song: song, result: result)
            }
            onProgress(songs.count)
            return outcomes
        }

        let songsBySourceID = Dictionary(grouping: songs, by: \Song.sourceID)
        var orderedSourceIDs: [String] = []
        var seenSourceIDs = Set<String>()
        for song in songs where seenSourceIDs.insert(song.sourceID).inserted {
            orderedSourceIDs.append(song.sourceID)
        }

        var outcomeBySongID: [String: SongFileDeletionOutcome] = [:]
        outcomeBySongID.reserveCapacity(songs.count)
        var completedCount = 0

        sourceLoop: for sourceID in orderedSourceIDs {
            guard let sourceSongs = songsBySourceID[sourceID], !sourceSongs.isEmpty else { continue }
            guard let source = sourceByID[sourceID] else {
                plog("⚠️ Batch source deletion could not find source \(sourceID)")
                for song in sourceSongs {
                    outcomeBySongID[song.id] = SongFileDeletionOutcome(
                        song: song,
                        result: Self.sourceNotFoundDeletionResult(for: song)
                    )
                    completedCount += 1
                }
                onProgress(completedCount)
                continue
            }

            let conn = connector(for: source)
            do {
                try await conn.connect()
            } catch {
                let message = error.localizedDescription
                plog("⚠️ Batch source deletion connection failed for source \(sourceID): \(message)")
                for song in sourceSongs {
                    var failure = SongFileDeletionResult()
                    failure.failedPaths.append(.init(path: song.filePath, message: message))
                    outcomeBySongID[song.id] = SongFileDeletionOutcome(song: song, result: failure)
                    completedCount += 1
                }
                onProgress(completedCount)
                continue
            }

            let batchSize = max(1, conn.preferredDeleteBatchSize)
            if batchSize > 1 {
                // Cloud providers such as Baidu expose a real batch recycle-bin
                // API. Deleting 4K duplicates one HTTP call at a time takes
                // minutes and quickly hits rate limits, so process bounded
                // chunks and publish progress once per chunk.
                for start in stride(from: 0, to: sourceSongs.count, by: batchSize) {
                    if Task.isCancelled { break sourceLoop }
                    let end = min(start + batchSize, sourceSongs.count)
                    let chunk = Array(sourceSongs[start..<end])
                    do {
                        try await conn.deleteFiles(at: chunk.map(\.filePath))
                        for song in chunk {
                            var result = SongFileDeletionResult()
                            result.deletedPaths.append(song.filePath)
                            result.audioStatus = .deleted
                            outcomeBySongID[song.id] = SongFileDeletionOutcome(song: song, result: result)
                        }

                        // Sidecars are cleanup-only: once the audio deletion
                        // succeeded, a missing/locked sidecar must never keep a
                        // dead song in the library. Batch them best-effort.
                        let sidecarPaths = Array(Set(chunk
                            .filter { deleteSidecarsForSongIDs.contains($0.id) }
                            .flatMap { Self.sidecarPathsToDelete(for: $0) }))
                        for sidecarStart in stride(from: 0, to: sidecarPaths.count, by: batchSize) {
                            let sidecarEnd = min(sidecarStart + batchSize, sidecarPaths.count)
                            do {
                                try await conn.deleteFiles(
                                    at: Array(sidecarPaths[sidecarStart..<sidecarEnd])
                                )
                            } catch {
                                plog("⚠️ Batch sidecar deletion failed for source \(sourceID): \(error.localizedDescription)")
                            }
                        }
                    } catch {
                        let aggregateMissing = Self.isMissingFileError(error)
                        if SourceBatchDeletionFailurePolicy.shouldRetryIndividually(
                            batchCount: chunk.count,
                            aggregateErrorIndicatesMissing: aggregateMissing
                        ) {
                            plog("⚠️ Batch source deletion reported a missing path; retrying \(chunk.count) items individually for source \(sourceID)")
                            for song in chunk {
                                if Task.isCancelled { break sourceLoop }
                                let result = await Self.performSourceFileDeletion(
                                    for: song,
                                    connector: conn,
                                    deleteSidecars: deleteSidecarsForSongIDs.contains(song.id),
                                    connectFirst: false
                                )
                                outcomeBySongID[song.id] = SongFileDeletionOutcome(
                                    song: song,
                                    result: result
                                )
                                completedCount += 1
                                onProgress(completedCount)
                            }
                            continue
                        }

                        let message = error.localizedDescription
                        for song in chunk {
                            var result = SongFileDeletionResult()
                            if aggregateMissing {
                                result.missingPaths.append(song.filePath)
                                result.audioStatus = .alreadyMissing
                            } else {
                                result.failedPaths.append(.init(path: song.filePath, message: message))
                            }
                            outcomeBySongID[song.id] = SongFileDeletionOutcome(song: song, result: result)
                        }
                        plog("⚠️ Batch source deletion failed for source \(sourceID), paths=\(chunk.count): \(message)")
                    }
                    completedCount += chunk.count
                    onProgress(completedCount)
                }
            } else {
                for song in sourceSongs {
                    if Task.isCancelled { break sourceLoop }
                    let result = await Self.performSourceFileDeletion(
                        for: song,
                        connector: conn,
                        deleteSidecars: deleteSidecarsForSongIDs.contains(song.id),
                        connectFirst: false
                    )
                    outcomeBySongID[song.id] = SongFileDeletionOutcome(song: song, result: result)
                    completedCount += 1
                    onProgress(completedCount)
                }
            }
        }

        // Preserve caller order even though provider batching is grouped by
        // source. This keeps progress/result handling deterministic.
        return songs.compactMap { outcomeBySongID[$0.id] }
    }

    /// Build all sidecar-sharing decisions in one O(librarySize) pass. The old
    /// per-song `retainedSongs.contains` implementation was O(deleteCount ×
    /// librarySize) and repeatedly allocated Sets on the main actor.
    nonisolated static func sidecarDeletionSongIDs(
        deleting songs: [Song],
        retaining retainedSongs: [Song]
    ) -> Set<String> {
        var retainedSidecarPaths = Set<String>()
        retainedSidecarPaths.reserveCapacity(retainedSongs.count * 2)
        for retained in retainedSongs {
            for path in sidecarPathsToDelete(for: retained) {
                retainedSidecarPaths.insert(sidecarSharingKey(sourceID: retained.sourceID, path: path))
            }
        }

        var result = Set<String>()
        result.reserveCapacity(songs.count)
        for song in songs {
            let paths = sidecarPathsToDelete(for: song)
            guard !paths.isEmpty,
                  paths.allSatisfy({
                      !retainedSidecarPaths.contains(sidecarSharingKey(sourceID: song.sourceID, path: $0))
                  })
            else { continue }
            result.insert(song.id)
        }
        return result
    }

    private nonisolated static func sidecarSharingKey(sourceID: String, path: String) -> String {
        "\(sourceID)\u{0}\(path)"
    }

    nonisolated func shouldDeleteSidecars(for song: Song, retaining retainedSongs: [Song]) -> Bool {
        Self.sidecarDeletionSongIDs(deleting: [song], retaining: retainedSongs).contains(song.id)
    }

    private nonisolated static func sourceNotFoundDeletionResult(for song: Song) -> SongFileDeletionResult {
        var result = SongFileDeletionResult()
        result.failedPaths.append(.init(path: song.filePath, message: "Source not found"))
        return result
    }

    private nonisolated static func performSourceFileDeletion(
        for song: Song,
        connector: any MusicSourceConnector,
        deleteSidecars: Bool,
        connectFirst: Bool = true
    ) async -> SongFileDeletionResult {
        var result = SongFileDeletionResult()

        do {
            if connectFirst {
                try await connector.connect()
            }
            do {
                try await connector.deleteFile(at: song.filePath)
                result.deletedPaths.append(song.filePath)
                result.audioStatus = .deleted
            } catch {
                if isMissingFileError(error) {
                    result.missingPaths.append(song.filePath)
                    result.audioStatus = .alreadyMissing
                } else {
                    result.failedPaths.append(.init(path: song.filePath, message: error.localizedDescription))
                    logDeletionFailures(result, song: song)
                    return result
                }
            }

            if deleteSidecars {
                for path in sidecarPathsToDelete(for: song) {
                    do {
                        try await connector.deleteFile(at: path)
                        result.deletedPaths.append(path)
                    } catch {
                        if isMissingFileError(error) {
                            result.missingPaths.append(path)
                        } else {
                            // The audio is already gone. A sidecar cleanup
                            // failure is a warning, not a reason to retain a
                            // library row that can no longer play.
                            plog("⚠️ Delete sidecar failed for '\(song.title)' at \(path): \(error.localizedDescription)")
                            result.sidecarWarnings.append(.init(
                                path: path,
                                message: error.localizedDescription
                            ))
                        }
                    }
                }
            }
        } catch {
            result.failedPaths.append(.init(path: song.filePath, message: error.localizedDescription))
        }

        logDeletionFailures(result, song: song)
        return result
    }

    private nonisolated static func logDeletionFailures(_ result: SongFileDeletionResult, song: Song) {
        guard result.hasFailures else { return }
        let failures = result.failedPaths.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
        plog("⚠️ Delete source files failed for '\(song.title)': \(failures)")
    }

    private static var smbCacheDir: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("primuse_smb_cache")
    }

    func audioCacheSize() -> Int64 {
        Self.audioCacheSize(dirs: Self.audioCacheSizeDirs)
    }

    /// 后台线程版 ── 整个 audio cache 目录可达 20GB, 同步枚举会冻结主线程,
    /// 所以「存储管理」页走这个: 用 Task.detached 在后台 walk, 主 actor 只
    /// 拿到最终的 Int64。枚举范围与同步版一致 (含 smbCache)。
    func audioCacheSizeAsync() async -> Int64 {
        let dirs = Self.audioCacheSizeDirs
        return await Task.detached(priority: .utility) {
            Self.audioCacheSize(dirs: dirs)
        }.value
    }

    /// 主 actor 上算好目录列表 (纯 FileManager 查询, Sendable), 实际枚举可
    /// 在任意线程跑。
    private static var audioCacheSizeDirs: [URL] {
        [
            FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent(audioCacheDirName),
            smbCacheDir,
        ]
    }

    /// 一个源占用的全部 per-source 缓存目录。下载缓存按协议散落在多个目录,
    /// `deleteSourceCaches` 删除与 `diskUsage` 统计都走这里, 保证口径一致
    /// (否则统计会系统性低估 SMB/SFTP/NFS/云 等源的真实占用)。
    static func perSourceCacheDirs(sourceID: String) -> [URL] {
        let fm = FileManager.default
        let caches = fm.primuseDirectoryURL(for: .cachesDirectory)
        let temp = fm.temporaryDirectory
        return [
            caches.appendingPathComponent(audioCacheDirName).appendingPathComponent(sourceID),
            caches.appendingPathComponent(videoCacheDirName).appendingPathComponent(sourceID),
            caches.appendingPathComponent("primuse_cloud_cache").appendingPathComponent(sourceID),
            caches.appendingPathComponent("primuse_s3_cache").appendingPathComponent(sourceID),
            caches.appendingPathComponent("fnmusic_artwork").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_ftp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_nfs_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_upnp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_media_server_cache_\(sourceID)"),
            temp.appendingPathComponent("primuse_subsonic_cache_\(sourceID)"),
            temp.appendingPathComponent("primuse_scan_\(sourceID)"),
        ]
    }

    /// 单个源占用的磁盘大小(后台枚举, 不卡主线程)。本地导入源算沙箱
    /// Documents/LocalMusic 的原始拷贝; 其它源算全部 per-source 下载缓存目录。
    func diskUsage(for source: MusicSource) async -> Int64 {
        let dirs: [URL] = source.id == LocalImportService.existingSourceID
            ? [LocalImportService.musicDirectory]
            : Self.perSourceCacheDirs(sourceID: source.id)
        return await Task.detached(priority: .utility) {
            Self.audioCacheSize(dirs: dirs)
        }.value
    }

    nonisolated private static func audioCacheSize(dirs: [URL]) -> Int64 {
        var total: Int64 = 0
        for basePath in dirs {
            guard let enumerator = FileManager.default.enumerator(
                at: basePath, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
            ) else { continue }
            while let fileURL = enumerator.nextObject() as? URL {
                if let size = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// 给「存储管理」页用的统计 —— 把 audio cache 拆成三类:
    /// - completed: 完整下完的歌曲 (rename 成 final 名), 受 2GB LRU 控制
    /// - partial: `.partial` / `.partial.prewarmed` / `.offline` 半成品
    ///   (用户跳过 / prewarm 完没听 / 离线下载中断), 启动时 7 天清一次,
    ///   也可以这里手动一键清
    /// - orphaned: 子目录里的文件, 但 sourceID 已经不在 sources 表里
    ///   (用户删过源 / source ID 变更), 没人会再访问, 全是垃圾
    struct AudioCacheBreakdown {
        var completedBytes: Int64 = 0
        var pinnedBytes: Int64 = 0
        /// 「正在播放/缓存中」—— 当前还有活跃 streaming session 的 .partial。
        /// 用户暂停 / 切到下一首前都算这类, 不该跟「真中断」混在一起让人
        /// 误以为出问题。session 结束后会自动 finalize / 落入 partialBytes。
        var activeBytes: Int64 = 0
        /// 「真半成品」—— 用户播到一半切走的, 或下载失败的。下次还有用
        /// (sparse cache 复用) 但用户视角是「中断了」。
        var partialBytes: Int64 = 0
        /// 「预热种子」—— prewarmCloudSong 写的 head + tail (合计 ~1.25MB / 首),
        /// 让下次播首次解码秒出。看着是 .partial 但属于设计内的小种子,
        /// 不应该让用户误以为出问题了。判定方法: `.partial` 旁边有
        /// `.partial.prewarmed` marker 文件。
        var prewarmSeedBytes: Int64 = 0
        var orphanedBytes: Int64 = 0
        var orphanedSourceIDs: Set<String> = []
    }

    func audioCacheBreakdown() async -> AudioCacheBreakdown {
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
        let aliveSourceIDs: Set<String>
        if let sources = try? await sourcesProvider() {
            aliveSourceIDs = Set(sources.map { $0.id })
        } else {
            aliveSourceIDs = []
        }
        // 当前活跃 streaming session 的 .partial 路径, 让 UI 把它们标成
        // 「正在播放」而不是「中断」。
        let activeSessionPaths = CloudPlaybackSource.activeSessionPaths()
        let pinnedRelativePaths = await AudioCacheManager.shared.pinnedRelativePaths()

        // 主 actor 上只采集需要隔离的输入 (sources / pinned / active session),
        // 把真正会 walk 整个 cache 目录的部分丢到后台线程, 避免冻结 UI。
        return await Task.detached(priority: .utility) {
            Self.audioCacheBreakdown(
                basePath: basePath,
                aliveSourceIDs: aliveSourceIDs,
                activeSessionPaths: activeSessionPaths,
                pinnedRelativePaths: pinnedRelativePaths
            )
        }.value
    }

    nonisolated private static func audioCacheBreakdown(
        basePath: URL,
        aliveSourceIDs: Set<String>,
        activeSessionPaths: Set<String>,
        pinnedRelativePaths: Set<String>
    ) -> AudioCacheBreakdown {
        var result = AudioCacheBreakdown()

        guard let subdirs = try? FileManager.default.contentsOfDirectory(
            at: basePath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return result }

        // 先收集所有 .partial.prewarmed marker 路径, 后面判断 .partial 是否
        // 是「预热种子」时用。
        let fm = FileManager.default
        var prewarmMarkers: Set<String> = []
        for sourceDir in subdirs {
            guard (try? sourceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            if let e = fm.enumerator(at: sourceDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                while let fileURL = e.nextObject() as? URL {
                    if fileURL.lastPathComponent.hasSuffix(".partial.prewarmed") {
                        prewarmMarkers.insert(fileURL.path)
                    }
                }
            }
        }

        for sourceDir in subdirs {
            guard (try? sourceDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let sid = sourceDir.lastPathComponent
            let isOrphan = !aliveSourceIDs.contains(sid)
            if isOrphan { result.orphanedSourceIDs.insert(sid) }

            let enumerator = fm.enumerator(
                at: sourceDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                let size = Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
                let name = fileURL.lastPathComponent
                if isOrphan {
                    result.orphanedBytes += size
                    continue
                }
                if name.hasSuffix(".partial.prewarmed") {
                    // marker 本身, 算到 prewarm 类
                    result.prewarmSeedBytes += size
                } else if name.hasSuffix(".offline") {
                    result.partialBytes += size
                } else if name.hasSuffix(".partial") {
                    let markerPath = fileURL.path + CloudPlaybackSource.prewarmMarkerSuffix
                    if activeSessionPaths.contains(fileURL.path) {
                        // 当前正在播 / 暂停的歌, 不是真"中断"
                        result.activeBytes += size
                    } else if prewarmMarkers.contains(markerPath) {
                        // 旁边有 marker = prewarm 种子 (head+tail sparse), 设计内
                        result.prewarmSeedBytes += size
                    } else {
                        // 之前播过没下完 + 现在不在活跃 session 里 = 真中断
                        result.partialBytes += size
                    }
                } else {
                    let relativePath = "\(sid)/\(name)"
                    if pinnedRelativePaths.contains(relativePath) {
                        result.pinnedBytes += size
                    } else {
                        result.completedBytes += size
                    }
                }
            }
        }
        return result
    }

    /// 一键清掉所有孤立 sourceID 的整个 cache 子目录。
    func purgeOrphanedAudioCache() async {
        let breakdown = await audioCacheBreakdown()
        for sid in breakdown.orphanedSourceIDs {
            purgeAudioCache(forSourceID: sid)
        }
    }

    /// 一键清掉所有 `.partial` / `.offline` 半成品 (无视 mtime, 等价于用户主动决定
    /// 「不要任何半下载文件了」)。正在 streaming 的歌会立即变成 cache miss
    /// 重新下, 但不会丢功能。
    @discardableResult
    func purgeAllPartialFiles() -> (freedBytes: Int64, failedCount: Int) {
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
        var freed: Int64 = 0
        var failed = 0
        guard let enumerator = FileManager.default.enumerator(
            at: basePath, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var partials: [(URL, Int64)] = []
        while let fileURL = enumerator.nextObject() as? URL {
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".partial") || name.hasSuffix(".partial.prewarmed") || name.hasSuffix(".offline") else { continue }
            let size = Int64((try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            partials.append((fileURL, size))
        }
        for (url, size) in partials {
            do {
                try FileManager.default.removeItem(at: url)
                freed += size
            } catch {
                failed += 1
            }
        }
        plog("🧹 purgeAllPartialFiles: freed \(freed / 1024 / 1024)MB, failed=\(failed)")
        return (freed, failed)
    }

    private func reconcilePathKeyedCaches(
        previousSongs: [Song],
        currentSongs: [Song]
    ) {
        let currentByID = Dictionary(
            currentSongs.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        let cachesRoot = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)

        for previous in previousSongs {
            guard let current = currentByID[previous.id],
                  current.sourceID == previous.sourceID,
                  current.filePath != previous.filePath else { continue }

            let previousTaskKey = audioCacheRelativePath(for: previous)
            offlineDownloadTasks[previousTaskKey]?.task.cancel()
            offlineDownloadTasks[previousTaskKey] = nil
            preservingAutomaticRefreshPaths.remove(previousTaskKey)
            contentChangeProtectionPendingPaths.remove(previousTaskKey)
            contentChangeInvalidationGenerationByPath[previousTaskKey] = nil
            blockedUntrustedAudioCachePaths.remove(previousTaskKey)
            backgroundAudioCacheTasks[previous.id]?.task.cancel()
            backgroundAudioCacheTasks[previous.id] = nil

            let decision = SourceStableCacheTransitionPolicy.decision(
                previousPath: previous.filePath,
                currentPath: current.filePath,
                previousRevision: previous.revision,
                currentRevision: current.revision,
                previousSize: previous.fileSize,
                currentSize: current.fileSize
            )
            let previousAudioURL = audioCacheDirectory(for: previous.sourceID)
                .appendingPathComponent(cacheFileName(for: previous))
            let currentAudioURL = audioCacheDirectory(for: current.sourceID)
                .appendingPathComponent(cacheFileName(for: current))
            let previousRelativePath = audioCacheRelativePath(for: previous)
            let currentRelativePath = audioCacheRelativePath(for: current)
            let cloudCacheDirectory = cachesRoot
                .appendingPathComponent("primuse_cloud_cache")
                .appendingPathComponent(previous.sourceID)
                .appendingPathComponent(
                    MusicSourceSecurityRevision.cacheNamespace(for: previous.sourceID)
                )
            let previousCloudURL = cloudCacheDirectory.appendingPathComponent(
                CloudDriveHelper.cacheFileName(for: previous.filePath)
            )
            let currentCloudURL = cloudCacheDirectory.appendingPathComponent(
                CloudDriveHelper.cacheFileName(for: current.filePath)
            )

            switch decision {
            case .none:
                continue
            case .migrate:
                let migratedAudioBytes: Int64?
                do {
                    migratedAudioBytes = try SourceStableCacheFileMigration.migrateCompletedFile(
                        from: previousAudioURL,
                        to: currentAudioURL
                    )
                } catch {
                    migratedAudioBytes = nil
                    plog("⚠️ Stable audio cache migration failed: \(error.localizedDescription)")
                }
                if let migratedAudioBytes {
                    Task {
                        await AudioCacheManager.shared.migrateEntry(
                            from: previousRelativePath,
                            to: currentRelativePath,
                            byteCount: migratedAudioBytes
                        )
                    }
                }
                do {
                    try SourceStableCacheFileMigration.migrateCompletedFile(
                        from: previousCloudURL,
                        to: currentCloudURL
                    )
                } catch {
                    plog("⚠️ Stable cloud cache migration failed: \(error.localizedDescription)")
                }
            case .invalidate:
                Self.removeCacheFileFamily(at: previousAudioURL)
                try? FileManager.default.removeItem(at: previousCloudURL)
                Task {
                    await AudioCacheManager.shared.removeEntry(path: previousRelativePath)
                }
                setOfflineAudioSnapshot(.notCached, for: previous.id)
            }
        }
    }

    func deleteAudioCache(for song: Song) {
        backgroundAudioCacheTasks[song.id]?.task.cancel()
        let cacheURL = cacheURL(for: song)
        Self.removeCacheFileFamily(at: cacheURL)
        deleteConnectorTempCaches(for: song)
        let relativePath = audioCacheRelativePath(for: song)
        preservingAutomaticRefreshPaths.remove(relativePath)
        contentChangeProtectionPendingPaths.remove(relativePath)
        contentChangeInvalidationGenerationByPath[relativePath] = nil
        blockedUntrustedAudioCachePaths.remove(relativePath)
        Task { await AudioCacheManager.shared.removeEntry(path: relativePath) }
        setOfflineAudioSnapshot(.notCached, for: song.id)
    }

    func deleteLocalCaches(for song: Song) {
        deleteLocalCaches(for: [song])
    }

    /// Content revisions are different from removals: an Always Download
    /// artifact remains a valid same-account fallback until the replacement is
    /// fully transferred and atomically installed. Classification consults both
    /// the live desired set and the durable playlist ownership manifest before
    /// any canonical audio bytes are deleted.
    private func invalidateLocalCachesForContentChanges(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        contentChangeInvalidationGeneration += 1
        let generation = contentChangeInvalidationGeneration
        let candidatePaths = Set(songs.map { audioCacheRelativePath(for: $0) })
        for path in candidatePaths {
            contentChangeInvalidationGenerationByPath[path] = generation
        }

        // Fail closed against destructive invalidation while the manifest actor
        // is being consulted. Live playlist ownership can be protected
        // immediately; cold-start ownership is added when the durable query
        // returns.
        contentChangeProtectionPendingPaths.formUnion(candidatePaths)
        preservingAutomaticRefreshPaths.formUnion(songs.compactMap { song in
            automaticPlaylistPinnedSongsByID[song.id] == nil
                ? nil
                : audioCacheRelativePath(for: song)
        })

        Task { [weak self] in
            let persistedPaths = await AudioCacheManager.shared
                .automaticPlaylistPinnedRelativePaths(matching: candidatePaths)
            guard let self else { return }
            let currentPaths = Set(candidatePaths.filter {
                self.contentChangeInvalidationGenerationByPath[$0] == generation
            })
            guard !currentPaths.isEmpty else { return }

            let livePaths = Set(songs.compactMap { song -> String? in
                let path = self.audioCacheRelativePath(for: song)
                guard currentPaths.contains(path),
                      self.automaticPlaylistPinnedSongsByID[song.id] != nil else {
                    return nil
                }
                return path
            })
            let protectedPaths = AutomaticOfflineContentChangePolicy.protectedPaths(
                candidates: currentPaths,
                livePlaylistPaths: livePaths,
                persistedPlaylistPaths: persistedPaths,
                blockedUntrustedPaths: self.blockedUntrustedAudioCachePaths
            )

            for path in currentPaths {
                self.contentChangeInvalidationGenerationByPath[path] = nil
            }
            self.contentChangeProtectionPendingPaths.subtract(currentPaths)
            self.preservingAutomaticRefreshPaths.formUnion(protectedPaths)
            let currentSongs = songs.filter {
                currentPaths.contains(self.audioCacheRelativePath(for: $0))
            }
            self.deleteLocalCaches(
                for: currentSongs,
                preserveFreshMetadataAssets: true,
                preservingAudioPaths: protectedPaths
            )
        }
    }

    func deleteLocalCaches(
        for songs: [Song],
        preserveFreshMetadataAssets: Bool = false,
        preservingAudioPaths: Set<String> = []
    ) {
        guard songs.isEmpty == false else { return }

        for song in songs {
            backgroundAudioCacheTasks[song.id]?.task.cancel()
            let relativePath = audioCacheRelativePath(for: song)
            if preservingAudioPaths.contains(relativePath) {
                preservingAutomaticRefreshPaths.insert(relativePath)
            } else {
                preservingAutomaticRefreshPaths.remove(relativePath)
                contentChangeProtectionPendingPaths.remove(relativePath)
                contentChangeInvalidationGenerationByPath[relativePath] = nil
                blockedUntrustedAudioCachePaths.remove(relativePath)
            }
        }

        let cachesRoot = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let tempRoot = FileManager.default.temporaryDirectory
        var cacheTargets: [URL] = []
        cacheTargets.reserveCapacity(songs.count * 6)
        var audioRelativePaths: [String] = []
        audioRelativePaths.reserveCapacity(songs.count)

        for song in songs {
            let audioName = cacheFileName(for: song)
            let audioRelativePath = "\(song.sourceID)/\(audioName)"
            if !preservingAudioPaths.contains(audioRelativePath) {
                cacheTargets.append(
                    cachesRoot
                        .appendingPathComponent(Self.audioCacheDirName)
                        .appendingPathComponent(song.sourceID)
                        .appendingPathComponent(audioName)
                )
                audioRelativePaths.append(audioRelativePath)
            }

            let cacheName = CacheFileNamePolicy.make(path: song.filePath)
            let legacyName = CacheFileNamePolicy.legacySanitized(path: song.filePath)
            let connectorNamespace = MusicSourceSecurityRevision.cacheNamespace(
                for: song.sourceID
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_smb_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_smb_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(legacyName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_ftp_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(legacyName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_sftp_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_webdav_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("primuse_s3_cache")
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(connectorNamespace)
                    .appendingPathComponent(cacheName)
            )
            if let nfsName = NFSSelectionPathCodec.cacheFileName(for: song.filePath) {
                cacheTargets.append(
                    tempRoot.appendingPathComponent("primuse_nfs_cache")
                        .appendingPathComponent(song.sourceID)
                        .appendingPathComponent(connectorNamespace)
                        .appendingPathComponent(nfsName)
                )
            }
            if let upnpURL = URL(string: song.filePath),
               let scheme = upnpURL.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                let upnpName = CacheFileNamePolicy.make(
                    path: upnpURL.absoluteString,
                    preferredExtension: upnpURL.pathExtension.isEmpty ? "bin" : upnpURL.pathExtension
                )
                cacheTargets.append(
                    tempRoot.appendingPathComponent("primuse_upnp_cache")
                        .appendingPathComponent(song.sourceID)
                        .appendingPathComponent(connectorNamespace)
                        .appendingPathComponent(upnpName)
                )
            }

            if let mvPath = normalizedMusicVideoPath(for: song),
               URL(string: mvPath)?.scheme == nil {
                musicVideoCacheTasks[
                    Self.musicVideoCacheKey(sourceID: song.sourceID, path: mvPath)
                ]?.cancel()
                cacheTargets.append(
                    cachesRoot
                        .appendingPathComponent(Self.videoCacheDirName)
                        .appendingPathComponent(song.sourceID)
                        .appendingPathComponent(connectorNamespace)
                        .appendingPathComponent(
                            Self.videoCacheFileName(sourceID: song.sourceID, path: mvPath)
                        )
                )
            }
            if !preservingAudioPaths.contains(audioRelativePath) {
                setOfflineAudioSnapshot(.notCached, for: song.id)
            }
        }

        // A source deletion can remove thousands of songs. Posting one artwork
        // invalidation per song (often twice: id + cover ref) forced SwiftUI
        // through thousands of update cycles. Clear the small in-memory cache
        // once and publish one broad invalidation instead.
        if songs.count == 1, let song = songs.first {
            CachedArtworkView.invalidateCache(for: song.id)
            if let coverRef = song.coverArtFileName {
                CachedArtworkView.invalidateCache(for: coverRef)
            }
        } else {
            CachedArtworkView.clearMemoryCache()
        }

        Task.detached(priority: .utility) { [cacheTargets] in
            for target in cacheTargets {
                if Task.isCancelled { return }
                Self.removeCacheFileFamily(at: target)
            }
        }

        if !audioRelativePaths.isEmpty {
            Task {
                await AudioCacheManager.shared.removeEntries(paths: audioRelativePaths)
            }
        }
        let songIDs = songs.map(\.id)
        Task {
            if preserveFreshMetadataAssets {
                await MetadataAssetStore.shared.invalidateMissingCaches(for: songs)
            } else {
                await MetadataAssetStore.shared.invalidateCaches(forSongIDs: songIDs)
            }
        }
    }

    /// Source removal already deletes whole per-source audio/video/temp
    /// directories, so do not expand every song into six individual file
    /// deletion operations. Only legacy WebDAV cache files lack a source
    /// directory and still require per-song paths.
    private func deleteLocalCachesForRemovedSources(
        _ sourceIDs: Set<String>,
        songs: [Song],
        songIDs: Set<String>
    ) {
        guard !sourceIDs.isEmpty else { return }
        removeOfflineAudioSnapshots(forSongIDs: songIDs)
        for (key, task) in musicVideoCacheTasks where sourceIDs.contains(Self.sourceID(in: key, separator: ":")) {
            task.cancel()
        }

        CachedArtworkView.clearMemoryCache()

        let legacyWebDAVRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_webdav_cache")
        Task.detached(priority: .background) { [songs, legacyWebDAVRoot] in
            for song in songs {
                if Task.isCancelled { return }
                let target = legacyWebDAVRoot.appendingPathComponent(
                    CacheFileNamePolicy.legacySanitized(path: song.filePath)
                )
                Self.removeCacheFileFamily(at: target)
            }
        }
        Task.detached(priority: .background) { [songIDs] in
            await MetadataAssetStore.shared.invalidateCaches(
                forSongIDs: Array(songIDs)
            )
        }
    }

    private func deleteConnectorTempCaches(for song: Song) {
        let cacheName = CacheFileNamePolicy.make(path: song.filePath)
        let legacyName = CacheFileNamePolicy.legacySanitized(path: song.filePath)
        let temp = FileManager.default.temporaryDirectory
        let namespace = MusicSourceSecurityRevision.cacheNamespace(for: song.sourceID)
        func scoped(_ root: String) -> URL {
            temp.appendingPathComponent(root)
                .appendingPathComponent(song.sourceID)
                .appendingPathComponent(namespace)
        }
        let candidates = [
            scoped("primuse_smb_cache").appendingPathComponent(cacheName),
            scoped("primuse_smb_cache").appendingPathComponent(legacyName),
            scoped("primuse_ftp_cache").appendingPathComponent(legacyName),
            scoped("primuse_sftp_cache").appendingPathComponent(cacheName),
            scoped("primuse_sftp_cache").appendingPathComponent(legacyName),
            scoped("primuse_webdav_cache").appendingPathComponent(cacheName),
            temp.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(legacyName),
            FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("primuse_s3_cache")
                .appendingPathComponent(song.sourceID)
                .appendingPathComponent(namespace)
                .appendingPathComponent(cacheName),
        ]
        for url in candidates {
            Self.removeCacheFileFamily(at: url)
        }
    }

    private nonisolated static func removeCacheFileFamily(at url: URL) {
        for candidate in cacheFileFamilyURLs(at: url) {
            try? FileManager.default.removeItem(at: candidate)
        }
    }

    private nonisolated static func cacheFileFamilyExists(at url: URL) -> Bool {
        cacheFileFamilyURLs(at: url).contains {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private nonisolated static func cacheFileFamilyURLs(at url: URL) -> [URL] {
        let partial = URL(fileURLWithPath: url.path + ".partial")
        let refresh = refreshCacheURL(for: url)
        return [
            url,
            URL(fileURLWithPath: url.path + ".installing"),
            partial,
            URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix),
            URL(fileURLWithPath: url.path + ".offline"),
            refresh,
            URL(fileURLWithPath: refresh.path + ".installing"),
            URL(fileURLWithPath: refresh.path + ".offline"),
        ]
    }

    private nonisolated static func refreshCacheURL(for canonical: URL) -> URL {
        URL(fileURLWithPath: canonical.path + ".refresh")
    }

    private nonisolated static func sourceID(in namespacedPath: String, separator: Character) -> String {
        guard let separatorIndex = namespacedPath.firstIndex(of: separator) else {
            return namespacedPath
        }
        return String(namespacedPath[..<separatorIndex])
    }

    private nonisolated static func removeRefreshCacheFiles(at canonical: URL) {
        let refresh = refreshCacheURL(for: canonical)
        try? FileManager.default.removeItem(at: refresh)
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: refresh.path + ".installing")
        )
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: refresh.path + ".offline")
        )
    }

    private nonisolated static func refreshCacheFilesExist(at canonical: URL) -> Bool {
        let refresh = refreshCacheURL(for: canonical)
        return FileManager.default.fileExists(atPath: refresh.path)
            || FileManager.default.fileExists(atPath: refresh.path + ".installing")
            || FileManager.default.fileExists(atPath: refresh.path + ".offline")
    }

    func deleteSourceCaches(sourceID: String) {
        deleteSourceCaches(sourceIDs: [sourceID])
    }

    func deleteSourceCaches(sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        preservingAutomaticRefreshPaths = preservingAutomaticRefreshPaths.filter { path in
            !sourceIDs.contains(Self.sourceID(in: path, separator: "/"))
        }
        contentChangeProtectionPendingPaths = contentChangeProtectionPendingPaths.filter { path in
            !sourceIDs.contains(Self.sourceID(in: path, separator: "/"))
        }
        contentChangeInvalidationGenerationByPath = contentChangeInvalidationGenerationByPath.filter { path, _ in
            !sourceIDs.contains(Self.sourceID(in: path, separator: "/"))
        }
        blockedUntrustedAudioCachePaths = blockedUntrustedAudioCachePaths.filter { path in
            !sourceIDs.contains(Self.sourceID(in: path, separator: "/"))
        }
        for record in backgroundAudioCacheTasks.values where sourceIDs.contains(record.sourceID) {
            record.task.cancel()
        }
        let offlineTaskKeys = offlineDownloadTasks.keys.filter {
            sourceIDs.contains(Self.sourceID(in: $0, separator: "/"))
        }
        for key in offlineTaskKeys {
            offlineDownloadTasks[key]?.task.cancel()
            offlineDownloadTasks[key] = nil
        }
        automaticPlaylistPinnedSongsByID = automaticPlaylistPinnedSongsByID.filter {
            !sourceIDs.contains($0.value.sourceID)
        }
        let paths = sourceIDs.flatMap(Self.perSourceCacheDirs(sourceID:))
        // Rename each live directory before scheduling recursive cleanup.
        // Same-volume moves are metadata operations, so even a multi-GB source
        // leaves the active namespace quickly. A restored/re-added source can
        // then create a fresh canonical directory that this cleanup cannot
        // accidentally remove.
        let stagedPaths = Self.stageCacheDirectoriesForDeletion(paths)
        Task.detached(priority: .background) { [stagedPaths, sourceIDs] in
            await AudioCacheManager.shared.removeAllEntries(
                forSourcePrefixes: sourceIDs.map { "\($0)/" }
            )
            Self.deleteStagedCacheDirectories(stagedPaths)
        }
    }

    /// Detach active cache trees with same-parent renames before recursive
    /// deletion. Failed renames are left in place: leaking an OS-reclaimable
    /// cache is safer than a delayed delete racing a newly restored source.
    nonisolated static func stageCacheDirectoriesForDeletion(_ paths: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var staged: [URL] = []
        staged.reserveCapacity(paths.count)
        for path in paths where fileManager.fileExists(atPath: path.path) {
            let destination = path.deletingLastPathComponent().appendingPathComponent(
                ".primuse-deleting-\(path.lastPathComponent)-\(UUID().uuidString)",
                isDirectory: true
            )
            do {
                try fileManager.moveItem(at: path, to: destination)
                staged.append(destination)
            } catch {
                plog("⚠️ Source cache detach deferred: \(error.localizedDescription)")
            }
        }
        return staged
    }

    nonisolated static func deleteStagedCacheDirectories(_ paths: [URL]) {
        let fileManager = FileManager.default
        for path in paths {
            autoreleasepool {
                try? fileManager.removeItem(at: path)
            }
        }
    }

    /// 清空所有音频缓存。返回 (成功删除字节数, 失败文件数)。
    ///
    /// 之前的版本对整个目录调一次 removeItem(at:), 任何一个文件 handle
    /// 没释放 (audio engine 正在读, NSURLSession 还在写) 就整个失败,
    /// `try?` 又吞错误 — 用户以为清了实际没动。现在先递归枚举每个文件
    /// 单独删, 把 in-flight 文件之外的都干掉, 只对 cache 目录的整个
    /// removeItem 是 best-effort 的最后一步。
    @discardableResult
    func clearAudioCache() async -> (freedBytes: Int64, failedCount: Int) {
        cancelBackgroundAudioCaching(keeping: [])
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
        var freed: Int64 = 0
        var failed = 0
        let pinnedRelativePaths = await AudioCacheManager.shared.pinnedRelativePaths()

        for dir in [basePath, Self.smbCacheDir] {
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            // 先收集再删, 避免 enumerator 边删边遍历崩。
            var files: [(URL, Int64)] = []
            while let fileURL = enumerator.nextObject() as? URL {
                guard let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                if fileURL.path.hasPrefix(basePath.path + "/") {
                    let relative = String(fileURL.path.dropFirst(basePath.path.count + 1))
                    if pinnedRelativePaths.contains(relative) {
                        continue
                    }
                }
                files.append((fileURL, Int64(values.totalFileAllocatedSize ?? 0)))
            }
            for (url, size) in files {
                do {
                    try FileManager.default.removeItem(at: url)
                    freed += size
                } catch {
                    failed += 1
                    plog("⚠️ clearAudioCache: cannot remove \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // 文件都删完了, 临时目录可以一把删掉。主 audio cache 目录里可能
            // 还保留离线固定文件, 不能递归删目录。
            if dir == Self.smbCacheDir {
                try? FileManager.default.removeItem(at: dir)
            }
        }

        await AudioCacheManager.shared.clearUnpinnedAccessEntries()
        plog("🧹 clearAudioCache: freed \(freed / 1024 / 1024)MB, failed=\(failed)")
        return (freed, failed)
    }

    /// 启动时清掉超过 `olderThanDays` 没动的 `.partial` 半成品 + 对应的
    /// `.partial.prewarmed` marker。这些文件平时无人管 —— Range streaming
    /// 路径只在歌完整下完后 rename, 用户跳过 / prewarm 完没接着播的歌
    /// 会留下一堆 `.partial` 永久占盘。LRU 也只盯 final 文件, 看不到
    /// `.partial`。
    ///
    /// 只清 mtime 超过阈值的, 现在正在 streaming 的 `.partial` (mtime
    /// 是新的) 不会被误删。
    @discardableResult
    nonisolated static func pruneStalePartialFiles(olderThanDays days: Int = 7) -> Bool {
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
        guard let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return true }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var removedBytes: Int64 = 0
        var removedCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
            guard !withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) else {
                return false
            }
            let name = fileURL.lastPathComponent
            guard name.hasSuffix(".partial") || name.hasSuffix(".partial.prewarmed") else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey]),
                  let mtime = values.contentModificationDate,
                  mtime < cutoff else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? 0)
            if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                removedBytes += size
                removedCount += 1
            }
        }
        if removedCount > 0 {
            let mb = Double(removedBytes) / 1_048_576
            plog("🧹 pruned \(removedCount) stale .partial files (\(String(format: "%.1f", mb)) MB)")
        }
        return true
    }

    /// 删除指定 source 的整个 audio cache 子目录 + LRU 里属于这个源的记录。
    /// 只在 LibraryService.removeSource() 流程里用 —— 用户主动删源时一并
    /// 回收磁盘, 不然 caches/primuse_audio_cache/<sourceID>/ 里的整本歌
    /// + `.partial` 半成品永远没人动。
    func purgeAudioCache(forSourceID sourceID: String) {
        preservingAutomaticRefreshPaths = preservingAutomaticRefreshPaths.filter {
            !$0.hasPrefix("\(sourceID)/")
        }
        contentChangeProtectionPendingPaths = contentChangeProtectionPendingPaths.filter {
            !$0.hasPrefix("\(sourceID)/")
        }
        contentChangeInvalidationGenerationByPath = contentChangeInvalidationGenerationByPath.filter {
            !$0.key.hasPrefix("\(sourceID)/")
        }
        blockedUntrustedAudioCachePaths = blockedUntrustedAudioCachePaths.filter {
            !$0.hasPrefix("\(sourceID)/")
        }
        for record in backgroundAudioCacheTasks.values where record.sourceID == sourceID {
            record.task.cancel()
        }
        let dir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.removeItem(at: dir)
        Task { await AudioCacheManager.shared.removeAllEntries(forSourcePrefix: "\(sourceID)/") }
    }

    /// Starts single-flight cache work for a song without waiting for it.
    /// Streamable Range formats only seed their sparse head/tail cache. Formats
    /// that require a complete local file (notably DTS/FFmpeg) materialize the
    /// canonical audio cache so switching tracks can reuse the finished file.
    func cacheInBackground(song: Song, cacheEnabled: Bool = true) {
        _ = backgroundAudioCacheTask(for: song, cacheEnabled: cacheEnabled)
    }

    /// Queue prefetch awaits each song in order so a large complete-file format
    /// cannot split bandwidth with the second and third queued tracks.
    func cacheForUpcomingPlayback(song: Song, cacheEnabled: Bool = true) async {
        guard let task = backgroundAudioCacheTask(for: song, cacheEnabled: cacheEnabled) else { return }
        await task.value
    }

    /// If a user selects a song while its prefetch is still running, join that
    /// transfer instead of starting a duplicate foreground full download.
    func waitForBackgroundAudioCache(for song: Song) async {
        let record = backgroundAudioCacheTasks[song.id]
        let hasUsableCachedAudio = cachedURL(for: song) != nil
        guard OfflinePlaybackPolicy.shouldWaitForBackgroundCache(
            hasUsableCachedAudio: hasUsableCachedAudio,
            hasInFlightTask: record != nil
        ), let task = record?.task else {
            if hasUsableCachedAudio {
                record?.task.cancel()
            }
            return
        }
        plog("↩️ Cache: joining in-flight prefetch for '\(song.title)'")
        await task.value
    }

    func cancelBackgroundAudioCaching(keeping songIDs: Set<String>) {
        for (songID, record) in backgroundAudioCacheTasks where !songIDs.contains(songID) {
            record.task.cancel()
        }
    }

    func setAutomaticAudioCachingEnabled(_ enabled: Bool) {
        guard automaticAudioCachingEnabled != enabled else { return }
        automaticAudioCachingEnabled = enabled
        guard !enabled else { return }
        cancelBackgroundAudioCaching(keeping: [])
        CloudPlaybackSource.disablePersistenceForActiveSessions()
    }

    private func backgroundAudioCacheTask(
        for song: Song,
        cacheEnabled: Bool
    ) -> Task<Void, Never>? {
        guard cacheEnabled,
              automaticAudioCachingEnabled,
              audioCacheReadsAreAllowed(for: song.sourceID),
              cachedURL(for: song) == nil,
              offlineDownloadTasks[audioCacheRelativePath(for: song)] == nil else { return nil }
        if let record = backgroundAudioCacheTasks[song.id] {
            return record.task
        }

        let runID = UUID()
        let task = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            await self.performBackgroundAudioCache(song: song, cacheEnabled: cacheEnabled)
            self.finishBackgroundAudioCacheTask(songID: song.id, runID: runID)
        }
        backgroundAudioCacheTasks[song.id] = BackgroundAudioCacheTaskRecord(
            id: runID,
            sourceID: song.sourceID,
            taskKey: audioCacheRelativePath(for: song),
            task: task
        )
        return task
    }

    private func finishBackgroundAudioCacheTask(songID: String, runID: UUID) {
        guard backgroundAudioCacheTasks[songID]?.id == runID else { return }
        backgroundAudioCacheTasks[songID] = nil
    }

    private func performBackgroundAudioCache(song: Song, cacheEnabled: Bool) async {
        do {
            try Task.checkCancellation()
            guard await ensureAudioCacheScopeValidated(for: song.sourceID) else { return }
            guard cachedURL(for: song) == nil else { return }

            let sources = try await sourcesProvider()
            guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                plog("⚠️ Cache: source not found for '\(song.title)'")
                return
            }

            // Local-source audio is already the durable local file. Copying it
            // into the remote/offline cache only duplicates storage.
            guard source.type != .local else { return }
            guard RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: source.type) else {
                plog("⏩ Cache: skip \(source.type.rawValue) prewarm for '\(song.title)' (foreground Range playback keeps priority)")
                return
            }

            let usesRangeStreaming = shouldUseRangeStreamingForPlayback(source: source, song: song)
            let mode = RangeStreamingPrefetchPolicy.backgroundCacheMode(
                cacheEnabled: cacheEnabled,
                supportsRangeStreaming: source.supportsRangeStreaming,
                hasKnownFileSize: song.fileSize > 0,
                usesRangeStreamingForPlayback: usesRangeStreaming,
                requiresCompleteLocalFile: FileFormatRouter.requiresCompleteLocalFile(song.fileFormat)
            )
            guard mode != .disabled else {
                plog("⏩ Cache: skip full prefetch for '\(song.title)' (\(source.type.displayName) demand-stream policy)")
                return
            }

            let conn = connector(for: source)
            try await conn.connect()
            try Task.checkCancellation()

            switch mode {
            case .disabled:
                return
            case .rangePrewarm:
                await prewarmCloudSong(song: song, connector: conn)
            case .completeFile:
                _ = await performOfflineDownload(song)
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                plog("↩️ Cache prefetch cancelled for '\(song.title)'")
            } else {
                plog("⚠️ Cache failed for '\(song.title)': \(error.localizedDescription)")
            }
        }
    }

    private func prepareOfflineTransferCapacity(
        expectedSize: Int64,
        lease: AudioCachePathLease,
        respectsConfiguredCacheLimit: Bool = true
    ) async throws -> Int64 {
        let maximum = try await offlineTransferMaximumBytes(
            expectedSize: expectedSize,
            lease: lease,
            respectsConfiguredCacheLimit: respectsConfiguredCacheLimit
        )
        if respectsConfiguredCacheLimit {
            guard await AudioCacheManager.shared.evictIfNeeded(reserveBytes: 0) else {
                throw OfflineTransferValidationError.insufficientCapacity(
                    required: maximum,
                    available: 0
                )
            }
        }
        return maximum
    }

    private func remoteFileSize(
        at path: String,
        connector: any MusicSourceConnector
    ) async throws -> Int64 {
        let parent = (path as NSString).deletingLastPathComponent
        let listingPath = parent.isEmpty ? "/" : parent
        let targetPath = Self.normalizedRemotePath(path)
        let targetName = (path as NSString).lastPathComponent
        let items = try await connector.listFiles(at: listingPath)
        guard let item = items.first(where: {
            !$0.isDirectory && Self.normalizedRemotePath($0.path) == targetPath
        }) ?? items.first(where: {
            !$0.isDirectory && $0.name == targetName
        }) else {
            throw SourceError.fileNotFound(path)
        }
        guard item.size > 0 else {
            throw AutomaticOfflineTransferDeferralError.unboundedAutomaticTransfer
        }
        return item.size
    }

    private func offlineTransferMaximumBytes(
        expectedSize: Int64,
        lease: AudioCachePathLease,
        respectsConfiguredCacheLimit: Bool
    ) async throws -> Int64 {
        let availableDiskBytes = Self.availableAudioCacheDiskBytes()
        let minimum = OfflineTransferSizePolicy.minimumAllowedBytes(
            expectedSize: expectedSize
        )
        let requiredCapacity = expectedSize > 0 ? expectedSize : max(1, minimum)
        let approval = await AudioCacheManager.shared.approveTransferReservation(
            lease,
            expectedSize: expectedSize,
            physicalAvailableBytes: availableDiskBytes,
            minimumRequiredBytes: requiredCapacity,
            respectsConfiguredCacheLimit: respectsConfiguredCacheLimit
        )
        let maximum: Int64
        switch approval {
        case .approved(let approved):
            maximum = approved
        case .invalidLease:
            throw AutomaticOfflineTransferDeferralError.artifactLeased
        case .insufficientCapacity(let available):
            throw OfflineTransferValidationError.insufficientCapacity(
                required: requiredCapacity,
                available: available
            )
        }
        guard maximum > 0, maximum >= requiredCapacity else {
            throw OfflineTransferValidationError.insufficientCapacity(
                required: requiredCapacity,
                available: maximum
            )
        }
        return maximum
    }

    private nonisolated static func availableAudioCacheDiskBytes() -> Int64 {
        let base = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        guard let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: base.path
        ), let value = attributes[.systemFreeSize] as? NSNumber else { return 0 }
        return value.int64Value
    }

    private nonisolated static func validateCompleteCacheFile(
        at url: URL,
        expectedSize: Int64,
        maximumBytes: Int64? = nil
    ) throws {
        let actualSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        try OfflineTransferSizePolicy.validate(
            actualSize: actualSize,
            expectedSize: expectedSize,
            maximumBytes: maximumBytes
        )
    }

    private nonisolated static func installCacheFile(
        from source: URL,
        to target: URL,
        move: Bool
    ) throws {
        try OfflineCacheAtomicReplacement.install(
            source: source,
            target: target,
            move: move
        )
    }

    /// Prewarm a cloud song so the next "play" is instant:
    /// - Resolve and cache the dlink (saves the 200-500ms multi-API round trip)
    /// - Pull the first 256KB into the `.partial` cache file
    ///
    /// `CloudPlaybackSource` recognises a `.partial` file at exactly the
    /// prewarm head size as a trustworthy seed and re-uses the bytes when
    /// the actual play session starts — so the very first SFB read hits
    /// disk, not the network. Idempotent on repeat calls.
    private func prewarmCloudSong(song: Song, connector: any MusicSourceConnector) async {
        guard automaticAudioCachingEnabled else { return }
        if isPrewarmed(song: song) { return }
        let fileSize = song.fileSize
        guard fileSize > 0 else { return }
        let seedSize = min(fileSize, Self.prewarmHeadSize + Self.prewarmTailSize)
        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
            path: audioCacheRelativePath(for: song),
            reserveBytes: 0
        ) else { return }
        guard audioCacheReadsAreAllowed(for: song.sourceID) else {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            return
        }
        defer {
            Task {
                await AudioCacheManager.shared.releasePathFamilyLease(lease)
            }
        }
        guard (try? await prepareOfflineTransferCapacity(
            expectedSize: seedSize,
            lease: lease
        )) != nil else {
            return
        }
        do {
            // 并发拉 head + tail —— SFB.open() 必读 mp3 ID3v1 (tail 128B),
            // 不预热 tail 就会触发 1-2s 的 user-facing fetch 卡顿。
            // 短文件 (head + tail overlap) 时 tail 直接为空。
            let tailSize = min(Self.prewarmTailSize, max(0, fileSize - Self.prewarmHeadSize))
            async let headData = connector.fetchRange(
                path: song.filePath,
                offset: 0,
                length: Self.prewarmHeadSize,
                priority: .background
            )
            async let tailData: Data = tailSize > 0
                ? connector.fetchRange(
                    path: song.filePath,
                    offset: fileSize - tailSize,
                    length: tailSize,
                    priority: .background
                )
                : Data()
            let (head, tail) = try await (headData, tailData)
            try Task.checkCancellation()
            guard automaticAudioCachingEnabled else { return }
            seedPrewarmCache(song: song, head: head, tail: tail, fileSize: fileSize)
        } catch {
            if Task.isCancelled {
                plog("↩️ Prewarm cancelled for '\(song.title)'")
            } else {
                plog("⚠️ Prewarm failed for '\(song.title)': \(error.localizedDescription)")
            }
        }
    }

    static let prewarmHeadSize: Int64 = CloudPlaybackSource.prewarmHeadBytes
    static let prewarmTailSize: Int64 = CloudPlaybackSource.prewarmTailBytes

    /// Same as `prewarmCloudSong` but accepts a Song directly and resolves
    /// the connector itself. Exposed so `ScanService` can run a serialized
    /// prewarm sweep over every cloud song in a fresh scan (avoiding the
    /// fire-and-forget `cacheInBackground` which spawns one Task per song
    /// and would stampede the connector).
    func prewarmCloudSongPublic(song: Song) async {
        guard automaticAudioCachingEnabled,
              await ensureAudioCacheScopeValidated(for: song.sourceID),
              let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }),
              shouldUseRangeStreamingForPlayback(source: source, song: song) else { return }
        guard RangeStreamingPrefetchPolicy.allowsBackgroundPrewarm(for: source.type) else { return }
        let conn = connector(for: source)
        do { try await conn.connect() } catch { return }
        await prewarmCloudSong(song: song, connector: conn)
    }

    /// 主动结束 `song` 对应的 streaming session: 把 .partial 推向 final
    /// (如果缺口在自动补齐阈值内) 或者保持原状。AudioPlayerService 在
    /// 切歌 / stop / 播完时调, 让 .partial 不依赖 SFB 是否还会读字节就能
    /// 走完应有的 rename 路径。缓存关闭时还要 unregister temp session,
    /// 避免 registry 持有已结束的临时流。
    func finalizeStreamingSession(for song: Song) {
        guard playbackAudioCacheLeaseFinalizations[song.id] == nil else { return }

        var trailingFills: [Task<Void, Never>] = []
        let cache = cacheURL(for: song)
        if let fill = CloudPlaybackSource.finalizeSession(
            partialPath: cache.path + ".partial"
        ) {
            trailingFills.append(fill)
        }

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        for prefix in ["primuse-stream", "primuse-http"] {
            let partialPath = tempDir
                .appendingPathComponent("\(prefix)-\(song.id)")
                .path + ".partial"
            if let fill = CloudPlaybackSource.finalizeSession(partialPath: partialPath) {
                trailingFills.append(fill)
            }
        }

        guard let leaseRecord = playbackAudioCacheLeases[song.id] else { return }
        guard !trailingFills.isEmpty else {
            releaseAudioCacheLeaseForPlayback(
                songID: song.id,
                expectedGeneration: leaseRecord.generation
            )
            return
        }

        let finalizationID = UUID()
        let generation = leaseRecord.generation
        let finalizedTrailingFills = trailingFills
        let finalizationTask = Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                for fill in finalizedTrailingFills {
                    await fill.value
                }
            } onCancel: {
                finalizedTrailingFills.forEach { $0.cancel() }
            }
            guard let self,
                  let current = self.playbackAudioCacheLeaseFinalizations[song.id],
                  current.id == finalizationID,
                  current.generation == generation else { return }
            self.playbackAudioCacheLeaseFinalizations[song.id] = nil
            self.releaseAudioCacheLeaseForPlayback(
                songID: song.id,
                expectedGeneration: generation
            )
        }
        playbackAudioCacheLeaseFinalizations[song.id] = PlaybackAudioCacheLeaseFinalization(
            id: finalizationID,
            generation: generation,
            sourceID: song.sourceID,
            task: finalizationTask
        )
    }

    func cancelStreamingSessionForMaterialization(
        for song: Song,
        expectedStreamEpoch streamEpoch: UInt64
    ) async -> Bool {
        let canonical = cacheURL(for: song)
        let cachePartial = URL(fileURLWithPath: canonical.path + ".partial")
        guard await CloudPlaybackSource.retireSessionForMaterialization(
            sourceID: song.sourceID,
            streamEpoch: streamEpoch,
            partialPath: cachePartial.path
        ) else { return false }
        let tempDir = FileManager.default.temporaryDirectory
        for prefix in ["primuse-stream", "primuse-http"] {
            let partial = URL(fileURLWithPath: tempDir
                .appendingPathComponent("\(prefix)-\(song.id)")
                .path + ".partial")
            guard await CloudPlaybackSource.retireSessionForMaterialization(
                sourceID: song.sourceID,
                streamEpoch: streamEpoch,
                partialPath: partial.path
            ) else { return false }
        }
        await AudioCacheManager.shared.refreshPathFamily(
            path: audioCacheRelativePath(for: song)
        )
        return CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: streamEpoch
        )
    }

    func prepareHTTPStreamingCache(
        for song: Song,
        prefersPersistentCache: Bool
    ) async -> (
        url: URL,
        relativePath: String?,
        persistOnComplete: Bool,
        maximumTransferBytes: Int64
    )? {
        if prefersPersistentCache,
           await ensureAudioCacheScopeValidated(for: song.sourceID),
           await retainAudioCacheLeaseForPlayback(
               song,
               reserveBytes: song.fileSize,
               mode: .persistentCache,
               requiresTransferReservation: true
           ),
           let maximum = playbackAudioCacheLeases[song.id]?.maximumTransferBytes {
            return (
                cacheURL(for: song),
                audioCacheRelativePath(for: song),
                true,
                maximum
            )
        }

        // The sparse decoder file lives on the same data volume as Caches.
        // Even a non-persistent playback therefore reserves its worst-case
        // physical growth before the first byte is written; this reservation
        // deliberately ignores the configured cache limit but still preserves
        // global disk headroom and all concurrent reservations.
        let physicalMode: PlaybackAudioCacheReservationMode =
            playbackAudioCacheLeases[song.id]?.mode == .canonicalPhysical
                || (!prefersPersistentCache
                    && playbackAudioCacheLeases[song.id]?.mode.usesCanonicalStorage == true)
            ? .canonicalPhysical
            : .temporaryPhysical
        guard await retainAudioCacheLeaseForPlayback(
            song,
            reserveBytes: song.fileSize,
            mode: physicalMode,
            requiresTransferReservation: true
        ), let maximum = playbackAudioCacheLeases[song.id]?.maximumTransferBytes else {
            return nil
        }
        return (
            physicalMode.usesCanonicalStorage
                ? cacheURL(for: song)
                : FileManager.default.temporaryDirectory
                    .appendingPathComponent("primuse-http-\(song.id)"),
            nil,
            false,
            maximum
        )
    }

    private func retainAudioCacheLeaseForPlayback(
        _ song: Song,
        reserveBytes: Int64 = 0,
        mode: PlaybackAudioCacheReservationMode = .readOnly,
        requiresTransferReservation: Bool = false
    ) async -> Bool {
        if var existingRecord = playbackAudioCacheLeases[song.id] {
            // One lease protects exactly one sparse-file storage location for
            // its lifetime. A persistent canonical writer may drop only its
            // configured-cache charge while retaining the same physical path.
            if existingRecord.mode != mode {
                // Turning automatic caching off mid-track converts the live
                // sparse writer into a temporary session. Preserve the same
                // physical reservation and lease so an immediate seek/recovery
                // cannot fail merely because persistence was disabled.
                guard existingRecord.mode == .persistentCache,
                      mode == .canonicalPhysical,
                      await AudioCacheManager.shared
                          .downgradeTransferReservationToPhysicalOnly(
                              existingRecord.lease
                          ),
                      var currentRecord = playbackAudioCacheLeases[song.id],
                      currentRecord.lease == existingRecord.lease,
                      currentRecord.mode == .persistentCache
                        || currentRecord.mode == .canonicalPhysical else {
                    return false
                }
                if currentRecord.mode == .persistentCache {
                    currentRecord.mode = .canonicalPhysical
                    playbackAudioCacheLeases[song.id] = currentRecord
                }
                existingRecord = currentRecord
            }
            if mode != .temporaryPhysical,
               !audioCacheReadsAreAllowed(for: song.sourceID) {
                return false
            }
            var approvedMaximum = existingRecord.maximumTransferBytes
            if reserveBytes > 0 || requiresTransferReservation {
                guard let maximum = try? await prepareOfflineTransferCapacity(
                   expectedSize: reserveBytes,
                   lease: existingRecord.lease,
                   respectsConfiguredCacheLimit: mode.respectsConfiguredCacheLimit
                ) else { return false }
                approvedMaximum = maximum
            }
            // Capacity checks above can yield. A finalizer or security-scope
            // change may have retired the snapshot while we were waiting.
            guard var currentRecord = playbackAudioCacheLeases[song.id],
                  currentRecord.lease == existingRecord.lease,
                  currentRecord.generation == existingRecord.generation,
                  currentRecord.mode == existingRecord.mode else {
                return false
            }
            var finalizationToAwait: PlaybackAudioCacheLeaseFinalization?
            if let finalization = playbackAudioCacheLeaseFinalizations[song.id],
               finalization.generation == currentRecord.generation {
                playbackAudioCacheLeaseFinalizations[song.id] = nil
                currentRecord.generation &+= 1
                finalizationToAwait = finalization
            }
            currentRecord.maximumTransferBytes = approvedMaximum
            playbackAudioCacheLeases[song.id] = currentRecord
            if let finalizationToAwait {
                finalizationToAwait.task.cancel()
                await finalizationToAwait.task.value
                guard let resumedRecord = playbackAudioCacheLeases[song.id],
                      resumedRecord.lease == currentRecord.lease,
                      resumedRecord.generation == currentRecord.generation,
                      resumedRecord.mode == currentRecord.mode else {
                    return false
                }
            }
            return true
        }
        let relativePath = audioCacheRelativePath(for: song)
        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(
            path: relativePath,
            reserveBytes: 0
        ) else { return false }
        guard !mode.usesCanonicalStorage
                || audioCacheReadsAreAllowed(for: song.sourceID) else {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            return false
        }
        var approvedMaximum: Int64?
        if reserveBytes > 0 || requiresTransferReservation {
            guard let maximum = try? await prepareOfflineTransferCapacity(
               expectedSize: reserveBytes,
               lease: lease,
               respectsConfiguredCacheLimit: mode.respectsConfiguredCacheLimit
            ) else {
                await AudioCacheManager.shared.releasePathFamilyLease(lease)
                return false
            }
            approvedMaximum = maximum
        }
        playbackAudioCacheLeases[song.id] = PlaybackAudioCacheLeaseRecord(
            lease: lease,
            sourceID: song.sourceID,
            relativePath: relativePath,
            generation: 1,
            mode: mode,
            maximumTransferBytes: approvedMaximum
        )
        activePlaybackAudioCachePaths[relativePath, default: 0] += 1
        return true
    }

    private func cachedURLWithPlaybackLease(for song: Song) async -> URL? {
        if playbackAudioCacheLeases[song.id] != nil {
            return cachedURL(for: song)
        }
        let relativePath = audioCacheRelativePath(for: song)
        guard let lease = await AudioCacheManager.shared.acquirePathFamilyLease(path: relativePath) else {
            return nil
        }
        guard audioCacheReadsAreAllowed(for: song.sourceID) else {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            return nil
        }
        guard let cached = cachedURL(for: song) else {
            await AudioCacheManager.shared.releasePathFamilyLease(lease)
            await removeBlockedArtifactIfPossible(path: relativePath)
            return nil
        }
        playbackAudioCacheLeases[song.id] = PlaybackAudioCacheLeaseRecord(
            lease: lease,
            sourceID: song.sourceID,
            relativePath: relativePath,
            generation: 1,
            mode: .readOnly,
            maximumTransferBytes: nil
        )
        activePlaybackAudioCachePaths[relativePath, default: 0] += 1
        return cached
    }

    private func releaseAudioCacheLeaseForPlayback(
        songID: String,
        expectedGeneration: UInt64? = nil
    ) {
        guard let record = playbackAudioCacheLeases[songID],
              expectedGeneration == nil || record.generation == expectedGeneration else {
            return
        }
        playbackAudioCacheLeases[songID] = nil
        let releasedPath = record.relativePath
        let remaining = max(0, (activePlaybackAudioCachePaths[releasedPath] ?? 1) - 1)
        activePlaybackAudioCachePaths[releasedPath] = remaining == 0 ? nil : remaining
        Task { @MainActor [weak self] in
            await AudioCacheManager.shared.releasePathFamilyLease(record.lease)
            await self?.removeBlockedArtifactIfPossible(path: releasedPath)
        }
    }

    private func releasePlaybackAudioCacheLeases(sourceID: String) {
        let songIDs = playbackAudioCacheLeases.compactMap { songID, record in
            record.sourceID == sourceID ? songID : nil
        }
        for songID in songIDs {
            if let finalization = playbackAudioCacheLeaseFinalizations.removeValue(
                forKey: songID
            ) {
                finalization.task.cancel()
            }
            releaseAudioCacheLeaseForPlayback(songID: songID)
        }
    }

    private func removeBlockedArtifactIfPossible(path: String) async {
        guard blockedUntrustedAudioCachePaths.contains(path),
              !(await AudioCacheManager.shared.isPathFamilyLeased(path: path)) else { return }
        let target = FileManager.default
            .primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(path)
        for url in AutomaticOfflineUntrustedCleanupPolicy.canonicalURLs(for: target) {
            try? FileManager.default.removeItem(at: url)
        }
        await AudioCacheManager.shared.refreshPathFamily(path: path)
    }

    /// True if `song` lives on a source that supports HTTP Range streaming
    /// (i.e. would go through `CloudPlaybackSource` at play time). Used by
    /// metadata backfill to decide whether to seed the prewarm cache —
    /// local/file sources never hit `CloudPlaybackSource`, so writing a
    /// `.partial` for them would waste disk for nothing.
    func songSupportsRangeStreaming(_ song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider() else { return false }
        return sources.first(where: { $0.id == song.sourceID })?.supportsRangeStreaming ?? false
    }

    /// Already-prewarmed marker check. Marker JSON 存在 + partial 文件
    /// 大小覆盖所有 listed ranges + head range 长度 >= 当前 prewarmHeadSize
    /// 才算 prewarm。head 长度检查让 prewarm head 调大后旧 partial 自然
    /// 重新 prewarm (不会被旧 256KB head 短路)。
    func isPrewarmed(song: Song) -> Bool {
        guard audioCacheReadsAreAllowed(for: song.sourceID) else { return false }
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)
        guard let m = CloudPlaybackSource.PrewarmMarker.read(from: marker),
              FileManager.default.fileExists(atPath: partial.path),
              let attrs = try? FileManager.default.attributesOfItem(atPath: partial.path),
              let size = attrs[.size] as? Int64,
              let maxEnd = m.swiftRanges.map(\.upperBound).max(),
              size >= maxEnd,
              let firstRange = m.swiftRanges.first,
              firstRange.lowerBound == 0,
              (firstRange.upperBound - firstRange.lowerBound) >= Self.prewarmHeadSize
        else { return false }
        return true
    }

    /// 兼容旧调用方 (MetadataBackfillService 拿到 head bytes 时只 seed head)。
    /// 新代码应使用 `seedPrewarmCache(song:head:tail:fileSize:)`。
    func seedPrewarmCache(song: Song, head: Data) {
        seedPrewarmCache(song: song, head: head, tail: Data(), fileSize: 0)
    }

    /// Write `head` (+ optional `tail`) to the song's sparse `.partial` cache
    /// and place the prewarm marker JSON. Used by `prewarmCloudSong` and
    /// MetadataBackfillService (head-only, via the compatibility overload).
    /// fileSize=0 means "tail unknown, only seed head".
    func seedPrewarmCache(song: Song, head: Data, tail: Data, fileSize: Int64) {
        guard automaticAudioCachingEnabled,
              audioCacheReadsAreAllowed(for: song.sourceID),
              !head.isEmpty else { return }
        let cache = cacheURL(for: song)
        let partial = URL(fileURLWithPath: cache.path + ".partial")
        let marker = URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix)

        // Already seeded with at least equivalent ranges? Skip.
        if isPrewarmed(song: song) {
            return
        }

        try? FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: marker)

        do {
            // 写 sparse partial: head 在 offset 0, tail 在 fileSize-tail.count
            // (中间 byte hole, file system 自动 sparse, 不占实际空间)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            let handle = try FileHandle(forWritingTo: partial)
            try handle.write(contentsOf: head)
            var ranges: [[Int64]] = [[0, Int64(head.count)]]
            if !tail.isEmpty, fileSize > Int64(head.count) {
                let tailOffset = fileSize - Int64(tail.count)
                if tailOffset >= Int64(head.count) {  // 不覆盖 head
                    try handle.seek(toOffset: UInt64(tailOffset))
                    try handle.write(contentsOf: tail)
                    ranges.append([tailOffset, fileSize])
                }
            }
            try handle.close()
            // marker JSON 必须最后写 —— 如果中间崩溃, 没 marker 就不信任 partial。
            let m = CloudPlaybackSource.PrewarmMarker(v: CloudPlaybackSource.PrewarmMarker.currentVersion, ranges: ranges)
            try m.write(to: marker)
            plog("⏩ Prewarm: '\(song.title)' head=\(head.count / 1024)KB tail=\(tail.count / 1024)KB cached")
        } catch {
            plog("⚠️ Prewarm seed failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    /// Build a streaming `SFBInputSource` for `song`. Used by
    /// AudioPlayerService when `resolveURL` returns a `primuse-stream://`
    /// URL. The returned source reads via HTTP Range and writes fetched
    /// chunks to the same cache file used by `localURL` — once enough
    /// ranges accumulate (or the user replays after a full listen) the
    /// next play hits Priority 1 above and bypasses streaming entirely.
    /// When `cacheEnabled` is false (the user disabled Audio Cache), the
    /// streaming partial is routed to `NSTemporaryDirectory` and is never
    /// promoted to the canonical cache path — the file is still needed
    /// during the session for SFB to read from, then it is deleted when the
    /// playback session ends.
    func makeStreamingInputSource(
        for song: Song,
        cacheEnabled: Bool = true,
        expectedStreamEpoch streamEpoch: UInt64
    ) async throws -> InputSource? {
        let scopeValidated = await ensureAudioCacheScopeValidated(for: song.sourceID)
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: streamEpoch
        ) else { return nil }
        var persistentCacheAllowed = cacheEnabled && scopeValidated
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == song.sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        guard !song.isStreamDescriptor else { return nil }
        let conn = connector(for: source)
        try await conn.connect()
        guard song.fileSize > 0,
              await sourceScopeIsCurrent(
                sourceID: source.id,
                expectedScope: expectedScope
              ),
              CloudPlaybackSource.isStreamEpochTicketCurrent(
                sourceID: song.sourceID,
                ticket: streamEpoch
              ) else { return nil }
        // Reserve both physical and configured-cache capacity before writing
        // a persistent sparse file. A temporary sparse file still needs a
        // physical-only reservation because it shares the same data volume.
        let cacheRelativePath: String?
        var physicalMode: PlaybackAudioCacheReservationMode = .temporaryPhysical
        if persistentCacheAllowed {
            let retained = await retainAudioCacheLeaseForPlayback(
                song,
                reserveBytes: song.fileSize,
                mode: .persistentCache
            )
            if !retained {
                persistentCacheAllowed = false
            }
        }
        if !persistentCacheAllowed {
            physicalMode = playbackAudioCacheLeases[song.id]?.mode == .canonicalPhysical
                || (playbackAudioCacheLeases[song.id]?.mode.usesCanonicalStorage == true
                    && !cacheEnabled)
                ? .canonicalPhysical
                : .temporaryPhysical
            guard await retainAudioCacheLeaseForPlayback(
                song,
                reserveBytes: song.fileSize,
                mode: physicalMode
            ) else {
                throw OfflineTransferValidationError.insufficientCapacity(
                    required: song.fileSize,
                    available: 0
                )
            }
        }
        let cache: URL
        if persistentCacheAllowed {
            cacheRelativePath = audioCacheRelativePath(for: song)
            cache = cacheURL(for: song)
        } else if physicalMode.usesCanonicalStorage {
            // Keep a cache-off rebuild on the original sparse path. The
            // writer-token replacement below then retires the old canonical
            // writer before the new one starts, so one physical reservation
            // never covers both canonical and NSTemporaryDirectory copies.
            cacheRelativePath = nil
            cache = cacheURL(for: song)
        } else {
            cacheRelativePath = nil
            cache = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("primuse-stream-\(song.id)")
        }

        let prefetchAhead = RangeStreamingPrefetchPolicy.aheadCount(
            for: source.type,
            defaultValue: CloudPlaybackSource.prefetchAhead
        )
        let allowsTrailingFill = RangeStreamingPrefetchPolicy
            .allowsAutomaticTrailingFill(for: source.type)
        if prefetchAhead < CloudPlaybackSource.prefetchAhead {
            plog("☁️ \(source.type.rawValue) streaming: background chunk prefetch limited to \(prefetchAhead) for '\(song.title)'")
        }

        guard await sourceScopeIsCurrent(
            sourceID: source.id,
            expectedScope: expectedScope
        ), CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: song.sourceID,
            ticket: streamEpoch
        ) else {
            releaseAudioCacheLeaseForPlayback(songID: song.id)
            return nil
        }

        let inputSource = CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            streamEpoch: streamEpoch,
            persistOnComplete: persistentCacheAllowed,
            cacheRelativePath: cacheRelativePath,
            prefetchAhead: prefetchAhead,
            allowsTrailingFill: allowsTrailingFill
        )
        if inputSource == nil {
            releaseAudioCacheLeaseForPlayback(songID: song.id)
        }
        return inputSource
    }

    /// Metadata reads use the same runtime STRM resolution as playback. This
    /// prevents the backfill worker from parsing the wrapper text as audio and
    /// keeps signed URLs out of the persisted Song model.
    func fetchMetadataRange(
        for song: Song,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent = .bulkBounded
    ) async throws -> Data {
        let connector = try await connectorForSong(song)
        guard song.isStreamDescriptor else {
            return try await connector.fetchMetadataRange(
                path: song.filePath,
                offset: offset,
                length: length,
                intent: intent
            )
        }
        switch try await resolveSTRMTarget(for: song, connector: connector) {
        case .sourcePath(let path):
            return try await connector.fetchMetadataRange(
                path: path,
                offset: offset,
                length: length,
                intent: intent
            )
        case .openListSourcePath(let path, _):
            guard let webDAV = connector as? any OpenListSTRMResolvingConnector else {
                throw SourceError.connectionFailed("OpenList STRM transport unavailable")
            }
            return try await webDAV.fetchOpenListSTRMMetadataRange(
                for: path,
                offset: offset,
                length: length,
                intent: intent
            )
        case .remote(let url):
            return try await Self.fetchRemoteMetadataRange(
                url: url,
                offset: offset,
                length: length,
                intent: intent
            )
        }
    }

    private nonisolated static func fetchRemoteMetadataRange(
        url: URL,
        offset: Int64,
        length: Int64,
        intent: MetadataRangeReadIntent
    ) async throws -> Data {
        guard let range = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        var request = URLRequest(url: url)
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.timeoutInterval = 30

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        let session = URLSession(
            configuration: config,
            delegate: SmartSSLDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let requestedBodyBytes = Int(clamping: max(length, 0))
        let maximumRangedBodyBytes = requestedBodyBytes > Int.max - 64 * 1024
            ? Int.max
            : requestedBodyBytes + 64 * 1024
        let wholeResponsePrefixLimit = WholeResourceMetadataRangePolicy
            .wholeResponsePrefixLimit(
                requestedOffset: offset,
                requestedLength: length
            )
        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: session,
            maximumRangedBodyBytes: maximumRangedBodyBytes,
            wholeResponsePrefixLimit: wholeResponsePrefixLimit
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid STRM metadata response")
        }
        switch http.statusCode {
        case 206:
            let data = try boundedRemoteMetadataSlice(
                temporaryURL,
                offset: 0,
                length: length
            )
            guard HTTPByteRangeResponsePolicy.validatedTotalLength(
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init),
                bodyLength: data.count,
                requestedOffset: offset,
                requestedLength: length
            ) != nil else {
                throw SourceError.connectionFailed("Invalid STRM Content-Range response")
            }
            return data
        case 200:
            switch WholeResourceMetadataRangePolicy.responseDisposition(
                requestedOffset: offset,
                intent: intent
            ) {
            case .consumeBoundedPrefix:
                return try boundedRemoteMetadataSlice(
                    temporaryURL,
                    offset: offset,
                    length: length
                )
            case .rejectSuffixWithoutConsuming:
                throw MetadataRangeReadError.suffixRangeUnsupported
            case .useCompleteFileFallback:
                var wholeRequest = request
                wholeRequest.setValue(nil, forHTTPHeaderField: "Range")
                let (completeURL, completeResponse) = try await TrustedHTTPTransport.download(
                    for: wholeRequest,
                    session: session
                )
                defer { try? FileManager.default.removeItem(at: completeURL) }
                guard let completeHTTP = completeResponse as? HTTPURLResponse,
                      completeHTTP.statusCode == 200 else {
                    throw SourceError.connectionFailed("STRM complete metadata fallback failed")
                }
                return try boundedRemoteMetadataSlice(
                    completeURL,
                    offset: offset,
                    length: length
                )
            }
        default:
            throw SourceError.connectionFailed("STRM metadata range failed: HTTP \(http.statusCode)")
        }
    }

    private nonisolated static func boundedRemoteMetadataSlice(
        _ fileURL: URL,
        offset: Int64,
        length: Int64
    ) throws -> Data {
        guard length > 0 else { return Data() }
        guard offset != Int64.min else { return Data() }
        guard length <= 64 * 1024 * 1024 else {
            throw SourceError.connectionFailed("STRM metadata suffix window is too large")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let total = Int64(clamping: try handle.seekToEnd())
        let start = offset >= 0 ? offset : max(0, total + offset)
        guard start < total else {
            throw SourceError.connectionFailed("STRM metadata response was empty")
        }
        try handle.seek(toOffset: UInt64(start))
        let readLength = Int(clamping: min(length, total - start))
        guard let data = try handle.read(upToCount: readLength), !data.isEmpty else {
            throw SourceError.connectionFailed("STRM metadata response was empty")
        }
        return data
    }

    /// 对支持预授权直链的云盘(目前 OneDrive),返回可整文件下载的 HTTPS 直链。
    /// 大文件用它走「整文件渐进下载」绕开逐 chunk Range —— OneDrive 服务端对大文件
    /// 的分段 Range 会挂死,但整文件直接下载很快。
    func resolveDirectDownloadURL(for song: Song) async -> URL? {
        let sources = (try? await sourcesProvider()) ?? []
        guard let source = sources.first(where: {
            $0.id == song.sourceID && $0.isEnabled && !$0.isDeleted
        }) else { return nil }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        let streamEpoch = CloudPlaybackSource.streamEpochTicket(sourceID: source.id)
        guard (try? await ensureCurrentPlaybackResolutionScope(
            sourceID: source.id,
            expectedScope: expectedScope,
            streamEpoch: streamEpoch
        )) != nil else { return nil }
        let conn = connector(for: source)
        if let oneDrive = conn as? OneDriveSource {
            guard (try? await oneDrive.connect()) != nil,
                  (try? await ensureCurrentPlaybackResolutionScope(
                      sourceID: source.id,
                      expectedScope: expectedScope,
                      streamEpoch: streamEpoch
                  )) != nil,
                  let url = try? await oneDrive.publicDownloadURL(
                      path: song.filePath
                  ),
                  (try? await ensureCurrentPlaybackResolutionScope(
                      sourceID: source.id,
                      expectedScope: expectedScope,
                      streamEpoch: streamEpoch
                  )) != nil else { return nil }
            return url
        }
        return nil
    }

    private func shouldUseRangeStreamingForPlayback(source: MusicSource, song: Song) -> Bool {
        guard source.supportsRangeStreaming, song.fileSize > 0 else { return false }
        // FFmpeg fallback formats need a seekable complete file. Routing them
        // through the generic SFB range InputSource would fail to open or, for
        // a DTS-CD WAV, risk treating the compressed bitstream as PCM noise.
        // Fall through to a direct HTTP URL (full-download decoder) or the
        // connector's localURL download instead.
        if FileFormatRouter.requiresCompleteLocalFile(song.fileFormat) { return false }
        // 服务端转码源: 需要服务端转码的格式(WMA)走渐进流(streamingURL 返回
        // 转码 mp3), 不能按原文件 fileSize 做 Range, 否则会读越界。
        if source.type.isSubsonicFamily, SubsonicSource.requiresServerTranscode(song.fileFormat) {
            return false
        }
        return !shouldPreferPlainStreamingForPlayback(source: source, song: song)
    }

    private func shouldPreferPlainStreamingForPlayback(source: MusicSource, song: Song) -> Bool {
        if source.type.isSubsonicFamily {
            return shouldPreferAuthenticatedSubsonicWANStream(source: source, song: song)
        }

        // With more than one enabled endpoint, connector-backed Range reads
        // keep route failover available after playback has started. A plain
        // URL would permanently bind the player to whichever route produced
        // it, so it is used only for single-route configurations (or the
        // transcoded/unknown-size cases filtered by the caller).
        if source.connectionConfiguration != nil,
           source.connectionCandidates.count > 1 {
            return false
        }
        if source.type.isMediaServer {
            return !requiresConnectorBackedHTTPTransport(for: source)
        }
        guard Self.nasAPIPlainStreamingTypes.contains(source.type),
              song.fileFormat == .mp3 else { return false }

        // A user-approved public cleartext host must stay inside its connector:
        // a direct URL would escape to the player's URLSession and be rejected
        // by ATS. Connector-backed Range reads use TrustedHTTPTransport instead.
        if Self.publicHTTPConnectorStreamingTypes.contains(source.type),
           let host = source.host,
           let url = NetworkURLBuilder.baseURL(
               host: host,
               scheme: source.useSsl ? "https" : "http",
               port: source.port
           ),
           TrustedHTTPTransport.requiresPlainSocket(for: url) {
            return false
        }

        // On cellular / Low Data Mode, prefer a plain HTTP URL over the
        // connector fetchRange path. The player still uses Range reads when
        // fileSize is known, but it avoids connector/API work per chunk.
        if NetworkMonitor.shared.isExpensive || NetworkMonitor.shared.isConstrained {
            return true
        }

        // NAS API sources on a public hostname are usually WAN / reverse-proxy
        // paths. Keep connector-backed Range streaming for LAN IPs and .local
        // hosts where latency is low; use direct HTTP Range for WAN hosts.
        guard let host = source.host, !host.isEmpty else { return false }
        return !Self.isProbablyLocalHost(host)
    }

    /// Navidrome's authenticated `stream` URL is self-contained. On a public
    /// route the generic HTTP playback source is the safer owner: it can
    /// follow a read-only media redirect without forwarding Subsonic query
    /// credentials and can validate a proxy's whole-resource response when
    /// the proxy ignores `Range`. The connector path remains authoritative on
    /// LAN routes, for alternate TLS identities, and for formats that need a
    /// complete local file.
    private func shouldPreferAuthenticatedSubsonicWANStream(
        source: MusicSource,
        song: Song
    ) -> Bool {
        guard source.type.isSubsonicFamily else { return false }

        let usesServerTranscodedStream = SubsonicSource.requiresServerTranscode(
            song.fileFormat
        )
        guard !FileFormatRouter.requiresCompleteLocalFile(song.fileFormat)
                || usesServerTranscodedStream else {
            return false
        }

        let projectedSource: MusicSource
        if source.connectionConfiguration != nil,
           source.connectionCandidates.count > 1 {
            guard let activeKind = activeConnectionRoutes[source.id],
                  activeKind == .publicAddress,
                  let activeCandidate = source.connectionCandidates.first(where: {
                      $0.kind == activeKind
                  }) else {
                return false
            }
            projectedSource = source.applyingConnectionCandidate(activeCandidate)
        } else {
            projectedSource = source
        }

        guard projectedSource.alternateTLSValidationHostname == nil,
              let host = projectedSource.host,
              !host.isEmpty else {
            return false
        }
        return !Self.isProbablyLocalHost(host)
    }

    private static let nasAPIPlainStreamingTypes: Set<MusicSourceType> = [
        .synology,
        .qnap,
        .ugreen,
    ]

    private static let publicHTTPConnectorStreamingTypes: Set<MusicSourceType> = [
        .synology,
        .qnap,
        .ugreen,
    ]

    private func permitsConfiguredDirectURL(
        for source: MusicSource,
        song: Song
    ) -> Bool {
        let usesServerTranscodedStream = source.type.isSubsonicFamily
            && SubsonicSource.requiresServerTranscode(song.fileFormat)
        return ConfiguredSourceDirectURLPolicy.permitsDirectURL(
            requiresCompleteLocalFile: FileFormatRouter.requiresCompleteLocalFile(song.fileFormat),
            usesServerTranscodedStream: usesServerTranscodedStream,
            hasMultipleConnectionRoutes: source.connectionConfiguration != nil
                && source.connectionCandidates.count > 1,
            usesAlternateTLSIdentity: source.alternateTLSValidationHostname != nil
        )
    }

    private func requiresConnectorBackedHTTPTransport(for source: MusicSource) -> Bool {
        if source.connectionConfiguration != nil,
           source.connectionCandidates.count > 1 {
            return true
        }
        if source.alternateTLSValidationHostname != nil {
            return true
        }
        guard let host = source.host,
              let url = NetworkURLBuilder.baseURL(
                  host: host,
                  scheme: source.useSsl ? "https" : "http",
                  port: source.port
              ) else {
            return false
        }
        if TrustedHTTPTransport.requiresPlainSocket(for: url) {
            return true
        }
        guard source.useSsl, let endpoint = NetworkEndpointIdentity(url: url) else {
            return false
        }
        return SSLTrustStore.isTrustedSync(domain: endpoint.key)
    }

    private nonisolated static func isProbablyLocalHost(_ rawHost: String) -> Bool {
        let trimmed = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return false }

        let host: String
        if let url = URL(string: trimmed), let parsed = url.host {
            host = parsed
        } else {
            host = trimmed
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .split(separator: ":", maxSplits: 1)
                .first
                .map(String.init) ?? trimmed
        }

        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host == "::1" || host.hasPrefix("fe80:") { return true }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch octets[0] {
        case 10, 127:
            return true
        case 169:
            return octets[1] == 254
        case 172:
            return (16...31).contains(octets[1])
        case 192:
            return octets[1] == 168
        default:
            return false
        }
    }

    /// Get the shared connector for a song's source (for playback and file writing).
    func connectorForSong(_ song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)
        try await conn.connect()
        return conn
    }

    func remoteDisplayName(for song: Song) async throws -> String? {
        let conn = try await connectorForSong(song)
        guard let provider = conn as? RemoteFileDisplayNameProviding else { return nil }
        let name = try await provider.displayName(for: song.filePath)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    /// Lyrics / cover / scrape 复用 playback connector(cached pool)。SMB 例外:
    /// sidecar 读取会显式走 `.background`, 由 fetchRange 懒连第二条
    /// libsmb2 会话;这里不先调前台 connect(), 否则仅为检查连接也会
    /// 排在正在播放的 foreground gate 后面。其他来源仍复用已登录
    /// connector, 避免重复 SSL/login。
    func auxiliaryConnector(for song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)  // cache: true, 复用
        if !(conn is SMBSource) {
            try await conn.connect()  // idempotent on isLoggedIn
        }
        return conn
    }

    /// Sidecar 写回不复用播放/缓存 connector。OneDrive 等云盘 connector
    /// 内部会缓存直链和维护 actor 状态, 上传 sidecar 时复用同一个实例容易把
    /// 正在播放/离线缓存的 range 请求拖慢或卡住。
    func sidecarWriteConnector(for song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let scopeFingerprint = Self.audioCacheScopeSignature(for: source)
        if let existing = sidecarConnectors[source.id] {
            if SourceConnectorScopePolicy.canReuse(
                cachedFingerprint: sidecarConnectorScopeFingerprints[source.id],
                requestedFingerprint: scopeFingerprint,
                requiredFingerprint: requiredConnectorScopeFingerprints[source.id],
                validationPending: connectorScopeValidationPendingSourceIDs.contains(source.id)
            ) {
                if !(existing is SMBSource) {
                    try await existing.connect()
                }
                return existing
            }
            sidecarConnectors[source.id] = nil
            sidecarConnectorScopeFingerprints[source.id] = nil
            retireSidecarConnector(existing)
        }
        let conn = connector(for: source, cache: false)
        guard !(conn is NoAvailableConnectionSourceConnector) else {
            throw SourceError.connectionFailed(String(localized: "offline_download_failed"))
        }
        // Retain before the first await. If connect/write fails, the AMSMB2
        // object must not immediately deinitialize its possibly-invalid C
        // context while the failure is unwinding.
        sidecarConnectors[source.id] = conn
        sidecarConnectorScopeFingerprints[source.id] = scopeFingerprint
        if !(conn is SMBSource) {
            try await conn.connect()
        }
        return conn
    }

    func invalidateDownloadCacheAfterSidecarWrite(for song: Song) async {
        guard let conn = try? await connectorForSong(song),
              let oneDrive = conn as? OneDriveSource else {
            return
        }
        await oneDrive.invalidateCachedDownloadURL(path: song.filePath)
    }

    /// 把一次播放回报给"服务端曲库源"(Subsonic/Navidrome 等)。
    /// submission=false → nowPlaying, true → 计入播放次数/历史。
    /// 非服务端源(NAS/云盘/本地)直接 no-op。尽力而为, 不抛错。
    func reportServerScrobble(for song: Song, submission: Bool) async {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }) else { return }
        guard let conn = connector(for: source) as? ServerScrobblingConnector else { return }
        await conn.scrobble(songPath: song.filePath, submission: submission)
    }

    /// 拉取服务端曲库源上的用户歌单。源不支持(NAS / 云盘 / 本地)返回 nil,
    /// 与"支持但一个歌单都没有"(返回空快照)区分开 —— 后者要清理本地陈旧镜像,
    /// 前者什么都不该动。
    func fetchServerPlaylists(for source: MusicSource) async throws -> ServerPlaylistSnapshot? {
        guard let conn = connector(for: source) as? any ServerPlaylistConnector else { return nil }
        return try await conn.fetchServerPlaylists()
    }

    func serverMediaSharingAvailability(
        for target: ServerMediaShareTarget
    ) async throws -> ServerMediaSharingAvailability {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == target.sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for media share")
        }
        guard ServerMediaShareTargetPolicy.supports(source.type) else {
            return .unsupported
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope),
              let provider = connector(for: source) as? any ServerMediaSharingConnector else {
            throw CancellationError()
        }
        let availability = try await provider.serverMediaSharingAvailability()
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope) else {
            throw CancellationError()
        }
        return availability
    }

    func createServerMediaShare(
        for target: ServerMediaShareTarget,
        description: String?,
        expiresAt: Date?
    ) async throws -> ServerMediaShare {
        try Task.checkCancellation()
        let request = try ServerMediaShareRequest(
            itemIDs: target.itemIDs,
            description: description,
            expiresAt: expiresAt
        )
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == target.sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for media share")
        }
        guard ServerMediaShareTargetPolicy.supports(source.type) else {
            throw ServerMediaSharingError.unsupported
        }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope),
              let provider = connector(for: source) as? any ServerMediaSharingConnector else {
            throw CancellationError()
        }
        // `withMutation` deliberately never replays this call on an alternate
        // route: a lost response cannot prove that the first route did not
        // already create a public link.
        return try await provider.createServerMediaShare(request)
    }

    func fetchServerListeningStats(
        for source: MusicSource
    ) async throws -> ServerListeningStatsPayload? {
        guard source.type.serverListeningStatsCapability != .unavailable else { return nil }
        let connector = connector(for: source)
        if let provider = connector as? any ServerListeningStatsConnector {
            return try await provider.fetchServerListeningStats()
        }

        // If a supported source ever resolves to a connector without this optional
        // capability, preserve any concrete connection error before reporting the
        // implementation mismatch. It must not be presented as an unsupported service.
        try await connector.connect()
        throw SourceError.connectionFailed(
            String(localized: "stats_server_error_connector_unavailable")
        )
    }

    func fetchServerFavorites(for source: MusicSource) async throws -> ServerFavoriteSnapshot? {
        guard ServerFavoriteWritebackPolicy.supports(source.type) else { return nil }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope),
              let conn = connector(for: source) as? any ServerFavoriteConnector else {
            throw CancellationError()
        }
        let snapshot = try await conn.fetchServerFavorites()
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope) else {
            throw CancellationError()
        }
        return snapshot
    }

    func fetchServerFavorites(sourceID: String) async throws -> ServerFavoriteSnapshot? {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for favorite refresh")
        }
        return try await fetchServerFavorites(for: source)
    }

    func setServerFavorite(
        for song: Song,
        source: MusicSource,
        isFavorite: Bool
    ) async throws -> ServerFavoriteSnapshot? {
        guard source.id == song.sourceID else { throw CancellationError() }
        let expectedScope = Self.audioCacheScopeSignature(for: source)
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope) else {
            throw CancellationError()
        }
        guard ServerFavoriteWritebackPolicy.supports(source.type) else { return nil }
        guard let itemID = ServerFavoriteWritebackPolicy.songID(
            fromConnectorPath: song.filePath,
            sourceType: source.type
        ) else {
            throw SourceError.fileNotFound(song.filePath)
        }
        guard let conn = connector(for: source) as? any ServerFavoriteConnector else {
            throw SourceError.connectionFailed("Server favorite connector unavailable")
        }
        let snapshot = try await conn.setServerFavorite(itemID: itemID, isFavorite: isFavorite)
        guard await sourceScopeIsCurrent(sourceID: source.id, expectedScope: expectedScope) else {
            throw CancellationError()
        }
        return snapshot
    }

    private func sourceScopeIsCurrent(
        sourceID: String,
        expectedScope: String
    ) async -> Bool {
        guard !credentialChangesInProgress.contains(sourceID),
              !MusicSourceSecurityRevision.hasPendingChange(for: sourceID),
              let sources = try? await sourcesProvider(),
              let current = sources.first(where: {
                  $0.id == sourceID && $0.isEnabled && !$0.isDeleted
              }) else { return false }
        return Self.audioCacheScopeSignature(for: current) == expectedScope
    }

    private func ensureCurrentPlaybackResolutionScope(
        sourceID: String,
        expectedScope: String,
        streamEpoch: UInt64
    ) async throws {
        guard CloudPlaybackSource.isStreamEpochTicketCurrent(
            sourceID: sourceID,
            ticket: streamEpoch
        ), await sourceScopeIsCurrent(
            sourceID: sourceID,
            expectedScope: expectedScope
        ) else {
            throw CancellationError()
        }
    }

    func fetchServerRadioStations(for source: MusicSource) async throws -> ServerRadioStationSnapshot? {
        guard let conn = connector(for: source) as? any ServerRadioConnector else { return nil }
        return try await conn.fetchServerRadioStations()
    }

    func resolveServerRadioStream(
        sourceID: String,
        stationID: String,
        forceRefresh: Bool = false
    ) async throws -> URL {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: {
            $0.id == sourceID && $0.isEnabled && !$0.isDeleted
        }) else {
            throw SourceError.fileNotFound("Source not found for radio station")
        }
        guard let resolver = connector(for: source) as? any ServerRadioStreamResolvingConnector else {
            throw SourceError.connectionFailed("Server radio resolver unavailable")
        }
        return try await resolver.resolveServerRadioStream(
            stationID: stationID,
            forceRefresh: forceRefresh
        )
    }

    /// 该歌是否来自"服务端曲库源"(Subsonic/Navidrome、Jellyfin/Emby/Plex)。
    /// 这类源的 title/artist/album/duration 由服务端权威提供, 刮削不应覆盖,
    /// 也不该为取标签去读(可能转码的)音频流。
    func isServerLibrarySource(for song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }) else {
            return false
        }
        return source.type.isServerLibrary
    }

    func supportsSidecarWriting(for song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }) else {
            return false
        }
        return Self.supportsSidecarWriting(sourceType: source.type)
    }

    func tagMetadataPersistenceMode(for song: Song) async -> TagMetadataPersistenceMode {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }) else {
            return .localOnly
        }
        switch AudioMetadataWritebackPolicy.capability(
            sourceType: source.type,
            format: song.fileFormat
        ) {
        case .embedded:
            return song.isCueTrack || song.isStreamDescriptor ? .sidecarOnly : .embedded
        case .serverAPI:
            return .serverAPI
        case .sidecarOnly:
            return .sidecarOnly
        case .localOnly:
            return .localOnly
        }
    }

    /// The tag editor's only source-write entry point. Capability routing,
    /// per-field outcomes, optimistic replacement, and provider/API error
    /// reporting all stay behind this boundary.
    func writeTagMetadata(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> TagMetadataWritebackReport {
        let mode = await tagMetadataPersistenceMode(for: original)
        let connector = try await connectorForSong(original)
        let report = await TagMetadataWritebackCoordinator.write(
            mode: mode,
            connector: connector,
            original: original,
            updated: updated,
            coverData: coverData
        )
        if mode == .embedded {
            // The file may already have reached the replace stage even when a
            // mandatory readback later reports an error. Never retain bytes
            // cached under the pre-write revision in either outcome.
            deleteAudioCache(for: original)
        }
        if report.remoteMutationOccurred {
            let writtenFields = report.fields.compactMap { result -> String? in
                if case .written = result.disposition { return result.field.rawValue }
                return nil
            }
            plog(
                "Metadata writeback completed for songID=\(original.id) "
                    + "mode=\(String(describing: mode)) fields=\(writtenFields.joined(separator: ","))"
            )
        }
        return report
    }

    func supportsMediaServerWriteback(for song: Song) async -> Bool {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == song.sourceID }) else {
            return false
        }
        switch source.type {
        case .jellyfin, .emby, .plex:
            return true
        default:
            return false
        }
    }

    func writeScrapedMetadataToMediaServer(
        original: Song,
        updated: Song,
        coverData: Data?,
        lyricsLines: [LyricLine]?,
        lyricsContent: String? = nil
    ) async -> MediaServerWritebackResult {
        do {
            let connector = try await connectorForSong(updated)
            guard let writer = connector as? any MediaServerWritebackConnector else {
                return MediaServerWritebackResult(
                    unsupported: ["This media server connector does not support metadata writeback"]
                )
            }
            return await writer.writeScrapedMetadata(
                original: original,
                updated: updated,
                coverData: coverData,
                lyricsLines: lyricsLines,
                lyricsContent: lyricsContent
            )
        } catch {
            return MediaServerWritebackResult(errors: [error.localizedDescription])
        }
    }

    func removeLyricsFromMediaServer(for song: Song) async -> MediaServerWritebackResult {
        do {
            let connector = try await connectorForSong(song)
            guard let writer = connector as? any MediaServerWritebackConnector else {
                return MediaServerWritebackResult(
                    unsupported: ["This media server connector does not support lyrics removal"]
                )
            }
            return await writer.removeLyrics(for: song)
        } catch {
            return MediaServerWritebackResult(errors: [error.localizedDescription])
        }
    }

    nonisolated static func supportsSidecarWriting(sourceType: MusicSourceType) -> Bool {
        sourceType.supportsSidecarWriting
    }


    /// Downloads artwork inside the connector's routed read operation. A local
    /// URL that becomes stale during a Wi-Fi handoff can therefore retire that
    /// route and retry through the configured public endpoint in the same view
    /// load, rather than poisoning the five-minute failed-artwork cache.
    func artworkData(
        for reference: String,
        sourceID: String,
        maximumBytes: Int,
        purpose: ArtworkFetchPurpose = .thumbnail
    ) async -> Data? {
        guard maximumBytes > 0,
              let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == sourceID }) else {
            return nil
        }
        let conn = connector(for: source)
        do {
            return try await conn.fetchArtworkData(
                for: reference,
                maximumBytes: maximumBytes,
                purpose: purpose
            )
        } catch {
            return nil
        }
    }

    func refreshConnector(for sourceID: String) async {
        // Ordinary reconnects, source renames and device-trust updates do not
        // change the byte namespace. The source notification already fences
        // endpoint/configuration edits through the public scope fingerprint.
        invalidateConnectorCachesForSourceConfigurationChange([sourceID])
        await finishConnectorScopeRefresh(for: sourceID)
    }

    /// Begins a durable two-phase credential transition. The pending revision
    /// fences scans and connectors immediately, but cache reconciliation is
    /// deliberately not scheduled until the credential write commits. A
    /// normal persistence failure can therefore abort without deleting trusted
    /// offline bytes; a crash leaves the durable pending revision fail-closed.
    func credentialsWillChange(for sourceID: String) throws {
        guard !credentialChangesInProgress.contains(sourceID) else {
            throw POSIXError(.EBUSY)
        }
        try MusicSourceSecurityRevision.prepareChange(for: sourceID)
        credentialChangesInProgress.insert(sourceID)
        invalidateConnectorCachesForSourceConfigurationChange(
            [sourceID],
            scheduleValidation: false
        )
        let generation = (audioCacheScopeGenerationBySourceID[sourceID] ?? 0) &+ 1
        audioCacheScopeGenerationBySourceID[sourceID] = generation
        validatedAudioCacheSourceIDs.remove(sourceID)
        blockedAudioCacheSourceIDs.insert(sourceID)
        cancelAudioCacheWorkForScopeChange(sourceID: sourceID)
        NotificationCenter.default.post(
            name: .primuseSourceSecurityScopeWillChange,
            object: nil,
            userInfo: ["sourceID": sourceID]
        )
    }

    /// Completes a prepared transition after the new credential is durable.
    /// The effective fingerprint is unchanged by the promotion from pending to
    /// committed, and only now may reconciliation isolate the previous scope.
    func credentialsDidChange(for sourceID: String) throws {
        guard credentialChangesInProgress.contains(sourceID) else {
            throw POSIXError(.EINVAL)
        }
        try MusicSourceSecurityRevision.commitChange(for: sourceID)
        credentialChangesInProgress.remove(sourceID)
        audioCacheSourceConfigurationsDidChange([sourceID])
    }

    /// The storage API reported failure but cannot prove whether its target
    /// value was already made durable. Keep the pending revision and every
    /// source gate closed, while releasing only the in-process attempt lock so
    /// a later explicit retry can allocate a strictly newer revision.
    func credentialsChangeOutcomeUncertain(for sourceID: String) {
        credentialChangesInProgress.remove(sourceID)
    }

    /// Cancels a prepared transition when credential persistence did not
    /// mutate storage. Revalidation returns to the previous fingerprint and
    /// preserves its cache instead of treating the failed attempt as rotation.
    func credentialsDidNotChange(for sourceID: String) throws {
        guard credentialChangesInProgress.contains(sourceID) else {
            throw POSIXError(.EINVAL)
        }
        try MusicSourceSecurityRevision.abortChange(for: sourceID)
        credentialChangesInProgress.remove(sourceID)
        audioCacheSourceConfigurationsDidChange([sourceID])
    }

    private func finishConnectorScopeRefresh(for sourceID: String) async {
        guard !credentialChangesInProgress.contains(sourceID),
              !MusicSourceSecurityRevision.hasPendingChange(for: sourceID) else {
            return
        }
        let generation = connectorScopeValidationGenerationBySourceID[sourceID]
        await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
        guard connectorScopeValidationGenerationBySourceID[sourceID] == generation,
              let sources = try? await sourcesProvider(),
              connectorScopeValidationGenerationBySourceID[sourceID] == generation,
              let source = sources.first(where: { $0.id == sourceID && !$0.isDeleted }) else {
            return
        }
        requiredConnectorScopeFingerprints[sourceID] = Self.audioCacheScopeSignature(for: source)
        connectorSourceModifiedAtByID[sourceID] = source.modifiedAt
        connectorScopeValidationPendingSourceIDs.remove(sourceID)
    }

    func removeConnector(for sourceID: String) async {
        // Cancelling a browsing session retires runtime state but does not
        // assert that credentials changed, so it must not advance the durable
        // security epoch or invalidate otherwise trusted offline bytes.
        invalidateConnectorCachesForSourceConfigurationChange([sourceID])
        await finishConnectorScopeRefresh(for: sourceID)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()
        connectorScopeFingerprints.removeAll()
        unavailableConnectors.removeAll()

        for (_, connector) in sidecarConnectors {
            if connector is SMBSource {
                // See the retention note above: a rejected libsmb2 request
                // can leave AMSMB2 4.0.3 unsafe to destroy. Remove it from the
                // reusable cache but keep that rare object alive.
                retiredSMBSidecarConnectors.append(connector)
            } else {
                await connector.disconnect()
            }
        }
        sidecarConnectors.removeAll()
        sidecarConnectorScopeFingerprints.removeAll()
        requiredConnectorScopeFingerprints.removeAll()
        connectorSourceModifiedAtByID.removeAll()
        connectorScopeValidationPendingSourceIDs.removeAll()
        connectorScopeValidationGenerationBySourceID.removeAll()
        activeConnectionRoutes.removeAll()
        lastSuccessfulConnectionRoutes.removeAll()
    }

    private func setActiveConnectionRoute(
        _ kind: SourceConnectionCandidateKind?,
        for sourceID: String
    ) {
        if let kind {
            activeConnectionRoutes[sourceID] = kind
            lastSuccessfulConnectionRoutes[sourceID] = kind
        } else {
            activeConnectionRoutes.removeValue(forKey: sourceID)
        }
    }
}

private extension SourceManager {
    nonisolated static func sidecarPathsToDelete(for song: Song) -> [String] {
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songFileName = (song.filePath as NSString).lastPathComponent
        let songBase = (songFileName as NSString).deletingPathExtension

        var paths: [String] = []
        for ext in PrimuseConstants.supportedLyricsExtensions {
            paths.append((songDir as NSString).appendingPathComponent("\(songBase).\(ext)"))
        }
        paths.append((songDir as NSString).appendingPathComponent("\(songBase)-cover.jpg"))

        if let lyricsRef = song.lyricsFileName, isSafeLyricsSidecar(lyricsRef, for: song) {
            paths.append(lyricsRef)
        }
        if let coverRef = song.coverArtFileName, isSafeCoverSidecar(coverRef, for: song) {
            paths.append(coverRef)
        }

        var seen: Set<String> = [song.filePath]
        return paths.filter { path in
            guard seen.contains(path) == false else { return false }
            seen.insert(path)
            return true
        }
    }

    nonisolated static func isSafeLyricsSidecar(_ path: String, for song: Song) -> Bool {
        isSafeSameDirectorySidecar(
            path,
            for: song,
            allowedExtensions: Set(PrimuseConstants.supportedLyricsExtensions),
            allowedBaseSuffixes: [""]
        )
    }

    nonisolated static func isSafeCoverSidecar(_ path: String, for song: Song) -> Bool {
        isSafeSameDirectorySidecar(
            path,
            for: song,
            allowedExtensions: Set(PrimuseConstants.supportedCoverExtensions),
            allowedBaseSuffixes: ["", "-cover"]
        )
    }

    nonisolated static func isSafeSameDirectorySidecar(
        _ path: String,
        for song: Song,
        allowedExtensions: Set<String>,
        allowedBaseSuffixes: [String]
    ) -> Bool {
        guard path.contains("://") == false, path.contains("/") else { return false }

        let songDir = normalizedRemotePath((song.filePath as NSString).deletingLastPathComponent)
        let sidecarDir = normalizedRemotePath((path as NSString).deletingLastPathComponent)
        guard songDir == sidecarDir else { return false }

        let songBase = ((song.filePath as NSString).lastPathComponent as NSString)
            .deletingPathExtension
            .lowercased()
        let sidecarName = (path as NSString).lastPathComponent
        let sidecarBase = (sidecarName as NSString).deletingPathExtension.lowercased()
        let sidecarExt = (sidecarName as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(sidecarExt) else { return false }

        return allowedBaseSuffixes.contains { suffix in
            sidecarBase == "\(songBase)\(suffix)"
        }
    }

    nonisolated static func normalizedRemotePath(_ path: String) -> String {
        let components = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.isEmpty == false else { return "/" }
        return "/" + components.joined(separator: "/")
    }

    nonisolated static func isMissingFileError(_ error: Error) -> Bool {
        if case SourceError.fileNotFound = error { return true }
        if case SourceError.pathNotFound = error { return true }
        if case CloudDriveError.fileNotFound = error { return true }

        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
            return true
        }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileNoSuchFileError {
            return true
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("not found")
            || message.contains("no such file")
            || message.contains("不存在")
    }
}

extension Notification.Name {
    /// A durable credential transition has fenced the previous source scope.
    /// userInfo: ["sourceID": String]
    static let primuseSourceSecurityScopeWillChange = Notification.Name(
        "primuse.sourceSecurityScopeWillChange"
    )

    /// 一个音乐源遇到需要用户更新凭据的认证失败。
    /// userInfo: ["sourceID": String, "message": String]
    static let primuseSourceAuthFailed = Notification.Name("primuse.sourceAuthFailed")
}

/// 节流后台 connect() 的失败上报 — 多个并发预取/解码同时挂时, 不要让用户
/// 收到 N 个相同弹窗。每个 sourceID 默认 60s 内只发一次。
@MainActor
enum SourceAuthAlert {
    private static var lastReport: [String: Date] = [:]
    private static let throttle: TimeInterval = 60

    static func report(sourceID: String, message: String) {
        let now = Date()
        if let last = lastReport[sourceID], now.timeIntervalSince(last) < throttle {
            return
        }
        lastReport[sourceID] = now
        NotificationCenter.default.post(
            name: .primuseSourceAuthFailed,
            object: nil,
            userInfo: ["sourceID": sourceID, "message": message]
        )
    }

    /// 用户成功重连后调用,解除节流让下次失败立刻能弹。
    static func clear(sourceID: String) {
        lastReport[sourceID] = nil
    }
}
