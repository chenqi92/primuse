import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class LocalReferenceFileChangeTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

    private func write(_ title: String, to file: URL, artist: String? = nil, atomically: Bool = false) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        func frame(_ key: String, _ value: String) -> Data {
            let text = Data([0]) + Data(value.utf8)
            return Data(key.utf8) + Data([0, 0, 0, UInt8(text.count), 0, 0]) + text
        }
        var tags = frame("TIT2", title)
        if let artist { tags.append(frame("TPE1", artist)) }
        tags.append(Data(repeating: 0, count: 100 - tags.count))
        var bytes = Data([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 100]) + tags
        let audio = Data([0xFF, 0xFB, 0x90, 0x64]) + Data(repeating: 0, count: 413)
        for _ in 0..<100 { bytes.append(audio) }
        try bytes.write(to: file, options: atomically ? .atomic : [])
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    }

    private func scanned(_ local: LocalFileSource, existing: [Song] = []) async throws -> [Song] {
        var songs: [Song] = []
        for try await row in try await local.scanSongs(from: "/", existingSongs: existing) { songs.append(row.song) }
        return songs
    }

    func testIndependentCopiesConvergeOnlyAfterEachFileChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceID = UUID().uuidString
        let mac = LocalFileSource(sourceID: sourceID, basePath: root.appendingPathComponent("Mac"))
        let phone = LocalFileSource(sourceID: sourceID, basePath: root.appendingPathComponent("Phone"))
        let a = root.appendingPathComponent("Mac/Album/Track.mp3")
        let b = root.appendingPathComponent("Phone/Album/Track.mp3")
        try write("Amber", to: a)
        try write("Amber", to: b)
        let firstMac = try await scanned(mac)
        let firstPhone = try await scanned(phone)
        let macRead = try await mac.refreshedLocalSong(XCTUnwrap(firstMac.first), notified: true)
        let phoneRead = try await phone.refreshedLocalSong(XCTUnwrap(firstPhone.first), notified: true)
        let original = try XCTUnwrap(macRead)
        let other = try XCTUnwrap(phoneRead)
        XCTAssertEqual(original.title, "Amber")
        XCTAssertEqual(original.id, other.id)
        try write("Cedar", to: a)
        let afterScan = try await scanned(mac, existing: [original])
        let updated = try XCTUnwrap(afterScan.first)
        XCTAssertEqual(updated.title, "Cedar")
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.dateAdded, original.dateAdded)
        XCTAssertEqual(updated.fileSize, original.fileSize)
        XCTAssertEqual(updated.lastModified, original.lastModified)
        XCTAssertNotEqual(updated.revision, original.revision)
        let unchanged = try await phone.refreshedLocalSong(other, notified: false)
        XCTAssertNil(unchanged)
        let unchangedScan = try await scanned(phone, existing: [other])
        XCTAssertEqual(unchangedScan.first?.title, "Amber")
        try write("Cedar", to: b, atomically: true)
        let delivered = try await phone.refreshedLocalSong(other, notified: false)
        XCTAssertEqual(delivered?.title, "Cedar")
        XCTAssertNil(delivered?.userMetadataEditedAt)
        var edited = other
        edited.title = "My title"
        edited.userMetadataEditedAt = Date()
        let protected = try await phone.refreshedLocalSong(edited, notified: true)
        XCTAssertEqual(protected?.title, edited.title)
        XCTAssertEqual(protected?.userMetadataEditedAt, edited.userMetadataEditedAt)
        let source = MusicSource(id: sourceID, name: "Local", type: .local)
        XCTAssertFalse(PeerScanSeedStore.isEligible(source))
        XCTAssertTrue(MusicSourceCloudSyncPolicy.eligibleSongs([updated], sources: [source]).isEmpty)
    }

    func testCoordinatedFolderEditRefreshesOnlyTheReportedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Music", isDirectory: true)
        let file = directory.appendingPathComponent("Album/Track.mp3")
        let sibling = directory.appendingPathComponent("Other/Track.mp3")
        try write("Amber", to: file)
        try write("Amber", to: sibling)
        let source = MusicSource(id: UUID().uuidString, name: "Folder", type: .local, basePath: directory.path)
        #if os(iOS)
        // A mobile picker returns a minimal bookmark. On Mac the fixture is
        // already accessible under the test host's temporary directory.
        let bookmark = try directory.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: "primuse.localBookmark." + source.id)
        defer { LocalBookmarkStore.remove(sourceID: source.id) }
        #endif
        let local = LocalFileSource(sourceID: source.id, basePath: directory)
        let manager = SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in local })
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("Library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("Sources"))
        store.add(source)
        var expectsFolderDiscovery = false
        let scan = ScanService(fileManager: LocalRefreshTestFileManager(root: root), connectorProvider: { _ in
            XCTAssertTrue(expectsFolderDiscovery, "A known file edit should not launch directory discovery")
            return local
        }, diagnosticProvider: { source, _ in SourceDiagnosticReport(source: source, startedAt: Date(), checks: []) })
        scan.automaticScansAllowed = { true }
        let initial = try await scanned(local)
        for song in initial {
            let read = try await local.refreshedLocalSong(song, notified: true)
            library.addSongs([try XCTUnwrap(read)], pruneMissingSongs: false)
        }
        let target = try XCTUnwrap(library.songs.first { $0.filePath == "/Album/Track.mp3" })
        let untouched = try XCTUnwrap(library.songs.first { $0.filePath == "/Other/Track.mp3" })
        var enabled = true
        let service = LocalReferenceRefreshService(sourcesStore: store, sourceManager: manager, library: library,
            scanService: scan, scraperService: MusicScraperService(sourceManager: manager, checkpointDirectory: root),
            automaticRefreshEnabled: { _ in enabled }, automaticWorkAllowed: { true })
        service.start()
        defer { service.stop() }
        func hasPresenter() -> Bool {
            NSFileCoordinator.filePresenters.contains { $0.presentedItemURL?.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path }
        }
        for _ in 0..<100 where !hasPresenter() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(hasPresenter())
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: &coordinationError) { url in
            do { try write("Cedar", to: url) } catch { writeError = error }
        }
        XCTAssertNil(coordinationError)
        XCTAssertNil(writeError)
        for _ in 0..<160 where library.storedSong(id: target.id)?.title != "Cedar" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.storedSong(id: target.id)?.title, "Cedar")
        XCTAssertEqual(library.storedSong(id: untouched.id)?.title, "Amber")
        #if os(macOS)
        // Command-line editors can modify the physical file without coordinating a write.
        try write("Maple", to: file)
        for _ in 0..<160 where library.storedSong(id: target.id)?.title != "Maple" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.storedSong(id: target.id)?.title, "Maple")
        XCTAssertEqual(library.storedSong(id: untouched.id)?.title, "Amber")
        #endif
        service.stop()
        try write("Birch", to: file, atomically: true)
        service.start()
        service.verifyWhenVisible(target)
        service.verifyWhenVisible(untouched)
        for _ in 0..<160 where library.storedSong(id: target.id)?.title != "Birch" {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(library.storedSong(id: target.id)?.title, "Birch")
        XCTAssertEqual(library.storedSong(id: untouched.id)?.title, "Amber")
        expectsFolderDiscovery = true
        let destination = sibling.deletingLastPathComponent().appendingPathComponent("Moved.mp3")
        let mover = NSFileCoordinator()
        mover.coordinate(writingItemAt: file, options: .forMoving, writingItemAt: destination, options: [],
                         error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                mover.item(at: from, didMoveTo: to)
            } catch { writeError = error }
        }
        XCTAssertNil(coordinationError)
        XCTAssertNil(writeError)
        func moveWasIndexed() -> Bool {
            !library.songs.contains { $0.filePath == "/Album/Track.mp3" }
                && library.songs.contains { $0.filePath == "/Other/Moved.mp3" }
        }
        for _ in 0..<200 where !moveWasIndexed() { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(moveWasIndexed())
        XCTAssertEqual(library.storedSong(id: untouched.id)?.title, "Amber")
        enabled = false
        service.refreshPreferences()
        XCTAssertFalse(hasPresenter())
        try await library.persistNowAndWait().get()
    }

    func testLegacyBaselineAndExplicitNotificationWhenProviderPreservesAllStamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Track.mp3")
        let local = LocalFileSource(sourceID: UUID().uuidString, basePath: root)
        try write("Amber", to: file, artist: "River Room")
        let initial = try await scanned(local)
        let read = try await local.refreshedLocalSong(XCTUnwrap(initial.first), notified: true)
        var legacy = try XCTUnwrap(read)
        legacy.revision = legacy.revision?.components(separatedBy: "|").first
        XCTAssertEqual(legacy.artistName, "River Room")
        let originalState = try await local.metadataWritebackState(for: legacy.filePath)
        XCTAssertTrue(originalState.matchesScannedSong(legacy))
        let remoteState = EmbeddedMetadataRemoteFileState(fileSize: originalState.fileSize, modifiedDate: originalState.modifiedDate,
                                                         revision: originalState.revision)
        XCTAssertFalse(remoteState.matchesScannedSong(legacy))
        try write("Cedar", to: file)
        let updatedState = try await local.metadataWritebackState(for: legacy.filePath)
        XCTAssertFalse(updatedState.matchesScannedSong(legacy))
        var unversioned = legacy
        unversioned.revision = nil
        let rescanned = try await scanned(local, existing: [unversioned])
        XCTAssertEqual(rescanned.first?.title, "Cedar")
        legacy.revision = updatedState.revision
        let skipped = try await local.refreshedLocalSong(legacy, notified: false)
        XCTAssertNil(skipped)
        let notified = try await local.refreshedLocalSong(legacy, notified: true)
        XCTAssertEqual(notified?.title, "Cedar")
        XCTAssertNil(notified?.artistName)
    }

    func testReferencePathsRespectIndividualFilesAndNamedRoots() {
        let root = URL(fileURLWithPath: "/media/Album", isDirectory: true)
        let reference = LocalBookmarkStore.ResolvedReference(virtualPathComponent: "Album (2)", url: root, isDirectory: true)
        XCTAssertEqual(reference.sourcePath(for: root.appendingPathComponent("Disc/Track.mp3")), "/Album (2)/Disc/Track.mp3")
        XCTAssertNil(reference.sourcePath(for: URL(fileURLWithPath: "/media/Album2/Track.mp3")))
        let file = root.appendingPathComponent("Track.mp3")
        let single = LocalBookmarkStore.ResolvedReference(virtualPathComponent: "Track (2).mp3", url: file, isDirectory: false)
        XCTAssertEqual(single.sourcePath(for: file), "/Track (2).mp3")
        XCTAssertNil(single.sourcePath(for: root.appendingPathComponent("Other.mp3")))
    }

    #if os(macOS)
    func testFileEventsReportOnlyTheIndividuallySelectedFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Track.mp3")
        let other = root.appendingPathComponent("Other.mp3")
        try write("Amber", to: selected)
        try write("Amber", to: other)
        let changed = expectation(description: "Selected file changed")
        changed.assertForOverFulfill = false
        let reference = LocalBookmarkStore.ResolvedReference(virtualPathComponent: "Track (2).mp3", url: selected, isDirectory: false)
        let stream = try XCTUnwrap(MacLocalReferenceEvents(references: [reference]) { events in
            for event in events {
                switch event {
                case .item("/Track (2).mp3"), .removed("/Track (2).mp3"): changed.fulfill()
                default: XCTFail("Unselected path was reported")
                }
            }
        })
        try write("Cedar", to: other)
        try write("Cedar", to: selected)
        await fulfillment(of: [changed], timeout: 8)
        withExtendedLifetime(stream) {}
    }
    #endif
}

private final class LocalRefreshTestFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}
