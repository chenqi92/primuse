import Foundation
import Testing
@testable import PrimuseKit

private func show(
    _ id: String,
    title: String? = nil,
    author: String? = nil,
    folder: String? = nil,
    tags: [String]? = nil
) -> PodcastShow {
    PodcastShow(
        id: id,
        feedURL: URL(string: "https://feeds.example.com/\(id)")!,
        title: title ?? id,
        author: author,
        subscribedAt: Date(timeIntervalSince1970: 1_800_000_000),
        folderName: folder,
        tagNames: tags
    )
}

@Suite("Podcast show organization")
struct PodcastShowOrganizationTests {
    @Test("Folder and tag names are normalized on the show")
    func assignedNames() {
        let blank = show("a", folder: "   ", tags: [" ", ""])
        #expect(blank.assignedFolderName == nil)
        #expect(blank.assignedTagNames.isEmpty)

        let messy = show("b", folder: "  科技   播客 ", tags: ["Daily", " daily ", "News"])
        #expect(messy.assignedFolderName == "科技 播客")
        #expect(messy.assignedTagNames == ["Daily", "News"])
    }

    @Test("Folders and tags are derived from the shows, sorted by name")
    func derivedFolderAndTags() {
        let shows = [
            show("a", folder: "Tech", tags: ["daily"]),
            show("b", folder: "TECH", tags: ["Daily", "news"]),
            show("c", folder: "History"),
            show("d", tags: ["news"]),
            show("e"),
        ]
        let folders = PodcastShowOrganization.folders(in: shows)
        #expect(folders.map(\.name) == ["History", "Tech"])
        #expect(folders.map(\.showCount) == [1, 2])
        #expect(PodcastShowOrganization.ungroupedCount(in: shows) == 2)

        let tags = PodcastShowOrganization.tags(in: shows)
        #expect(tags.map(\.name) == ["daily", "news"])
        #expect(tags.map(\.showCount) == [2, 2])
        #expect(PodcastShowOrganization.folders(in: []).isEmpty)
    }

    @Test("Filtering by folder scope keeps the incoming order")
    func folderScope() {
        let shows = [
            show("a", folder: "Tech"),
            show("b"),
            show("c", folder: "tech"),
            show("d", folder: "History"),
        ]
        let tech = PodcastShowOrganization.filtered(shows, with: PodcastShowFilter(folder: .folder("TECH")))
        #expect(tech.map(\.id) == ["a", "c"])
        let ungrouped = PodcastShowOrganization.filtered(shows, with: PodcastShowFilter(folder: .ungrouped))
        #expect(ungrouped.map(\.id) == ["b"])
        #expect(PodcastShowOrganization.filtered(shows, with: .unfiltered).map(\.id) == ["a", "b", "c", "d"])
    }

    @Test("Several tags narrow to the shows carrying all of them")
    func tagIntersection() {
        let shows = [
            show("a", tags: ["daily", "news"]),
            show("b", tags: ["daily"]),
            show("c", tags: ["News", "Daily", "tech"]),
        ]
        let filter = PodcastShowFilter(tagNames: ["DAILY", "news"])
        #expect(PodcastShowOrganization.filtered(shows, with: filter).map(\.id) == ["a", "c"])
        #expect(filter.isNarrowed)
    }

    @Test("Search matches title, author, folder and tags; every word has to hit")
    func search() {
        let shows = [
            show("a", title: "不合时宜", author: "王磬", folder: "人文", tags: ["对谈"]),
            show("b", title: "The Daily", author: "The New York Times", folder: "News", tags: ["morning"]),
            show("c", title: "Hardcore History", author: "Dan Carlin"),
        ]
        func ids(_ text: String) -> [String] {
            PodcastShowOrganization.filtered(shows, with: PodcastShowFilter(searchText: text)).map(\.id)
        }
        #expect(ids("daily") == ["b"])
        #expect(ids("carlin") == ["c"])
        #expect(ids("人文") == ["a"])
        #expect(ids("MORNING") == ["b"])
        #expect(ids("news times") == ["b"])
        #expect(ids("news carlin").isEmpty)
        #expect(ids("   ") == ["a", "b", "c"])

        let tokens = RadioStationOrganization.searchTokens("对谈")
        #expect(PodcastShowOrganization.matchesQuery(shows[0], tokens: tokens))
        #expect(!PodcastShowOrganization.matchesQuery(shows[1], tokens: tokens))
    }

    @Test("Grouping sorts folders by name and puts ungrouped shows last")
    func grouping() {
        let shows = [
            show("a"),
            show("b", folder: "Tech"),
            show("c", folder: "History"),
            show("d", folder: "tech"),
            show("e"),
        ]
        let groups = PodcastShowOrganization.grouped(shows)
        #expect(groups.map(\.name) == ["History", "Tech", nil])
        #expect(groups.map { $0.shows.map(\.id) } == [["c"], ["b", "d"], ["a", "e"]])
        #expect(groups.last?.isUngrouped == true)
        #expect(groups.map(\.id) == ["History", "Tech", ""])
        #expect(PodcastShowOrganization.grouped([show("x")]).map(\.name) == [nil])
    }

    @Test("Shows saved before folders existed still decode, and the new fields round-trip")
    func persistence() throws {
        let legacy = """
        {"id":"a","feedURL":"https://feeds.example.com/a","title":"A","subscribedAt":0}
        """
        let decoded = try JSONDecoder().decode(PodcastShow.self, from: Data(legacy.utf8))
        #expect(decoded.folderName == nil)
        #expect(decoded.tagNames == nil)

        let organized = show("b", folder: "Tech", tags: ["daily"])
        let roundTripped = try JSONDecoder().decode(PodcastShow.self, from: JSONEncoder().encode(organized))
        #expect(roundTripped == organized)
        #expect(roundTripped.assignedFolderName == "Tech")
        #expect(roundTripped.assignedTagNames == ["daily"])
    }
}
