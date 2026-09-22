import Foundation
import Testing
@testable import PrimuseKit

@Suite("Search result section layout")
struct SearchResultSectionLayoutTests {
    @Test("An empty or unreadable store keeps the original search page order")
    func defaultsWhenNothingStored() {
        #expect(SearchResultSectionLayout.decodeOrder("") == SearchResultSectionLayout.defaultOrder)
        #expect(SearchResultSectionLayout.decodeOrder("not json") == SearchResultSectionLayout.defaultOrder)
        #expect(SearchResultSectionLayout.decodeHidden("").isEmpty)
    }

    @Test("Every section appears exactly once in the default order")
    func defaultOrderCoversAllSections() {
        let order = SearchResultSectionLayout.defaultOrder
        #expect(Set(order) == Set(SearchResultSection.allCases))
        #expect(order.count == SearchResultSection.allCases.count)
    }

    @Test("A stored order round-trips")
    func orderRoundTrips() {
        let custom: [SearchResultSection] = [
            .metadata, .lyrics, .albums, .artists, .path, .fuzzy, .appleMusic, .intelligent,
        ]
        let encoded = SearchResultSectionLayout.encodeOrder(custom)
        #expect(SearchResultSectionLayout.decodeOrder(encoded) == custom)
    }

    @Test("The default order is stored as an empty string so later defaults still apply")
    func defaultOrderEncodesEmpty() {
        #expect(SearchResultSectionLayout.encodeOrder(SearchResultSectionLayout.defaultOrder).isEmpty)
    }

    @Test("Unknown entries are dropped without discarding the rest of the order")
    func unknownEntriesAreDropped() {
        let raw = #"["lyrics","somethingNew","metadata","lyrics"]"#
        let order = SearchResultSectionLayout.decodeOrder(raw)
        #expect(order.filter { $0 == .lyrics }.count == 1)
        #expect(order.firstIndex(of: .lyrics)! < order.firstIndex(of: .metadata)!)
        #expect(Set(order) == Set(SearchResultSection.allCases))
    }

    @Test("A section missing from the store returns to its default neighbourhood")
    func missingSectionInsertedAtDefaultPosition() {
        // 老存档里没有 intelligent,应落在 fuzzy 之后、appleMusic 之前。
        let raw = #"["metadata","albums","artists","path","lyrics","fuzzy","appleMusic"]"#
        let order = SearchResultSectionLayout.decodeOrder(raw)
        let fuzzy = order.firstIndex(of: .fuzzy)!
        let intelligent = order.firstIndex(of: .intelligent)!
        let appleMusic = order.firstIndex(of: .appleMusic)!
        #expect(fuzzy < intelligent)
        #expect(intelligent < appleMusic)
        #expect(order.first == .metadata)
    }

    @Test("Hidden sections round-trip")
    func hiddenRoundTrips() {
        let hidden: Set<SearchResultSection> = [.path, .fuzzy, .albums]
        let encoded = SearchResultSectionLayout.encodeHidden(hidden)
        #expect(SearchResultSectionLayout.decodeHidden(encoded) == hidden)
        #expect(SearchResultSectionLayout.encodeHidden([]).isEmpty)
    }

    @Test("Apple Music visibility belongs to the catalog search switch, not this store")
    func appleMusicNeverStoredAsHidden() {
        let encoded = SearchResultSectionLayout.encodeHidden([.appleMusic, .path])
        #expect(SearchResultSectionLayout.decodeHidden(encoded) == [.path])
        #expect(SearchResultSectionLayout.decodeHidden(#"["appleMusic"]"#).isEmpty)
    }

    @Test("The last local section cannot be hidden")
    func lastLocalSectionStays() {
        let local = SearchResultSection.allCases.filter(\.isLocal)
        let allButMetadata = Set(local).subtracting([.metadata])
        #expect(!SearchResultSectionLayout.canHide(.metadata, hidden: allButMetadata))
        #expect(SearchResultSectionLayout.canHide(.metadata, hidden: allButMetadata.subtracting([.lyrics])))
        // Apple Music 不算本机结果,它开着也挡不住最后一块本机结果被保留。
        #expect(SearchResultSectionLayout.canHide(.appleMusic, hidden: allButMetadata))
    }

    @Test("A store that hides every local section keeps the first one visible")
    func storeHidingEverythingIsRepaired() {
        let raw = SearchResultSection.allCases
            .map { "\"\($0.rawValue)\"" }
            .joined(separator: ",")
        let hidden = SearchResultSectionLayout.decodeHidden("[\(raw)]")
        #expect(!hidden.contains(.albums))
        #expect(hidden.contains(.artists))
        #expect(!hidden.contains(.appleMusic))
    }

    @Test("Moving within all rows matches Array.move semantics")
    func reorderWithAllRowsDisplayed() {
        let order = SearchResultSectionLayout.defaultOrder
        // 把 lyrics(第 4 行)拖到最前面。
        let moved = SearchResultSectionLayout.reordering(
            order,
            displayed: order,
            fromOffsets: IndexSet(integer: 4),
            toOffset: 0
        )
        #expect(moved == [.lyrics, .albums, .artists, .metadata, .path, .fuzzy, .intelligent, .appleMusic])

        // 把 albums 拖到 metadata 之后(目标下标按移走前算)。
        let down = SearchResultSectionLayout.reordering(
            order,
            displayed: order,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3
        )
        #expect(down == [.artists, .metadata, .albums, .path, .lyrics, .fuzzy, .intelligent, .appleMusic])
    }

    @Test("Rows the editor does not list keep their place while the others move")
    func reorderSkipsUndisplayedRows() {
        let order = SearchResultSectionLayout.defaultOrder
        let displayed = order.filter { $0 != .intelligent && $0 != .appleMusic }
        // 列出来的最后一行 fuzzy 拖到最前面。
        let moved = SearchResultSectionLayout.reordering(
            order,
            displayed: displayed,
            fromOffsets: IndexSet(integer: displayed.count - 1),
            toOffset: 0
        )
        #expect(moved == [.fuzzy, .albums, .artists, .metadata, .path, .lyrics, .intelligent, .appleMusic])
    }

    @Test("Out-of-range moves leave the order untouched")
    func invalidMoveIsIgnored() {
        let order = SearchResultSectionLayout.defaultOrder
        let moved = SearchResultSectionLayout.reordering(
            order,
            displayed: order,
            fromOffsets: IndexSet(integer: 42),
            toOffset: 0
        )
        #expect(moved == order)
    }
}

@Suite("Search result page layout")
struct SearchResultPageLayoutTests {
    private let all = Set(SearchResultSection.allCases)

    @Test("Column count grows with width and stops at three")
    func columnCount() {
        #expect(SearchResultPageLayout.columnCount(for: 0) == 1)
        #expect(SearchResultPageLayout.columnCount(for: 500) == 1)
        #expect(SearchResultPageLayout.columnCount(for: 704) == 2)
        #expect(SearchResultPageLayout.columnCount(for: 1100) == 3)
        #expect(SearchResultPageLayout.columnCount(for: 3000) == 3)
    }

    @Test("The first block with items sits beside the top match")
    func heroNeighborIsFirstWithItems() {
        let plan = SearchResultPageLayout.plan(
            order: SearchResultSectionLayout.defaultOrder,
            present: all.subtracting([.albums]),
            withItems: all.subtracting([.albums, .appleMusic]),
            hasTopMatch: true,
            width: 1165
        )
        #expect(plan.heroNeighbor == .artists)
        #expect(!plan.rows.flatMap(\.sections).contains(.artists))
    }

    @Test("Shelves take a full row and adjacent lists pair up")
    func rowsPackByForm() {
        let plan = SearchResultPageLayout.plan(
            order: SearchResultSectionLayout.defaultOrder,
            present: all,
            withItems: all,
            hasTopMatch: true,
            width: 1165
        )
        #expect(plan.heroNeighbor == .albums)
        #expect(plan.rows.map(\.sections) == [
            [.artists],
            [.metadata, .path, .lyrics],
            [.fuzzy, .intelligent],
            [.appleMusic],
        ])
    }

    @Test("A narrow page stacks every block and drops the hero neighbour")
    func narrowPageStacks() {
        let plan = SearchResultPageLayout.plan(
            order: SearchResultSectionLayout.defaultOrder,
            present: all,
            withItems: all,
            hasTopMatch: true,
            width: 600
        )
        #expect(plan.heroNeighbor == nil)
        #expect(plan.rows.allSatisfy { $0.sections.count == 1 })
        #expect(plan.rows.count == SearchResultSection.allCases.count)
    }

    @Test("Without a top match nothing is pulled up beside it")
    func noTopMatch() {
        let plan = SearchResultPageLayout.plan(
            order: [.lyrics, .metadata],
            present: [.lyrics, .metadata],
            withItems: [.lyrics, .metadata],
            hasTopMatch: false,
            width: 1165
        )
        #expect(plan.heroNeighbor == nil)
        #expect(plan.rows.map(\.sections) == [[.lyrics, .metadata]])
    }

    @Test("The user's order decides which lists share a row")
    func customOrderRespected() {
        let order: [SearchResultSection] = [.lyrics, .albums, .fuzzy, .metadata, .artists, .path]
        let plan = SearchResultPageLayout.plan(
            order: order,
            present: Set(order),
            withItems: Set(order),
            hasTopMatch: true,
            width: 900
        )
        #expect(plan.heroNeighbor == .lyrics)
        #expect(plan.rows.map(\.sections) == [[.albums], [.fuzzy, .metadata], [.artists], [.path]])
    }

    @Test("Preview counts fill whole columns")
    func previewCounts() {
        #expect(SearchResultPageLayout.previewCount(for: .metadata, innerColumns: 1, besideTopMatch: false) == 6)
        #expect(SearchResultPageLayout.previewCount(for: .metadata, innerColumns: 3, besideTopMatch: false) == 9)
        #expect(SearchResultPageLayout.previewCount(for: .path, innerColumns: 2, besideTopMatch: true) == 10)
        #expect(SearchResultPageLayout.previewCount(for: .lyrics, innerColumns: 1, besideTopMatch: false) == 3)
        #expect(SearchResultPageLayout.previewCount(for: .lyrics, innerColumns: 3, besideTopMatch: false) == 6)
        #expect(SearchResultPageLayout.previewCount(for: .albums, innerColumns: 2, besideTopMatch: false) == 0)
    }

    @Test("Shelf item count and widths")
    func widths() {
        #expect(SearchResultPageLayout.shelfItemCount(width: 1165, minimumItemWidth: 146, spacing: 20) == 7)
        #expect(SearchResultPageLayout.shelfItemCount(width: 100, minimumItemWidth: 146, spacing: 20) == 1)
        #expect(SearchResultPageLayout.heroNeighborWidth(totalWidth: 1165) == 861)
        #expect(SearchResultPageLayout.blockWidth(totalWidth: 1048, blocksInRow: 2) == 512)
    }

    @Test("Column-major chunks read down each column first")
    func chunks() {
        let chunks = SearchResultPageLayout.columnMajorChunks(Array(1...7), columns: 3)
        #expect(chunks == [[1, 2, 3], [4, 5, 6], [7]])
        #expect(SearchResultPageLayout.columnMajorChunks([1, 2], columns: 3) == [[1], [2]])
        #expect(SearchResultPageLayout.columnMajorChunks([Int](), columns: 2).isEmpty)
    }
}
