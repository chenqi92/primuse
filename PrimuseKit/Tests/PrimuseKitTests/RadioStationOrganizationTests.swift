import Foundation
import Testing
@testable import PrimuseKit

private func station(
    _ name: String,
    folder: String? = nil,
    tags: [String]? = nil,
    url: String = "https://example.com/stream"
) -> RadioStation {
    RadioStation(
        id: name,
        name: name,
        streamURL: url,
        folderName: folder,
        tagNames: tags
    )
}

@Suite("Radio station organization")
struct RadioStationOrganizationTests {
    // MARK: - 归一化

    @Test("Folder names collapse whitespace and drop control characters")
    func folderNameNormalization() {
        #expect(RadioStationOrganization.normalizedFolderName("  Jazz   Classics \n") == "Jazz Classics")
        #expect(RadioStationOrganization.normalizedFolderName("Jazz\u{0007}") == "Jazz")
        #expect(RadioStationOrganization.normalizedFolderName("   ") == nil)
        #expect(RadioStationOrganization.normalizedFolderName(nil) == nil)
    }

    @Test("Overlong names are truncated to the limit")
    func nameTruncation() {
        let long = String(repeating: "电", count: 200)
        let folder = RadioStationOrganization.normalizedFolderName(long)
        #expect(folder?.count == RadioStationOrganization.maximumFolderNameLength)
        let tag = RadioStationOrganization.normalizedTagName(long)
        #expect(tag?.count == RadioStationOrganization.maximumTagNameLength)
    }

    @Test("Tag lists dedupe case-insensitively and keep the first spelling")
    func tagListNormalization() {
        let tags = RadioStationOrganization.normalizedTagNames(["Jazz", " jazz ", "JAZZ", "News"])
        #expect(tags == ["Jazz", "News"])
        #expect(RadioStationOrganization.normalizedTagNames([]) == nil)
        #expect(RadioStationOrganization.normalizedTagNames(["  "]) == nil)
    }

    @Test("A station cannot carry more tags than the limit")
    func tagListCap() {
        let many = (0..<40).map { "tag\($0)" }
        let tags = RadioStationOrganization.normalizedTagNames(many)
        #expect(tags?.count == RadioStationOrganization.maximumTagsPerStation)
    }

    @Test("Names differing only in case or width are the same name")
    func nameEquivalence() {
        #expect(RadioStationOrganization.isSameName("Jazz", "JAZZ"))
        #expect(RadioStationOrganization.isSameName("ＦＭ", "FM"))
        #expect(!RadioStationOrganization.isSameName("Jazz", "Rock"))
    }

    // MARK: - 归纳

    @Test("Folders are derived from stations and counted")
    func folderSummaries() {
        let stations = [
            station("A", folder: "新闻"),
            station("B", folder: "新闻"),
            station("C", folder: "音乐"),
            station("D"),
        ]
        let folders = RadioStationOrganization.folders(in: stations)
        #expect(folders.map(\.name) == ["新闻", "音乐"])
        #expect(folders.map(\.stationCount) == [2, 1])
        #expect(RadioStationOrganization.ungroupedCount(in: stations) == 1)
    }

    @Test("Empty folder placeholders appear with a zero count and never duplicate a real folder")
    func folderPlaceholders() {
        let stations = [station("A", folder: "新闻")]
        let folders = RadioStationOrganization.folders(
            in: stations,
            additionalNames: ["新闻", "稍后再听", "  "]
        )
        #expect(folders.count == 2)
        #expect(folders.first(where: { $0.name == "新闻" })?.stationCount == 1)
        #expect(folders.first(where: { $0.name == "稍后再听" })?.isEmpty == true)
    }

    @Test("Tags are derived from stations and counted")
    func tagSummaries() {
        let stations = [
            station("A", tags: ["爵士", "深夜"]),
            station("B", tags: ["爵士"]),
            station("C"),
        ]
        let tags = RadioStationOrganization.tags(in: stations)
        #expect(tags.map(\.name) == ["深夜", "爵士"])
        #expect(tags.first(where: { $0.name == "爵士" })?.stationCount == 2)
    }

    // MARK: - 筛选

    @Test("Folder scope selects all, ungrouped, or one folder")
    func folderScopeFiltering() {
        let stations = [
            station("A", folder: "新闻"),
            station("B", folder: "音乐"),
            station("C"),
        ]
        #expect(RadioStationOrganization.filtered(stations, with: .unfiltered).count == 3)
        #expect(RadioStationOrganization.filtered(
            stations,
            with: RadioStationFilter(folder: .ungrouped)
        ).map(\.name) == ["C"])
        #expect(RadioStationOrganization.filtered(
            stations,
            with: RadioStationFilter(folder: .folder("新闻"))
        ).map(\.name) == ["A"])
    }

    @Test("Multiple tags narrow the result instead of widening it")
    func tagIntersection() {
        let stations = [
            station("A", tags: ["爵士", "深夜"]),
            station("B", tags: ["爵士"]),
            station("C", tags: ["深夜"]),
        ]
        let filtered = RadioStationOrganization.filtered(
            stations,
            with: RadioStationFilter(tagNames: ["爵士", "深夜"])
        )
        #expect(filtered.map(\.name) == ["A"])
    }

    @Test("Search matches name, folder, tags and endpoint, and every token must hit")
    func searchMatching() {
        let stations = [
            station("Jazz FM", folder: "音乐", tags: ["深夜"], url: "https://jazz.example.com/live"),
            station("News One", folder: "新闻", url: "https://news.example.com/live"),
        ]
        func names(_ query: String) -> [String] {
            RadioStationOrganization.filtered(
                stations,
                with: RadioStationFilter(searchText: query)
            ).map(\.name)
        }
        #expect(names("jazz") == ["Jazz FM"])
        #expect(names("音乐") == ["Jazz FM"])
        #expect(names("深夜") == ["Jazz FM"])
        #expect(names("news.example") == ["News One"])
        #expect(names("jazz 深夜") == ["Jazz FM"])
        #expect(names("jazz 新闻").isEmpty)
        #expect(names("   ").count == 2)
    }

    @Test("Filtering keeps the incoming priority order")
    func filteringPreservesOrder() {
        let stations = [
            station("C", folder: "音乐"),
            station("A", folder: "音乐"),
            station("B", folder: "音乐"),
        ]
        let filtered = RadioStationOrganization.filtered(
            stations,
            with: RadioStationFilter(folder: .folder("音乐"))
        )
        #expect(filtered.map(\.name) == ["C", "A", "B"])
    }

    // MARK: - 分组

    @Test("Grouping sorts folders by name and puts ungrouped last")
    func grouping() {
        let stations = [
            station("A", folder: "音乐"),
            station("B"),
            station("C", folder: "新闻"),
            station("D", folder: "音乐"),
        ]
        let groups = RadioStationOrganization.grouped(stations)
        #expect(groups.map(\.name) == ["新闻", "音乐", nil])
        #expect(groups.last?.isUngrouped == true)
        #expect(groups[1].stations.map(\.name) == ["A", "D"])
    }

    @Test("Grouping folds names that differ only in case into one group")
    func groupingFoldsEquivalentNames() {
        let groups = RadioStationOrganization.grouped([
            station("A", folder: "Jazz"),
            station("B", folder: "JAZZ"),
        ])
        #expect(groups.count == 1)
        #expect(groups.first?.name == "Jazz")
        #expect(groups.first?.stations.count == 2)
    }

    // MARK: - 标签编辑

    @Test("Adding a tag reports no change when it is already there or the list is full")
    func addingTags() {
        #expect(RadioStationOrganization.adding(tag: "爵士", to: nil) == .updated(["爵士"]))
        #expect(RadioStationOrganization.adding(tag: " 爵士 ", to: ["爵士"]) == .unchanged)
        #expect(RadioStationOrganization.adding(tag: "JAZZ", to: ["jazz"]) == .unchanged)
        #expect(RadioStationOrganization.adding(tag: "  ", to: ["爵士"]) == .unchanged)
        let full = (0..<RadioStationOrganization.maximumTagsPerStation).map { "tag\($0)" }
        #expect(RadioStationOrganization.adding(tag: "extra", to: full) == .unchanged)
    }

    @Test("Removing the last tag stores nil rather than an empty list")
    func removingTags() {
        #expect(RadioStationOrganization.removing(tag: "爵士", from: ["爵士"]) == .updated(nil))
        #expect(RadioStationOrganization.removing(tag: "爵士", from: ["新闻"]) == .unchanged)
        #expect(RadioStationOrganization.removing(tag: "爵士", from: nil) == .unchanged)
    }

    @Test("Renaming a tag merges it into an existing one instead of duplicating")
    func renamingTags() {
        #expect(RadioStationOrganization.renaming(
            tag: "爵士",
            to: "Jazz",
            in: ["爵士", "深夜"]
        ) == .updated(["Jazz", "深夜"]))
        #expect(RadioStationOrganization.renaming(
            tag: "爵士",
            to: "深夜",
            in: ["爵士", "深夜"]
        ) == .updated(["深夜"]))
        #expect(RadioStationOrganization.renaming(tag: "爵士", to: "Jazz", in: ["新闻"]) == .unchanged)
    }

    // MARK: - 配色

    @Test("Tag colors are stable and independent of spelling case")
    func paletteIndex() {
        let a = RadioStationOrganization.paletteIndex(forTag: "爵士", paletteSize: 8)
        let b = RadioStationOrganization.paletteIndex(forTag: "爵士", paletteSize: 8)
        #expect(a == b)
        #expect((0..<8).contains(a))
        #expect(RadioStationOrganization.paletteIndex(forTag: "Jazz", paletteSize: 8)
            == RadioStationOrganization.paletteIndex(forTag: "JAZZ", paletteSize: 8))
        #expect(RadioStationOrganization.paletteIndex(forTag: "Jazz", paletteSize: 0) == 0)
    }

    // MARK: - 电台上的读取口

    @Test("Station accessors normalize what was stored")
    func stationAccessors() {
        let raw = RadioStation(
            name: "A",
            streamURL: "https://example.com/stream",
            folderName: "  ",
            tagNames: ["爵士", "爵士", " "]
        )
        #expect(raw.assignedFolderName == nil)
        #expect(raw.assignedTagNames == ["爵士"])
    }

    @Test("Old snapshots without folder or tag keys still decode")
    func backwardCompatibleDecoding() throws {
        let json = """
        {
          "id": "s1",
          "name": "Legacy",
          "streamURL": "https://example.com/stream",
          "streamFormat": "automatic",
          "createdAt": 0,
          "modifiedAt": 0,
          "isDeleted": false
        }
        """
        let decoded = try JSONDecoder().decode(RadioStation.self, from: Data(json.utf8))
        #expect(decoded.folderName == nil)
        #expect(decoded.assignedTagNames.isEmpty)
    }

    // MARK: - 服务端镜像的文件夹

    @Test("Server folders nest under the source name and keep their own part when too long")
    func serverFolderName() {
        #expect(ServerRadioFolderPolicy.folderName(sourceName: "家里的群晖", serverFolderName: "我的最爱") == "家里的群晖 / 我的最爱")
        #expect(ServerRadioFolderPolicy.folderName(sourceName: "  ", serverFolderName: "我的最爱") == "我的最爱")
        #expect(ServerRadioFolderPolicy.folderName(sourceName: "NAS", serverFolderName: nil) == nil)
        let long = ServerRadioFolderPolicy.folderName(
            sourceName: String(repeating: "N", count: 80),
            serverFolderName: "User-defined Radio"
        )
        #expect(long?.count == RadioStationOrganization.maximumFolderNameLength)
        #expect(long?.hasSuffix(" / User-defined Radio") == true)
    }

    @Test("Synced folders follow the server until the user moves the station")
    func reconciledServerFolder() {
        let managed = ["NAS / 我的最爱", "NAS / 自定义电台"]
        // 新镜像直接用同步给的文件夹。
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: nil, isNewMirror: true, assigned: "NAS / 我的最爱", syncManagedFolderNames: managed
        ) == "NAS / 我的最爱")
        // 还在同步给的文件夹里:服务端换了,跟着换。
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: "nas / 自定义电台", isNewMirror: false, assigned: "NAS / 我的最爱", syncManagedFolderNames: managed
        ) == "NAS / 我的最爱")
        // 用户挪到自己的文件夹、或移出文件夹,都不动。
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: "爵士", isNewMirror: false, assigned: "NAS / 我的最爱", syncManagedFolderNames: managed
        ) == "爵士")
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: nil, isNewMirror: false, assigned: "NAS / 我的最爱", syncManagedFolderNames: managed
        ) == nil)
        // 服务端不分文件夹的源(Subsonic 等)保持原样。
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: "NAS / 我的最爱", isNewMirror: false, assigned: nil, syncManagedFolderNames: []
        ) == "NAS / 我的最爱")
        #expect(ServerRadioFolderPolicy.reconciledFolderName(
            current: nil, isNewMirror: true, assigned: nil, syncManagedFolderNames: []
        ) == nil)
    }
}
