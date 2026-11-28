import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 UA:要拿整库来判断、最后删东西或写东西的动作,在歌曲模型放掉之后(和这次启动根本没装)先把模型
/// 装回来再判断,判断与模型在内存里时相同;装不回来时什么都不删。
@MainActor
final class WholeLibraryActionHoldTests: LibraryReleasedTwinTestCase {
    private struct Deletion: Equatable {
        var attempts: [String]
        var removed: Int
        var failed: Int
        var remaining: [String]
    }

    /// 批量删源文件:选中一首与别的分轨共用文件和旁挂文件的歌(CUE 的一轨)和一首自己一个文件的歌。
    /// 前者的旁挂文件不该去删,后者的照删;删掉的行从库里移走。
    private func deleteSourceFiles(
        in library: MusicLibrary, _ name: String, timeout: Duration = SongModelArrayRead.defaultTimeout
    ) async throws -> Deletion {
        let suite = "WholeLibraryActionHold-\(name)-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = directory.appendingPathComponent("\(name)-services", isDirectory: true)
        let source = MusicSource(id: Self.sourceA, name: "A", type: .webdav)
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(source)
        let paths = Self.fixture(prefix: "ua").filter { $0.sourceID == Self.sourceA }.map(\.filePath)
        let connector = ActionHoldConnector(sourceID: Self.sourceA, files: Set(paths))
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        let settings = PlaybackSettingsStore(
            defaults: defaults, cloudSync: CloudKVSSync(store: nil, defaults: defaults, observing: nil)
        )
        let player = AudioPlayerService(
            sourceManager: manager, library: library, playbackSettings: settings,
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")),
            musicSessionMemoryStore: MusicSessionMemoryStore(defaults: defaults, url: root.appendingPathComponent("music.json")),
            activateAudioSession: { _ in XCTFail("An empty queue must stay silent") }
        )
        let service = SongBatchRemovalService(library: library, sourceManager: manager, sourcesStore: store, player: player)
        service.songModelTimeout = timeout
        let selected = try ["ua-cue-1", "ua-loose"].map { id in
            try XCTUnwrap(library.storedSong(id: id), "\(name): \(id)")
        }
        let task = try XCTUnwrap(service.remove(selected, mode: .sourceFiles))
        await task.value
        let outcome = try XCTUnwrap(service.lastOutcome)
        let attempts = await connector.deletionAttempts
        let remaining = library.isReady ? library.songs.map(\.id).sorted() : []
        return Deletion(attempts: attempts.sorted(), removed: outcome.removed, failed: outcome.failed, remaining: remaining)
    }

    /// 模型在内存里、真放掉之后、这次启动没装:批量删源文件判断出的要删的文件与旁挂文件、移走的行都相同;
    /// 后两种各装一次模型(占用 `.userAction`),做完放手。
    func testBatchSourceDeletionDecidesTheSameWithoutTheSongModel() async throws {
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let (loaded, _) = try makeLaunchedTwin("ua-loaded", songs: Self.fixture(prefix: "ua"))
        await assertShadowMatches(loaded, "loaded fixture")
        let expected = try await deleteSourceFiles(in: loaded, "loaded")
        XCTAssertEqual(expected.removed, 2)
        XCTAssertEqual(expected.failed, 0)
        XCTAssertTrue(expected.attempts.contains("/Music/Live/set.flac"))
        XCTAssertTrue(expected.attempts.contains("/Music/Loose/loose.mp3"))
        XCTAssertFalse(expected.attempts.contains("/Music/Live/set.lrc"), "the other CUE track keeps the shared sidecars")
        XCTAssertTrue(expected.attempts.contains("/Music/Loose/loose.lrc"), "a song's own sidecars are deleted")
        XCTAssertFalse(expected.remaining.contains("ua-loose"))

        let (released, _) = try makeLaunchedTwin("ua-released", songs: Self.fixture(prefix: "ua"))
        await assertShadowMatches(released, "released fixture")
        let before = try await releaseForReal(released)
        let afterRelease = try await deleteSourceFiles(in: released, "released")
        XCTAssertEqual(afterRelease, expected, "released: the same files, sidecars and rows")
        XCTAssertEqual(released.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertFalse(released.songModelHoldReasons.contains(.userAction), "the hold ended with the operation")

        let (_, storage) = try await launchFixture("ua-launch", songs: Self.fixture(prefix: "ua"))
        let unloaded = await launch(try copyOfDirectory(storage, "ua-unloaded"), unloaded: true)
        XCTAssertEqual(unloaded.songModelLaunch, "unloaded")
        try await waitUntilUsable(unloaded)
        XCTAssertFalse(unloaded.isReady)
        let afterLaunch = try await deleteSourceFiles(in: unloaded, "unloaded")
        XCTAssertEqual(afterLaunch.attempts, expected.attempts, "never loaded: the same files and sidecars")
        XCTAssertEqual(afterLaunch.removed, expected.removed)
        XCTAssertEqual(afterLaunch.remaining, expected.remaining)
        XCTAssertEqual(unloaded.songModelResidencyStatistics.loads, 1)
    }

    /// 模型装不回来(测量钩子放掉的库不会自己装载):一个文件都不删,选中的歌按删除失败交回。
    func testBatchSourceDeletionThatCannotBringTheModelBackDeletesNothing() async throws {
        let (library, _) = try makeLaunchedTwin("ua-stuck", songs: Self.fixture(prefix: "ua"))
        await assertShadowMatches(library, "fixture")
        let selected = ["ua-cue-1", "ua-loose"].compactMap { id in library.storedSong(id: id) }
        XCTAssertEqual(selected.count, 2)
        library.dropSongModelForMeasurement(includingCollections: true)
        let result = try await deleteSourceFiles(in: library, "stuck", timeout: .milliseconds(300))
        XCTAssertEqual(result.attempts, [], "cannot answer: nothing is deleted")
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(result.failed, 2, "reported as failed deletions")
        XCTAssertFalse(library.songModelHoldReasons.contains(.userAction))
    }

    /// 删整个分轨文件前的确认框里「有 N 首用这个文件」:放掉之后按文件问目录,与模型在内存里时的数相同,
    /// 不装模型、不读整库数组。
    func testTheWholeFileWarningCountsTheSameTracksWhileReleased() async throws {
        func segment(_ number: Int) -> Song {
            var song = Song(
                id: "ua-seg-\(number)", title: "Segment \(number)", albumTitle: "Concert", artistName: "Band",
                trackNumber: number, discNumber: 1, duration: 60, fileFormat: .flac,
                filePath: "/Music/Concert/whole.flac", sourceID: Self.sourceA, genre: "Pop", year: 2010
            )
            song.cueSheetPath = "/Music/Concert/whole.cue"
            song.cueStartTime = Double(number - 1) * 60
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_100 + Double(number))
            return song
        }
        let (library, _) = try makeLaunchedTwin(
            "ua-whole-file", songs: Self.fixture(prefix: "ua"), extra: (1...3).map(segment)
        )
        await assertShadowMatches(library, "fixture")
        let selected = try XCTUnwrap(library.storedSong(id: "ua-seg-1"))
        let warning = try XCTUnwrap(SourceFileDeletionPolicy.wholeFileWarning(for: [selected]))
        let loadedMessage = warning.message(for: [selected], in: library)
        let loadedTracks = SourceFileDeletionPolicy.WholeFileWarning.tracksSharingFiles(of: [selected], in: library)
        XCTAssertEqual(SourceFileDeletionPolicy.affectedSongs(deleting: [selected], in: loadedTracks).count, 3)

        let before = try await releaseForReal(library)
        XCTAssertEqual(warning.message(for: [selected], in: library), loadedMessage)
        assertNoLoadAndNoArrayRead(library, since: before, "the whole-file warning")
    }

    /// 「整理整个曲库的标签」:放掉之后先装回来,选进来的歌与模型在内存里时相同;装不回来时 nil,不打开空的整理页。
    func testTidyingTheWholeLibraryWaitsForTheSongModel() async throws {
        let (library, _) = try makeLaunchedTwin("ua-tidy", songs: Self.fixture(prefix: "ua-tidy"))
        await assertShadowMatches(library, "fixture")
        let loaded = await BatchSongSelection.wholeLibraryForTidy(library)
        let loadedIDs = try XCTUnwrap(loaded).songs.map(\.id)
        XCTAssertFalse(loadedIDs.isEmpty)
        let before = try await releaseForReal(library)
        let released = await BatchSongSelection.wholeLibraryForTidy(library)
        XCTAssertEqual(released?.songs.map(\.id), loadedIDs)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)

        let (stuck, _) = try makeLaunchedTwin("ua-tidy-stuck", songs: Self.fixture(prefix: "ua-tidy-stuck"))
        await assertShadowMatches(stuck, "fixture")
        stuck.dropSongModelForMeasurement(includingCollections: true)
        let none = await SongModelArrayRead.read(stuck, timeout: .milliseconds(200)) {
            BatchSongSelection(songs: stuck.songs)
        }
        XCTAssertNil(none, "cannot answer: no selection, not an empty one")
    }
}

/// 记下删了哪些路径的音乐源连接(只删存在的文件;不存在的报找不到,同真的连接)。
private actor ActionHoldConnector: MusicSourceConnector {
    let sourceID: String
    private(set) var files: Set<String>
    private(set) var deletionAttempts: [String] = []

    init(sourceID: String, files: Set<String>) {
        self.sourceID = sourceID
        self.files = files
    }

    func deleteFile(at path: String) async throws {
        deletionAttempts.append(path)
        guard files.remove(path) != nil else { throw SourceError.fileNotFound(path) }
    }

    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
}
