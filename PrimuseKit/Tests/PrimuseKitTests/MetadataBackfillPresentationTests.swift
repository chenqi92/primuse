import Foundation
import Testing
@testable import PrimuseKit

@Suite("Metadata backfill presentation")
struct MetadataBackfillPresentationTests {
    @Test("One song resolves to exactly one visible state")
    func stateResolutionIsMutuallyExclusive() {
        #expect(resolve() == .pendingInspection)
        #expect(resolve(isWaitingForWiFi: true) == .waitingForWiFi)
        #expect(resolve(hasDeferredRetry: true) == .retryPending)
        #expect(resolve(
            hasDeferredRetry: true,
            isSourceUnavailable: true
        ) == .sourceUnavailable)
        #expect(resolve(
            hasUnreadableTags: true,
            hasFileIssue: true,
            isSourceUnavailable: true
        ) == .unreadableTags)
        #expect(resolve(
            hasPlayableIncompleteDetails: true,
            hasDeferredRetry: true
        ) == .playableIncomplete)
        #expect(resolve(
            hasFileIssue: true,
            hasDeferredRetry: true
        ) == .fileUnavailable)
        #expect(resolve(
            isSourceUnavailable: true,
            isStalled: true
        ) == .stalled)
        #expect(resolve(
            needsInspection: false,
            isSourceUnavailable: true
        ) == nil)
    }

    @Test("Source totals keep pending, retry, and failures disjoint")
    func summaryTotalsAreDisjoint() {
        var summary = MetadataBackfillSourceSummary()
        for state in MetadataBackfillItemState.allCases {
            summary.record(state)
        }

        #expect(summary.pendingInspectionCount == 1)
        #expect(summary.waitingForWiFiCount == 1)
        #expect(summary.retryPendingCount == 1)
        #expect(summary.sourceUnavailableCount == 1)
        #expect(summary.fileUnavailableCount == 1)
        #expect(summary.unreadableTagsCount == 1)
        #expect(summary.playableIncompleteCount == 1)
        #expect(summary.stalledCount == 1)
        #expect(summary.activeQueueCount == 2)
        #expect(summary.retryableCount == 5)
        #expect(summary.problemCount == 6)
        #expect(summary.affectedCount == 8)
    }

    @Test("Summary rail and result filters share one disjoint grouping")
    func statusFiltersPartitionEveryVisibleState() {
        let visibleFilters = MetadataBackfillStatusFilter.allCases.filter { $0 != .all }

        for state in MetadataBackfillItemState.allCases {
            let matches = visibleFilters.filter { $0.includes(state) }
            #expect(matches.count == 1)
            #expect(MetadataBackfillStatusFilter.all.includes(state))
        }

        let summary = MetadataBackfillSourceSummary(
            pendingInspectionCount: 2,
            waitingForWiFiCount: 3,
            retryPendingCount: 5,
            sourceUnavailableCount: 7,
            fileUnavailableCount: 11,
            unreadableTagsCount: 13,
            playableIncompleteCount: 17,
            stalledCount: 19
        )

        #expect(summary.count(for: .all) == 77)
        #expect(summary.count(for: .pending) == 5)
        #expect(summary.count(for: .retry) == 24)
        #expect(summary.count(for: .sourceProblem) == 18)
        #expect(summary.count(for: .unreadable) == 13)
        #expect(summary.count(for: .incomplete) == 17)
    }

    @Test("Diagnostic display removes signed URL and credential material")
    func diagnosticDisplayRedactsCredentials() {
        let signedURL = "GET https://alice:secret@example.com/song.flac?token=abc&sig=def#preview Authorization: Bearer xyz"
        #expect(
            MetadataBackfillDisplayRedactionPolicy.redact(signedURL)
                == "GET https://example.com/song.flac Authorization: ••••"
        )

        let looseSecrets = "access_token=abc signature=def retry later"
        #expect(
            MetadataBackfillDisplayRedactionPolicy.redact(looseSecrets)
                == "access_token=•••• signature=•••• retry later"
        )
    }

    @Test("Persisted diagnostics retain exact failure context")
    func diagnosticRoundTrip() throws {
        let timestamp = Date(timeIntervalSince1970: 1_725_000_000)
        let record = MetadataBackfillDiagnosticRecord(
            state: .fileUnavailable,
            reason: "HTTP 416 while reading FLAC tail",
            attemptCount: 3,
            lastAttemptAt: timestamp
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(
            MetadataBackfillDiagnosticRecord.self,
            from: data
        )

        #expect(decoded == record)
    }

    @Test("Explicit retry reopens terminal failures without broad source churn")
    func retrySelectionKeepsTerminalAndTransientRulesDistinct() {
        #expect(MetadataBackfillRetrySelectionPolicy.shouldReopen(
            needsInspection: false,
            hasConfirmedFailure: true,
            hasFileIssue: false,
            isSessionParked: false,
            automaticRetriesExhausted: false
        ))
        #expect(MetadataBackfillRetrySelectionPolicy.shouldReopen(
            needsInspection: false,
            hasConfirmedFailure: false,
            hasFileIssue: true,
            isSessionParked: false,
            automaticRetriesExhausted: false
        ))
        #expect(!MetadataBackfillRetrySelectionPolicy.shouldReopen(
            needsInspection: false,
            hasConfirmedFailure: false,
            hasFileIssue: false,
            isSessionParked: true,
            automaticRetriesExhausted: true
        ))
        #expect(MetadataBackfillRetrySelectionPolicy.shouldReopen(
            needsInspection: true,
            hasConfirmedFailure: false,
            hasFileIssue: false,
            isSessionParked: true,
            automaticRetriesExhausted: false
        ))
    }

    @Test("Lightweight status projection filters and sorts without Song values")
    func statusProjectionFiltersAndSortsStableRows() {
        let rows = [
            makeDisplayItem(id: "pending-b", title: "Beta", state: .pendingInspection),
            makeDisplayItem(id: "retry", title: "Zulu", state: .retryPending),
            makeDisplayItem(id: "source", title: "Alpha", state: .sourceUnavailable),
            makeDisplayItem(id: "pending-a", title: "Alpha", state: .pendingInspection),
            makeDisplayItem(
                id: "artist-match",
                title: "No title match",
                artist: "Needle Artist",
                state: .fileUnavailable
            ),
        ]

        let all = MetadataBackfillStatusProjectionPolicy.project(
            rows,
            filter: .all,
            query: ""
        )
        #expect(all.map(\.songID) == [
            "source", "artist-match", "retry", "pending-a", "pending-b",
        ])

        let artistSearch = MetadataBackfillStatusProjectionPolicy.project(
            rows,
            filter: .sourceProblem,
            query: " needle "
        )
        #expect(artistSearch.map(\.songID) == ["artist-match"])
    }

    @Test("Search projects the complete source before the first display page")
    func statusSearchCoversRowsBeyondInitialPage() {
        let rows = (0..<1_000).map { index in
            makeDisplayItem(
                id: "song-\(index)",
                title: index == 999 ? "Deep Needle" : "Track \(index)",
                state: .pendingInspection
            )
        }

        let projected = MetadataBackfillStatusProjectionPolicy.project(
            rows,
            filter: .all,
            query: "needle"
        )

        #expect(projected.map(\.songID) == ["song-999"])
        #expect(!rows.prefix(MetadataBackfillStatusPaginationPolicy.defaultPageSize)
            .contains { $0.songID == "song-999" })
    }

    @Test("Status pages grow in bounded increments and clamp to the result count")
    func statusPaginationIsBounded() {
        #expect(MetadataBackfillStatusPaginationPolicy.initialVisibleCount(
            totalCount: 1_000,
            pageSize: 128
        ) == 128)
        #expect(MetadataBackfillStatusPaginationPolicy.nextVisibleCount(
            currentCount: 128,
            totalCount: 1_000,
            pageSize: 128
        ) == 256)
        #expect(MetadataBackfillStatusPaginationPolicy.nextVisibleCount(
            currentCount: 990,
            totalCount: 1_000,
            pageSize: 128
        ) == 1_000)
        #expect(MetadataBackfillStatusPaginationPolicy.initialVisibleCount(
            totalCount: -1,
            pageSize: 0
        ) == 0)
    }

    private func resolve(
        needsInspection: Bool = true,
        hasUnreadableTags: Bool = false,
        hasPlayableIncompleteDetails: Bool = false,
        hasFileIssue: Bool = false,
        hasDeferredRetry: Bool = false,
        isSourceUnavailable: Bool = false,
        isStalled: Bool = false,
        isWaitingForWiFi: Bool = false
    ) -> MetadataBackfillItemState? {
        MetadataBackfillItemStatePolicy.resolve(
            needsInspection: needsInspection,
            hasUnreadableTags: hasUnreadableTags,
            hasPlayableIncompleteDetails: hasPlayableIncompleteDetails,
            hasFileIssue: hasFileIssue,
            hasDeferredRetry: hasDeferredRetry,
            isSourceUnavailable: isSourceUnavailable,
            isStalled: isStalled,
            isWaitingForWiFi: isWaitingForWiFi
        )
    }

    private func makeDisplayItem(
        id: String,
        title: String,
        artist: String? = nil,
        state: MetadataBackfillItemState
    ) -> MetadataBackfillStatusDisplayItem {
        MetadataBackfillStatusDisplayItem(
            songID: id,
            title: title,
            artistName: artist,
            filePath: "/music/\(id).flac",
            fileFormat: "FLAC",
            hasMissingDuration: false,
            state: state,
            workReasons: [.artwork],
            diagnostic: nil,
            attemptCount: 0
        )
    }
}
