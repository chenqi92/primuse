import Foundation

enum SourceFileMutationError: Error, LocalizedError, Sendable {
    case permissionDenied
    case readOnly

    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "delete_source_permission_denied")
        case .readOnly: String(localized: "delete_source_read_only")
        }
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
