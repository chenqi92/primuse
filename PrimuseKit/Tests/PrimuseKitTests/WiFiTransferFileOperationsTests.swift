import Foundation
import Testing
@testable import PrimuseKit

@Suite("Wi-Fi transfer off-main filesystem primitives")
struct WiFiTransferFileOperationsTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Creating a staging folder is complete when the call returns")
    func createDirectoryIsVisibleAfterAwait() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("album/disc 1")
        try await WiFiTransferFilePreparation.createDirectory(at: nested)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: nested.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test("Removing a populated tree leaves nothing behind for the enumeration that follows")
    func removeItemCompletesBeforeEnumeration() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("song")
        try await WiFiTransferFilePreparation.createDirectory(at: folder)
        for index in 0..<8 {
            try await WiFiTransferFilePreparation.write(Data("chunk\(index)".utf8), to: folder.appendingPathComponent("f\(index).bin"))
        }
        try await WiFiTransferFilePreparation.removeItem(at: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(remaining.isEmpty)
    }

    @Test("A moved file is readable at the destination and gone from the source")
    func moveItemIsComplete() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("staged.tmp")
        let destination = root.appendingPathComponent("Song.flac")
        try await WiFiTransferFilePreparation.write(Data("audio".utf8), to: source)
        try await WiFiTransferFilePreparation.moveItem(at: source, to: destination)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let moved = try Data(contentsOf: destination)
        #expect(moved == Data("audio".utf8))
    }

    @Test("The async space check keeps the synchronous rule")
    func checkSpaceAsyncMatchesSynchronousRule() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try await WiFiTransferFilePreparation.checkSpaceAsync(at: root, additionalBytes: 0)
        await #expect(throws: WiFiTransferError.self) {
            try await WiFiTransferFilePreparation.checkSpaceAsync(at: root, additionalBytes: Int64.max / 2)
        }
    }

    @Test("A cancelled caller fails fast instead of extending the staging tree")
    func cancelledCallerStopsStaging() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("late")
        // No sleep and no race: the wrapper checks cancellation before it
        // spawns its worker, so an already-cancelled caller can never reach
        // the filesystem.
        let task = Task { try await WiFiTransferFilePreparation.createDirectory(at: folder) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test("Cleanup still runs for a cancelled caller — the tree is enumerated afterwards")
    func cancelledCallerStillCleansUp() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("half-written")
        try await WiFiTransferFilePreparation.createDirectory(at: folder)
        try await WiFiTransferFilePreparation.write(Data("partial".utf8), to: folder.appendingPathComponent("a.bin"))
        let task = Task {
            try? await Task.sleep(for: .milliseconds(50))
            try await WiFiTransferFilePreparation.removeItem(at: folder)
        }
        task.cancel()
        try await task.value
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
