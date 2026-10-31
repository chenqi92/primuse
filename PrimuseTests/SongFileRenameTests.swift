import Foundation
import PrimuseKit
import XCTest
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import Primuse

final class SongFileRenameTests: XCTestCase {
    func testWebDAVRenameUsesConditionalMoveWithoutOverwrite() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RenameDAVProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let id = UUID().uuidString
        let source = WebDAVSource(sourceID: id, host: "rename.invalid", useSsl: true,
            username: "", password: "", mutationSession: session)
        let state = EmbeddedMetadataRemoteFileState(fileSize: 8, modifiedDate: nil, revision: "\"version-1\"")
        try await source.moveFileWithoutReplacing(from: "/\(id)/old.flac", to: "/\(id)/歌手.flac", expected: state)
        let request = try XCTUnwrap(RenameDAVProtocol.takeRequest(id))
        XCTAssertEqual(request.httpMethod, "MOVE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"version-1\"")
        XCTAssertEqual(URL(string: try XCTUnwrap(request.value(forHTTPHeaderField: "Destination")))?.path, "/\(id)/歌手.flac")
        await source.disconnect()
    }

    func testLocalRenameKeepsBytesCompanionsAndSongIdentityAcrossRescan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = Data(repeating: 0x2A, count: 2048)
        try audio.write(to: directory.appendingPathComponent("old.mp3"))
        try Data("[00:01]Hello".utf8).write(to: directory.appendingPathComponent("old.lrc"))
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("old-cover.jpg"))
        try Data([4, 5, 6]).write(to: directory.appendingPathComponent("cover.jpg"))
        let connector = LocalFileSource(sourceID: UUID().uuidString, basePath: directory)
        try await connector.connect()
        let sourceID = await connector.sourceID
        var initial: [Song] = []
        for try await row in try await connector.scanSongs(from: "/") { initial.append(row.song) }
        var original = try XCTUnwrap(initial.first)
        XCTAssertEqual(original.sourceID, sourceID)
        original.title = "Edited title"
        original.coverArtFileName = "/old-cover.jpg"
        original.lyricsFileName = "/old.lrc"
        let state = try await connector.metadataWritebackState(for: original.filePath)
        original.revision = state.revision
        original.lastModified = state.modifiedDate
        original.userMetadataEditedAt = Date()
        let result = try await connector.renameSongFile(original, stem: "歌手 - New Song")
        XCTAssertEqual(result.song.id, original.id)
        XCTAssertEqual(result.song.filePath, "/歌手 - New Song.mp3")
        XCTAssertEqual(result.song.lyricsFileName, "/歌手 - New Song.lrc")
        XCTAssertEqual(result.song.coverArtFileName, "/歌手 - New Song-cover.jpg")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("歌手 - New Song.mp3")), audio)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("cover.jpg")), Data([4, 5, 6]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("old.mp3").path))
        var rescanned: [Song] = []
        for try await row in try await connector.scanSongs(from: "/", existingSongs: [result.song]) {
            rescanned.append(row.song)
        }
        XCTAssertEqual(rescanned.map(\.id), [original.id])
        XCTAssertEqual(rescanned.first?.title, "Edited title")
        try audio.write(to: directory.appendingPathComponent("old.mp3"))
        var reusedName: [Song] = []
        for try await row in try await connector.scanSongs(from: "/", existingSongs: [result.song]) {
            reusedName.append(row.song)
        }
        XCTAssertEqual(Set(reusedName.map(\.id)).count, 2)
        XCTAssertEqual(reusedName.first { $0.filePath == result.song.filePath }?.id, original.id)
        await connector.disconnect()
    }

    func testRemoteRescanDistinguishesNewFileAtPreviousName() async throws {
        let connector = RenameFixture()
        let scanner = ConnectorScanner(connector: connector, sourceID: connector.sourceID)
        var initial: [Song] = []
        for try await update in await scanner.scan(directories: ["/"]) { initial = update.songs }
        let original = try XCTUnwrap(initial.first)
        let result = try await connector.renameSongFile(original, stem: "new")
        await connector.restoreOldName()
        var rescanned: [Song] = []
        for try await update in await scanner.scan(directories: ["/"], existingSongs: [result.song], identityIndex: [:]) {
            rescanned = update.songs
        }
        XCTAssertEqual(Set(rescanned.map(\.id)).count, 2)
        XCTAssertEqual(rescanned.first { $0.filePath == "/new.flac" }?.id, original.id)
    }

    @MainActor
    func testRenamedPathUpdatesPersistedScanIndex() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = root.appendingPathComponent("Primuse")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let original = RenameFixture().song
        let oldKey = "path:\(original.filePath)"
        let entry = SourceSyncIndexedItem(stableKey: oldKey, path: original.filePath,
            displayName: "old.flac", parentPath: "/", isDirectory: false, songIDs: [original.id],
            size: 8, modifiedDate: nil, revision: "audio")
        let state = SourceSyncState(sourceID: original.sourceID, scopeFingerprint: "fixture", index: [oldKey: entry])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([original.sourceID: state]).write(to: storage.appendingPathComponent("source-sync-states.json"))
        let fileManager = RenameTestFileManager(root: root)
        let scan = ScanService(fileManager: fileManager)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"), deferredMaintenanceAllowed: { false })
        await library.whenReady()
        library.addSongs([original])
        await library.waitForPendingIndex()
        var updated = original
        updated.filePath = "/New.flac"
        updated.lyricsFileName = "/New.lrc"
        try await scan.prepareForFileRename(sourceID: original.sourceID)
        try await scan.recordMetadataFileReplacement(original: original, updated: updated, in: library)
        let index = ScanService(fileManager: fileManager).libraryFolderSyncIndex(for: original.sourceID)
        XCTAssertNil(index[oldKey])
        XCTAssertEqual(index["path:/new.flac"]?.path, "/New.flac")
        XCTAssertEqual(index["path:/new.flac"]?.displayName, "New.flac")
        XCTAssertEqual(index["path:/new.flac"]?.songIDs, [original.id])
        XCTAssertEqual(library.storedSong(id: original.id)?.lyricsFileName, "/New.lrc")
    }

    @MainActor
    func testPausedPlaybackAndRepeatedQueueEntriesKeepNewLocation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "rename-playback-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AudioPlayerService(playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Renaming a paused song must not start playback") })
        var original = RenameFixture().song
        original.duration = 180
        player.queueEntries = [QueueEntry(song: original), QueueEntry(song: original)]
        let entryIDs = player.queueEntries.map(\.id)
        player.currentSong = original
        player.currentTime = 42
        let finish = try player.prepareForSourceFileRename(original)
        var updated = original
        updated.filePath = "/new.flac"
        updated.lyricsFileName = "/new.lrc"
        finish(updated)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.currentTime, 42)
        XCTAssertEqual(player.currentSong?.filePath, updated.filePath)
        XCTAssertEqual(player.queueEntries.map(\.id), entryIDs)
        XCTAssertTrue(player.queueEntries.allSatisfy { $0.song.filePath == updated.filePath })
    }

    #if os(iOS)
    @MainActor
    func testArtistAllAlbumsGridScrollsVertically() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "rename-grid-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = MusicLibrary(storageDirectory: root, deferredMaintenanceAllowed: { false }, searchIndexDefaults: defaults)
        let player = AudioPlayerService(library: library, playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: root.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Browsing albums must not start playback") })
        let albums = (1...20).map { Album(id: "album-\($0)", title: "Album \($0)", artistName: "Artist") }
        let view = NavigationStack { ArtistAlbumsView(title: "artist_releases", albums: albums) }
            .environment(library).environment(player)
            .environment(SourceManager(sourcesProvider: { [] }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(700))
        func scrollViews(_ view: UIView) -> [UIScrollView] {
            (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scroll = try XCTUnwrap(scrollViews(host.view).first { $0.contentSize.height > $0.bounds.height })
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "artist-all-albums-grid"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    func testLocalExclusiveMoveDoesNotOverwriteLateDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2]).write(to: directory.appendingPathComponent("old.mp3"))
        let connector = LocalFileSource(sourceID: UUID().uuidString, basePath: directory)
        let state = try await connector.renameFileState(at: "/old.mp3")
        try Data([3, 4]).write(to: directory.appendingPathComponent("new.mp3"))
        do {
            try await connector.moveFileWithoutReplacing(from: "/old.mp3", to: "/new.mp3", expected: state)
            XCTFail("Must not overwrite a file created after preflight")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("old.mp3")), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("new.mp3")), Data([3, 4]))
    }

    func testLocalRenameRefusesSymbolicLinkWithoutMovingItsTarget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1, 2]).write(to: root.appendingPathComponent("target.mp3"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.mp3"), withDestinationURL: root.appendingPathComponent("target.mp3"))
        let connector = LocalFileSource(sourceID: UUID().uuidString, basePath: root)
        let canRename = await connector.canRenameFile(at: "/link.mp3")
        XCTAssertFalse(canRename)
        do {
            _ = try await connector.renameFileState(at: "/link.mp3")
            XCTFail("A rename must not follow the final symbolic link")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("target.mp3")), Data([1, 2]))
    }

    func testFailureRollsBackCompanions() async throws {
        let connector = RenameFixture(failure: .beforeAudio)
        do {
            _ = try await connector.renameSongFile(connector.song, stem: "new")
            XCTFail("Expected move rejection")
        } catch { }
        let paths = await connector.paths
        XCTAssertEqual(paths, Set(["/old.flac", "/old.lrc"]))
    }

    func testLostMoveReplyIsReconciledAndRolledBack() async throws {
        let connector = RenameFixture(failure: .lostReply)
        do {
            _ = try await connector.renameSongFile(connector.song, stem: "new")
            XCTFail("Expected lost reply")
        } catch { }
        let paths = await connector.paths
        XCTAssertEqual(paths, Set(["/old.flac", "/old.lrc"]))
    }

    func testLostRollbackReplyDoesNotPublishUnconfirmedNewPath() async throws {
        let connector = RenameFixture(failure: .lostRollbackReply)
        do {
            _ = try await connector.renameSongFile(connector.song, stem: "new")
            XCTFail("Expected the original move rejection")
        } catch SongFileRenameError.partial {
            XCTFail("A confirmed rollback must keep the original paths")
        } catch { }
        let paths = await connector.paths
        XCTAssertEqual(paths, Set(["/old.flac", "/old.lrc"]))
    }

    func testFailedRollbackReturnsConfirmedCompanionLocation() async throws {
        let connector = RenameFixture(failure: .rollback)
        do {
            _ = try await connector.renameSongFile(connector.song, stem: "new")
            XCTFail("Expected partial failure")
        } catch SongFileRenameError.partial(let result, _) {
            XCTAssertEqual(result.song.filePath, "/old.flac")
            XCTAssertEqual(result.song.lyricsFileName, "/new.lrc")
            XCTAssertEqual(result.song.id, connector.song.id)
        }
    }

    func testStaleSongDoesNotMutateFiles() async throws {
        let connector = RenameFixture()
        var stale = connector.song
        stale.revision = "stale"
        do {
            _ = try await connector.renameSongFile(stale, stem: "new")
            XCTFail("Expected conflict")
        } catch { }
        let count = await connector.moveCount
        XCTAssertEqual(count, 0)
    }

    func testUnavailableReadbackKeepsCommittedLocation() async throws {
        let connector = RenameFixture(failure: .readback)
        let result = try await connector.renameSongFile(connector.song, stem: "new")
        XCTAssertEqual(result.song.filePath, "/new.flac")
        XCTAssertNotNil(result.notice)
        let paths = await connector.paths
        XCTAssertEqual(paths, Set(["/new.flac", "/new.lrc"]))
    }

    @MainActor
    func testLibraryReplacementKeepsPlaylistAndLikedState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MusicLibrary(storageDirectory: directory, deferredMaintenanceAllowed: { false })
        await library.whenReady()
        let connector = RenameFixture()
        library.addSongs([connector.song])
        await library.waitForPendingIndex()
        library.toggleLiked(songID: connector.song.id)
        let playlist = library.createPlaylist(name: "Keep membership")
        library.add(songIDs: [connector.song.id], toPlaylist: playlist.id)
        let result = try await connector.renameSongFile(connector.song, stem: "new")
        library.replaceSong(result.song)
        XCTAssertTrue(library.isLiked(songID: connector.song.id))
        XCTAssertEqual(library.songs(forPlaylist: playlist.id).map(\.id), [connector.song.id])
        XCTAssertEqual(library.storedSong(id: connector.song.id)?.filePath, "/new.flac")
    }
}

private final class RenameDAVProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests: [String: URLRequest] = [:]
    static func takeRequest(_ id: String) -> URLRequest? { lock.withLock { requests.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let id = url.path.split(separator: "/").first else { return }
        Self.lock.withLock { Self.requests[String(id)] = request }
        let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor RenameFixture: PathFileRenameConnector {
    enum Failure: Sendable { case beforeAudio, lostReply, lostRollbackReply, rollback, readback }
    nonisolated let sourceID = "rename-fixture"
    nonisolated let supportsSidecarWriting = true
    nonisolated var song: Song {
        var song = Song(id: "stable-id", title: "Title", fileFormat: .flac,
            filePath: "/old.flac", sourceID: sourceID, fileSize: 8, lyricsFileName: "/old.lrc")
        song.revision = "audio"
        return song
    }
    let failure: Failure?
    var files: [String: String] = ["/old.flac": "audio", "/old.lrc": "lyrics"]
    private(set) var moveCount = 0
    var paths: Set<String> { Set(files.keys) }
    init(failure: Failure? = nil) { self.failure = failure }
    func restoreOldName() { files["/old.flac"] = "another-audio" }
    func connect() async throws {}
    func disconnect() async {}
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        files.map { .init(name: ($0.key as NSString).lastPathComponent, path: $0.key,
            isDirectory: false, size: 8, modifiedDate: Date(timeIntervalSince1970: 100), revision: $0.value) }
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        if failure == .readback && path == "/new.flac" { throw URLError(.networkConnectionLost) }
        guard let revision = files[path] else { throw SourceError.fileNotFound(path) }
        return .init(fileSize: 8, modifiedDate: Date(timeIntervalSince1970: 100), revision: revision)
    }
    func replaceMetadataFile(at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState) async throws {
        throw SongFileRenameError.unsupported
    }
    func moveFileWithoutReplacing(from: String, to: String, expected: EmbeddedMetadataRemoteFileState) async throws {
        moveCount += 1
        if from == "/old.flac", failure == .beforeAudio || failure == .rollback || failure == .lostRollbackReply { throw POSIXError(.EACCES) }
        if from == "/new.lrc", failure == .rollback { throw POSIXError(.EACCES) }
        guard files[to] == nil else { throw POSIXError(.EEXIST) }
        guard files[from] == expected.revision else { throw EmbeddedMetadataWritebackSourceError.conflict }
        files[to] = files.removeValue(forKey: from)
        if from == "/old.flac", failure == .lostReply { throw URLError(.networkConnectionLost) }
        if from == "/new.lrc", failure == .lostRollbackReply { throw URLError(.networkConnectionLost) }
    }
}

private final class RenameTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}
