import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// C2:车机在歌曲模型不在内存里时用到的几条目录查询在规模夹具上的耗时与内存 —— 「专辑艺术家」列表(`albumArtistBrowse`,
/// 车机的专辑艺人 A–Z、资料库入口与 Mac 侧栏的人数都靠它)、车机的专辑艺人 A–Z 整条路、首页那两样要扫整表的
/// (专辑块的前若干张、最近添加)、专辑与歌曲 A–Z。量法同 RC-b 的 D2(`ReleaseCategoryBackfillProbe`):只开规模夹具
/// 旁边那份目录的副本,不装曲库;先补齐发行类别(不列只有单曲的人时要它),再一条一条量。没有夹具时跳过。
final class CarPlayCatalogScaleTests: XCTestCase {
    private static func report(_ line: String) {
        plog(line)
        print(line)
    }

    func testCarPlayCatalogQueriesOnTheScaleCatalog() async throws {
        guard let scale = ProcessInfo.processInfo.environment["PRIMUSE_SCALE_DIR"] else {
            throw XCTSkip("Set PRIMUSE_SCALE_DIR to the scale fixture (its -catalog sibling holds the catalog)")
        }
        let fixture = URL(fileURLWithPath: scale, isDirectory: true)
        let source = fixture.deletingLastPathComponent()
            .appendingPathComponent(fixture.lastPathComponent + "-catalog", isDirectory: true)
            .appendingPathComponent("library-catalog.sqlite")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Build the scale catalog fixture first (testBuildScaleCatalogFixture)")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("c2-carplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library-catalog.sqlite").path
        try FileManager.default.copyItem(atPath: source.path, toPath: path)
        let choices = await MainActor.run { FullReleaseAlbumArtistMemo.Choices(AlbumReleaseCategoryStore.shared) }
        let listLimit = await MainActor.run { CarPlayHomeCatalog.listLimit }
        let lines = try await Task.detached(priority: .utility) { () throws -> [String] in
            try Self.measureAll(path: path, choices: choices, listLimit: listLimit)
        }.value
        for line in lines { Self.report("📏 C2 CarPlay catalog " + line) }
    }

    private static func measureAll(path: String, choices: FullReleaseAlbumArtistMemo.Choices, listLimit: Int) throws -> [String] {
        typealias Probe = ReleaseCategoryBackfillProbe
        let catalog = try LibraryCatalog(path: path)
        _ = try catalog.backfillReleaseCategories()
        var lines = [String(format: "songs=%d albums=%d categoriesComplete=%@", try catalog.rowList(.visible).rowids.count,
                            try catalog.albumKeys(visibleOnly: true).keys.count,
                            (try catalog.releaseCategoriesAreComplete()) ? "yes" : "no")]
        func measure(_ label: String, _ work: () throws -> Int) throws {
            lines.append(try Probe.measure(label, catalog: catalog, catalogPath: path, work: work))
        }
        try measure("albumArtistBrowse(.library) (CarPlay A–Z, hub count, Mac sidebar)") {
            try catalog.albumArtistBrowse(order: .library).keys.count
        }
        try measure("albumArtistBrowse(.library) again (warm page cache)") {
            try catalog.albumArtistBrowse(order: .library).keys.count
        }
        try measure("albumArtistBrowse(.reading) (iPhone Artists page)") {
            try catalog.albumArtistBrowse(order: .reading(unknownArtistName: "Unknown Artist")).keys.count
        }
        try measure("full-release album artists (RC-b memo)") {
            try FullReleaseAlbumArtistMemo.shared.artistIDs(catalog: catalog, choices: choices)?.count ?? -1
        }
        for hiding in [false, true] {
            let query = LibraryArtistBrowseQuery(
                unknownArtistName: "Unknown Artist", search: "", mode: .albumArtists, readingOrder: false,
                likedOrder: nil, fullReleaseChoices: hiding ? choices : nil
            )
            try measure("CarPlay album artists A–Z, first 500 (hiding single-only \(hiding))") {
                try CarPlayArtistLists.artists(.byName, query: query, catalog: catalog, rowCache: LibraryRowCache()).count
            }
        }
        try measure("CarPlay albums A–Z, first 500 (firstAlbumsByTitle)") { try catalog.firstAlbumsByTitle(limit: 500).count }
        try measure("CarPlay songs A–Z, first 500 (firstSongsByTitle)") { try catalog.firstSongsByTitle(limit: 500).count }
        try measure("CarPlay home: recently added (carPlayRecentlyAdded)") {
            let recent = try catalog.carPlayRecentlyAdded(scope: CarPlayHomeCatalog.musicScope, songLimit: 100,
                                                          albumLimit: 60, singleLimit: 100)
            return recent.songIDs.count + recent.albums.count + recent.singles.count
        }
        var request = CarPlayHomeCatalog.Request()
        request.albumLimit = listLimit + 1
        request.wantsRecentlyAdded = true
        try measure("CarPlay home: album block (first \(listLimit + 1) by title) + recently added, materialized") {
            let parts = try CarPlayHomeCatalog.parts(request, catalog: catalog)
            return parts.albums.count + parts.recent.count + parts.recentAlbums.count + parts.singles.count
        }
        return lines
    }
}
