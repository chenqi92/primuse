import Foundation
import PrimuseKit
import UIKit
import XCTest
@testable import Primuse

/// DL4:iCloud 整库上传、Apple TV 直传之前的整理改成一页一页做(`preparePortableSnapshotPageByPage`)。每一条都与
/// DL4 之前整份解码的写法(调试构建里的 `preparePortableSnapshotDataIncludingArtworkAssetsReference`)比:交出的
/// 字节、留下的歌数、歌词文件名、封面字节数、「还有可同步的源」逐项相同;读不了、写不进、取消时两边都不交出东西,
/// 临时文件不留。
@MainActor
final class PortableSnapshotPreparationStreamingTests: LibraryReleasedTwinTestCase {
    private static let huge = Int.max / 4
    private static let nas = MusicSource(id: "dl4-nas", name: "NAS", type: .navidrome)
    private static let phone = MusicSource(id: "dl4-phone", name: "Phone", type: .local)
    private static let optedOut = MusicSource(id: "dl4-optout", name: "Opted out", type: .navidrome)

    // MARK: - Byte identity across the fallback ladder

    /// 同一份样例(用户上传的封面、歌自己选的封面、缓存的歌封面与专辑封面、旧式引用、艺人封面与头像引用、歌单里的
    /// 占位条目、最近播放、自动艺人头像目录、三个源),三种写法的输入(编码器写的、键序打乱的、斜杠不转义的),
    /// 局域网 / iCloud / iCloud 加关掉一个源 / 只有本机源四种过滤,一串大小上限(从整份放得下一路往下,
    /// 每级退路都走到,最后放不下):每一处两边相同,分页大小不影响结果。
    func testUploadPreparationEqualsTheWholeLibraryDecodeAcrossTheFallbackLadder() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let filesBefore = Self.exportFiles()
        let filters: [(name: String, sources: [MusicSource]?, excluded: Set<String>)] = [
            ("LAN", nil, ["dl4-optout"]),
            ("iCloud", [Self.nas, Self.phone, Self.optedOut], []),
            ("iCloud opted out", [Self.nas, Self.phone, Self.optedOut], ["dl4-optout"]),
            ("only device-local sources", [Self.phone], []),
        ]
        let cloudLyrics = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssets(
            fixture.inputs[0].data, cloudSources: [Self.nas, Self.phone, Self.optedOut], assetStore: fixture.store
        )
        XCTAssertEqual(cloudLyrics?.eligibleLyricsFileNames, fixture.expectedCloudLyricsNames,
                       "only the kept songs' lyrics that are in the lyrics directory")
        var seen = Set<String>()
        for (inputName, input) in fixture.inputs {
            for filter in filters {
                let label = "\(inputName) / \(filter.name)"
                let full = try await assertSame(
                    input, fixture.store, filter.sources, filter.excluded, limits: .init(), pageSizes: [1, 4, 1_000], label
                )
                let fullSize = try XCTUnwrap(full, label).data.count
                var points = [fullSize, fullSize - 1, fullSize - 300, fullSize - 900]
                points += [0, 512, 1_000, 1_500, 2_000, 2_500, 3_000, 4_000, 6_000, 10_000].map { input.count + $0 }
                points += [input.count / 2, 64]
                for encoded in points where encoded > 0 {
                    for withoutArtwork in [encoded, Self.huge] {
                        let limits = MusicLibrary.PortableSnapshotSizeLimits(encodedBytes: encoded, withoutArtworkBytes: withoutArtwork)
                        let result = try await assertSame(
                            input, fixture.store, filter.sources, filter.excluded, limits: limits, pageSizes: [3],
                            "\(label) encoded=\(encoded) withoutArtwork=\(withoutArtwork)"
                        )
                        seen.insert(Self.variant(result))
                    }
                }
            }
        }
        // 每一级退路都走到过:带封面与内容表、丢了内容表、丢了封面留内容表、两样都丢、放不下。
        XCTAssertEqual(seen, ["artwork+contents", "artwork", "contents", "neither", "nil"], "the ladder was exercised")
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file is left")
    }

    /// 真库的导出(装着模型时从内存导、真放掉之后从目录导):两份输入整理出的字节相同,也与以前的写法相同。
    func testPreparationOfTheLoadedAndTheReleasedExportEqualsTheReference() async throws {
        let songs = Self.fixture(prefix: "dl4")
        let library = try makeLaunchedTwin("dl4", songs: songs).library
        library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
        _ = library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[7].id, songs[12].id])
        library.recordPlayback(of: songs[7].id)
        await assertShadowMatches(library, "fixture")
        guard case .snapshot(let loaded) = await library.portableSnapshotIncludingSongs(byteLimit: 64 << 20) else {
            return XCTFail("the loaded library exports")
        }
        let before = try await releaseForReal(library)
        guard case .snapshot(let released) = await library.portableSnapshotIncludingSongs(byteLimit: 64 << 20) else {
            return XCTFail("the released library exports from the catalog")
        }
        XCTAssertEqual(released, loaded)
        let store = MetadataAssetStore(storageDirectory: directory.appendingPathComponent("assets"))
        let cloud = [MusicSource(id: Self.sourceA, name: "A", type: .navidrome), MusicSource(id: Self.sourceB, name: "B", type: .local)]
        for (sources, name) in [(nil, "LAN"), (cloud, "iCloud")] as [([MusicSource]?, String)] {
            let fromMemory = try await assertSame(loaded, store, sources, [], limits: .init(), pageSizes: [2, 1_000], "loaded \(name)")
            let fromCatalog = try await assertSame(released, store, sources, [], limits: .init(), pageSizes: [2, 1_000], "released \(name)")
            XCTAssertEqual(fromMemory?.data, fromCatalog?.data, name)
            XCTAssertNotNil(fromMemory, name)
        }
        assertNoLoadAndNoArrayRead(library, since: before, "preparing the released export")
    }

    /// 以前整份解码时页与页之间没有取消点;现在每页之间、第二遍每首歌之间都能取消。取消、读到坏的一页、写不进去
    /// (读回也失败):都是 nil,与以前「解不出来就 nil」一样,不交出缺页的快照,临时文件不留。写不进去但读得回来时
    /// 照常交出同样的字节(退回内存接着拼)。
    func testCancellationUnreadablePagesAndFailedWritesNeverHandOverAPartialSnapshot() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let input = try XCTUnwrap(fixture.inputs.first?.data)
        let sources = [Self.nas, Self.phone, Self.optedOut]
        let filesBefore = Self.exportFiles()
        defer {
            PortableSnapshotPreparationTesting.pageDidDecode = nil
            LibraryCatalogExportOutput.failsWritesBeyondBytesForTesting = nil
            LibraryCatalogExportOutput.failsReadBackForTesting = false
        }
        func prepare(_ data: Data, pageSize: Int = 3) async -> MusicLibrary.PortableSnapshotTransferData? {
            await Task {
                await MusicLibrary.preparePortableSnapshotPageByPage(
                    data, cloudSources: sources, excludedSourceIDs: [], assetStore: fixture.store,
                    maximumArtworkBytes: MusicLibrary.portableArtworkBudgetBytes, limits: .init(), pageSize: pageSize
                )
            }.value
        }
        for cancelledPass in [1, 2] {
            let pages = DecodedPageLog()
            PortableSnapshotPreparationTesting.pageDidDecode = { pass, decoded in
                pages.append(pass)
                if pass == cancelledPass, decoded >= 6 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            let result = await prepare(input)
            XCTAssertNil(result, "cancelled in pass \(cancelledPass)")
            XCTAssertEqual(pages.passes.filter { $0 == cancelledPass }.count, 2, "stopped right after the page that cancelled")
            XCTAssertFalse(pages.passes.contains(cancelledPass + 1), "the next pass does not start")
            PortableSnapshotPreparationTesting.pageDidDecode = nil
        }
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file after cancellation")

        // 坏的输入:两边收不收一样,收了交出的字节一样。
        let text = try XCTUnwrap(String(data: input, encoding: .utf8))
        let songsStart = try XCTUnwrap(text.range(of: "\"songs\":["))
        let corruptions: [(String, Data)] = [
            ("cut inside the songs", Data(input.prefix(text.utf8.distance(from: text.startIndex, to: songsStart.upperBound) + 400))),
            ("a song with a wrong type", Data(text.replacingOccurrences(of: "\"duration\":105", with: "\"duration\":\"x\"").utf8)),
            ("no songs key", Data(text.replacingOccurrences(of: "\"songs\":[", with: "\"tracks\":[").utf8)),
            ("a trailing comma in the songs", Data(text.replacingOccurrences(of: "}]}", with: "},]}").utf8)),
        ]
        for (name, data) in corruptions {
            XCTAssertNotEqual(data, input, name)
            let reference = try await assertSame(data, fixture.store, sources, [], limits: .init(), pageSizes: [3, 1_000], name)
            // 数组末尾多一个逗号 JSONDecoder 是收的(以前整份解码照样整理出来),两边一样就行;前三种都读不了。
            if name != "a trailing comma in the songs" { XCTAssertNil(reference, name) }
        }
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file after an unreadable page")

        // 写不进去、读回也失败:nil。写不进去但读得回来:同样的字节。
        let expected = try await assertSame(input, fixture.store, sources, [], limits: .init(), pageSizes: [3], "baseline")
        LibraryCatalogExportOutput.failsWritesBeyondBytesForTesting = 64
        LibraryCatalogExportOutput.failsReadBackForTesting = true
        let lost = await prepare(input)
        XCTAssertNil(lost, "the bytes already written are gone")
        LibraryCatalogExportOutput.failsReadBackForTesting = false
        let recovered = await prepare(input)
        XCTAssertEqual(recovered?.data, expected?.data, "recovered in memory with the same bytes")
        LibraryCatalogExportOutput.failsWritesBeyondBytesForTesting = nil
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file after a failed write")

        // 歌的字节已经超过上限:不编完就不交(与以前编完再判一样是 nil)。
        let tooLarge = MusicLibrary.PortableSnapshotSizeLimits(encodedBytes: 2_000, withoutArtworkBytes: 2_000)
        let early = try await assertSame(input, fixture.store, sources, [], limits: tooLarge, pageSizes: [1], "too large")
        XCTAssertNil(early)
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file after a refusal")

        // 空曲库:照常交出(只有小状态)。
        let empty = try JSONSerialization.data(withJSONObject: ["songs": [Any](), "playlists": [Any]()])
        let emptyResult = try await assertSame(empty, fixture.store, sources, [], limits: .init(), pageSizes: [1], "empty")
        XCTAssertEqual(emptyResult?.eligibleSongCount, 0)

        // 只有本机源:一首都不留,照常交出(iCloud 据此删掉这台设备的那条记录)。
        let allLocal = [MusicSource(id: Self.nas.id, name: "NAS as local", type: .local), Self.phone,
                        MusicSource(id: Self.optedOut.id, name: "Opted out as local", type: .local)]
        let noSongs = try await assertSame(input, fixture.store, allLocal, [], limits: .init(), pageSizes: [1, 1_000], "all local")
        XCTAssertEqual(noSongs?.eligibleSongCount, 0)
        XCTAssertEqual(noSongs?.hasCloudEligibleSources, false)
        XCTAssertEqual(Self.exportFiles().subtracting(filesBefore), [], "no temporary file after an empty result")
    }

    /// 局域网分段直传的封面那一段(`collectPortableArtwork(fromSnapshotData:)`)同样一页一页收,与以前相同。
    func testLANArtworkStageCollectsPageByPageLikeTheReference() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        for (inputName, input) in fixture.inputs {
            for budget in [MusicLibrary.portableArtworkBudgetBytes, 6_000, 1_500, 1, 0] {
                let reference = await MusicLibrary.collectPortableArtworkReference(
                    fromSnapshotData: input, assetStore: fixture.store, maximumRawBytes: budget
                )
                for pageSize in [1, 5, 1_000] {
                    let streamed = await MusicLibrary.collectPortableArtwork(
                        fromSnapshotData: input, assetStore: fixture.store, maximumRawBytes: budget, pageSize: pageSize
                    )
                    let label = "\(inputName) budget=\(budget) pageSize=\(pageSize)"
                    XCTAssertEqual(streamed?.customAssets, reference?.customAssets, label)
                    XCTAssertEqual(streamed?.cachedAssets, reference?.cachedAssets, label)
                    XCTAssertEqual(streamed?.references, reference?.references, label)
                    XCTAssertEqual(streamed?.rawBytes, reference?.rawBytes, label)
                    XCTAssertEqual(streamed?.coverContentSongIDs, reference?.coverContentSongIDs, label)
                    XCTAssertNotNil(streamed, label)
                }
                if budget == MusicLibrary.portableArtworkBudgetBytes {
                    XCTAssertFalse(reference?.customAssets.isEmpty ?? true, inputName)
                    XCTAssertFalse(reference?.cachedAssets.isEmpty ?? true, inputName)
                    XCTAssertTrue(reference?.references.keys.contains { $0.hasPrefix("artist/") } ?? false, inputName)
                    XCTAssertTrue(reference?.references.keys.contains { $0.hasPrefix("album/") } ?? false, inputName)
                }
            }
        }
        let unreadable = Data("{\"songs\":[{]}".utf8)
        let streamed = await MusicLibrary.collectPortableArtwork(fromSnapshotData: unreadable, assetStore: fixture.store)
        let reference = await MusicLibrary.collectPortableArtworkReference(fromSnapshotData: unreadable, assetStore: fixture.store)
        XCTAssertNil(streamed)
        XCTAssertNil(reference)
    }

    // MARK: - Comparing

    /// 以前的写法与一页一页的写法(各个分页大小)比;返回以前那份的结果。
    @discardableResult
    private func assertSame(
        _ data: Data,
        _ store: MetadataAssetStore,
        _ sources: [MusicSource]?,
        _ excluded: Set<String>,
        limits: MusicLibrary.PortableSnapshotSizeLimits,
        pageSizes: [Int],
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> MusicLibrary.PortableSnapshotTransferData? {
        let reference = await MusicLibrary.preparePortableSnapshotDataIncludingArtworkAssetsReference(
            data, cloudSources: sources, excludedSourceIDs: excluded, assetStore: store, limits: limits
        )
        for pageSize in pageSizes {
            let streamed = await MusicLibrary.preparePortableSnapshotPageByPage(
                data, cloudSources: sources, excludedSourceIDs: excluded, assetStore: store,
                maximumArtworkBytes: MusicLibrary.portableArtworkBudgetBytes, limits: limits, pageSize: pageSize
            )
            let context = "\(label) pageSize=\(pageSize)"
            XCTAssertEqual(streamed == nil, reference == nil, "nil: \(context)", file: file, line: line)
            guard let streamed, let reference else { continue }
            XCTAssertEqual(streamed.data.count, reference.data.count, "size: \(context)", file: file, line: line)
            XCTAssertTrue(streamed.data == reference.data, "bytes: \(context)", file: file, line: line)
            XCTAssertEqual(streamed.eligibleSongCount, reference.eligibleSongCount, "songs: \(context)", file: file, line: line)
            // 歌词名单(DL4):以前是每首留下的歌一个名字,现在只记歌词目录里有的;上传按名单从同一个目录挑出来的一样。
            let lyricsDirectory = MetadataAssetStore.shared.lyricsDirectoryURL
            let present = Set((try? FileManager.default.contentsOfDirectory(atPath: lyricsDirectory.path)) ?? [])
            XCTAssertEqual(streamed.eligibleLyricsFileNames, reference.eligibleLyricsFileNames.map { $0.intersection(present) },
                           "lyrics: \(context)", file: file, line: line)
            func gathered(_ names: Set<String>?) -> LyricsSnapshotEncoder.Result? {
                LyricsSnapshotEncoder.encodeDirectory(
                    lyricsDirectory, maximumOutputBytes: 4 << 20, maximumFileBytes: 1 << 20, allowedFileNames: names
                )
            }
            let lyricsNow = gathered(streamed.eligibleLyricsFileNames)
            let lyricsBefore = gathered(reference.eligibleLyricsFileNames)
            XCTAssertEqual(lyricsNow?.data, lyricsBefore?.data, "gathered lyrics: \(context)", file: file, line: line)
            XCTAssertEqual(lyricsNow?.fileCount, lyricsBefore?.fileCount, "gathered lyrics: \(context)", file: file, line: line)
            XCTAssertEqual(lyricsNow?.skippedFileCount, lyricsBefore?.skippedFileCount, "skipped lyrics: \(context)", file: file, line: line)
            XCTAssertEqual(streamed.artworkBytes, reference.artworkBytes, "artwork: \(context)", file: file, line: line)
            XCTAssertEqual(streamed.hasCloudEligibleSources, reference.hasCloudEligibleSources, "sources: \(context)", file: file, line: line)
        }
        return reference
    }

    private static func variant(_ result: MusicLibrary.PortableSnapshotTransferData?) -> String {
        guard let result,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else { return "nil" }
        let artwork = object["cachedArtworkAssets"] != nil || object["artworkAssets"] != nil
        let contents = object["coverContentSongIDs"] != nil
        switch (artwork, contents) {
        case (true, true): return "artwork+contents"
        case (true, false): return "artwork"
        case (false, true): return "contents"
        case (false, false): return "neither"
        }
    }

    private static func exportFiles() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("primuse-library-export-") })
    }

    // MARK: - Fixture

    private struct Fixture {
        let root: URL
        /// 写进共用歌词目录的几份歌词(上传从那里挑),用完删掉。
        let lyricsFiles: [URL]
        let store: MetadataAssetStore
        let inputs: [(name: String, data: Data)]
        /// iCloud 时歌词名单应有的样子:留下的歌里歌词目录有文件的那几个。
        let expectedCloudLyricsNames: Set<String>

        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
            for url in lyricsFiles { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 能压缩得不太好的小图(格子各一种颜色),JPEG 或 PNG(PNG 要先转成传输用的 JPEG)。
    private static func image(seed: Int, size: Int = 24, jpeg: Bool = true) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 | 1
            for y in stride(from: 0, to: size, by: 3) {
                for x in stride(from: 0, to: size, by: 3) {
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    UIColor(red: CGFloat(state & 0xFF) / 255, green: CGFloat((state >> 8) & 0xFF) / 255,
                            blue: CGFloat((state >> 16) & 0xFF) / 255, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: 3, height: 3))
                }
            }
        }
        return try XCTUnwrap(jpeg ? rendered.jpegData(compressionQuality: 0.9) : rendered.pngData())
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dl4-prep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = MetadataAssetStore(storageDirectory: root)
        let uploadedOld = try XCTUnwrap(store.storeCustomArtworkSync(try Self.image(seed: 1)))
        let uploadedNew = try XCTUnwrap(store.storeCustomArtworkSync(try Self.image(seed: 2)))
        let selectedOnly = try XCTUnwrap(store.storeCustomArtworkSync(try Self.image(seed: 3)))
        let shared = try Self.image(seed: 4)
        let deep = (0..<30).map { "d\($0)" }.joined(separator: "/")
        var songs: [Song] = []
        func add(_ source: MusicSource, album: Int?, artist: String, cover: String? = nil, artistArtwork: String? = nil,
                 lyrics: String? = nil) -> Song {
            let index = songs.count
            let song = Song(
                id: "dl4-\(source.id)-\(index)", title: "Title \(index) / part", albumID: album.map { "dl4-album-\($0)" },
                albumTitle: album.map { "Album \($0)" }, artistName: artist, duration: 100 + Double(index),
                fileFormat: .flac, filePath: "/Music/\(deep)/\(artist)/\(index).flac", sourceID: source.id,
                dateAdded: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                coverArtFileName: cover, artistArtworkFileName: artistArtwork, lyricsFileName: lyrics
            )
            songs.append(song)
            return song
        }
        let adaThumbnail = try XCTUnwrap(SourceOwnedArtworkReference.make(sourceID: Self.nas.id, reference: "ada.jpg"))
        for index in 0..<8 {
            let song = add(Self.nas, album: index / 3, artist: index.isMultiple(of: 2) ? "Ada" : "Ben、Cy",
                           artistArtwork: index == 2 ? "ada.jpg" : nil,
                           lyrics: index == 1 ? "0123456789abcdef0123456789abcdef.json" : (index == 3 ? "track.lrc" : nil))
            let cover = index == 5 ? shared : try Self.image(seed: 10 + index)
            store.storeCoverSync(cover, for: song.id)
        }
        _ = add(Self.nas, album: 3, artist: "Ada", cover: "selected-\(uploadedNew).jpg")
        _ = add(Self.nas, album: 3, artist: "Dee", cover: "selected-\(selectedOnly).jpg")
        _ = add(Self.nas, album: nil, artist: "Eve", cover: "legacy-cover.jpg")
        try Self.image(seed: 30).write(to: store.artworkDirectoryURL.appendingPathComponent("legacy-cover.jpg"))
        for index in 0..<6 {
            let song = add(Self.phone, album: 10 + index / 2, artist: "Phone Artist \(index % 2)",
                           cover: index == 0 ? "selected-\(selectedOnly).jpg" : nil,
                           lyrics: index == 1 ? "fedcba9876543210fedcba9876543210.json" : nil)
            let cover = index == 3 ? shared : try Self.image(seed: 40 + index)
            if index > 0 { store.storeCoverSync(cover, for: song.id) }
        }
        for index in 0..<4 {
            let song = add(Self.optedOut, album: 20, artist: "Opted Artist", artistArtwork: "opt.jpg")
            store.storeCoverSync(try Self.image(seed: 50 + index), for: song.id)
        }
        // 专辑 1 的封面是 PNG:传输前要先转成 JPEG(第一次转、之后用转好的那份)。
        let albumCovers = [("dl4-album-0", try Self.image(seed: 60)), ("dl4-album-1", try Self.image(seed: 61, jpeg: false)),
                           ("dl4-album-11", try Self.image(seed: 62)), ("dl4-album-20", try Self.image(seed: 63))]
        for (albumID, cover) in albumCovers {
            _ = await store.storeAlbumCover(cover, forAlbumID: albumID)
        }
        func artistID(_ name: String) -> String { LibraryGroupingReference.hashID(ArtistIdentityPolicy.groupingKey(name)) }
        let artistCovers = [(artistID("Ada"), try Self.image(seed: 70)),
                            (artistID("Ada") + "\u{1F}" + adaThumbnail, try Self.image(seed: 71)),
                            (artistID("Phone Artist 1"), try Self.image(seed: 72)), (artistID("Opted Artist"), try Self.image(seed: 73))]
        for (id, cover) in artistCovers {
            _ = await store.storeArtistImage(cover, forArtistID: id)
        }

        let catalogs = try JSONDecoder().decode([SourceArtistArtworkCatalog].self, from: Data("""
        [{"sourceID":"dl4-nas","directoryParents":{},"songParentDirectories":{},"candidatesByDirectory":{}},
         {"sourceID":"dl4-phone","directoryParents":{},"songParentDirectories":{},"candidatesByDirectory":{}}]
        """.utf8))
        let pending = PlaylistPendingEntry.makeID()
        let snapshot = MusicLibrary.Snapshot(
            songs: songs,
            playlists: [Playlist(id: "dl4-p1", name: "Mixed"), Playlist(id: "dl4-p2", name: "Phone only")],
            artworkOverrides: [
                LibraryArtworkOverride(owner: .init(kind: .album, id: "dl4-album-0"), mode: .uploaded,
                                       uploadedContentID: uploadedOld, updatedAt: Date(timeIntervalSince1970: 1_000)),
                LibraryArtworkOverride(owner: .init(kind: .artist, id: artistID("Ben")), mode: .uploaded,
                                       uploadedContentID: uploadedNew, updatedAt: Date(timeIntervalSince1970: 2_000)),
                LibraryArtworkOverride(owner: .init(kind: .album, id: "dl4-album-1"), mode: .selectedSong,
                                       updatedAt: Date(timeIntervalSince1970: 3_000)),
            ],
            automaticArtistArtworkCatalogs: catalogs,
            mirrorPlaylistSuppressions: nil,
            smartPlaylists: nil,
            playlistSongIDs: [
                "dl4-p1": [songs[0].id, songs[12].id, pending, songs[3].id, songs[0].id, songs[20].id],
                "dl4-p2": [songs[13].id, songs[14].id],
            ],
            recentPlaybackSongIDs: [songs[13].id, songs[2].id, songs[19].id, songs[9].id],
            deletedSongIdentities: ["dl4-nas:/gone.flac"],
            pendingPlaylistIdentities: nil,
            pendingHistoryIdentities: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sorted = try encoder.encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: sorted)
        let shuffled = try JSONSerialization.data(withJSONObject: object)
        let unescaped = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        // 歌词:一首留下的歌(按 id 起的名字)、一个旧式文件名、一首本机源的歌(iCloud 时不在名单里)、一份谁都不是的。
        let lyricsDirectory = MetadataAssetStore.shared.lyricsDirectoryURL
        try FileManager.default.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
        let keptName = MetadataAssetStore.shared.expectedLyricsFileName(for: songs[0].id)
        let legacyName = "0123456789abcdef0123456789abcdef.json"
        let names = [keptName, legacyName, MetadataAssetStore.shared.expectedLyricsFileName(for: songs[13].id),
                     "ffffffffffffffffffffffffffffffff.json"]
        var lyricsFiles: [URL] = []
        for name in names {
            let url = lyricsDirectory.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            try Data("[{\"time\":0,\"text\":\"\(name)\"}]".utf8).write(to: url)
            lyricsFiles.append(url)
        }
        return Fixture(
            root: root, lyricsFiles: lyricsFiles, store: store,
            inputs: [("encoder", sorted), ("serialized", shuffled), ("unescaped", unescaped)],
            expectedCloudLyricsNames: [keptName, legacyName]
        )
    }
}

/// 每解出一页记一笔(在整理的线程上调)。
private final class DecodedPageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    func append(_ pass: Int) {
        lock.withLock { recorded.append(pass) }
    }

    var passes: [Int] { lock.withLock { recorded } }
}
