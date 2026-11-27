import Foundation
import Testing
@testable import PrimuseKit

@Suite("Release-date browsing groups albums by decade, then year, then artist")
struct ReleaseDateBrowseLayoutTests {
    private let currentYear = 2026

    @Test("Decades run newest first, then earlier, then unknown; years newest first inside a decade")
    func decadeAndYearOrder() {
        let albums = [
            album("adele-25", "25", "Adele", 2015),
            album("jay-1", "范特西", "周杰伦", 2001),
            album("blur", "Parklife", "Blur", 1994),
            album("adele-21", "21", "Adele", 2011),
            album("jay-2", "叶惠美", "周杰伦", 2003),
            album("miles", "Kind of Blue", "Miles Davis", 1959),
            album("demo", "Demo", "Band", nil),
            album("beatles", "Abbey Road", "The Beatles", 1969),
            album("taylor", "1989", "Taylor Swift", 2014),
        ]
        let layout = ReleaseDateBrowseLayoutBuilder.layout(albums: albums, currentYear: currentYear)

        #expect(layout.decades.map(\.era) == [
            .decade(2010), .decade(2000), .decade(1990), .decade(1960), .earlier, .unknown,
        ])
        let tens = layout.decades[0]
        #expect(tens.years.map(\.year) == [2015, 2014, 2011])
        #expect(tens.albumCount == 3)
        #expect(layout.decades[1].years.map(\.year) == [2003, 2001])
        #expect(layout.decades[4].years.flatMap { $0.albums.map(\.id) } == ["miles"])
        #expect(layout.decades[5].years.map(\.year) == [nil])
        #expect(layout.decades[5].years[0].albums.map(\.id) == ["demo"])
        #expect(layout.albumCount == albums.count)
    }

    @Test("Inside one year albums follow the artist order of the album wall")
    func sameYearSortsByArtist() {
        let albums = [
            album("z", "Zeta", "周杰伦", 2003),
            album("a", "Alpha", "Adele", 2003),
            album("b", "Beta", "Beyond", 2003),
            album("u", "Untitled", "Unknown Artist", 2003),
        ]
        let layout = ReleaseDateBrowseLayoutBuilder.layout(
            albums: albums, currentYear: currentYear, unknownArtistName: "Unknown Artist"
        )
        #expect(layout.decades.count == 1)
        #expect(layout.decades[0].years[0].albums.map(\.id) == ["a", "b", "z", "u"])
    }

    @Test("Implausible years count as unknown")
    func implausibleYears() {
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 98, currentYear: currentYear) == .unknown)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 0, currentYear: currentYear) == .unknown)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 20150101, currentYear: currentYear) == .unknown)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: nil, currentYear: currentYear) == .unknown)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 2027, currentYear: currentYear) == .decade(2020))
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 2028, currentYear: currentYear) == .unknown)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 1960, currentYear: currentYear) == .decade(1960))
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 1959, currentYear: currentYear) == .earlier)
        #expect(ReleaseDateBrowseLayoutBuilder.era(for: 1685, currentYear: currentYear) == .earlier)
    }

    @Test("The chart runs oldest to newest and keeps empty decades in between as zero bars")
    func chartKeepsTheTimeline() {
        let albums = [
            album("a", "A", "X", 1975),
            album("b", "B", "X", 1977),
            album("c", "C", "X", 2012),
            album("d", "D", "X", 1955),
            album("e", "E", "X", nil),
        ]
        let layout = ReleaseDateBrowseLayoutBuilder.layout(albums: albums, currentYear: currentYear)
        #expect(layout.chartBars == [
            .init(era: .earlier, albumCount: 1),
            .init(era: .decade(1970), albumCount: 2),
            .init(era: .decade(1980), albumCount: 0),
            .init(era: .decade(1990), albumCount: 0),
            .init(era: .decade(2000), albumCount: 0),
            .init(era: .decade(2010), albumCount: 1),
            .init(era: .unknown, albumCount: 1),
        ])
        // The list itself only shows decades that have albums.
        #expect(layout.decades.map(\.era) == [.decade(2010), .decade(1970), .earlier, .unknown])
    }

    @Test("An empty library has nothing to draw")
    func emptyLibrary() {
        let layout = ReleaseDateBrowseLayoutBuilder.layout(albums: [], currentYear: currentYear)
        #expect(layout.decades.isEmpty)
        #expect(layout.chartBars.isEmpty)
        #expect(layout.albumCount == 0)
    }

    @Test("A library without any years is one unknown group")
    func onlyUnknown() {
        let layout = ReleaseDateBrowseLayoutBuilder.layout(
            albums: [album("a", "A", "X", nil), album("b", "B", "Y", 0)],
            currentYear: currentYear
        )
        #expect(layout.decades.map(\.era) == [.unknown])
        #expect(layout.chartBars == [.init(era: .unknown, albumCount: 2)])
    }

    @Test("Filtering keeps order, drops emptied years and decades, and recounts the chart")
    func filteredLayout() {
        let albums = [
            album("adele-25", "25", "Adele", 2015),
            album("adele-21", "21", "Adele", 2011),
            album("jay-1", "范特西", "周杰伦", 2001),
            album("jay-2", "叶惠美", "周杰伦", 2003),
            album("blur", "Parklife", "Blur", 1994),
        ]
        let layout = ReleaseDateBrowseLayoutBuilder.layout(albums: albums, currentYear: currentYear)
        let jay = layout.filtered { $0.artistName == "周杰伦" }

        #expect(jay.decades.map(\.era) == [.decade(2000)])
        #expect(jay.decades[0].years.map(\.year) == [2003, 2001])
        #expect(jay.decades[0].albumCount == 2)
        #expect(jay.albumCount == 2)
        #expect(jay.chartBars.map(\.era) == layout.chartBars.map(\.era))
        #expect(jay.chartBars.first { $0.era == .decade(2010) }?.albumCount == 0)
        #expect(jay.chartBars.first { $0.era == .decade(2000) }?.albumCount == 2)

        let none = layout.filtered { _ in false }
        #expect(none.decades.isEmpty)
        #expect(none.albumCount == 0)
    }

    private func album(_ id: String, _ title: String, _ artist: String, _ year: Int?) -> Album {
        Album(id: id, title: title, artistName: artist, year: year)
    }
}
