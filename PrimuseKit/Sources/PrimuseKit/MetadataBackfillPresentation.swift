import Foundation

/// A mutually-exclusive, user-visible state for one song's embedded metadata
/// inspection. Keeping these cases disjoint prevents one failed request from
/// making an entire source look as though every queued song failed.
public enum MetadataBackfillItemState: String, Codable, CaseIterable, Sendable {
    case pendingInspection
    case waitingForWiFi
    case retryPending
    case sourceUnavailable
    case fileUnavailable
    case unreadableTags
    case playableIncomplete
    case stalled

    public var isActionable: Bool {
        switch self {
        case .pendingInspection, .waitingForWiFi, .retryPending,
             .sourceUnavailable, .fileUnavailable, .unreadableTags, .stalled:
            true
        case .playableIncomplete:
            false
        }
    }

    public var isFailure: Bool {
        switch self {
        case .sourceUnavailable, .fileUnavailable, .unreadableTags, .stalled:
            true
        case .pendingInspection, .waitingForWiFi, .retryPending, .playableIncomplete:
            false
        }
    }
}

/// The compact, mutually-exclusive groups shared by the source summary rail
/// and the affected-song list. Keeping the grouping in one policy prevents a
/// summary count from opening a list with different membership rules.
public enum MetadataBackfillStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pending
    case retry
    case sourceProblem
    case unreadable
    case incomplete

    public var id: String { rawValue }

    public func includes(_ state: MetadataBackfillItemState) -> Bool {
        switch self {
        case .all:
            true
        case .pending:
            state == .pendingInspection || state == .waitingForWiFi
        case .retry:
            state == .retryPending || state == .stalled
        case .sourceProblem:
            state == .sourceUnavailable || state == .fileUnavailable
        case .unreadable:
            state == .unreadableTags
        case .incomplete:
            state == .playableIncomplete
        }
    }
}

public enum MetadataBackfillDisplayRedactionPolicy {
    public static func redact(_ value: String) -> String {
        var result = value
        result = replacing(
            pattern: #"(?i)(https?://)[^/@\s]+@"#,
            in: result,
            with: "$1"
        )
        result = replacing(
            pattern: #"(?i)(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?"#,
            in: result,
            with: "$1"
        )
        result = replacing(
            pattern: #"(?i)\bAuthorization:\s*[^\r\n,;]+"#,
            in: result,
            with: "Authorization: ••••"
        )
        return replacing(
            pattern: #"(?i)\b(access[_-]?token|refresh[_-]?token|token|authorization|signature|sig)=([^\s&]+)"#,
            in: result,
            with: "$1=••••"
        )
    }

    private static func replacing(
        pattern: String,
        in value: String,
        with template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: template
        )
    }
}

/// Durable context for the last failed inspection attempt. Song IDs remain the
/// source of truth for queue membership; this record only explains the exact
/// observed error without turning a transient failure into a permanent block.
public struct MetadataBackfillDiagnosticRecord: Codable, Equatable, Sendable {
    public let state: MetadataBackfillItemState
    public let reason: String
    public let attemptCount: Int
    public let lastAttemptAt: Date

    public init(
        state: MetadataBackfillItemState,
        reason: String,
        attemptCount: Int,
        lastAttemptAt: Date
    ) {
        self.state = state
        self.reason = reason
        self.attemptCount = max(0, attemptCount)
        self.lastAttemptAt = lastAttemptAt
    }
}

/// Cached, disjoint counts for one source card and its detail screen.
public struct MetadataBackfillSourceSummary: Equatable, Sendable {
    public var pendingInspectionCount: Int
    public var waitingForWiFiCount: Int
    public var retryPendingCount: Int
    public var sourceUnavailableCount: Int
    public var fileUnavailableCount: Int
    public var unreadableTagsCount: Int
    public var playableIncompleteCount: Int
    public var stalledCount: Int

    public init(
        pendingInspectionCount: Int = 0,
        waitingForWiFiCount: Int = 0,
        retryPendingCount: Int = 0,
        sourceUnavailableCount: Int = 0,
        fileUnavailableCount: Int = 0,
        unreadableTagsCount: Int = 0,
        playableIncompleteCount: Int = 0,
        stalledCount: Int = 0
    ) {
        self.pendingInspectionCount = pendingInspectionCount
        self.waitingForWiFiCount = waitingForWiFiCount
        self.retryPendingCount = retryPendingCount
        self.sourceUnavailableCount = sourceUnavailableCount
        self.fileUnavailableCount = fileUnavailableCount
        self.unreadableTagsCount = unreadableTagsCount
        self.playableIncompleteCount = playableIncompleteCount
        self.stalledCount = stalledCount
    }

    public var activeQueueCount: Int {
        pendingInspectionCount + waitingForWiFiCount
    }

    public var retryableCount: Int {
        retryPendingCount + sourceUnavailableCount + fileUnavailableCount
            + unreadableTagsCount + stalledCount
    }

    public var problemCount: Int {
        retryPendingCount + sourceUnavailableCount + fileUnavailableCount
            + unreadableTagsCount + playableIncompleteCount + stalledCount
    }

    public var affectedCount: Int {
        activeQueueCount + problemCount
    }

    public func count(for filter: MetadataBackfillStatusFilter) -> Int {
        switch filter {
        case .all:
            affectedCount
        case .pending:
            activeQueueCount
        case .retry:
            retryPendingCount + stalledCount
        case .sourceProblem:
            sourceUnavailableCount + fileUnavailableCount
        case .unreadable:
            unreadableTagsCount
        case .incomplete:
            playableIncompleteCount
        }
    }

    public mutating func record(_ state: MetadataBackfillItemState) {
        switch state {
        case .pendingInspection:
            pendingInspectionCount += 1
        case .waitingForWiFi:
            waitingForWiFiCount += 1
        case .retryPending:
            retryPendingCount += 1
        case .sourceUnavailable:
            sourceUnavailableCount += 1
        case .fileUnavailable:
            fileUnavailableCount += 1
        case .unreadableTags:
            unreadableTagsCount += 1
        case .playableIncomplete:
            playableIncompleteCount += 1
        case .stalled:
            stalledCount += 1
        }
    }
}

public enum MetadataBackfillItemStatePolicy {
    public static func resolve(
        needsInspection: Bool,
        hasUnreadableTags: Bool,
        hasPlayableIncompleteDetails: Bool,
        hasFileIssue: Bool,
        hasDeferredRetry: Bool,
        isSourceUnavailable: Bool,
        isStalled: Bool,
        isWaitingForWiFi: Bool
    ) -> MetadataBackfillItemState? {
        if hasUnreadableTags { return .unreadableTags }
        if hasFileIssue { return .fileUnavailable }
        if hasPlayableIncompleteDetails { return .playableIncomplete }
        guard needsInspection else { return nil }
        if isStalled { return .stalled }
        if isSourceUnavailable { return .sourceUnavailable }
        if hasDeferredRetry { return .retryPending }
        return isWaitingForWiFi ? .waitingForWiFi : .pendingInspection
    }
}

public enum MetadataBackfillRetrySelectionPolicy {
    /// Explicit retry may reopen a confirmed per-file failure even when the
    /// failed read completed every ordinary inspection marker. Source-wide
    /// transient parking remains limited to rows that still need work.
    public static func shouldReopen(
        needsInspection: Bool,
        hasConfirmedFailure: Bool,
        hasFileIssue: Bool,
        isSessionParked: Bool,
        automaticRetriesExhausted: Bool
    ) -> Bool {
        if hasConfirmedFailure || hasFileIssue { return true }
        guard needsInspection else { return false }
        return isSessionParked || automaticRetriesExhausted
    }
}
