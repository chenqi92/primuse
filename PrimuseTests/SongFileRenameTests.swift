import Foundation
import PrimuseKit
import XCTest
import SwiftUI
#if os(iOS)
import UIKit
#endif
@testable import Primuse

final class SongFileRenameTests: XCTestCase {
    func testLocalCueRescanKeepsImageMembershipOrderAndInvalidatesChangedSheets() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CueRescan-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func sheet(_ image: Int, title: String) -> String {
            """
            TITLE "Collection \(image)"
            PERFORMER "Fixture Artist"
            FILE "image-\(image).flac" WAVE
              TRACK 01 AUDIO
                TITLE "\(title)"
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                TITLE "Second \(image)"
                INDEX 01 00:01:00
            """
        }
        for image in 0..<3 {
            try Data(repeating: 0, count: 2_048).write(to: directory.appendingPathComponent("image-\(image).flac"))
            try Data(sheet(image, title: "First \(image)").utf8)
                .write(to: directory.appendingPathComponent("image-\(image).cue"))
        }
        let connector = LocalFileSource(sourceID: UUID().uuidString, basePath: directory)
        var initial: [Song] = []
        for try await row in try await connector.scanSongs(from: "/") { initial.append(row.song) }
        XCTAssertEqual(initial.count, 6)
        XCTAssertTrue(initial.allSatisfy(\.isCueTrack))
        let sourceID = try XCTUnwrap(initial.first?.sourceID)
        var existing = Array(initial.reversed())
        for index in existing.indices { existing[index].title = "Edited \(index)" }
        // A whole-file row at the same path must not become a virtual track.
        existing.append(Song(id: "physical", title: "Whole image", fileFormat: .flac,
                             filePath: "/image-0.flac", sourceID: sourceID))
        var rescanned: [Song] = []
        for try await row in try await connector.scanSongs(from: "/", existingSongs: existing) {
            rescanned.append(row.song)
        }
        for image in 0..<3 {
            let path = "/image-\(image).flac"
            let expected = existing.filter { $0.filePath == path && $0.isCueTrack }
            let actual = rescanned.filter { $0.filePath == path }
            XCTAssertEqual(actual.map(\.id), expected.map(\.id))
            XCTAssertEqual(actual.map(\.title), expected.map(\.title))
        }
        try Data(sheet(1, title: "Changed first track").utf8)
            .write(to: directory.appendingPathComponent("image-1.cue"))
        var updated: [Song] = []
        for try await row in try await connector.scanSongs(from: "/", existingSongs: existing) {
            updated.append(row.song)
        }
        XCTAssertEqual(updated.count, 6)
        XCTAssertTrue(updated.contains { $0.filePath == "/image-1.flac" && $0.title == "Changed first track" })
        XCTAssertTrue(updated.filter { $0.filePath != "/image-1.flac" }.allSatisfy { $0.title.hasPrefix("Edited ") })
        await connector.disconnect()
    }

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

    /// 群晖这类前面隔着反向代理的 WebDAV 不认 MOVE 上的 `If` 目标条件，每次都回 412。
    /// 目标仍是编辑前那一份时去掉条件再覆盖一次。
    func testWebDAVReplaceRetriesUnconditionallyWhenServerRejectsIfOnUnchangedDestination() async throws {
        let id = UUID().uuidString
        ConditionalMoveDAVProtocol.prepare(id, etag: "\"v1\"", moveStatuses: [412, 204])
        let source = Self.conditionalMoveSource(id)
        let edited = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(id).flac")
        try Data(repeating: 7, count: 16).write(to: edited)
        defer { try? FileManager.default.removeItem(at: edited) }
        let expected = EmbeddedMetadataRemoteFileState(fileSize: 8, modifiedDate: nil, revision: "\"v1\"")

        try await source.replaceMetadataFile(at: "/\(id)/song.flac", with: edited, expected: expected)

        let moves = ConditionalMoveDAVProtocol.requests(id).filter { $0.httpMethod == "MOVE" }
        XCTAssertEqual(moves.count, 2)
        XCTAssertNotNil(moves.first?.value(forHTTPHeaderField: "If"))
        XCTAssertNil(moves.last?.value(forHTTPHeaderField: "If"))
        XCTAssertEqual(moves.last?.value(forHTTPHeaderField: "Overwrite"), "T")
        await source.disconnect()
    }

    func testWebDAVReplaceStillConflictsWhenDestinationChangedBehindTheRejectedMove() async throws {
        let id = UUID().uuidString
        ConditionalMoveDAVProtocol.prepare(id, etag: "\"v2\"", moveStatuses: [412, 204])
        let source = Self.conditionalMoveSource(id)
        let edited = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(id).flac")
        try Data(repeating: 7, count: 16).write(to: edited)
        defer { try? FileManager.default.removeItem(at: edited) }
        let expected = EmbeddedMetadataRemoteFileState(fileSize: 8, modifiedDate: nil, revision: "\"v1\"")

        do {
            try await source.replaceMetadataFile(at: "/\(id)/song.flac", with: edited, expected: expected)
            XCTFail("A changed destination must not be overwritten")
        } catch EmbeddedMetadataWritebackSourceError.conflict {}

        let methods = ConditionalMoveDAVProtocol.requests(id).compactMap(\.httpMethod)
        XCTAssertEqual(methods.filter { $0 == "MOVE" }.count, 1)
        XCTAssertTrue(methods.contains("DELETE"), "The uploaded temporary file is cleaned up")
        await source.disconnect()
    }

    private static func conditionalMoveSource(_ id: String) -> WebDAVSource {
        WebDAVSource(
            sourceID: id, host: "conditional-move.invalid", useSsl: true,
            username: "", password: "",
            sessionConfiguration: {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ConditionalMoveDAVProtocol.self]
                return configuration
            }
        )
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
    func testArtistAlbumsGridUsesTheArtistPageScrollView() async throws {
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
        let view = NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    Text("Artist")
                    ArtistAlbumsGrid(albums: albums)
                }
                .padding(.horizontal, 20)
            }
        }
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
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
        }
        let pageScrollViews = scrollViews(host.view)
        XCTAssertEqual(pageScrollViews.count, 1, "Expanded albums must share the artist page's scroll view")
        let scroll = try XCTUnwrap(pageScrollViews.first { $0.contentSize.height > $0.bounds.height })
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

/// 带条件的 MOVE 先按给定的状态码答，PROPFIND 报出固定的强 ETag。按路径第一段区分用例。
private final class ConditionalMoveDAVProtocol: URLProtocol, @unchecked Sendable {
    private struct State {
        var etag: String
        var moveStatuses: [Int]
        var requests: [URLRequest] = []
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: State] = [:]

    static func prepare(_ id: String, etag: String, moveStatuses: [Int]) {
        lock.withLock { states[id] = State(etag: etag, moveStatuses: moveStatuses) }
    }

    static func requests(_ id: String) -> [URLRequest] {
        lock.withLock { states[id]?.requests ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let id = url.path.split(separator: "/").first.map(String.init) else { return }
        var status = 201
        var body = Data()
        var headers = ["Content-Length": "0"]
        Self.lock.withLock {
            guard var state = Self.states[id] else { return }
            state.requests.append(request)
            switch request.httpMethod {
            case "PROPFIND":
                status = 207
                body = Data("""
                <?xml version="1.0" encoding="utf-8"?>
                <D:multistatus xmlns:D="DAV:"><D:response><D:href>\(url.path)</D:href><D:propstat><D:prop>
                <D:getcontentlength>8</D:getcontentlength><D:getetag>\(state.etag)</D:getetag>
                <D:resourcetype/></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>
                """.utf8)
                headers = ["Content-Type": "application/xml", "Content-Length": "\(body.count)"]
            case "MOVE":
                status = state.moveStatuses.isEmpty ? 204 : state.moveStatuses.removeFirst()
            case "DELETE":
                status = 204
            default:
                status = 201
            }
            Self.states[id] = state
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
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
