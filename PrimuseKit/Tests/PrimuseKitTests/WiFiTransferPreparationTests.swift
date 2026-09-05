import Foundation
import Network
import Testing
@testable import PrimuseKit

@Suite("Wi-Fi transfer file preparation")
struct WiFiTransferPreparationTests {
    private static let chunkSize: Int64 = 1024 * 1024

    @Test("Remote materialization requests exact chunks and preserves every byte")
    func downloadsExactChunks() async throws {
        let workspace = try makeWorkspace("exact-chunks")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("song.flac")
        let size = Self.chunkSize * 2 + 37
        let recorder = DownloadRecorder()

        try await WiFiTransferFilePreparation.download(
            to: destination,
            size: size,
            read: { offset, length in
                await recorder.read(offset: offset, length: length)
            },
            progress: { bytes in
                await recorder.recordProgress(bytes)
            }
        )

        #expect(await recorder.requests == [
            .init(offset: 0, length: Self.chunkSize),
            .init(offset: Self.chunkSize, length: Self.chunkSize),
            .init(offset: Self.chunkSize * 2, length: 37),
        ])
        #expect(await recorder.progress == [Self.chunkSize, Self.chunkSize * 2, size])
        #expect(try Data(contentsOf: destination) == generatedBytes(offset: 0, length: size))
    }

    @Test("Short reads and cancellation remove the partial destination")
    func removesPartialDownloads() async throws {
        let workspace = try makeWorkspace("partial-cleanup")
        defer { try? FileManager.default.removeItem(at: workspace) }

        let shortDestination = workspace.appendingPathComponent("short.flac")
        await #expect(throws: WiFiTransferError.invalidRequest) {
            try await WiFiTransferFilePreparation.download(
                to: shortDestination,
                size: Self.chunkSize + 1,
                read: { _, length in Data(repeating: 7, count: Int(length - 1)) },
                progress: { _ in }
            )
        }
        #expect(!FileManager.default.fileExists(atPath: shortDestination.path))

        let cancelledDestination = workspace.appendingPathComponent("cancelled.flac")
        let signal = StartSignal()
        let task = Task {
            try await WiFiTransferFilePreparation.download(
                to: cancelledDestination,
                size: Self.chunkSize + 1,
                read: { _, length in
                    await signal.markStarted()
                    try await Task.sleep(for: .seconds(30))
                    return Data(repeating: 9, count: Int(length))
                },
                progress: { _ in }
            )
        }
        await signal.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: cancelledDestination.path))
    }

    @Test("An existing destination is never overwritten")
    func preservesExistingDestination() async throws {
        let workspace = try makeWorkspace("destination-conflict")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let destination = workspace.appendingPathComponent("song.mp3")
        let existing = Data("existing-library-file".utf8)
        try existing.write(to: destination)

        await #expect(throws: WiFiTransferError.conflict) {
            try await WiFiTransferFilePreparation.download(
                to: destination,
                size: 4,
                read: { _, _ in Data([1, 2, 3, 4]) },
                progress: { _ in }
            )
        }
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test("Only an exact regular file is accepted as a complete cache")
    func requiresExactCacheSize() throws {
        let workspace = try makeWorkspace("complete-cache")
        defer { try? FileManager.default.removeItem(at: workspace) }
        let partialCache = workspace.appendingPathComponent("partial.flac")
        let completeCache = workspace.appendingPathComponent("complete.flac")

        try Data(repeating: 1, count: 95).write(to: partialCache)
        try Data(repeating: 1, count: 100).write(to: completeCache)
        #expect(!WiFiTransferFilePreparation.isCompleteCache(partialCache, expectedSize: 100))
        #expect(WiFiTransferFilePreparation.isCompleteCache(completeCache, expectedSize: 100))
        #expect(!WiFiTransferFilePreparation.isCompleteCache(completeCache, expectedSize: 0))
    }

    @Test("Library capability boundaries reject virtual and protected media")
    func enforcesLibraryCapabilityBoundaries() {
        var song = makeSong(path: "/Music/song.flac", size: 1_024)
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .smb) == nil)

        song.cueSheetPath = "/Music/album.cue"
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .smb) == "libraryCue")
        song.cueSheetPath = nil

        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .appleMusic) == "libraryProtected")

        song.filePath = "/Music/radio.strm"
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .smb) == "libraryStream")

        song.filePath = "/Music/song.flac"
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .ugreen) == "librarySourceUnavailable")
    }

    @Test("Unknown size is resolved locally but rejected for remote sources")
    func distinguishesUnknownLocalAndRemoteSizes() {
        let song = makeSong(path: "/Music/song.flac", size: 0)
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .local) == nil)
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .appleMusicLibrary) == nil)
        #expect(WiFiTransferFilePreparation.unavailableReason(song: song, sourceType: .smb) == "libraryUnknownSize")
    }

    @Test("Safe names cannot expose source paths or create path components")
    func createsSafeExportNames() {
        let title = "  ../Night/Live:\\\n" + String(repeating: "乐", count: 100)
        let song = Song(
            id: "safe-name",
            title: title,
            fileFormat: .flac,
            filePath: "/private/source/account-secret/original.FLAC",
            sourceID: "source",
            fileSize: 1
        )
        let name = WiFiTransferFilePreparation.fileName(for: song)

        #expect(name.hasSuffix(".flac"))
        #expect(!name.hasPrefix("."))
        #expect(!name.contains("/"))
        #expect(!name.contains("\\"))
        #expect(!name.contains(":"))
        #expect(!name.contains("\n"))
        #expect(!name.contains("account-secret"))
        #expect(name.deletingPathExtension.utf8.count <= 180)
    }

    @Test("Merged selections retain temporary batches and keep sidecars together")
    func retainsMergedTemporaryDirectories() async throws {
        let baseDirectory = try makeWorkspace("selection-base")
        let additionDirectory = try makeWorkspace("selection-addition")
        try Data([1]).write(to: baseDirectory.appendingPathComponent("song.flac"))
        let occupiedFolder = baseDirectory.appendingPathComponent("Incoming")
        try FileManager.default.createDirectory(at: occupiedFolder, withIntermediateDirectories: true)
        try Data([2]).write(to: occupiedFolder.appendingPathComponent("existing.mp3"))
        try Data([3]).write(to: additionDirectory.appendingPathComponent("song.flac"))
        try Data("lyrics".utf8).write(to: additionDirectory.appendingPathComponent("song.lrc"))
        try Data([4, 5]).write(to: additionDirectory.appendingPathComponent("song.jpg"))

        var base: WiFiTransferSelection? = try await .prepareTemporaryDirectory(baseDirectory)
        var addition: WiFiTransferSelection? = try await .prepareTemporaryDirectory(additionDirectory)
        let baseLease = WeakSelectionBox(base)
        let additionLease = WeakSelectionBox(addition)
        var merged: WiFiTransferSelection? = try base!.appending(addition!, conflictFolder: "Incoming")

        let expectedPaths = Set([
            "song.flac",
            "Incoming/existing.mp3",
            "Incoming (2)/song.flac",
            "Incoming (2)/song.lrc",
            "Incoming (2)/song.jpg",
        ])
        #expect(Set(merged!.files.map(\.path)) == expectedPaths)

        var deduplicated: WiFiTransferSelection? = try merged!.appending(merged!, conflictFolder: "Unused")
        #expect(Set(deduplicated!.files.map(\.path)) == expectedPaths)
        #expect(deduplicated!.files.count == expectedPaths.count)

        let sidecarIDs = Set(deduplicated!.files.filter { $0.path.hasPrefix("Incoming (2)/") }.map(\.id))
        var kept: WiFiTransferSelection? = deduplicated!.keeping(sidecarIDs)
        #expect(Set(kept!.files.map(\.path)) == Set([
            "Incoming (2)/song.flac",
            "Incoming (2)/song.lrc",
            "Incoming (2)/song.jpg",
        ]))

        base = nil
        addition = nil
        merged = nil
        deduplicated = nil
        #expect(baseLease.value != nil)
        #expect(additionLease.value != nil)
        #expect(FileManager.default.fileExists(atPath: baseDirectory.path))
        #expect(FileManager.default.fileExists(atPath: additionDirectory.path))
        #expect(kept!.files.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })

        kept = nil
        #expect(baseLease.value == nil)
        #expect(additionLease.value == nil)
        #expect(!FileManager.default.fileExists(atPath: baseDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: additionDirectory.path))
    }

    @Test("Library album groups never cross source boundaries")
    func isolatesAlbumsFromDifferentSources() {
        let first = makeSong(
            id: "first", path: "/Music/first.flac", size: 1, sourceID: "source-a",
            albumTitle: "Shared Album", artistName: "Track Artist A", albumArtistName: "Various Artists"
        )
        let second = makeSong(
            id: "second", path: "/Music/second.flac", size: 1, sourceID: "source-b",
            albumTitle: "Shared Album", artistName: "Track Artist B", albumArtistName: "Various Artists"
        )
        let firstGroup = WiFiTransferLibraryGroupID(song: first)
        let secondGroup = WiFiTransferLibraryGroupID(song: second)

        #expect(firstGroup.album == secondGroup.album)
        #expect(firstGroup != secondGroup)
    }

    @Test("Ungrouped songs stay explicit and album artist joins compilation tracks")
    func groupsByAlbumArtistAndKeepsMissingAlbumsUngrouped() {
        let ungrouped = makeSong(
            id: "ungrouped", path: "/Music/single.flac", size: 1,
            albumTitle: "  ", artistName: "Solo Artist"
        )
        let first = makeSong(
            id: "first", path: "/Music/first.flac", size: 1,
            albumTitle: "Compilation", artistName: "Track Artist A", albumArtistName: "Various Artists"
        )
        let second = makeSong(
            id: "second", path: "/Music/second.flac", size: 1,
            albumTitle: "Compilation", artistName: "Track Artist B", albumArtistName: "Various Artists"
        )

        #expect(WiFiTransferLibraryGroupID(song: ungrouped).album == nil)
        #expect(WiFiTransferLibraryGroupID(song: first) == WiFiTransferLibraryGroupID(song: second))
    }

    @Test("A partial parent selection becomes fully selected, then fully deselected")
    func togglesPartialParentSelectionAsOneGroup() throws {
        let group = ["first", "second", "third"]
        let partial: Set<String> = ["first", "outside"]

        let fullySelected = try WiFiTransferLibraryGrouping.toggling(group, in: partial)
        #expect(fullySelected == ["first", "second", "third", "outside"])

        let deselected = try WiFiTransferLibraryGrouping.toggling(group, in: fullySelected)
        #expect(deselected == ["outside"])
    }

    @Test("An over-limit group is rejected without changing the existing selection")
    func rejectsWholeGroupWithoutTruncatingSelection() {
        let original: Set<String> = ["kept"]
        let group = (0..<WiFiTransferLibraryGrouping.selectionLimit).map { "new-\($0)" }

        #expect(throws: WiFiTransferError.tooLarge) {
            try WiFiTransferLibraryGrouping.toggling(group, in: original)
        }
        #expect(original == ["kept"])
    }

    @Test("Library search matches visible metadata but not source paths")
    func matchesLibraryMetadataOnly() {
        let song = makeSong(
            path: "/private/Hidden Needle/song.flac", size: 1,
            albumTitle: "Evening Sessions", artistName: "The Ensemble"
        )

        #expect(WiFiTransferLibraryGrouping.matches(song, query: "  evening "))
        #expect(WiFiTransferLibraryGrouping.matches(song, query: "ensemble"))
        #expect(WiFiTransferLibraryGrouping.matches(song, query: "Song"))
        #expect(WiFiTransferLibraryGrouping.matches(song, query: "   "))
        #expect(!WiFiTransferLibraryGrouping.matches(song, query: "Hidden Needle"))
    }

    @Test("Discovery failures distinguish policy, authorization, network, and fallback cases")
    func classifiesDiscoveryFailures() {
        #expect(WiFiTransferDiscovery.failureKey(.dns(-65_570)) == "discoveryPermission")
        #expect(WiFiTransferDiscovery.failureKey(.dns(-65_555)) == "discoveryBonjour")
        #expect(WiFiTransferDiscovery.failureKey(.posix(.ENETUNREACH)) == "discoveryNetwork")
        #expect(WiFiTransferDiscovery.failureKey(.posix(.ECONNRESET)) == "discoveryUnavailable")
    }

    private func makeSong(
        id: String = "song",
        path: String,
        size: Int64,
        sourceID: String = "source",
        albumTitle: String? = nil,
        artistName: String? = nil,
        albumArtistName: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: "Song",
            albumTitle: albumTitle,
            artistName: artistName,
            albumArtistName: albumArtistName,
            fileFormat: .flac,
            filePath: path,
            sourceID: sourceID,
            fileSize: size
        )
    }

    private func makeWorkspace(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp/primuse-issue87-preparation-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspace = root.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        return workspace
    }
}

private struct DownloadRequest: Equatable, Sendable {
    let offset: Int64
    let length: Int64
}

private actor DownloadRecorder {
    private(set) var requests: [DownloadRequest] = []
    private(set) var progress: [Int64] = []

    func read(offset: Int64, length: Int64) -> Data {
        requests.append(.init(offset: offset, length: length))
        return generatedBytes(offset: offset, length: length)
    }

    func recordProgress(_ bytes: Int64) {
        progress.append(bytes)
    }
}

private actor StartSignal {
    private var started = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuations.append($0) }
    }
}

private final class WeakSelectionBox {
    weak var value: WiFiTransferSelection?

    init(_ value: WiFiTransferSelection?) {
        self.value = value
    }
}

private func generatedBytes(offset: Int64, length: Int64) -> Data {
    Data((0..<Int(length)).map { UInt8(truncatingIfNeeded: offset + Int64($0)) })
}

private extension String {
    var deletingPathExtension: String { (self as NSString).deletingPathExtension }
}
