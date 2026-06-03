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
            // S3 uses host=endpoint, basePath=bucket, extraConfig=JSON{region}
            let extraJson = (try? JSONSerialization.jsonObject(with: Data((source.extraConfig ?? "{}").utf8))) as? [String: String] ?? [:]
            connector = S3Source(
                sourceID: source.id,
                endpoint: source.host ?? "s3.amazonaws.com",
                region: extraJson["region"] ?? "us-east-1",
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

        let selectedDirectories = explicitDirectories ?? decodeSelectedDirectories(source.extraConfig)
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
        let selectedDirectories = explicitDirectories ?? decodeSelectedDirectories(source.extraConfig)
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

    private func decodeSelectedDirectories(_ config: String?) -> [String] {
        guard let config,
              let data = config.data(using: .utf8),
              let directories = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return directories
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

        let conn = connector(for: source)
        try await conn.connect()

        // Priority 1: Cached local file (instant playback)
        if let cached = cachedURL(for: song) {
            return cached
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

    // MARK: - Audio Cache

    private static let audioCacheDirName = "primuse_audio_cache"

    private func audioCacheDirectory(for sourceID: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Self.audioCacheDirName)
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func audioCacheRelativePath(for song: Song) -> String {
        "\(song.sourceID)/\(song.filePath.replacingOccurrences(of: "/", with: "_"))"
    }

    func cachedURL(for song: Song) -> URL? {
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
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
        let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
        return audioCacheDirectory(for: song.sourceID).appendingPathComponent(sanitized)
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
        guard offlineAudioSnapshots[song.id]?.isDownloading != true else { return }
        Task { [weak self] in
            await self?.performOfflineDownload(song)
        }
    }

    func downloadForOffline(songs: [Song]) {
        Task { [weak self] in
            for song in songs.filteredPlayable() {
                guard !Task.isCancelled else { break }
                await self?.performOfflineDownload(song)
            }
        }
    }

    func removeOfflineDownload(song: Song) {
        deleteAudioCache(for: song)
        offlineAudioSnapshots[song.id] = .notCached
    }

    private func performOfflineDownload(_ song: Song) async {
        guard offlineAudioSnapshots[song.id]?.isDownloading != true else { return }
        let relativePath = audioCacheRelativePath(for: song)
        let target = cacheURL(for: song)

        offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
            state: .downloading,
            progress: 0,
            byteCount: song.fileSize > 0 ? song.fileSize : nil,
            errorMessage: nil
        )

        do {
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

            if source.supportsRangeStreaming, song.fileSize > 0 {
                try await downloadOfflineByRanges(song: song, connector: connector, target: target)
            } else if let streamURL = try await connector.streamingURL(for: song.filePath) {
                try await downloadOfflineFromURL(streamURL, song: song, target: target)
            } else {
                let localURL = try await connector.localURL(for: song.filePath)
                try copyOfflineFile(from: localURL, to: target)
            }

            let size = fileSize(at: target)
            await AudioCacheManager.shared.markDownloaded(path: relativePath, byteCount: size, pinned: true)
            offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                state: .pinned,
                progress: nil,
                byteCount: size,
                errorMessage: nil
            )
            plog("✅ Offline: '\(song.title)' downloaded and pinned")
        } catch {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: target.path + ".offline"))
            offlineAudioSnapshots[song.id] = OfflineAudioCacheSnapshot(
                state: .failed,
                progress: nil,
                byteCount: nil,
                errorMessage: error.localizedDescription
            )
            plog("⚠️ Offline download failed for '\(song.title)': \(error.localizedDescription)")
        }
    }

    private func downloadOfflineByRanges(
        song: Song,
        connector: any MusicSourceConnector,
        target: URL
    ) async throws {
        let partial = URL(fileURLWithPath: target.path + ".offline")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        let chunkSize: Int64 = 2 * 1024 * 1024
        var offset: Int64 = 0

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
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
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

    private func fileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]),
              let size = values.totalFileAllocatedSize else { return nil }
        return Int64(size)
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
        var total: Int64 = 0
        let dirs = [
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Self.audioCacheDirName),
            Self.smbCacheDir,
        ]
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
    /// - partial: `.partial` / `.partial.prewarmed` 半成品 (用户跳过 /
    ///   prewarm 完没听), 启动时 7 天清一次, 也可以这里手动一键清
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
        var result = AudioCacheBreakdown()
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

    /// 一键清掉所有 `.partial` 半成品 (无视 mtime, 等价于用户主动决定
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
            guard name.hasSuffix(".partial") || name.hasSuffix(".partial.prewarmed") else { continue }
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

    private func removeCacheFileFamily(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        let partial = URL(fileURLWithPath: url.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: partial.path + CloudPlaybackSource.prewarmMarkerSuffix))
    }

    func deleteSourceCaches(sourceID: String) {
        let fileManager = FileManager.default
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let temp = fileManager.temporaryDirectory
        let paths = [
            caches.appendingPathComponent(Self.audioCacheDirName).appendingPathComponent(sourceID),
            caches.appendingPathComponent("primuse_cloud_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_smb_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_sftp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_ftp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_nfs_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_upnp_cache").appendingPathComponent(sourceID),
            temp.appendingPathComponent("primuse_scan_\(sourceID)"),
        ]
        for path in paths {
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
            let sanitized = song.filePath.replacingOccurrences(of: "/", with: "_")
            cacheRelativePath = "\(song.sourceID)/\(sanitized)"
            await AudioCacheManager.shared.evictIfNeeded(reserveBytes: song.fileSize)
        } else {
            cacheRelativePath = nil
        }

        return CloudPlaybackSource.makeInputSource(
            song: song,
            totalLength: song.fileSize,
            connector: conn,
            cacheURL: cache,
            persistOnComplete: cacheEnabled,
            cacheRelativePath: cacheRelativePath
        )
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
        case .synology, .smb:
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

private extension MusicSource {
    var supportsRangeStreaming: Bool {
        type.category == .cloudDrive
            || type == .webdav
            || type == .synology
            || type == .qnap
            || type == .ugreen
            || type == .fnos
            || type == .s3
            || type == .smb
            || type == .sftp
            || type == .ftp
            || type == .nfs
            || type.isSubsonicFamily
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
