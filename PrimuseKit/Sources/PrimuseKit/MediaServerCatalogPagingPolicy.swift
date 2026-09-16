import Foundation

/// One library's slice of a catalogue page.
public struct MediaServerCatalogPageRequest: Sendable, Equatable {
    /// Index into the ordered segment list the page space was built from.
    public let segmentIndex: Int
    /// Offset inside that library, i.e. the provider's `StartIndex`.
    public let startIndex: Int
    /// Rows to ask that library for, i.e. the provider's `Limit`.
    public let limit: Int

    public init(segmentIndex: Int, startIndex: Int, limit: Int) {
        self.segmentIndex = segmentIndex
        self.startIndex = startIndex
        self.limit = limit
    }
}

/// Jellyfin and Emby page per library, while the resumable catalogue walk needs
/// one flat offset space it can checkpoint and resume in. This flattens the
/// libraries — in a fixed order, back to back — and translates a global offset
/// into the per-library requests that fill exactly one page.
///
/// Pages must stay full until the real end of the catalogue: the caller treats
/// a short page as terminal, so a page that stopped at a library boundary
/// instead of continuing into the next one would truncate the walk.
public enum MediaServerCatalogPagingPolicy {
    public static func totalCount(segmentCounts: [Int]) -> Int {
        segmentCounts.reduce(0) { $0 + max(0, $1) }
    }

    public static func pageRequests(
        offset: Int,
        pageSize: Int,
        segmentCounts: [Int]
    ) -> [MediaServerCatalogPageRequest] {
        guard offset >= 0, pageSize > 0 else { return [] }
        var requests: [MediaServerCatalogPageRequest] = []
        var cursor = offset
        var remaining = pageSize
        var base = 0
        for (index, rawCount) in segmentCounts.enumerated() {
            let count = max(0, rawCount)
            let end = base + count
            defer { base = end }
            guard remaining > 0, count > 0, cursor < end else { continue }
            let localStart = max(0, cursor - base)
            let limit = min(remaining, count - localStart)
            guard limit > 0 else { continue }
            requests.append(
                MediaServerCatalogPageRequest(
                    segmentIndex: index,
                    startIndex: localStart,
                    limit: limit
                )
            )
            remaining -= limit
            cursor += limit
        }
        return requests
    }
}
