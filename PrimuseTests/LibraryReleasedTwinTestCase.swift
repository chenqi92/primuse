import Foundation
import Observation
import PrimuseKit
import XCTest
@testable import Primuse

/// 歌曲模型真放掉的测试共用的底子(6c 单元 4 S7):临时目录、开着目录双写的曲库、两个源(B 停用)的样例库、
/// 「像启动过一次」的孪生库、真放掉、「没装模型也没读整库数组」的断言、影子校验。各单元的测试类继承它,
/// 各自一个文件。
@MainActor
class LibraryReleasedTwinTestCase: XCTestCase {
    var directory: URL!

    var libraries: [MusicLibrary] = []

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCatalogDualWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for library in libraries { await library.stopCatalogMirror() }
        libraries = []
        try? FileManager.default.removeItem(at: directory)
    }

    func makeLibrary(
        catalog: LibraryCatalogMirroring = .enabled(startDelay: .zero),
        disabledSourceIDs: Set<String> = [],
        maintenanceAllowed: @escaping @MainActor () -> Bool = { true }
    ) -> MusicLibrary {
        let library = MusicLibrary(
            disabledSourceIDs: disabledSourceIDs,
            storageDirectory: directory,
            artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: maintenanceAllowed,
            catalogMirroring: catalog
        )
        library.catalogShadowModeOverride = .deep
        libraries.append(library)
        return library
    }

    static let sourceA = "dual-write-a"

    static let sourceB = "dual-write-b"

    /// 两个源;合唱、专辑艺人推断用的无标签目录、跨源同名专辑、有声书(m4b)、播客、
    /// 环境音、CUE 分轨(同一个文件)、多流派写法。
    static func fixture(prefix: String = UUID().uuidString.prefix(6).lowercased()) -> [Song] {
        var songs: [Song] = []
        func add(_ id: String, _ title: String, album: String?, artist: String?, albumArtist: String? = nil,
                 track: Int? = nil, disc: Int? = 1, path: String, source: String = sourceA,
                 genre: String? = "Pop", format: AudioFormat = .flac, cover: String? = nil, year: Int? = 2001,
                 added: TimeInterval = 0) {
            var song = Song(
                id: "\(prefix)-\(id)", title: title, albumTitle: album, artistName: artist, albumArtistName: albumArtist,
                trackNumber: track, discNumber: disc, duration: 180 + Double(songs.count), fileFormat: format,
                filePath: path, sourceID: source, genre: genre, year: year, coverArtFileName: cover
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000 + added + Double(songs.count))
            songs.append(song)
        }
        for track in 1...4 {
            add("blue-\(track)", "Blue \(track)", album: "Blue Room", artist: track == 2 ? "Ada、Ben" : "Ada",
                albumArtist: "Ada", track: track, path: "/Music/Ada/Blue Room/\(track).flac", cover: track == 1 ? "blue.jpg" : nil)
        }
        for track in 1...3 {
            add("comp-\(track)", "Comp \(track)", album: "Mixtape", artist: "Artist \(track)", track: track,
                path: "/Music/Mixtape/\(track).flac", genre: "Rock/Pop")
        }
        // 跨源同名专辑。
        for track in 1...2 {
            add("blueb-\(track)", "Blue B\(track)", album: "Blue Room", artist: "Ada", albumArtist: "Ada", track: track,
                path: "/Share/Ada/Blue Room/\(track).flac", source: sourceB)
        }
        add("loose", "Loose Track", album: nil, artist: nil, path: "/Music/Loose/loose.mp3", genre: nil, format: .mp3)
        for chapter in 1...3 {
            add("book-\(chapter)", "Chapter \(chapter)", album: "Long Story", artist: "Narrator", track: chapter,
                path: "/Books/Long Story/\(chapter).m4b", genre: "Audiobook", format: .m4a)
        }
        for episode in 1...2 {
            add("pod-\(episode)", "Episode \(episode)", album: "Weekly Show", artist: "Host", track: episode,
                path: "/Podcasts/Weekly/\(episode).mp3", source: sourceB, genre: "Podcast", format: .mp3)
        }
        add("rain", "Rain", album: "Sleep", artist: "Nature", path: "/Ambient/rain.flac", genre: "White Noise")
        for track in 1...2 {
            add("cue-\(track)", "Cue \(track)", album: "Live Set", artist: "DJ", track: track,
                path: "/Music/Live/set.flac", genre: "Electronic", cover: "set.jpg", added: 50)
        }
        return songs
    }

    func assertShadowMatches(
        _ library: MusicLibrary,
        _ step: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await library.waitForCatalogMirror()
        let report = await library.verifyCatalogShadow(reason: step, mode: .deep)
        XCTAssertEqual(report?.outcome, .matched, "\(step): \(report?.logLine ?? "no report (skipped)")", file: file, line: line)
    }

    /// 一个库的目录:带目录、停用源 B,同一份夹具;`extra` 是夹具之外另加的行。
    func makeTwin(
        _ name: String, songs: [Song], extra: [Song] = []
    ) throws -> (library: MusicLibrary, storage: URL) {
        let sources: Set<String> = [Self.sourceA, Self.sourceB]
        let storage = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let library = MusicLibrary(
            disabledSourceIDs: [Self.sourceB], storageDirectory: storage, artistNameConfiguration: .defaultValue,
            deferredMaintenanceAllowed: { true }, catalogMirroring: .enabled(startDelay: .zero)
        )
        library.catalogShadowModeOverride = .deep
        libraries.append(library)
        library.addSongs(songs + extra, affectedSourceIDs: sources.union(extra.map(\.sourceID)))
        return (library, storage)
    }

    final class Tally {
        var count = 0
    }

    /// 这个库要过的歌曲模型占用,按先后(测试登记开着的时候)。
    func songModelHolds(of library: MusicLibrary) -> [MusicLibrary.SongModelHoldReason] {
        (MusicLibrary.songModelHoldRequestsForTesting ?? [])
            .filter { $0.library == ObjectIdentifier(library) }
            .map(\.reason)
    }

    /// 歌曲模型此刻的样子(各份数组里 id 的先后):装回来之后要与放掉之前、与一直没放的库逐项相同。
    func modelPicture(_ library: MusicLibrary) -> [String: [String]] {
        var picture: [String: [String]] = [:]
        picture["songs"] = library.songs.map(\.id)
        picture["visibleSongs"] = library.visibleSongs.map(\.id)
        picture["musicSongs"] = library.musicSongs.map(\.id)
        picture["spokenWordSongs"] = library.spokenWordSongs.map(\.id)
        picture["ambientSongs"] = library.ambientSongs.map(\.id)
        picture["musicVideoSongs"] = library.musicVideoSongs.map(\.id)
        picture["localPodcastSongs"] = library.localPodcastSongs.map(\.id)
        picture["albums"] = library.albums.map(\.id).sorted()
        picture["artists"] = library.artists.map(\.id).sorted()
        picture["visibleAlbums"] = library.visibleAlbums.map(\.id)
        picture["visibleArtists"] = library.visibleArtists.map(\.id)
        picture["visibleAlbumArtists"] = library.visibleAlbumArtists.map(\.id)
        picture["visibleGenres"] = library.visibleGenres.map { genre in
            "\(genre.id) songs=\(genre.songCount) albums=\(genre.albumCount)"
        }
        picture["flags"] = [
            "spokenWord=\(library.hasSpokenWordContent) \(library.spokenWordSongCount)",
            "ambient=\(library.hasAmbientContent)",
            "musicVideo=\(library.hasMusicVideoContent)",
        ]
        return picture
    }

    func released(_ library: MusicLibrary, _ step: String, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let outcome = await releaseOnceShadowVerificationIsDone(library, trigger: step)
        guard case .released = outcome else {
            XCTFail("\(step): not released: \(outcome)", file: file, line: line)
            return false
        }
        return true
    }

    /// 放掉歌曲模型;影子校验还在跑时放不了(那是放掉自己的一条空闲条件),等它跑完再试,最多等 15 秒。
    /// 机器忙的时候定时的那一轮校验会正好落在测试要放的这一刻。别的拒绝理由原样返回。
    /// 测试里所有直接的放掉都走这里(期望放掉的,也期望某一条别的拒绝理由的)。
    func releaseOnceShadowVerificationIsDone(
        _ library: MusicLibrary, trigger: String, returningFreedMemory: Bool = true
    ) async -> MusicLibrary.SongModelReleaseOutcome {
        let deadline = ContinuousClock.now + .seconds(15)
        var outcome = await library.releaseSongModelIfIdle(trigger: trigger, returningFreedMemory: returningFreedMemory)
        while outcome == .skipped("catalog shadow verification in flight"), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            outcome = await library.releaseSongModelIfIdle(trigger: trigger, returningFreedMemory: returningFreedMemory)
        }
        return outcome
    }

    func waitUntilReady(_ library: MusicLibrary) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !library.isReady, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 同 `makeTwin`,旧库再像经过了一次启动那样标上迁移版本:只装歌曲模型要旧库是启动认的那一份,
    /// 这一轮进程里才建起来的旧库要到下一次启动(或一次整份装载)才标上。
    func makeLaunchedTwin(
        _ name: String, songs: [Song], extra: [Song] = []
    ) throws -> (library: MusicLibrary, storage: URL) {
        let twin = try makeTwin(name, songs: songs, extra: extra)
        let store = try IncrementalSongStore(path: twin.storage.appendingPathComponent("library-songs.sqlite").path)
        try store.markMigrationCompleted(version: 10)
        return twin
    }

    /// 真放掉歌曲模型(`releaseSongModelIfIdle`)。返回放掉那一刻的统计,给「没装、没读整库数组」比。
    func releaseForReal(_ library: MusicLibrary) async throws -> MusicLibrary.SongModelResidencyStatistics {
        library.songModelResidencyEnabled = true
        let outcome = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        guard case .released = outcome else {
            XCTFail("not released: \(outcome)")
            throw CancellationError()
        }
        XCTAssertFalse(library.isReady)
        XCTAssertTrue(library.isUsable)
        return library.songModelResidencyStatistics
    }

    func assertNoLoadAndNoArrayRead(
        _ library: MusicLibrary, since before: MusicLibrary.SongModelResidencyStatistics, _ step: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let now = library.songModelResidencyStatistics
        XCTAssertEqual(now.loads, before.loads, "\(step): a load was requested", file: file, line: line)
        XCTAssertEqual(now.arrayReadsWhileUnloaded, before.arrayReadsWhileUnloaded,
                       "\(step): a whole-library array was read", file: file, line: line)
        XCTAssertFalse(library.isLoadingSongModelForTesting, "\(step): a load is running", file: file, line: line)
    }

    // MARK: - Launch without the song model (P3 step 6e)

    /// 一个装好、落了盘的库(旧库像启动过那样标好):小状态有歌单、喜欢、最近播放;目录停下之后整个目录拷一份,
    /// 后面的「启动」都从拷贝开。
    func launchFixture(_ name: String, songs: [Song]) async throws -> (source: MusicLibrary, directory: URL) {
        let (library, storage) = try makeLaunchedTwin(name, songs: songs)
        _ = library.createPlaylist(name: "Kept", songIDs: [songs[0].id, songs[4].id, songs[7].id])
        library.setLiked(songID: songs[1].id, isLiked: true, propagatesServerMutation: false)
        library.recordPlayback(of: songs[2].id)
        await assertShadowMatches(library, "\(name) fixture")
        library.markPortableSnapshotDirtyForTesting()
        guard case .success = await library.persistNowAndWait(materializePortableSnapshot: true) else {
            throw XCTSkip("the fixture did not persist")
        }
        await library.waitForCatalogMirror()
        await library.stopCatalogMirror()
        return (library, storage)
    }

    /// 拷整个目录。原来那个库可能还在后台写缓存文件(先写临时文件再改名),拷到一半那个临时文件没了就再拷一次。
    func copyOfDirectory(_ directory: URL, _ name: String) throws -> URL {
        let copy = self.directory.appendingPathComponent(name, isDirectory: true)
        var lastError: Error?
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.copyItem(at: directory, to: copy)
                return copy
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// 像 App 那样启动一个库:准备中构造、装开关、目录提前启动、主线程外准备、`publishStartup` 发布。
    /// `beforePublish`:开关装好、目录提前启动之后、准备与发布之前调一次(DL3:场景先于「可用」变成活跃的那种启动)。
    func launch(
        _ directory: URL, unloaded: Bool, residency: Bool = true, catalog: LibraryCatalogMirroring = .enabled(startDelay: .zero),
        beforePublish: (MusicLibrary) -> Void = { _ in }
    ) async -> MusicLibrary {
        let library = MusicLibrary.makePreparing(
            storageDirectory: directory, disabledSourceIDs: [Self.sourceB], artistNameConfiguration: .defaultValue,
            catalogMirroring: catalog
        )
        library.catalogShadowModeOverride = .deep
        libraries.append(library)
        library.applySongModelResidencySettings(.init(
            isEnabled: residency, foregroundHold: false, playbackBlocksRelease: true, launchUnloaded: unloaded
        ))
        let classification = SpokenWordStore.shared.classificationSnapshot
        library.startCatalogBeforePublish(spokenWordClassification: classification)
        beforePublish(library)
        let disabled: Set<String> = [Self.sourceB]
        let prepared = await MusicLibrary.prepareStartup(
            disabledSourceIDs: disabled, storageDirectory: directory, artistNameConfiguration: .defaultValue,
            spokenWordClassification: classification, withoutTheSongModel: library.songModelResidencySettings.launchesUnloaded
        )
        await library.publishStartup(prepared) {
            await MusicLibrary.prepareStartup(
                disabledSourceIDs: disabled, storageDirectory: directory, artistNameConfiguration: .defaultValue,
                spokenWordClassification: classification
            )
        }
        return library
    }

    func waitUntilUsable(_ library: MusicLibrary) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !library.isUsable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
