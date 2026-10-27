import Foundation

public struct MetadataReadingRate: Sendable {
    private struct Checkpoint: Sendable {
        let date: Date
        let completed: Int
    }

    private static let window: TimeInterval = 15
    private var checkpoints: [Checkpoint]
    private var completed = 0
    private var lastCompletedAt: Date?

    public init(startedAt: Date) {
        checkpoints = [Checkpoint(date: startedAt, completed: 0)]
    }

    public mutating func recordCompletion(at now: Date) {
        let previous = lastCompletedAt ?? checkpoints[0].date
        if now < previous || now.timeIntervalSince(previous) >= Self.window {
            self = Self(startedAt: now)
        }
        completed += 1
        lastCompletedAt = now
        // One cumulative checkpoint per second bounds storage even for fast
        // local files; retaining the boundary gives an exact count and duration.
        if now.timeIntervalSince(checkpoints[checkpoints.count - 1].date) >= 1 {
            checkpoints.append(Checkpoint(date: now, completed: completed))
        }
        let cutoff = now.addingTimeInterval(-Self.window)
        while checkpoints.count > 1, checkpoints[1].date <= cutoff {
            checkpoints.removeFirst()
        }
    }

    public func songsPerMinute(at now: Date) -> Double? {
        guard let lastCompletedAt, now >= lastCompletedAt,
              now.timeIntervalSince(lastCompletedAt) < Self.window else { return nil }
        let cutoff = now.addingTimeInterval(-Self.window)
        let baseline = checkpoints.last { $0.date <= cutoff } ?? checkpoints[0]
        let elapsed = now.timeIntervalSince(baseline.date)
        let count = completed - baseline.completed
        guard elapsed >= 2, count >= 2 else { return nil }
        return Double(count) * 60 / elapsed
    }
}

public struct MetadataTagRereadProgress: Sendable, Equatable {
    public let total: Int
    public var completed = 0
    public var failed = 0
    public var skipped = 0
    public var isCancelled = false
    public var processed: Int { completed + failed + skipped }

    public init(total: Int) { self.total = total }
}

public enum MetadataTagRereadBatch {
    public enum Outcome: Sendable { case completed, failed, skipped }

    /// The fixed selection survives row updates; the same live budget applies
    /// to explicit rereads and automatic backfill. TV callers retain a serial default.
    @MainActor
    public static func run(
        songIDs: [String],
        scheduler: MetadataReadScheduler<String, Outcome> = .init(),
        limits: @escaping @MainActor () -> MetadataBackfillExecutionLimits = {
            .init(workerCount: 1, snapshotLimit: 64, interRequestDelay: 0, flushInterval: 5)
        },
        read: @escaping @MainActor @Sendable (String) async -> Outcome,
        progress: @escaping @MainActor (MetadataTagRereadProgress) -> Void
    ) async -> MetadataTagRereadProgress {
        var seen = Set<String>()
        let snapshot = songIDs.filter { seen.insert($0).inserted }
        var result = MetadataTagRereadProgress(total: snapshot.count)
        progress(result)
        let cancelled = await scheduler.run(items: snapshot, limits: limits, read: read) { _, outcome in
            guard !Task.isCancelled else { return }
            switch outcome {
            case .completed: result.completed += 1
            case .failed: result.failed += 1
            case .skipped: result.skipped += 1
            }
            progress(result)
        }
        result.isCancelled = cancelled || Task.isCancelled
        progress(result)
        return result
    }
}

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
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)(https?://)[^/@\s]+@"#, "$1"),
        (#"(?i)(https?://[^\s?#]+)(?:\?[^\s#]*)?(?:#[^\s]*)?"#, "$1"),
        (#"(?i)\bAuthorization:\s*[^\r\n,;]+"#, "Authorization: ••••"),
        (#"(?i)\b(access[_-]?token|refresh[_-]?token|token|authorization|signature|sig)=([^\s&]+)"#, "$1=••••"),
    ].compactMap { pattern, replacement in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, replacement) }
    }

    public static func redact(_ value: String) -> String {
        // Ordinary local paths cannot match any credential rule. Reuse the
        // immutable expressions when a row does contain URL/header material.
        guard value.contains(":") || value.contains("=") else { return value }
        return rules.reduce(value) { result, rule in
            rule.0.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..<result.endIndex, in: result),
                withTemplate: rule.1
            )
        }
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

    /// 源卡片只为用户自己看得出来的问题露面：标签读不出来、来源或文件出了问题。
    /// 排队、等 Wi-Fi、等重试、无进展都由后台自己收尾，只留在详情页。
    public var cardProblemCount: Int {
        sourceUnavailableCount + fileUnavailableCount + unreadableTagsCount
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
