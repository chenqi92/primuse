import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

/// 6c 单元 4 U9b:歌曲行上打开的标签编辑器,翻页队列(同源同目录的歌,按文件名排)在歌曲模型放掉之后从曲库目录取,
/// 与模型在内存里时在可见歌里挑的逐首相同 —— 子文件夹里的、别的源里同一路径的、停用源里的不算,CUE 分轨共用一个文件名时
/// 照库内顺序,只有一首或没有目录时没有队列;不装模型、不读整库数组。同目录的歌比上限多时占用模型照内存取。
@MainActor
final class TagEditorQueueReleasedTests: LibraryReadyCatalogFixture {
    private static func extra(prefix: String) -> [Song] {
        func song(_ id: String, _ title: String, path: String, source: String = sourceA) -> Song {
            var song = Song(id: "\(prefix)-\(id)", title: title, albumTitle: "Blue Room", artistName: "Ada",
                            fileFormat: .flac, filePath: path, sourceID: source)
            song.dateAdded = Date(timeIntervalSince1970: 1_700_600_000)
            return song
        }
        return [
            song("bonus", "Bonus", path: "/Music/Ada/Blue Room/Bonus/1.flac"),
            song("other-source", "Elsewhere", path: "/Music/Ada/Blue Room/9.flac", source: sourceB),
            song("upper", "Upper", path: "/Music/Ada/Blue Room/10.flac"),
            song("no-directory", "Bare", path: "bare.flac"),
            song("set-intro", "Intro", path: "/Music/Live/intro.flac"),
        ]
    }

    private static func anchors(prefix: String) -> [String] {
        ["blue-1", "blue-3", "upper", "bonus", "cue-1", "cue-2", "set-intro", "loose", "no-directory", "comp-2"]
            .map { "\(prefix)-\($0)" }
    }

    private func queues(_ library: MusicLibrary, anchors: [Song]) async throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for anchor in anchors {
            let answer = await SongTagEditorQueue.queue(for: anchor, library: library)
            let queue = try XCTUnwrap(answer, "\(anchor.id) answered")
            result[anchor.id] = queue.map(\.id)
        }
        return result
    }

    func testTagEditorQueueFromTheCatalogEqualsTheLoadedOne() async throws {
        let prefix = "u9b-queue"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix), extra: Self.extra(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let anchors = try Self.anchors(prefix: prefix).map { try XCTUnwrap(library.song(id: $0), $0) }
        let loaded = try await queues(library, anchors: anchors)
        XCTAssertEqual(loaded["\(prefix)-blue-1"]?.count, 5, "four tracks and 10.flac; not the bonus folder, not the other source")
        XCTAssertEqual(loaded["\(prefix)-blue-1"]?.last, "\(prefix)-upper", "file names in natural order: 10 after 4")
        XCTAssertEqual(loaded["\(prefix)-cue-1"], ["\(prefix)-set-intro", "\(prefix)-cue-1", "\(prefix)-cue-2"],
                       "two CUE tracks share one file name: library order")
        XCTAssertEqual(loaded["\(prefix)-loose"], [], "a single song has no queue")
        XCTAssertEqual(loaded["\(prefix)-no-directory"], [], "no directory, no queue")
        XCTAssertEqual(loaded["\(prefix)-bonus"], [])

        let loadedSongs = Dictionary(library.visibleSongs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let before = try await releaseForReal(library)
        let released = try await queues(library, anchors: anchors)
        XCTAssertEqual(released, loaded)
        // 编辑器拿到的是整首歌(翻页时显示下一首的歌名),与内存里的相同。
        let blueAnswer = await SongTagEditorQueue.queue(for: anchors[0], library: library)
        let blue = try XCTUnwrap(blueAnswer)
        XCTAssertEqual(blue, (loaded["\(prefix)-blue-1"] ?? []).compactMap { loadedSongs[$0] })
        // 行的正文与内容分级角标:放掉时用行自己的那首,不按 id 再读一遍目录(模型在内存里时照原来取最新的)。
        XCTAssertEqual(SongRowLatest.song(anchors[0], library: library), anchors[0])
        #if os(iOS)
        // 行本身:放掉之后画一屏歌曲行(含标签、内容分级、离线角标),不装模型、不读整库数组。
        let services = AppServices.shared
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("row-sources"))
        let window = try host(
            List(Array(loadedSongs.values.sorted { $0.id < $1.id }.prefix(12))) { song in SongRowView(song: song) }
                .environment(library).environment(sources).environment(services.playerService)
                .environment(services.sourceManager).environment(services.metadataBackfill)
                .environment(services.scraperSettingsStore).environment(services.themeService)
                .environment(services.batchRemoval).environment(services.scraperService)
        )
        try await Task.sleep(for: .milliseconds(500))
        unhost(window)
        #endif
        assertNoLoadAndNoArrayRead(library, since: before, "tag editor queue and song rows while released")

        // 同目录的歌比目录上一次取的上限多:占用模型照内存取,结果相同(装一次)。
        let limit = SongTagEditorQueue.catalogSongLimit
        SongTagEditorQueue.catalogSongLimit = 2
        defer { SongTagEditorQueue.catalogSongLimit = limit }
        let held = await SongTagEditorQueue.queue(for: anchors[0], library: library)
        XCTAssertEqual(held?.map(\.id), loaded["\(prefix)-blue-1"])
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
    }

    func testTagEditorQueueAfterALaunchThatNeverLoadedTheModel() async throws {
        let name = "u9b-queue-launch"
        let (source, library) = try await launchWithoutTheSongModel(name)
        let anchors = try ["blue-1", "cue-2", "mv-apple", "loose"].map { try XCTUnwrap(source.song(id: "\(name)-\($0)")) }
        let loaded = try await queues(source, anchors: anchors)
        XCTAssertEqual(loaded["\(name)-blue-1"]?.count, 4)
        let before = library.songModelResidencyStatistics
        let released = try await queues(library, anchors: anchors)
        XCTAssertEqual(released, loaded)
        XCTAssertFalse(library.isReady)
        assertNoLoadAndNoArrayRead(library, since: before, "tag editor queue after an unloaded launch")
    }
}
