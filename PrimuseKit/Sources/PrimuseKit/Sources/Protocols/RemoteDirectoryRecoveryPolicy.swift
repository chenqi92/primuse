import Foundation

public enum RemoteDirectoryListingOutcome: Equatable, Sendable {
    case populated
    case empty
    case retryableFailure
    case permanentFailure
}

public enum RemoteDirectoryRecoveryDecision: Equatable, Sendable {
    case accept
    case retryFreshConnection
    case fail
}

/// Keeps directory recovery bounded and makes protocols explicitly opt into
/// confirming an ambiguous empty response on a fresh transport. A protocol-
/// validated empty listing (for example WebDAV XML containing the directory's
/// own response) remains a normal success.
public enum RemoteDirectoryRecoveryPolicy {
    public static let maximumRetryAttempts = 1

    public static func decision(
        outcome: RemoteDirectoryListingOutcome,
        completedRetryAttempts: Int,
        emptyNeedsFreshConfirmation: Bool,
        previousAttemptWasEmpty: Bool = false
    ) -> RemoteDirectoryRecoveryDecision {
        switch outcome {
        case .populated:
            return .accept
        case .empty:
            guard emptyNeedsFreshConfirmation else {
                return .accept
            }
            if previousAttemptWasEmpty {
                return .accept
            }
            return completedRetryAttempts < maximumRetryAttempts
                ? .retryFreshConnection
                : .fail
        case .retryableFailure:
            return completedRetryAttempts < maximumRetryAttempts
                ? .retryFreshConnection
                : .fail
        case .permanentFailure:
            return .fail
        }
    }
}
