import Foundation
import Testing

@testable import PrimuseKit

struct MediaServerCatalogPagingPolicyTests {
    private typealias Policy = MediaServerCatalogPagingPolicy
    private typealias Request = MediaServerCatalogPageRequest

    /// One provider row, identified by the library it lives in.
    private struct CatalogRow: Equatable, CustomStringConvertible {
        let segmentIndex: Int
        let row: Int

        var description: String { "\(segmentIndex):\(row)" }
    }

    @Test func singleLibraryPagesFromTheStart() {
        #expect(
            Policy.pageRequests(offset: 0, pageSize: 500, segmentCounts: [70_000])
                == [Request(segmentIndex: 0, startIndex: 0, limit: 500)]
        )
    }

    @Test func singleLibraryLastPageIsShort() {
        #expect(
            Policy.pageRequests(offset: 69_800, pageSize: 500, segmentCounts: [70_000])
                == [Request(segmentIndex: 0, startIndex: 69_800, limit: 200)]
        )
    }

    @Test func offsetPastTheEndAsksForNothing() {
        #expect(Policy.pageRequests(offset: 70_000, pageSize: 500, segmentCounts: [70_000]).isEmpty)
        #expect(Policy.pageRequests(offset: 99_999, pageSize: 500, segmentCounts: [70_000]).isEmpty)
    }

    @Test func pageContinuesAcrossALibraryBoundary() {
        #expect(
            Policy.pageRequests(offset: 0, pageSize: 500, segmentCounts: [300, 400])
                == [
                    Request(segmentIndex: 0, startIndex: 0, limit: 300),
                    Request(segmentIndex: 1, startIndex: 0, limit: 200),
                ]
        )
    }

    @Test func secondPageResumesInsideTheSecondLibrary() {
        #expect(
            Policy.pageRequests(offset: 500, pageSize: 500, segmentCounts: [300, 400])
                == [Request(segmentIndex: 1, startIndex: 200, limit: 200)]
        )
    }

    @Test func emptyLibrariesOccupyNoOffsets() {
        #expect(
            Policy.pageRequests(offset: 0, pageSize: 500, segmentCounts: [0, 500, 0])
                == [Request(segmentIndex: 1, startIndex: 0, limit: 500)]
        )
        #expect(
            Policy.pageRequests(offset: 10, pageSize: 5, segmentCounts: [0, 20, 0, 20])
                == [Request(segmentIndex: 1, startIndex: 10, limit: 5)]
        )
    }

    @Test func onePageCanSpanThreeLibraries() {
        #expect(
            Policy.pageRequests(offset: 50, pageSize: 500, segmentCounts: [100, 100, 100])
                == [
                    Request(segmentIndex: 0, startIndex: 50, limit: 50),
                    Request(segmentIndex: 1, startIndex: 0, limit: 100),
                    Request(segmentIndex: 2, startIndex: 0, limit: 100),
                ]
        )
    }

    @Test func degenerateInputsAskForNothing() {
        #expect(Policy.pageRequests(offset: -1, pageSize: 500, segmentCounts: [10]).isEmpty)
        #expect(Policy.pageRequests(offset: 0, pageSize: 0, segmentCounts: [10]).isEmpty)
        #expect(Policy.pageRequests(offset: 0, pageSize: 500, segmentCounts: []).isEmpty)
        #expect(Policy.pageRequests(offset: 0, pageSize: 500, segmentCounts: [0, 0]).isEmpty)
        // A negative count cannot occupy offsets and must not shift the ones after it.
        #expect(
            Policy.pageRequests(offset: 0, pageSize: 4, segmentCounts: [-5, 10])
                == [Request(segmentIndex: 1, startIndex: 0, limit: 4)]
        )
    }

    /// Walking the whole catalogue one page at a time must visit every row of
    /// every library exactly once, in order, and every page before the last
    /// must be full — a short page is what tells the caller the walk ended.
    @Test func completeWalkCoversEveryRowExactlyOnce() {
        let layouts: [[Int]] = [
            [1],
            [500],
            [501],
            [70_000],
            [300, 400],
            [1, 1, 1, 1],
            [0, 500, 0, 7],
            [999, 1, 1_000, 3],
            [123, 456, 789],
            [500, 500, 500],
        ]
        for pageSize in [1, 3, 500] {
            for counts in layouts {
                let total = Policy.totalCount(segmentCounts: counts)
                var visited: [CatalogRow] = []
                var offset = 0
                var pages = 0
                while true {
                    let requests = Policy.pageRequests(
                        offset: offset,
                        pageSize: pageSize,
                        segmentCounts: counts
                    )
                    if requests.isEmpty { break }
                    pages += 1
                    #expect(pages <= total + 1, "walk did not terminate for \(counts)")
                    let served = requests.reduce(0) { $0 + $1.limit }
                    #expect(served <= pageSize)
                    for request in requests {
                        #expect(request.startIndex >= 0)
                        #expect(request.limit > 0)
                        #expect(request.startIndex + request.limit <= counts[request.segmentIndex])
                        for row in request.startIndex..<(request.startIndex + request.limit) {
                            visited.append(CatalogRow(segmentIndex: request.segmentIndex, row: row))
                        }
                    }
                    offset += served
                    // Only the final page may be short; otherwise the caller
                    // would stop the walk early.
                    if served < pageSize {
                        #expect(offset == total, "short page before the end of \(counts)")
                        break
                    }
                }
                #expect(offset == total, "walk stopped at \(offset) of \(total) for \(counts)")

                var expected: [CatalogRow] = []
                for (index, count) in counts.enumerated() where count > 0 {
                    for row in 0..<count {
                        expected.append(CatalogRow(segmentIndex: index, row: row))
                    }
                }
                #expect(visited == expected)
            }
        }
    }

    /// The same layout must produce the same requests regardless of where the
    /// walk was interrupted — that is what makes a staged page resumable.
    @Test func requestsDependOnlyOnTheOffset() {
        let counts = [733, 0, 1_299, 44]
        for offset in stride(from: 0, to: 2_100, by: 37) {
            let first = Policy.pageRequests(offset: offset, pageSize: 500, segmentCounts: counts)
            let second = Policy.pageRequests(offset: offset, pageSize: 500, segmentCounts: counts)
            #expect(first == second)
        }
    }
}
