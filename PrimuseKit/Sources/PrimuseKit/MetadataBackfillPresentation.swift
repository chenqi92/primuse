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

/// A status-row projection that deliberately excludes heavyweight `Song`
/// fields such as lyrics and artwork. The source detail screen can safely
/// move filtering and sorting of these values off the main actor.
public struct MetadataBackfillStatusDisplayItem: Identifiable, Equatable, Sendable {
    public let songID: String
    public let title: String
    public let artistName: String?
    public let filePath: String
    public let fileFormat: String
    public let hasMissingDuration: Bool
    public let state: MetadataBackfillItemState
    public let workReasons: MetadataBackfillWorkReasons
    public let diagnostic: MetadataBackfillDiagnosticRecord?
    public let attemptCount: Int

    public var id: String { songID }

    public init(
        songID: String,
        title: String,
        artistName: String?,
        filePath: String,
        fileFormat: String,
        hasMissingDuration: Bool,
        state: MetadataBackfillItemState,
        workReasons: MetadataBackfillWorkReasons,
        diagnostic: MetadataBackfillDiagnosticRecord?,
        attemptCount: Int
    ) {
        self.songID = songID
        self.title = title
        self.artistName = artistName
        self.filePath = filePath
        self.fileFormat = fileFormat
        self.hasMissingDuration = hasMissingDuration
        self.state = state
        self.workReasons = workReasons
        self.diagnostic = diagnostic
        self.attemptCount = max(0, attemptCount)
    }
}

public enum MetadataBackfillStatusProjectionPolicy {
    public static func project(
        _ items: [MetadataBackfillStatusDisplayItem],
        filter: MetadataBackfillStatusFilter,
        query: String
    ) -> [MetadataBackfillStatusDisplayItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items
            .filter { item in
                guard filter.includes(item.state) else { return false }
                guard !normalizedQuery.isEmpty else { return true }
                return item.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || item.filePath.localizedCaseInsensitiveContains(normalizedQuery)
                    || (item.artistName?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                    || item.fileFormat.localizedCaseInsensitiveContains(normalizedQuery)
            }
            .sorted { lhs, rhs in
                let leftPriority = sortPriority(lhs.state)
                let rightPriority = sortPriority(rhs.state)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                let pathOrder = lhs.filePath.localizedStandardCompare(rhs.filePath)
                if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
                return lhs.songID < rhs.songID
            }
    }

    private static func sortPriority(_ state: MetadataBackfillItemState) -> Int {
        switch state {
        case .sourceUnavailable, .fileUnavailable: 0
        case .retryPending, .stalled: 1
        case .unreadableTags: 2
        case .waitingForWiFi: 3
        case .pendingInspection: 4
        case .playableIncomplete: 5
        }
    }
}

public enum MetadataBackfillStatusPaginationPolicy {
    public static let defaultPageSize = 160

    public static func initialVisibleCount(
        totalCount: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        min(max(0, totalCount), max(1, pageSize))
    }

    public static func nextVisibleCount(
        currentCount: Int,
        totalCount: Int,
        pageSize: Int = defaultPageSize
    ) -> Int {
        let boundedTotal = max(0, totalCount)
        let boundedCurrent = min(max(0, currentCount), boundedTotal)
        return min(boundedTotal, boundedCurrent + max(1, pageSize))
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
