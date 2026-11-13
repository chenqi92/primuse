import Foundation
import Citadel
import PrimuseKit

enum SourceFileMutationError: Error, LocalizedError, Sendable, Equatable {
    case permissionDenied
    case readOnly
    /// FTP can reject a write without distinguishing missing paths from ACLs.
    case writeRejected(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "source_mutation_permission_denied", defaultValue: "Permission to modify source files was denied.")
        case .readOnly: String(localized: "source_mutation_read_only", defaultValue: "This source does not allow file changes.")
        case .writeRejected(let message): message
        }
    }
}

/// Protocol support is not account authorization. Classify typed failures only;
/// never infer permissions from localized error strings or a failed read.
enum MetadataWriteFailurePolicy {
    static func denial(_ error: any Error, depth: Int = 0) -> SourceFileMutationError? {
        guard !OperationCancellationPolicy.isCancellation(error) else { return nil }
        switch error {
        case SourceFileMutationError.permissionDenied: return .permissionDenied
        case SourceFileMutationError.readOnly: return .readOnly
        case EmbeddedMetadataCoordinatedWritebackError.accessDenied(_, _, let reason): return reason
        case CloudDriveError.permissionDenied(let permission):
            if case .fileWrite = permission { return .permissionDenied }
            return nil
        case let status as SFTPMessage.Status where status.errorCode == .permissionDenied:
            return .permissionDenied
        case SynologyError.fileOperationError(let code, _):
            if code == 105 || code == 407 { return .permissionDenied }
            if code == 411 { return .readOnly }
        default: break
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            if ns.code == Int(EACCES) || ns.code == Int(EPERM) { return .permissionDenied }
            if ns.code == Int(EROFS) { return .readOnly }
        }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteNoPermissionError { return .permissionDenied }
            if ns.code == NSFileWriteVolumeReadOnlyError { return .readOnly }
        }
        if depth < 8, let underlying = ns.userInfo[NSUnderlyingErrorKey] as? any Error {
            return denial(underlying, depth: depth + 1)
        }
        return nil
    }

    static func stopsSourceWrites(_ error: any Error) -> Bool {
        if denial(error) != nil { return true }
        switch error {
        case SourceFileMutationError.writeRejected,
             SourceError.authenticationFailed, SourceError.credentialUnavailable,
             CloudDriveError.notAuthenticated, CloudDriveError.tokenExpired,
             CloudDriveError.tokenRefreshFailed, CloudDriveError.permissionDenied,
             SynologyError.notLoggedIn:
            return true
        default: return false
        }
    }

    static func allowsLocalSave(_ error: any Error, depth: Int = 0) -> Bool {
        guard !OperationCancellationPolicy.isCancellation(error) else { return false }
        // A denied verification read can follow a committed replacement. It
        // must not turn an uncertain remote outcome into a successful save.
        if case EmbeddedMetadataCoordinatedWritebackError.accessDenied(_, let stage, _) = error {
            return stage == .replace
        }
        if case CloudDriveError.permissionDenied(let permission) = error {
            if case .fileWrite = permission { return true }
            return false
        }
        if depth < 8, let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error {
            return allowsLocalSave(underlying, depth: depth + 1)
        }
        return denial(error) != nil
    }

    static var localSaveNotice: String {
        String(localized: "metadata_writeback_local_only_notice",
               defaultValue: "The source refused write access. Your changes were saved only in Primuse; the source file was not updated.")
    }

    /// A failure that may well not happen again a moment later: a timeout, a
    /// dropped or refused connection, a server error. A refusal, a sign-in
    /// problem, a missing file or a conflict is not one — trying again gives
    /// the same answer.
    static func isTransient(_ error: any Error, depth: Int = 0) -> Bool {
        guard !OperationCancellationPolicy.isCancellation(error) else { return false }
        if denial(error) != nil || stopsSourceWrites(error) { return false }
        if RemoteDirectoryTransportErrorPolicy.isRetryable(error) { return true }
        switch error {
        case let ftp as FTPClientError:
            switch ftp {
            case .timedOut, .connectionClosed, .connectionFailed, .dataConnectionFailed: return true
            case .replyFailure(_, let code, _): return code == 421 || code == 425 || code == 426
            case .activeModeUnavailable, .invalidReply, .cancelled: return false
            }
        case CloudDriveError.apiError(let status, _):
            return CloudHTTPRetryPolicy.shouldRetry(statusCode: status)
        default:
            break
        }
        if depth < 8, let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error {
            return isTransient(underlying, depth: depth + 1)
        }
        return false
    }
}

/// Sources that refused to have a file rewritten, and when. A batch edit says
/// before it starts that these changes may stay in Primuse again; the next
/// write that goes through forgets the refusal.
@MainActor
enum SourceWriteRefusalMemory {
    private static let defaultsKey = "metadataWriteback.refusedSources.v1"
    /// Older refusals say little about the source today.
    static let relevance: TimeInterval = 30 * 24 * 60 * 60

    static func recordRefusal(sourceID: String, at date: Date = Date()) {
        var stored = load()
        stored[sourceID] = date.timeIntervalSince1970
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    static func recordWrite(sourceID: String) {
        var stored = load()
        guard stored.removeValue(forKey: sourceID) != nil else { return }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// The sources among these that refused a write recently.
    static func recentlyRefused(among sourceIDs: Set<String>, now: Date = Date()) -> Set<String> {
        let stored = load()
        return sourceIDs.filter { id in
            guard let seconds = stored[id] else { return false }
            return now.timeIntervalSince1970 - seconds < relevance
        }
    }

    private static func load() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Double] ?? [:]
    }
}

enum SourceError: Error, LocalizedError, Sendable {
    case pathNotFound(String)
    case fileNotFound(String)
    case connectionFailed(String)
    case credentialUnavailable(String)
    case authenticationFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .pathNotFound(let path):
            return String(format: String(localized: "error_path_not_found %@"), path)
        case .fileNotFound(let path):
            return String(format: String(localized: "error_file_not_found %@"), path)
        case .connectionFailed(let message):
            return String(format: String(localized: "error_connection_failed %@"), message)
        case .credentialUnavailable(let msg): return msg
        case .authenticationFailed:
            return String(localized: "error_authentication_failed")
        case .timeout:
            return String(localized: "error_connection_timeout")
        }
    }
}

/// A route reached the service but cannot proceed without user action (for
/// example a rejected password, account lock or required password change).
/// Adaptive routing must not repeat that login against every saved endpoint.
struct SourceConnectionTerminalError: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Text for a source failure shown to the listener. A `URLError` built in code
/// (a timeout race, for example) carries no localized description, and
/// Foundation then renders it as "NSURLErrorDomain error -1001".
enum SourceErrorPresentation {
    static func userFacingDescription(_ error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error.localizedDescription }
        if let described = nsError.userInfo[NSLocalizedDescriptionKey] as? String,
           !described.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return described
        }
        switch URLError.Code(rawValue: nsError.code) {
        case .timedOut:
            return String(localized: "error_connection_timeout")
        default:
            return String(localized: "playback_error_connection")
        }
    }
}
