import Foundation
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U4a:专辑页与专辑、艺人卡片在歌曲模型放掉之后从曲库目录答,与模型在内存里时同内容同顺序,
/// 不装模型、不读整库数组。
@MainActor
final class AlbumsReleasedTests: LibraryReleasedTwinTestCase {
    /// 专辑页按「最近添加」「歌曲数」排、只看离线可放的(专辑 id 一份)时,目录列表与内存路径排出来的相同;
    /// 每张专辑、每个艺人卡片借的那首歌,目录答的与内存里那张表的相同。
    func testAlbumsOrdersFiltersAndCardArtworkAnswerFromTheCatalogWhileReleased() async throws {
        var songs = Self.fixture(prefix: "albums-released")
        // 两张专辑的加入时间一样,另一张更新;服务端的专辑加入时间优先。
        songs[4].dateAdded = Date(timeIntervalSince1970: 1_800_000_000)
        songs[0].serverAlbumDateAdded = Date(timeIntervalSince1970: 1_900_000_000)
        let (library, _) = try makeLaunchedTwin("albums-released", songs: songs)
        await assertShadowMatches(library, "fixture")
        let unknown = String(localized: "unknown_artist")
        let albums = library.visibleAlbums
        func memory(_ order: AlbumGridOrder) -> [String] {
            AlbumGridOrder.layout(albums, order: order, songs: library.visibleSongs, unknownArtistName: unknown).items.map(\.id)
        }
        let recentLoaded = memory(.recentlyAdded)
        let bySongCountLoaded = memory(.songCount)
        let offlineIDs: Set<String> = Set(albums.prefix(2).map(\.id))
        let offlineLoaded = recentLoaded.filter(offlineIDs.contains)
        let albumArtLoaded = albums.map { library.scopedPreferredArtworkSong(forAlbumID: $0.id)?.id }
        let artists = library.visibleArtists
        let artistArtLoaded = artists.map { library.scopedPreferredArtworkSong(forArtistID: $0.id)?.id }
        XCTAssertGreaterThan(albums.count, 2)

        let before = try await releaseForReal(library)
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        func fromCatalog(_ query: LibraryAlbumBrowseQuery) throws -> [String] {
            let rows = try query.fetchRows(catalog)
            return try catalog.albums(keys: Array(rows.ids), visibleCounts: true).map(\.id)
        }
        let favorites = LibraryFavoriteLedger()
        func predicate(offline: Set<String>?) -> AlbumGridAlbumPredicate {
            AlbumGridAlbumPredicate(query: "", likedOnly: false, hidesSingleSongAlbums: false, favorites: favorites,
                                    unknownArtistName: unknown, offlineAlbumIDs: offline)
        }
        XCTAssertEqual(try fromCatalog(LibraryAlbumBrowseQuery(order: .recentlyAdded, unknownArtistName: unknown,
                                                              currentYear: 2026, predicate: nil)), recentLoaded, "recently added")
        XCTAssertEqual(try fromCatalog(LibraryAlbumBrowseQuery(order: .title, bySongCount: true, unknownArtistName: unknown,
                                                              currentYear: 2026, predicate: nil)), bySongCountLoaded, "song count")
        XCTAssertEqual(try fromCatalog(LibraryAlbumBrowseQuery(order: .recentlyAdded, unknownArtistName: unknown,
                                                              currentYear: 2026, predicate: predicate(offline: offlineIDs))),
                       offlineLoaded, "offline-only")
        var albumArt: [String?] = []
        for album in albums {
            albumArt.append(await ArtworkSongCatalogMemo.shared.preferredSongID(for: .album(album.id), library: library))
        }
        XCTAssertEqual(albumArt, albumArtLoaded, "album card artwork song")
        var artistArt: [String?] = []
        for artist in artists {
            artistArt.append(await ArtworkSongCatalogMemo.shared.preferredSongID(for: .artist(artist.id), library: library))
        }
        XCTAssertEqual(artistArt, artistArtLoaded, "artist card artwork song")
        assertNoLoadAndNoArrayRead(library, since: before, "Albums page and cards while released")
    }

    /// 专辑、艺人卡片真画在屏幕上(歌曲模型放掉之后):借封面的那首、艺人头像的上下文引用都从曲库目录答,
    /// 不读整库的封面表(诊断数到的那几份表),也不装模型。设备上见过艺人卡片放掉后 0.3–1.2 秒读那张表。
    func testArtworkCellsOnScreenReadNoWholeLibraryTableWhileReleased() async throws {
        let songs = Self.fixture(prefix: "cells-released")
        let (library, _) = try makeLaunchedTwin("cells-released", songs: songs)
        await assertShadowMatches(library, "fixture")
        let albums = library.visibleAlbums
        let artists = library.visibleArtists
        XCTAssertFalse(albums.isEmpty)
        XCTAssertFalse(artists.isEmpty)
        let before = try await releaseForReal(library)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView:
            ScrollView {
                VStack {
                    ForEach(albums) { AlbumArtworkView(album: $0, size: 40) }
                    ForEach(artists) { ArtistArtworkView(artist: $0, size: 40) }
                }
            }
            .environment(library)
            .environment(SourceManager(sourcesProvider: { [] }))
        )
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        defer {
            window.isHidden = true
            window.rootViewController = nil
            original?.makeKeyAndVisible()
        }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        assertNoLoadAndNoArrayRead(library, since: before, "album and artist cells on screen while released")
    }
}

