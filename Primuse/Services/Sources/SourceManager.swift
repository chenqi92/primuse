import CryptoKit
import Foundation
import PrimuseKit

struct SongFileDeletionResult: Sendable {
    struct Failure: Sendable {
        let path: String
        let message: String
    }

    var deletedPaths: [String] = []
    var missingPaths: [String] = []
    var failedPaths: [Failure] = []

    var hasFailures: Bool { !failedPaths.isEmpty }

    mutating func merge(_ other: SongFileDeletionResult) {
        deletedPaths.append(contentsOf: other.deletedPaths)
        missingPaths.append(contentsOf: other.missingPaths)
        failedPaths.append(contentsOf: other.failedPaths)
    }
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

    init(source: MusicSource, startedAt: Date, checks: [SourceDiagnosticCheck]) {
        self.id = UUID()
        self.sourceID = source.id
        self.sourceName = source.name
        self.startedAt = startedAt
        self.finishedAt = Date()
        self.checks = checks
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

@MainActor
@Observable
final class SourceManager {
    private var connectors: [String: any MusicSourceConnector] = [:]
    private let sourcesProvider: @Sendable () async throws -> [MusicSource]
    private(set) var offlineAudioSnapshots: [String: OfflineAudioCacheSnapshot] = [:]
    private var offlineDownloadTasks: [String: OfflineDownloadTaskRecord] = [:]
    private var musicVideoCacheTasks: [String: Task<URL, Error>] = [:]
    private var musicVideoCacheTargets: [String: URL] = [:]

    init(database: LibraryDatabase) {
        self.sourcesProvider = {
            try await database.allSources()
        }
        observeLibraryInvalidations()
    }

    init(sourcesProvider: @escaping @Sendable () async throws -> [MusicSource]) {
        self.sourcesProvider = sourcesProvider
        observeLibraryInvalidations()
    }

    private func observeLibraryInvalidations() {
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
                self.deleteLocalCaches(for: songs)
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

        let connector: any MusicSourceConnector
        switch source.type {
        case .synology:
            let pw = KeychainService.getPassword(for: source.id) ?? ""
            plog("🔧 SourceManager creating SynologySource id=\(source.id) host=\(source.host ?? "?") userLen=\(source.username?.count ?? 0) pwLen=\(pw.count)")
            connector = SynologySource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5001,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: pw,
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
            connector = SMBSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 445,
                sharePath: source.shareName ?? "",
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .webdav:
            connector = WebDAVSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .ftp:
            connector = FTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? "",
                encryption: source.ftpEncryption ?? .none
            )
        case .sftp:
            connector = SFTPSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
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
            connector = MediaServerSource(
                sourceID: source.id,
                kind: MediaServerSource.Kind(sourceType: source.type)!,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                secret: KeychainService.getPassword(for: source.id) ?? "",
                authType: source.authType
            )
        case .subsonic, .navidrome, .airsonic, .gonic:
            connector = SubsonicSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port,
                useSsl: source.useSsl,
                basePath: source.basePath,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .qnap:
            connector = QnapSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 8080,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .ugreen:
            connector = UgreenSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 9999,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
        case .fnos:
            connector = FnOSSource(
                sourceID: source.id,
                host: source.host ?? "",
                port: source.port ?? 5666,
                useSsl: source.useSsl,
                username: source.username ?? "",
                password: KeychainService.getPassword(for: source.id) ?? ""
            )
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
        case .pan115:
            connector = U115Source(sourceID: source.id)
        case .pan123:
            connector = Pan123Source(sourceID: source.id)
        case .s3:
            // S3 uses host=endpoint, basePath=bucket, and extraConfig holds
            // {"region":..., "dirs":[...]} — read region S3-aware so the dir
            // list sharing the slot doesn't break the lookup.
            connector = S3Source(
                sourceID: source.id,
                endpoint: source.host ?? "s3.amazonaws.com",
                region: source.s3Region ?? "us-east-1",
                bucket: source.basePath ?? "",
                accessKey: source.username ?? "",
                secretKey: KeychainService.getPassword(for: source.id) ?? "",
                useSsl: source.useSsl
            )
        case .appleMusic:
            // Apple Music 在系统侧 ApplicationMusicPlayer 播放, 不需要 connector
            // 扫文件 / 解析。给个 unsupported 占位让 switch 完整, 实际 scan
            // 走 AppleMusicLibraryService, play 由 AudioPlayerService 路由。
            connector = UnsupportedSourceConnector(sourceID: source.id, sourceType: .appleMusic)
        }

        if cache {
            connectors[source.id] = connector
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
                    checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_connection_title")))
                    return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
                }
            } else {
                checks.append(diagnosticCheck(for: error, source: source, title: String(localized: "source_diag_connection_title")))
                return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
            }
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
                return SourceDiagnosticReport(source: source, startedAt: startedAt, checks: checks)
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
        return "\(advice.title): \(advice.message) · \(advice.suggestion)"
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

        if source.type.requiresHost, trimmed(source.host).isEmpty {
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
        if source.type.isServerLibrary == false, selectedDirectories.isEmpty {
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

        let secret = KeychainService.getPassword(for: source.id) ?? ""
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
            if secret.isEmpty {
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
            case .notAuthenticated, .tokenExpired, .tokenRefreshFailed(_):
                return SourceDiagnosticAdvice(
                    title: String(localized: "source_diag_advice_oauth_title"),
                    message: String(localized: "source_diag_advice_oauth_message"),
                    suggestion: String(localized: "source_diag_advice_oauth_suggestion")
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
                if code == 401 || code == 403 { return authAdvice() }
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
                return pathAdvice(path: path)
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
            return pathAdvice(path: message)
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
                let nanoseconds = UInt64(max(0.1, seconds) * 1_000_000_000)
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

    func resolveURL(for song: Song) async throws -> URL {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }

        // Priority 1: Cached local file (instant playback). 必须在 connect() 之前判断:
        // 源不可达(断网 / NAS 关机 / 登录态失效)时 connect() 会抛错, 若先 connect
        // 就永远走不到缓存命中分支, 离线已下载的歌曲将无法播放。缓存命中是纯本地
        // 文件检查, 不依赖连接。
        if let cached = cachedURL(for: song) {
            return cached
        }

        let conn = connector(for: source)
        try await conn.connect()

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

    func resolveVideoAsset(for song: Song) async throws -> MusicVideoPlaybackAsset? {
        guard let mvPath = normalizedMusicVideoPath(for: song) else { return nil }
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
        let target = videoCacheURL(sourceID: source.id, path: mvPath)
        if FileManager.default.fileExists(atPath: target.path) {
            recordVideoCacheAccess(target)
            scheduleVideoCacheRevalidation(path: mvPath, connector: conn, target: target)
            return .url(target)
        }

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
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
                removeCacheFileFamily(at: target)
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
            removeCacheFileFamily(at: target)
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
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
        removeCacheFileFamily(at: videoCacheURL(sourceID: song.sourceID, path: mvPath))
    }

    // MARK: - Audio Cache

    private static let audioCacheDirName = "primuse_audio_cache"
    private static let offlineBatchConcurrency = 2
    private static let directDownloadUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func audioCacheDirectory(for sourceID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 缓存文件名:sanitize 后的 filePath 末尾补音频格式扩展名。OneDrive 等的 filePath
    /// 是无扩展名的 item id,缓存文件没扩展名时命中后 file:// 播放会因 pathExtension 为空
    /// 被判 "Unsupported format" 而秒退(表现为"播放后瞬间消失")。
    private func cacheFileName(for song: Song) -> String {
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
        let ext = song.fileFormat.rawValue.lowercased()
        if ext.isEmpty || sanitized.lowercased().hasSuffix(".\(ext)") { return sanitized }
        return "\(sanitized).\(ext)"
    }

    private func audioCacheRelativePath(for song: Song) -> String {
        "\(song.sourceID)/\(cacheFileName(for: song))"
    }

    func cachedURL(for song: Song) -> URL? {
        let sanitized = cacheFileName(for: song)
        let fileURL = audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
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

    func cacheURL(for song: Song) -> URL {
        return audioCacheDirectory(for: song.sourceID).appendingPathComponent(cacheFileName(for: song))
    }

    func offlineAudioSnapshot(for song: Song) -> OfflineAudioCacheSnapshot {
        if let snapshot = offlineAudioSnapshots[song.id] {
            return snapshot
        }
        let url = cacheURL(for: song)
        guard FileManager.default.fileExists(atPath: url.path) else { return .notCached }
        return OfflineAudioCacheSnapshot(
            state: .cached,
            progress: nil,
            byteCount: fileSize(at: url),
            errorMessage: nil
        )
    }

    func refreshOfflineAudioSnapshot(for song: Song) async {
        let url = cacheURL(for: song)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let snapshot = await AudioCacheManager.shared.snapshot(
            path: audioCacheRelativePath(for: song),
            fileExists: exists,
            byteCount: exists ? fileSize(at: url) : nil
        )
        offlineAudioSnapshots[song.id] = snapshot
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
        offlineAudioSnapshots[song.id] = .notCached
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

        offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: 0,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        )

        do {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: target.path) {
                let size = fileSize(at: target)
                await AudioCacheManager.shared.pin(path: relativePath, byteCount: size)
                offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                    state: .pinned,
                    progress: nil,
                    byteCount: size,
                    errorMessage: nil
                )
                return
            }

            let sources = try await sourcesProvider()
            guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                throw SourceError.fileNotFound("Source not found for song: \(song.title)")
            }

            let connector = connector(for: source)
            try await connector.connect()
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: max(song.fileSize, 10_485_760))

            if let oneDrive = connector as? OneDriveSource {
                do {
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath)
                    try await downloadOfflineFromDirectURL(directURL, song: song, target: target)
                } catch {
                    await oneDrive.invalidateCachedDownloadURL(path: song.filePath)
                    plog("↩️ Offline direct retry with fresh OneDrive URL for '\(song.title)': \(error.localizedDescription)")
                    let directURL = try await oneDrive.publicDownloadURL(path: song.filePath, forceRefresh: true)
                    try await downloadOfflineFromDirectURL(directURL, song: song, target: target)
                }
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
            offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                state: .pinned,
                progress: nil,
                byteCount: size,
                errorMessage: nil
            )
            plog(String(format: "✅ Offline: '%@' downloaded and pinned size=%lldKB elapsed=%.1fs", song.title, (size ?? 0) / 1024, Date().timeIntervalSince(startedAt)))
        } catch {
            if Task.isCancelled {
                offlineAudioSnapshots[song.id] = .notCached
                plog(String(format: "↩️ Offline download cancelled for '%@' after %.1fs", song.title, Date().timeIntervalSince(startedAt)))
                return
            }
            let partial = URL(fileURLWithPath: target.path + ".offline")
            let partialSize = byteSize(at: partial)
            offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                state: .failed,
                progress: nil,
                byteCount: partialSize > 0 ? partialSize : nil,
                errorMessage: error.localizedDescription
            )
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
        offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: song.fileSize > 0 ? min(0.99, Double(offset) / Double(song.fileSize)) : nil,
            byteCount: song.fileSize,
            errorMessage: nil
        )

        do {
            while offset < song.fileSize {
                let length = min(chunkSize, song.fileSize - offset)
                let data = try await connector.fetchRange(path: song.filePath, offset: offset, length: length)
                guard !data.isEmpty else {
                    throw SourceError.connectionFailed("Offline download returned an empty chunk")
                }
                try handle.write(contentsOf: data)
                offset += Int64(data.count)
                offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                    state: .downloading,
                    progress: min(0.99, Double(offset) / Double(song.fileSize)),
                    byteCount: song.fileSize,
                    errorMessage: nil
                )
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
                self?.offlineAudioSnapshots[songID] = OfflineAudioCacheSnapshot(
                    state: .downloading,
                    progress: total.map { $0 > 0 ? min(0.99, Double(downloadedBytes) / Double($0)) : 0 },
                    byteCount: total,
                    errorMessage: nil
                )
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
        offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: nil,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tempURL, response) = try await session.download(from: url)
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
        deleteLocalCaches(for: song)
        return result
    }

    @discardableResult
    func deleteSourceFiles(for song: Song, deleteSidecars: Bool = true) async -> SongFileDeletionResult {
        var result = SongFileDeletionResult()

        do {
            let sources = try await sourcesProvider()
            guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                result.failedPaths.append(.init(path: song.filePath, message: "Source not found"))
                return result
            }

            let conn = connector(for: source)
            try await conn.connect()

            do {
                try await conn.deleteFile(at: song.filePath)
                result.deletedPaths.append(song.filePath)
            } catch {
                if Self.isMissingFileError(error) {
                    result.missingPaths.append(song.filePath)
                } else {
                    result.failedPaths.append(.init(path: song.filePath, message: error.localizedDescription))
                    return result
                }
            }

            if deleteSidecars {
                for path in Self.sidecarPathsToDelete(for: song) {
                    do {
                        try await conn.deleteFile(at: path)
                        result.deletedPaths.append(path)
                    } catch {
                        if Self.isMissingFileError(error) {
                            result.missingPaths.append(path)
                        } else {
                            result.failedPaths.append(.init(path: path, message: error.localizedDescription))
                        }
                    }
                }
            }
        } catch {
            result.failedPaths.append(.init(path: song.filePath, message: error.localizedDescription))
        }

        if result.hasFailures {
            let failures = result.failedPaths.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            plog("⚠️ Delete source files failed for '\(song.title)': \(failures)")
        }
        return result
    }

    nonisolated func shouldDeleteSidecars(for song: Song, retaining retainedSongs: [Song]) -> Bool {
        let targetSidecars = Set(Self.sidecarPathsToDelete(for: song))
        guard targetSidecars.isEmpty == false else { return false }

        let sidecarsAreShared = retainedSongs.contains { retained in
            guard retained.id != song.id, retained.sourceID == song.sourceID else { return false }
            return Set(Self.sidecarPathsToDelete(for: retained)).isDisjoint(with: targetSidecars) == false
        }
        return !sidecarsAreShared
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
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(audioCacheDirName),
            smbCacheDir,
        ]
    }

    /// 一个源占用的全部 per-source 缓存目录。下载缓存按协议散落在多个目录,
    /// `deleteSourceCaches` 删除与 `diskUsage` 统计都走这里, 保证口径一致
    /// (否则统计会系统性低估 SMB/SFTP/NFS/云 等源的真实占用)。
    static func perSourceCacheDirs(sourceID: String) -> [URL] {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let temp = fm.temporaryDirectory
        return [
            caches.appendingPathComponent(audioCacheDirName).appendingPathComponent(sourceID),
            caches.appendingPathComponent(videoCacheDirName).appendingPathComponent(sourceID),
            caches.appendingPathComponent("primuse_cloud_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_ftp_cache").appendingPathComponent(sourceID),
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
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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

    func deleteAudioCache(for song: Song) {
        let cacheURL = cacheURL(for: song)
        removeCacheFileFamily(at: cacheURL)
        deleteConnectorTempCaches(for: song)
        let relativePath = audioCacheRelativePath(for: song)
        Task { await AudioCacheManager.shared.removeEntry(path: relativePath) }
        offlineAudioSnapshots[song.id] = .notCached
    }

    func deleteLocalCaches(for song: Song) {
        deleteLocalCaches(for: [song])
    }

    func deleteLocalCaches(for songs: [Song]) {
        guard songs.isEmpty == false else { return }

        for song in songs {
            deleteAudioCache(for: song)
            deleteMusicVideoCache(for: song)
            CachedArtworkView.invalidateCache(for: song.id)
            if let coverRef = song.coverArtFileName {
                CachedArtworkView.invalidateCache(for: coverRef)
            }
        }

        let songIDs = songs.map(\.id)
        Task {
            for songID in songIDs {
                await MetadataAssetStore.shared.invalidateCoverCache(forSongID: songID)
                await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
            }
        }
    }

    private func deleteConnectorTempCaches(for song: Song) {
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
        let temp = FileManager.default.temporaryDirectory
        let candidates = [
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(song.sourceID).appendingPathComponent(sanitized),
            temp.appendingPathComponent("primuse_ftp_cache").appendingPathComponent(song.sourceID).appendingPathComponent(sanitized),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(song.sourceID).appendingPathComponent(sanitized),
            temp.appendingPathComponent("primuse_webdav_cache").appendingPathComponent(sanitized),
        ]
        for url in candidates {
            removeCacheFileFamily(at: url)
        }
    }

    private nonisolated func removeCacheFileFamily(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let partial = URL(fileURLWithPath: url.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".offline"))
    }

    func deleteSourceCaches(sourceID: String) {
        let fileManager = FileManager.default
        for path in Self.perSourceCacheDirs(sourceID: sourceID) {
            try? fileManager.removeItem(at: path)
        }
        Task { await AudioCacheManager.shared.removeAllEntries(forSourcePrefix: "\(sourceID)/") }
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
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
    func pruneStalePartialFiles(olderThanDays days: Int = 7) {
        let basePath = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
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
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.removeItem(at: dir)
        Task { await AudioCacheManager.shared.removeAllEntries(forSourcePrefix: "\(sourceID)/") }
    }

    /// Background-cache a song file (generalized for all sources).
    /// Sources that use connector-backed Range streaming take a different
    /// path: instead of pre-downloading the whole file (wasteful — they
    /// stream on demand anyway), we warm the connector's dlink/cache and
    /// pull the first chunk into the `.partial` cache file. Result: when
    /// the user hits "next", the first reads are local.
    /// Pass `cacheEnabled: false` (when the user has Audio Cache off) to
    /// skip the prewarm/cache write entirely — we'll still play the song
    /// fine, just without the latency win.
    func cacheInBackground(song: Song, cacheEnabled: Bool = true) {
        guard cachedURL(for: song) == nil else { return }
        Task {
            do {
                let sources = try await sourcesProvider()
                guard let source = sources.first(where: { $0.id == song.sourceID }) else {
                    plog("⚠️ Cache: source not found for '\(song.title)'")
                    return
                }

                if source.type == .oneDrive {
                    plog("⏩ Cache: skip OneDrive prewarm for '\(song.title)' (foreground Range playback keeps priority)")
                    return
                }

                let conn = connector(for: source)
                try await conn.connect()

                if source.supportsRangeStreaming, song.fileSize > 0 {
                    if cacheEnabled, shouldUseRangeStreamingForPlayback(source: source, song: song) {
                        await prewarmCloudSong(song: song, connector: conn)
                    } else if shouldPreferPlainStreamingForPlayback(source: source, song: song) {
                        plog("⏩ Cache: skip full prefetch for '\(song.title)' (\(source.type.displayName) plain-stream policy)")
                    }
                    return
                }
                guard cacheEnabled else { return }

                guard let streamURL = try await conn.streamingURL(for: song.filePath) else {
                    plog("⚠️ Cache: no streaming URL for '\(song.title)'")
                    return
                }
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 300
                let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
                defer { session.finishTasksAndInvalidate() }
                let (tempURL, response) = try await session.download(from: streamURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    plog("⚠️ Cache: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for '\(song.title)'")
                    return
                }
                let target = cacheURL(for: song)
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tempURL, to: target)
                let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
                await AudioCacheManager.shared.recordAccess(path: "\(song.sourceID)/\(sanitized)")
                plog("✅ Cache: '\(song.title)' cached successfully")
            } catch {
                plog("⚠️ Cache failed for '\(song.title)': \(error.localizedDescription)")
            }
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
            async let headData = connector.fetchRange(path: song.filePath, offset: 0, length: Self.prewarmHeadSize)
            async let tailData: Data = tailSize > 0
                ? connector.fetchRange(path: song.filePath, offset: fileSize - tailSize, length: tailSize)
                : Data()
            let (head, tail) = try await (headData, tailData)
            seedPrewarmCache(song: song, head: head, tail: tail, fileSize: fileSize)
        } catch {
            plog("⚠️ Prewarm failed for '\(song.title)': \(error.localizedDescription)")
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
        guard source.type != .oneDrive else { return }
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

        let prefetchAhead = source.type == .oneDrive ? 0 : CloudPlaybackSource.prefetchAhead
        if source.type == .oneDrive {
            plog("☁️ OneDrive streaming: background chunk prefetch disabled for '\(song.title)'")
        }

        return CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            persistOnComplete: cacheEnabled,
            cacheRelativePath: cacheRelativePath,
            prefetchAhead: prefetchAhead
        )
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
        // 服务端转码源: 需要服务端转码的格式(WMA)走渐进流(streamingURL 返回
        // 转码 mp3), 不能按原文件 fileSize 做 Range, 否则会读越界。
        if source.type.isSubsonicFamily, SubsonicSource.requiresServerTranscode(song.fileFormat) {
            return false
        }
        return !shouldPreferPlainStreamingForPlayback(source: source, song: song)
    }

    private func shouldPreferPlainStreamingForPlayback(source: MusicSource, song: Song) -> Bool {
        guard Self.nasAPIPlainStreamingTypes.contains(source.type),
              song.fileFormat == .mp3 else { return false }

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
        .fnos,
    ]

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

    /// Lyrics / cover / scrape 都直接复用 playback connector(cached pool)。
    /// 之前用独立 instance"避免 actor blocking",但实测 connector 内 fetchRange
    /// 全是 await 点(让出 actor), 多个调用交错执行不会真 serial block。
    /// 复用 main connector 的最大好处: prewarm 阶段已经 connect 过, lyrics
    /// Tier3 第一首歌的 connect() 直接走 isLoggedIn 短路,免去 SSL+login 2-3s。
    func auxiliaryConnector(for song: Song) async throws -> any MusicSourceConnector {
        let sources = try await sourcesProvider()
        guard let source = sources.first(where: { $0.id == song.sourceID }) else {
            throw SourceError.fileNotFound("Source not found for song: \(song.title)")
        }
        let conn = connector(for: source)  // cache: true, 复用
        try await conn.connect()  // idempotent on isLoggedIn
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
        let conn = connector(for: source, cache: false)
        try await conn.connect()
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

    nonisolated static func supportsSidecarWriting(sourceType: MusicSourceType) -> Bool {
        switch sourceType {
        case .synology, .smb, .oneDrive, .dropbox, .googleDrive, .baiduPan, .aliyunDrive, .pan123:
            return true
        default:
            return false
        }
    }


    /// Get a direct HTTP URL for an image file on the source (for cover art display).
    /// Uses the shared connector — lightweight, just builds a URL without downloading.
    func imageURL(for path: String, sourceID: String) async -> URL? {
        guard let sources = try? await sourcesProvider(),
              let source = sources.first(where: { $0.id == sourceID }) else { return nil }
        let conn = connector(for: source)
        return try? await conn.imageURL(for: path)
    }

    func refreshConnector(for sourceID: String) async {
        guard let connector = connectors.removeValue(forKey: sourceID) else { return }
        await connector.disconnect()
    }

    func removeConnector(for sourceID: String) async {
        await refreshConnector(for: sourceID)
    }

    func disconnectAll() async {
        for (_, connector) in connectors {
            await connector.disconnect()
        }
        connectors.removeAll()
    }
}

private extension SourceManager {
    nonisolated static func sidecarPathsToDelete(for song: Song) -> [String] {
        let songDir = (song.filePath as NSString).deletingLastPathComponent
        let songFileName = (song.filePath as NSString).lastPathComponent
        let songBase = (songFileName as NSString).deletingPathExtension

        var paths: [String] = []
        paths.append((songDir as NSString).appendingPathComponent("\(songBase).lrc"))
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
    /// 一个音乐源的登录失败了 (密码错 / 2FA / 限流 / 网络挂)。
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
