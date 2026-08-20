import CryptoKit
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

private struct OfflineDownloadSongResult: Sendable {
    let snapshot: OfflineAudioCacheSnapshot
    let fallbackByteCount: Int64
}

private struct OfflineDownloadTaskRecord {
    let id: UUID
    let task: Task<Void, Never>
}

private struct BackgroundAudioCacheTaskRecord {
    let id: UUID
    let sourceID: String
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
    private let onProgress: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var response: HTTPURLResponse?
    private var downloadedBytes: Int64
    private var totalBytes: Int64?
    private var isFinished = false
    private var lastProgressAt = Date.distantPast

    init(
        partial: URL,
        initialBytes: Int64,
        expectedTotalBytes: Int64?,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void
    ) {
        self.partial = partial
        self.initialBytes = initialBytes
        self.expectedTotalBytes = expectedTotalBytes
        self.onProgress = onProgress
        self.downloadedBytes = initialBytes
        self.totalBytes = expectedTotalBytes
    }

    func run(request: URLRequest, configuration: URLSessionConfiguration) async throws -> HTTPURLResponse {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<HTTPURLResponse, Error>) in
                lock.lock()
                continuation = cont
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: { [weak self] in
            self?.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(throwing: SourceError.connectionFailed("Offline download returned a non-HTTP response"))
            completionHandler(.cancel)
            return
        }

        guard (200...299).contains(http.statusCode) else {
            finish(throwing: CloudDriveError.apiError(http.statusCode, "Offline direct download failed"))
            completionHandler(.cancel)
            return
        }

        do {
            try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: partial.path) {
                FileManager.default.createFile(atPath: partial.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: partial)
            if initialBytes > 0, http.statusCode == 206 {
                try handle.seekToEnd()
                downloadedBytes = initialBytes
            } else {
                try handle.truncate(atOffset: 0)
                downloadedBytes = 0
            }
            self.handle = handle
            self.response = http
            totalBytes = totalBytes(from: http, fallbackBodyBytes: response.expectedContentLength)
            onProgress(downloadedBytes, totalBytes)
            completionHandler(.allow)
        } catch {
            finish(throwing: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            downloadedBytes += Int64(data.count)
            let now = Date()
            if downloadedBytes >= totalBytes ?? Int64.max || now.timeIntervalSince(lastProgressAt) >= 0.25 {
                lastProgressAt = now
                onProgress(downloadedBytes, totalBytes)
            }
        } catch {
            finish(throwing: error)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        session.finishTasksAndInvalidate()
        if let error {
            finish(throwing: error)
        } else if let response {
            onProgress(downloadedBytes, totalBytes)
            finish(returning: response)
        } else {
            finish(throwing: SourceError.connectionFailed("Offline download completed without a response"))
        }
    }

    private func totalBytes(from response: HTTPURLResponse, fallbackBodyBytes: Int64) -> Int64? {
        if let total = Self.totalBytesFromContentRange(response.value(forHTTPHeaderField: "Content-Range")) {
            return total
        }
        if fallbackBodyBytes > 0 {
            return downloadedBytes + fallbackBodyBytes
        }
        return expectedTotalBytes
    }

    private static func totalBytesFromContentRange(_ header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        let value = header[header.index(after: slash)...]
        guard value != "*" else { return nil }
        return Int64(value)
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
        try await candidate.connector.connect()
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

    func fetchArtworkData(for reference: String, maximumBytes: Int) async throws -> Data? {
        try await routing.withRead {
            try await $0.fetchArtworkData(
                for: reference,
                maximumBytes: maximumBytes
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

    func fetchMetadataRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await routing.withRead {
            try await $0.fetchMetadataRange(path: path, offset: offset, length: length)
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

private struct RoutedMusicSourceConnector: RoutedConnectorProxy, OpenListSTRMResolvingConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func openListSTRMURL(for reference: String) async throws -> URL? {
        try await routing.withRead { connector in
            guard let resolver = connector as? any OpenListSTRMResolvingConnector else {
                return nil
            }
            return try await resolver.openListSTRMURL(for: reference)
        }
    }
}

private struct RoutedSubsonicConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    ServerScrobblingConnector, ServerLyricsConnector, ServerPlaylistConnector, ServerRadioConnector {
    let sourceID: String
    let routing: SourceConnectionRouter
    let routedSupportsSidecarWriting: Bool
    let routedPreferredDeleteBatchSize: Int

    func fetchServerPlaylists() async throws -> ServerPlaylistSnapshot {
        try await routing.withRead { connector in
            guard let provider = connector as? any ServerPlaylistConnector else {
                throw SourceError.connectionFailed("Server playlist connector unavailable")
            }
            return try await provider.fetchServerPlaylists()
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

}

private struct RoutedMediaServerConnector: RoutedConnectorProxy, RefreshingMetadataSongConnector,
    MediaServerWritebackConnector, ServerLyricsConnector, ServerPlaylistConnector,
    ServerRadioConnector, ServerRadioStreamResolvingConnector {
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

}

@MainActor
@Observable
final class SourceManager {
    private var connectors: [String: any MusicSourceConnector] = [:]
    /// Sidecar I/O uses a connector separate from playback, but it must remain
    /// retained. AMSMB2 4.0.3 can crash in its C-context deinitializer after a
    /// server rejects a write; creating one throwaway connector per song made
    /// a read-only SMB scrape reliably hit that upstream lifetime bug.
    private var sidecarConnectors: [String: any MusicSourceConnector] = [:]
    /// A replaced SMB connector cannot be safely destroyed after a failed C
    /// request on AMSMB2 4.0.3. Keep the rare retired instance alive until the
    /// process exits; normal playback and scrape paths remain bounded at one
    /// active connector per source.
    private var retiredSMBSidecarConnectors: [any MusicSourceConnector] = []
    private let sourcesProvider: @Sendable () async throws -> [MusicSource]
    private let songsProvider: @MainActor () -> [Song]
    @ObservationIgnored private var offlineAudioSnapshots: [String: OfflineAudioCacheSnapshot] = [:]
    @ObservationIgnored private var offlineAudioSnapshotEntries: [String: OfflineAudioSnapshotEntry] = [:]
    /// Lightweight aggregate used by the source cards. Download progress does
    /// not mutate this set; only entering/leaving the downloading state does.
    private(set) var offlineDownloadingSongIDs: Set<String> = []
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
    private var backgroundAudioCacheTasks: [String: BackgroundAudioCacheTaskRecord] = [:]
    private var musicVideoCacheTasks: [String: Task<URL, Error>] = [:]
    private var musicVideoCacheTargets: [String: URL] = [:]

    init(database: LibraryDatabase) {
        self.sourcesProvider = {
            try await database.allSources()
        }
        self.songsProvider = { [] }
        observeLibraryInvalidations()
    }

    init(
        sourcesProvider: @escaping @Sendable () async throws -> [MusicSource],
        songsProvider: @escaping @MainActor () -> [Song] = { [] }
    ) {
        self.sourcesProvider = sourcesProvider
        self.songsProvider = songsProvider
        observeLibraryInvalidations()
    }

    private func observeLibraryInvalidations() {
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
            let sourceIDs = Set((note.userInfo?["sourceIDs"] as? [String]) ?? [])
            MainActor.assumeIsolated {
                if sourceIDs.isEmpty {
                    self.deleteLocalCaches(for: songs, preserveFreshMetadataAssets: true)
                } else {
                    self.deleteLocalCachesForRemovedSources(sourceIDs, songs: songs)
                }
            }
        }

        NotificationCenter.default.addObserver(
            forName: .primuseSongsRemoved,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let songs = (note.userInfo?["songs"] as? [Song]) ?? []
            MainActor.assumeIsolated {
                self.deleteLocalCaches(for: songs)
            }
        }
    }

    func connector(for source: MusicSource) -> any MusicSourceConnector {
        return connector(for: source, cache: true)
    }

    private func connector(for source: MusicSource, cache: Bool) -> any MusicSourceConnector {
        if cache, let existing = connectors[source.id] {
            return existing
        }

        let connector = routedConnector(for: source)
        if cache,
           !(connector is CredentialUnavailableSourceConnector),
           !(connector is NoAvailableConnectionSourceConnector) {
            connectors[source.id] = connector
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
                deviceId: source.deviceId
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
                    password: password
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
                    authType: source.authType
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
                    password: password
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
                    password: password
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
                    password: password
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
                    password: password
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
                    password: password
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
                    useSsl: source.useSsl
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
                    await connector.disconnect()
                    checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_connection_title")))
                    return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
                }
            } else {
                await connector.disconnect()
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
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = (max(0.1, seconds) * 1_000_000_000)
                    .finiteUInt64(or: 100_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw SourceError.timeout
            }

            guard let result = try await group.next() else {
                throw SourceError.timeout
            }
            group.cancelAll()
            return result
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
    }

    private func resolveSTRMTarget(
        for song: Song,
        connector: any MusicSourceConnector
    ) async throws -> ResolvedSTRMTarget {
        let descriptor = try await connector.readSTRMDescriptor(path: song.filePath)
        switch descriptor.target {
        case .remote(let url):
            return .remote(url)
        case .sourcePath(let reference):
            guard let path = STRMSourcePathResolver.resolve(reference, relativeTo: song.filePath) else {
                throw STRMDescriptorError.invalidTarget
            }
            if let webDAV = connector as? any OpenListSTRMResolvingConnector,
               let originURL = try await webDAV.openListSTRMURL(for: path) {
                return .remote(originURL)
            }
            return .sourcePath(path)
        }
    }

    func resolveURL(for song: Song) async throws -> URL {
        // Priority 1: Cached local file (instant playback). 必须在 connect() 之前判断:
        // 源不可达(断网 / NAS 关机 / 登录态失效)时 connect() 会抛错。连本地
        // sourcesProvider 都不应挡在缓存前面，让完整离线文件成为真正的零网络路径。
        if let cached = cachedURL(for: song) {
            return cached
        }

        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        let conn = connector(for: source)
        try await conn.connect()

        if song.isStreamDescriptor {
            switch try await resolveSTRMTarget(for: song, connector: conn) {
            case .remote(let url):
                return url
            case .sourcePath(let path):
                if let streamURL = try await conn.streamingURL(for: path) {
                    return streamURL
                }
                return try await conn.localURL(for: path)
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
        // Priority 3: plain HTTP streaming URL. For known-size audio the
        // player now wraps it in an HTTP Range InputSource; unknown-size
        // legacy rows still fall back to StreamingDownloadDecoder.
        if let streamURL = try await conn.streamingURL(for: song.filePath) {
            return streamURL
        }
        // Priority 4: Download to local (sources without streaming URL).
        return try await conn.localURL(for: song.filePath)
    }

    /// Resolves a connector URL without selecting the generic Range playback
    /// scheme. The caller must fully download an HTTP(S) result before decode;
    /// connectors without a direct URL return their complete local file.
    func resolveFullDownloadSourceURL(for song: Song) async throws -> URL {
        if let cached = cachedURL(for: song) {
            return cached
        }

        let connector = try await connectorForSong(song)
        if song.isStreamDescriptor {
            switch try await resolveSTRMTarget(for: song, connector: connector) {
            case .remote(let url):
                return url
            case .sourcePath(let path):
                if let streamURL = try await connector.streamingURL(for: path) {
                    return streamURL
                }
                return try await connector.localURL(for: path)
            }
        }

        if let streamURL = try await connector.streamingURL(for: song.filePath) {
            return streamURL
        }
        return try await connector.localURL(for: song.filePath)
    }

    func resolveVideoAsset(for song: Song) async throws -> MusicVideoPlaybackAsset? {
        guard let mvPath = normalizedMusicVideoPath(for: song) else { return nil }

        // 独立 MV(mvPath == filePath): 文件本体已离线下载时直接本地播,
        // 不再经视频缓存重复下载同一份字节。
        if song.isStandaloneMusicVideo, let cached = cachedURL(for: song) {
            return .url(cached)
        }

        // 视频缓存命中同样必须完全脱离源连接。旧路径先 connect()，NAS 关机或
        // 飞行模式时会在本地文件检查前等待超时，连已经缓存的视频也播不了。
        let target = videoCacheURL(sourceID: song.sourceID, path: mvPath)
        if FileManager.default.fileExists(atPath: target.path) {
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

        if let url = URL(string: mvPath), let scheme = url.scheme, !scheme.isEmpty {
            return .url(url)
        }

        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        let conn = connector(for: source)
        try await conn.connect()

        if let streamURL = try await conn.streamingURL(for: mvPath) {
            return .url(streamURL)
        }

        if source.type.category == .local {
            return .url(try await conn.localURL(for: mvPath))
        }

        // 完整缓存直接本地播, 远端 size 校验放到后台 —— 命中路径不付
        // listFiles 的网络往返, 远端文件被替换时删缓存让下次播放重下。
        // 边下边播: 知道远端大小的 range 源用 resource loader 即点即播,
        // 后台顺序下载并行把完整文件落进缓存(loader 读已覆盖的前缀省流量)。
        if source.supportsRangeStreaming,
           let expectedSize = try? await Self.musicVideoFileSize(path: mvPath, connector: conn),
           expectedSize > 0 {
            let loader = MusicVideoStreamingLoader(
                connector: conn,
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

    private func videoCacheDirectory(for sourceID: String) -> URL {
        let dir = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.videoCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func videoCacheURL(sourceID: String, path: String) -> URL {
        videoCacheDirectory(for: sourceID)
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
        if let task = musicVideoCacheTasks[cacheKey] {
            return task
        }

        let target = videoCacheURL(sourceID: source.id, path: path)
        let task = Task { [self] in
            defer {
                self.musicVideoCacheTasks[cacheKey] = nil
                self.musicVideoCacheTargets[cacheKey] = nil
            }
            return try await self.materializeCachedMusicVideoURL(
                for: path, source: source, connector: connector, target: target, expectedSize: expectedSize
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
        connector: any MusicSourceConnector,
        target: URL,
        expectedSize knownSize: Int64?
    ) async throws -> URL {
        let expectedSize: Int64?
        if let knownSize, knownSize > 0 {
            expectedSize = knownSize
        } else {
            expectedSize = try? await Self.musicVideoFileSize(path: path, connector: connector)
        }
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

        if source.supportsRangeStreaming {
            try await downloadMusicVideoByRanges(path: path, connector: connector, target: target, expectedSize: expectedSize)
        } else {
            let localURL = try await connector.localURL(for: path)
            try copyMusicVideoFile(from: localURL, to: target)
        }

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
        connector: any MusicSourceConnector,
        target: URL,
        expectedSize: Int64?
    ) async throws {
        let partial = URL(fileURLWithPath: target.path + ".partial")
        var offset = byteSize(at: partial)
        if let expectedSize, expectedSize > 0 {
            if offset > expectedSize {
                try? FileManager.default.removeItem(at: partial)
                offset = 0
            } else if offset == expectedSize {
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: partial, to: target)
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
                if data.isEmpty {
                    guard offset > 0 else {
                        throw SourceError.fileNotFound("Music video file is empty: \(path)")
                    }
                    break
                }

                try handle.write(contentsOf: data)
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
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private nonisolated static func isRangeEndError(_ error: Error) -> Bool {
        if case CloudDriveError.apiError(let code, _) = error {
            return code == 416
        }
        return false
    }

    private nonisolated func copyMusicVideoFile(from source: URL, to target: URL) throws {
        if source.standardizedFileURL == target.standardizedFileURL { return }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
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
    private static let offlineBatchConcurrency = 2
    private static let offlineSnapshotProbeConcurrency = 16
    private static let directDownloadUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

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

    /// Pure URL construction for UI probes. Unlike `cacheURL(for:)`, this does
    /// not create directories, stat files, or run legacy migration on the main
    /// actor.
    private func audioCacheTargetURL(for song: Song) -> URL {
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
        let fileURL = audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
        migrateLegacyAudioCacheIfUnambiguous(for: song, destination: fileURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        // 完整性校验: 云盘断流 / 用户中途切歌时会留下 partial 文件
        // (比如 1MB 但实际应该 9MB)。命中后 SFBDecoder 只能解码前面那段,
        // 引擎播完触发 gapless boundary → 队列死循环。这里把不完整的
        // 缓存当作未命中, 删掉强制重下。 song.fileSize<=0 表示元数据没拿到,
        // 跳过校验避免误删。
        if song.fileSize > 0,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let actual = attrs[.size] as? Int64 {
            // 5% tolerance: 部分 sidecar / tag 改写后大小会差几 KB
            let minAcceptable = Int64(Double(song.fileSize) * 0.95)
            if actual < minAcceptable {
                plog("🗑 cachedURL: 缓存不完整 '\(song.title)' actual=\(actual / 1024)KB expected=\(song.fileSize / 1024)KB — 删除并强制重下")
                try? FileManager.default.removeItem(at: fileURL)
                return nil
            }
        }
        let relativePath = "\(song.sourceID)/\(sanitized)"
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
        CloudPlaybackSource.cancelSessionForMaterialization(partialPath: partialPath)
        try? FileManager.default.removeItem(atPath: partialPath)
        try? FileManager.default.removeItem(atPath: partialPath + CloudPlaybackSource.prewarmMarkerSuffix)

        let result = await downloadForOfflineBatch(songs: [song])
        guard result.succeeded, let cached = cachedURL(for: song) else { return nil }

        // Seeking is normal playback cache behavior, not an explicit offline
        // pin. Preserve a user's pre-existing pin, otherwise return the file
        // to the ordinary LRU-managed cache after the shared downloader exits.
        if !wasPinned {
            let relativePath = audioCacheRelativePath(for: song)
            await AudioCacheManager.shared.unpin(path: relativePath)
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .cached,
                progress: nil,
                byteCount: song.fileSize > 0 ? song.fileSize : nil,
                errorMessage: nil
            ), for: song.id)
        }
        return cached
    }

    func cacheURL(for song: Song) -> URL {
        let url = audioCacheDirectory(for: song.sourceID).appendingPathComponent(cacheFileName(for: song))
        migrateLegacyAudioCacheIfUnambiguous(for: song, destination: url)
        return url
    }

    /// Read-only cache lookup for artwork and other scrolling-adjacent work.
    /// Legacy migration remains on explicit playback/cache paths; a recycled
    /// list row must never create directories or synchronously touch disk on
    /// the main actor.
    func cachedURLForBackgroundRead(for song: Song) async -> URL? {
        let target = audioCacheTargetURL(for: song)
        let expectedSize = song.fileSize
        let isUsable = await Task.detached(priority: .utility) {
            Self.isUsableCacheFile(at: target, expectedSize: expectedSize)
        }.value
        guard isUsable else { return nil }
        Task {
            await AudioCacheManager.shared.recordAccess(path: audioCacheRelativePath(for: song))
        }
        return target
    }

    func offlineAudioSnapshot(for song: Song) -> OfflineAudioCacheSnapshot {
        if let snapshot = offlineAudioSnapshots[song.id] {
            return snapshot
        }
        let url = cacheURL(for: song)
        let snapshot: OfflineAudioCacheSnapshot
        if Self.isUsableCacheFile(at: url, expectedSize: song.fileSize) {
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
        guard offlineAudioSnapshots[songID] != snapshot else { return }
        offlineAudioSnapshots[songID] = snapshot
        offlineAudioSnapshotEntries[songID]?.update(snapshot)
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
        offlineAudioSnapshots.removeValue(forKey: songID)
        offlineAudioSnapshotEntries[songID]?.update(.notCached)
        offlineAudioSnapshotEntries.removeValue(forKey: songID)
        offlineDownloadingSongIDs.remove(songID)
    }

    /// Populate a row's first snapshot lazily. Negative results are cached as
    /// well, preventing repeated disk stats when the same row is recycled.
    func ensureOfflineAudioSnapshot(for song: Song) async {
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
        guard offlineAudioSnapshots[song.id] == nil else { return }
        setOfflineAudioSnapshot(snapshot, for: song.id)
    }

    func refreshOfflineAudioSnapshot(for song: Song) async {
        let url = cacheURL(for: song)
        let info = await Task.detached(priority: .utility) {
            Self.offlineFileInfo(at: url, expectedSize: song.fileSize)
        }.value
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
        _ = offlineDownloadTask(for: song)
    }

    func downloadForOffline(songs: [Song]) {
        Task { [weak self] in
            _ = await self?.downloadForOfflineBatch(songs: songs)
        }
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
                    await self.waitForOfflineDownload(song)
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
        offlineDownloadTasks[song.id]?.task.cancel()
        offlineDownloadTasks[song.id] = nil
        deleteAudioCache(for: song)
        setOfflineAudioSnapshot(.notCached, for: song.id)
    }

    private func waitForOfflineDownload(_ song: Song) async {
        let task = offlineDownloadTask(for: song)
        await task.value
    }

    private func offlineDownloadTask(for song: Song) -> Task<Void, Never> {
        if let record = offlineDownloadTasks[song.id] {
            plog("↩️ Offline: join existing download '\(song.title)'")
            return record.task
        }

        let runID = UUID()
        let songID = song.id
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performOfflineDownload(song)
            self.finishOfflineDownloadTask(songID: songID, runID: runID)
        }
        offlineDownloadTasks[songID] = OfflineDownloadTaskRecord(id: runID, task: task)
        return task
    }

    private func finishOfflineDownloadTask(songID: String, runID: UUID) {
        guard offlineDownloadTasks[songID]?.id == runID else { return }
        offlineDownloadTasks[songID] = nil
    }

    private func performOfflineDownload(_ song: Song) async {
        let startedAt = Date()
        let relativePath = audioCacheRelativePath(for: song)
        let target = cacheURL(for: song)

        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: 0,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        ), for: song.id)

        do {
            try Task.checkCancellation()
            if let cached = cachedURL(for: song) {
                let size = fileSize(at: cached)
                await AudioCacheManager.shared.pin(path: relativePath, byteCount: size)
                setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                    state: .pinned,
                    progress: nil,
                    byteCount: size,
                    errorMessage: nil
                ), for: song.id)
                return
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
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: max(song.fileSize, 10_485_760))

            if song.isStreamDescriptor {
                switch try await resolveSTRMTarget(for: song, connector: connector) {
                case .remote(let url):
                    try await downloadOfflineFromURL(url, song: song, target: target)
                case .sourcePath(let path):
                    if let streamURL = try await connector.streamingURL(for: path) {
                        try await downloadOfflineFromURL(streamURL, song: song, target: target)
                    } else {
                        let localURL = try await connector.localURL(for: path)
                        try copyOfflineFile(from: localURL, to: target)
                    }
                }
            } else if let oneDrive = connector as? OneDriveSource {
                do {
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath)
                    try await downloadOfflineFromDirectURL(directURL, song: song, target: target)
                } catch {
                    await oneDrive.invalidateCachedDownloadURL(path: song.filePath)
                    plog("↩️ Offline direct retry with fresh OneDrive URL for '\(song.title)': \(error.localizedDescription)")
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath, forceRefresh: true)
                    try await downloadOfflineFromDirectURL(directURL, song: song, target: target)
                }
            } else if RangeStreamingPrefetchPolicy.usesSingleTransferForCompleteDownload(
                for: source.type
            ) {
                try await cacheCompleteFile(song: song, connector: connector)
            } else if source.supportsRangeStreaming, song.fileSize > 0 {
                try await downloadOfflineByRanges(song: song, connector: connector, target: target)
            } else if let streamURL = try await connector.streamingURL(for: song.filePath) {
                try await downloadOfflineFromURL(streamURL, song: song, target: target)
            } else {
                let localURL = try await connector.localURL(for: song.filePath)
                try copyOfflineFile(from: localURL, to: target)
            }

            try Task.checkCancellation()
            let size = fileSize(at: target)
            await AudioCacheManager.shared.markDownloaded(path: relativePath, byteCount: size, pinned: true)
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .pinned,
                progress: nil,
                byteCount: size,
                errorMessage: nil
            ), for: song.id)
            plog(String(format: "✅ Offline: '%@' downloaded and pinned size=%lldKB elapsed=%.1fs", song.title, (size ?? 0) / 1024, Date().timeIntervalSince(startedAt)))
        } catch {
            if Task.isCancelled {
                setOfflineAudioSnapshot(.notCached, for: song.id)
                plog(String(format: "↩️ Offline download cancelled for '%@' after %.1fs", song.title, Date().timeIntervalSince(startedAt)))
                return
            }
            let partial = URL(fileURLWithPath: target.path + ".offline")
            let partialSize = byteSize(at: partial)
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .failed,
                progress: nil,
                byteCount: partialSize > 0 ? partialSize : nil,
                errorMessage: error.localizedDescription
            ), for: song.id)
            plog(String(format: "⚠️ Offline download failed for '%@' after %.1fs partial=%lldKB: %@", song.title, Date().timeIntervalSince(startedAt), partialSize / 1024, error.localizedDescription))
        }
    }

    private func downloadOfflineByRanges(
        song: Song,
        connector: any MusicSourceConnector,
        target: URL
    ) async throws {
        let partial = URL(fileURLWithPath: target.path + ".offline")
        let existingSize = byteSize(at: partial)
        if existingSize >= song.fileSize, song.fileSize > 0 {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            return
        }
        if existingSize > song.fileSize {
            try? FileManager.default.removeItem(at: partial)
        }
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        let chunkSize: Int64 = 2 * 1024 * 1024
        var offset: Int64 = max(0, min(byteSize(at: partial), song.fileSize))
        if offset > 0 {
            plog("↩️ Offline resume '\(song.title)' from \(offset / 1024)KB / \(song.fileSize / 1024)KB")
        }
        try handle.seek(toOffset: UInt64(offset))
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: song.fileSize > 0 ? min(0.99, Double(offset) / Double(song.fileSize)) : nil,
            byteCount: song.fileSize,
            errorMessage: nil
        ), for: song.id)

        do {
            while offset < song.fileSize {
                let length = min(chunkSize, song.fileSize - offset)
                let data = try await connector.fetchRange(path: song.filePath, offset: offset, length: length)
                guard Int64(data.count) == length else {
                    throw SourceError.connectionFailed(
                        "Offline download returned an invalid chunk: \(data.count)/\(length)"
                    )
                }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                    state: .downloading,
                    progress: min(0.99, Double(offset) / Double(song.fileSize)),
                    byteCount: song.fileSize,
                    errorMessage: nil
                ), for: song.id)
            }
            try handle.close()
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
        } catch {
            try? handle.close()
            throw error
        }
    }

    private func downloadOfflineFromDirectURL(_ url: URL, song: Song, target: URL) async throws {
        let partial = URL(fileURLWithPath: target.path + ".offline")
        let existingSize = byteSize(at: partial)
        if existingSize >= song.fileSize, song.fileSize > 0 {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            return
        }
        if existingSize > song.fileSize, song.fileSize > 0 {
            try? FileManager.default.removeItem(at: partial)
        }

        let resumeOffset = max(0, min(byteSize(at: partial), max(song.fileSize, 0)))
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
        let expectedTotal = song.fileSize > 0 ? song.fileSize : nil
        let delegate = OfflineDirectDownloadDelegate(
            partial: partial,
            initialBytes: resumeOffset,
            expectedTotalBytes: expectedTotal
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
        if song.fileSize > 0, finalSize < song.fileSize {
            throw SourceError.connectionFailed("Offline direct download incomplete: \(finalSize)/\(song.fileSize)")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: partial, to: target)
        plog(String(format: "✅ Offline direct download '%@' size=%lldKB elapsed=%.1fs", song.title, finalSize / 1024, Date().timeIntervalSince(startedAt)))
    }

    private func downloadOfflineFromURL(_ url: URL, song: Song, target: URL) async throws {
        setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: nil,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        ), for: song.id)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await TrustedHTTPTransport.download(
            from: url,
            session: session,
            timeout: 300
        )
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SourceError.connectionFailed("HTTP \(http.statusCode)")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tempURL, to: target)
    }

    private func copyOfflineFile(from source: URL, to target: URL) throws {
        if source.standardizedFileURL == target.standardizedFileURL { return }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: source, to: target)
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

            offlineDownloadTasks[previous.id]?.task.cancel()
            offlineDownloadTasks[previous.id] = nil
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
        Task { await AudioCacheManager.shared.removeEntry(path: relativePath) }
        setOfflineAudioSnapshot(.notCached, for: song.id)
    }

    func deleteLocalCaches(for song: Song) {
        deleteLocalCaches(for: [song])
    }

    func deleteLocalCaches(
        for songs: [Song],
        preserveFreshMetadataAssets: Bool = false
    ) {
        guard songs.isEmpty == false else { return }

        for song in songs {
            backgroundAudioCacheTasks[song.id]?.task.cancel()
        }

        let cachesRoot = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let tempRoot = FileManager.default.temporaryDirectory
        var cacheTargets: [URL] = []
        cacheTargets.reserveCapacity(songs.count * 6)
        var audioRelativePaths: [String] = []
        audioRelativePaths.reserveCapacity(songs.count)

        for song in songs {
            let audioName = cacheFileName(for: song)
            cacheTargets.append(
                cachesRoot
                    .appendingPathComponent(Self.audioCacheDirName)
                    .appendingPathComponent(song.sourceID)
                    .appendingPathComponent(audioName)
            )
            audioRelativePaths.append("\(song.sourceID)/\(audioName)")

            let cacheName = CacheFileNamePolicy.make(path: song.filePath)
            let legacyName = CacheFileNamePolicy.legacySanitized(path: song.filePath)
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_smb_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_smb_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(legacyName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_ftp_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(legacyName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_sftp_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                tempRoot.appendingPathComponent("primuse_webdav_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(cacheName)
            )
            cacheTargets.append(
                FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                    .appendingPathComponent("primuse_s3_cache")
                    .appendingPathComponent(song.sourceID).appendingPathComponent(cacheName)
            )
            if let nfsName = NFSSelectionPathCodec.cacheFileName(for: song.filePath) {
                cacheTargets.append(
                    tempRoot.appendingPathComponent("primuse_nfs_cache")
                        .appendingPathComponent(song.sourceID).appendingPathComponent(nfsName)
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
                        .appendingPathComponent(song.sourceID).appendingPathComponent(upnpName)
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
                        .appendingPathComponent(
                            Self.videoCacheFileName(sourceID: song.sourceID, path: mvPath)
                        )
                )
            }
            setOfflineAudioSnapshot(.notCached, for: song.id)
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

        Task {
            await AudioCacheManager.shared.removeEntries(paths: audioRelativePaths)
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
    private func deleteLocalCachesForRemovedSources(_ sourceIDs: Set<String>, songs: [Song]) {
        guard !sourceIDs.isEmpty else { return }
        for record in backgroundAudioCacheTasks.values where sourceIDs.contains(record.sourceID) {
            record.task.cancel()
        }
        let songIDs = songs.map(\.id)
        for songID in songIDs {
            removeOfflineAudioSnapshot(for: songID)
        }
        for (key, task) in musicVideoCacheTasks where sourceIDs.contains(where: { key.hasPrefix("\($0):") }) {
            task.cancel()
        }

        CachedArtworkView.clearMemoryCache()

        let legacyWebDAVRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_webdav_cache")
        let legacyTargets = songs.map {
            legacyWebDAVRoot.appendingPathComponent(
                CacheFileNamePolicy.legacySanitized(path: $0.filePath)
            )
        }
        Task.detached(priority: .utility) { [legacyTargets] in
            for target in legacyTargets {
                if Task.isCancelled { return }
                Self.removeCacheFileFamily(at: target)
            }
        }
        Task {
            await MetadataAssetStore.shared.invalidateCaches(forSongIDs: songIDs)
            await AudioCacheManager.shared.removeAllEntries(
                forSourcePrefixes: sourceIDs.map { "\($0)/" }
            )
        }
    }

    private func deleteConnectorTempCaches(for song: Song) {
        let cacheName = CacheFileNamePolicy.make(path: song.filePath)
        let legacyName = CacheFileNamePolicy.legacySanitized(path: song.filePath)
        let temp = FileManager.default.temporaryDirectory
        let candidates = [
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(song.sourceID).appendingPathComponent(cacheName),
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(song.sourceID).appendingPathComponent(legacyName),
            temp.appendingPathComponent("primuse_ftp_cache").appendingPathComponent(song.sourceID).appendingPathComponent(legacyName),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(song.sourceID).appendingPathComponent(cacheName),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(song.sourceID).appendingPathComponent(legacyName),
            temp.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(song.sourceID).appendingPathComponent(cacheName),
            temp.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(legacyName),
            FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
                .appendingPathComponent("primuse_s3_cache").appendingPathComponent(song.sourceID).appendingPathComponent(cacheName),
        ]
        for url in candidates {
            Self.removeCacheFileFamily(at: url)
        }
    }

    private nonisolated static func removeCacheFileFamily(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let partial = URL(fileURLWithPath: url.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".offline"))
    }

    func deleteSourceCaches(sourceID: String) {
        deleteSourceCaches(sourceIDs: [sourceID])
    }

    func deleteSourceCaches(sourceIDs: Set<String>) {
        guard !sourceIDs.isEmpty else { return }
        for record in backgroundAudioCacheTasks.values where sourceIDs.contains(record.sourceID) {
            record.task.cancel()
        }
        let paths = sourceIDs.flatMap(Self.perSourceCacheDirs(sourceID:))
        Task.detached(priority: .utility) { [paths] in
            let fileManager = FileManager.default
            for path in paths {
                if Task.isCancelled { return }
                try? fileManager.removeItem(at: path)
            }
        }
        Task {
            await AudioCacheManager.shared.removeAllEntries(
                forSourcePrefixes: sourceIDs.map { "\($0)/" }
            )
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
    nonisolated static func pruneStalePartialFiles(olderThanDays days: Int = 7) {
        let basePath = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent(Self.audioCacheDirName)
        guard let enumerator = FileManager.default.enumerator(
            at: basePath,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var removedBytes: Int64 = 0
        var removedCount = 0
        while let fileURL = enumerator.nextObject() as? URL {
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
    }

    /// 删除指定 source 的整个 audio cache 子目录 + LRU 里属于这个源的记录。
    /// 只在 LibraryService.removeSource() 流程里用 —— 用户主动删源时一并
    /// 回收磁盘, 不然 caches/primuse_audio_cache/<sourceID>/ 里的整本歌
    /// + `.partial` 半成品永远没人动。
    func purgeAudioCache(forSourceID sourceID: String) {
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

    private func backgroundAudioCacheTask(
        for song: Song,
        cacheEnabled: Bool
    ) -> Task<Void, Never>? {
        guard cacheEnabled, cachedURL(for: song) == nil else { return nil }
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
                try await cacheCompleteFile(song: song, connector: conn)
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                plog("↩️ Cache prefetch cancelled for '\(song.title)'")
            } else {
                plog("⚠️ Cache failed for '\(song.title)': \(error.localizedDescription)")
            }
        }
    }

    private func cacheCompleteFile(
        song: Song,
        connector: any MusicSourceConnector
    ) async throws {
        guard cachedURL(for: song) == nil else { return }
        let target = cacheURL(for: song)
        let reserveBytes = max(song.fileSize, 10_485_760)
        await AudioCacheManager.shared.evictIfNeeded(reserveBytes: reserveBytes)
        try Task.checkCancellation()

        if song.isStreamDescriptor {
            switch try await resolveSTRMTarget(for: song, connector: connector) {
            case .remote(let url):
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 300
                config.timeoutIntervalForResource = 60 * 60
                let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let (tempURL, response) = try await TrustedHTTPTransport.download(
                    from: url,
                    session: session,
                    timeout: 300
                )
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw SourceError.connectionFailed("HTTP \(http.statusCode)")
                }
                try await Task.detached(priority: .utility) {
                    try Self.installCacheFile(from: tempURL, to: target, move: true)
                }.value
            case .sourcePath(let path):
                if let streamURL = try await connector.streamingURL(for: path) {
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 300
                    config.timeoutIntervalForResource = 60 * 60
                    let session = URLSession(
                        configuration: config,
                        delegate: SmartSSLDelegate(),
                        delegateQueue: nil
                    )
                    defer { session.finishTasksAndInvalidate() }
                    let (tempURL, response) = try await TrustedHTTPTransport.download(
                        from: streamURL,
                        session: session,
                        timeout: 300
                    )
                    if let http = response as? HTTPURLResponse,
                       !(200...299).contains(http.statusCode) {
                        throw SourceError.connectionFailed("HTTP \(http.statusCode)")
                    }
                    try await Task.detached(priority: .utility) {
                        try Self.installCacheFile(from: tempURL, to: target, move: true)
                    }.value
                } else {
                    let localURL = try await connector.localURL(for: path)
                    try await Task.detached(priority: .utility) {
                        try Self.installCacheFile(from: localURL, to: target, move: false)
                    }.value
                }
            }
        } else if let streamURL = try await connector.streamingURL(for: song.filePath) {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 60 * 60
            config.networkServiceType = .background
            let session = URLSession(
                configuration: config,
                delegate: SmartSSLDelegate(),
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }
            let (tempURL, response) = try await TrustedHTTPTransport.download(
                from: streamURL,
                session: session,
                timeout: 300
            )
            if let http = response as? HTTPURLResponse,
               !(200...299).contains(http.statusCode) {
                throw SourceError.connectionFailed("HTTP \(http.statusCode)")
            }
            try Task.checkCancellation()
            try Self.validateCompleteCacheFile(at: tempURL, expectedSize: song.fileSize)
            if cachedURL(for: song) == nil {
                try await Task.detached(priority: .utility) {
                    try Self.installCacheFile(from: tempURL, to: target, move: true)
                }.value
            }
        } else {
            let localURL = try await connector.localURL(for: song.filePath)
            try Task.checkCancellation()
            try Self.validateCompleteCacheFile(at: localURL, expectedSize: song.fileSize)
            if cachedURL(for: song) == nil {
                try await Task.detached(priority: .utility) {
                    try Self.installCacheFile(from: localURL, to: target, move: false)
                }.value
            }
        }

        try Task.checkCancellation()
        try Self.validateCompleteCacheFile(at: target, expectedSize: song.fileSize)
        let byteCount = byteSize(at: target)
        let relativePath = audioCacheRelativePath(for: song)
        await AudioCacheManager.shared.recordAccess(path: relativePath)
        if offlineAudioSnapshot(for: song).state != .pinned {
            setOfflineAudioSnapshot(OfflineAudioCacheSnapshot(
                state: .cached,
                progress: nil,
                byteCount: byteCount,
                errorMessage: nil
            ), for: song.id)
        }
        plog("✅ Cache: '\(song.title)' complete file cached successfully")
    }

    private nonisolated static func validateCompleteCacheFile(
        at url: URL,
        expectedSize: Int64
    ) throws {
        guard expectedSize > 0 else { return }
        let actualSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64) ?? 0
        let minimumSize = Int64(Double(expectedSize) * 0.95)
        guard actualSize >= minimumSize else {
            throw SourceError.connectionFailed("Incomplete background cache: \(actualSize)/\(expectedSize)")
        }
    }

    private nonisolated static func installCacheFile(
        from source: URL,
        to target: URL,
        move: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        if source.standardizedFileURL == target.standardizedFileURL { return }
        if move {
            try FileManager.default.moveItem(at: source, to: target)
        } else {
            try FileManager.default.copyItem(at: source, to: target)
        }
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
        if isPrewarmed(song: song) { return }
        let fileSize = song.fileSize
        guard fileSize > 0 else { return }
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
        guard let sources = try? await sourcesProvider(),
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
        let cache = cacheURL(for: song)
        CloudPlaybackSource.finalizeSession(partialPath: cache.path + ".partial")

        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        for prefix in ["primuse-stream", "primuse-http"] {
            let partialPath = tempDir
                .appendingPathComponent("\(prefix)-\(song.id)")
                .path + ".partial"
            CloudPlaybackSource.finalizeSession(partialPath: partialPath)
        }
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
        guard !head.isEmpty else { return }
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
    /// during the session for SFB to read from, but iOS reaps the temp
    /// directory on its own schedule afterward.
    func makeStreamingInputSource(for song: Song, cacheEnabled: Bool = true) async throws -> InputSource? {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        guard !song.isStreamDescriptor else { return nil }
        let conn = connector(for: source)
        try await conn.connect()
        guard song.fileSize > 0 else { return nil }
        let cache = cacheEnabled
            ? cacheURL(for: song)
            : URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("primuse-stream-\(song.id)")

        // 启动 streaming 之前先按预计大小腾位置 —— Range streaming 路径以前
        // 完全没接 LRU, 缓存可以无限胀。这里做最低限度的 evict (只在持久化
        // 模式下), 让 2GB 上限对 NAS 也生效。注意是异步, 不阻塞首播 ——
        // 真正写满前不一定能 evict 完, 但能保证 LRU 不再被绕过。
        let cacheRelativePath: String?
        if cacheEnabled {
            cacheRelativePath = audioCacheRelativePath(for: song)
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
        } else {
            cacheRelativePath = nil
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

        return CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            persistOnComplete: cacheEnabled,
            cacheRelativePath: cacheRelativePath,
            prefetchAhead: prefetchAhead,
            allowsTrailingFill: allowsTrailingFill
        )
    }

    /// Metadata reads use the same runtime STRM resolution as playback. This
    /// prevents the backfill worker from parsing the wrapper text as audio and
    /// keeps signed URLs out of the persisted Song model.
    func fetchMetadataRange(
        for song: Song,
        offset: Int64,
        length: Int64
    ) async throws -> Data {
        let connector = try await connectorForSong(song)
        guard song.isStreamDescriptor else {
            return try await connector.fetchMetadataRange(
                path: song.filePath,
                offset: offset,
                length: length
            )
        }
        switch try await resolveSTRMTarget(for: song, connector: connector) {
        case .sourcePath(let path):
            return try await connector.fetchMetadataRange(
                path: path,
                offset: offset,
                length: length
            )
        case .remote(let url):
            return try await Self.fetchRemoteMetadataRange(
                url: url,
                offset: offset,
                length: length
            )
        }
    }

    private nonisolated static func fetchRemoteMetadataRange(
        url: URL,
        offset: Int64,
        length: Int64
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
        let (temporaryURL, response) = try await TrustedHTTPTransport.download(
            for: request,
            session: session
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
            // Some OpenList/proxy targets ignore Range. Metadata reads may
            // consume the response as a bounded head/tail window, while the
            // playback path keeps its strict random-access validation.
            return try boundedRemoteMetadataSlice(
                temporaryURL,
                offset: offset,
                length: length
            )
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
        guard let source = sources.first(where: { $0.id == song.sourceID }) else { return nil }
        let conn = connector(for: source)
        if let oneDrive = conn as? OneDriveSource {
            try? await oneDrive.connect()
            return try? await oneDrive.publicDownloadURL(path: song.filePath)
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

    private func requiresConnectorBackedHTTPTransport(for source: MusicSource) -> Bool {
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
        if let existing = sidecarConnectors[source.id] {
            if !(existing is SMBSource) {
                try await existing.connect()
            }
            return existing
        }
        let conn = connector(for: source, cache: false)
        // Retain before the first await. If connect/write fails, the AMSMB2
        // object must not immediately deinitialize its possibly-invalid C
        // context while the failure is unwinding.
        sidecarConnectors[source.id] = conn
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
        case .sidecarOnly:
            return .sidecarOnly
        case .localOnly:
            return .localOnly
        }
    }

    /// Returns nil when this editor is explicitly operating in local-only or
    /// sidecar-only mode. A non-nil result has already been downloaded and
    /// byte-verified after the server replacement.
    func writeEmbeddedMetadataIfSupported(
        original: Song,
        updated: Song,
        coverData: Data?
    ) async throws -> Song? {
        guard await tagMetadataPersistenceMode(for: original) == .embedded else {
            return nil
        }
        let connector = try await connectorForSong(original)
        let result = try await connector.writeEmbeddedMetadata(
            original: original,
            updated: updated,
            coverData: coverData
        )
        var sourceUpdated = updated
        sourceUpdated.fileSize = result.fileSize
        sourceUpdated.lastModified = result.modifiedDate
        sourceUpdated.revision = result.revision
        deleteAudioCache(for: original)
        plog("WebDAV embedded metadata writeback verified for songID=\(original.id) sha256=\(result.fileSHA256)")
        return sourceUpdated
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
        maximumBytes: Int
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
                maximumBytes: maximumBytes
            )
        } catch {
            return nil
        }
    }

    func refreshConnector(for sourceID: String) async {
        await SourceConnectionRuntime.shared.invalidate(sourceID: sourceID)
        activeConnectionRoutes.removeValue(forKey: sourceID)
        lastSuccessfulConnectionRoutes.removeValue(forKey: sourceID)
        if let connector = connectors.removeValue(forKey: sourceID) {
            await connector.disconnect()
        }
        if let sidecar = sidecarConnectors.removeValue(forKey: sourceID) {
            if sidecar is SMBSource {
                retiredSMBSidecarConnectors.append(sidecar)
            } else {
                await sidecar.disconnect()
            }
        }
    }

    func removeConnector(for sourceID: String) async {
        await refreshConnector(for: sourceID)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()

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
