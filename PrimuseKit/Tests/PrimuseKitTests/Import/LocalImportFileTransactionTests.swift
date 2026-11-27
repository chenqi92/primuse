import Foundation
import Testing
@testable import PrimuseKit

@Suite("Local import file transactions")
struct LocalImportFileTransactionTests {
    private struct InjectedCopyFailure: Error {}

    @Test("1200 files commit once with Unicode, long names, collisions and content deduplication")
    func bulkTransactionAndIdentity() throws {
        try withWorkspace { workspace in
            let sourceDirectory = workspace.appendingPathComponent("source", isDirectory: true)
            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            let databaseURL = workspace.appendingPathComponent("identity.sqlite")
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)

            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(
                    copyBufferSize: 4 * 1024,
                    maximumFileNameBytes: 180,
                    minimumFreeSpaceReserve: 0
                )
            )
            try transaction.prepareAndCleanStaging()
            let identity = try LocalImportIdentityStore(path: databaseURL.path)

            var pending: [LocalImportIdentityEntry] = []
            var committedCount = 0
            for index in 0..<1_200 {
                let source = sourceDirectory.appendingPathComponent("source-\(index).bin")
                try payload(index: index).write(to: source)
                let proposedName: String
                switch index % 5 {
                case 0: proposedName = "第\(index)首-夜曲.wav"
                case 1: proposedName = "Cafe\u{301}-🎵-\(index).wav"
                case 2: proposedName = String(repeating: "很长的名字", count: 40) + "-\(index).wav"
                default: proposedName = "同名歌曲.wav"
                }

                let staged = try transaction.stageCopy(
                    from: source,
                    originalFileName: proposedName
                )
                #expect(try identity.entry(forSHA256: staged.sha256) == nil)
                let committed = try transaction.commit(staged, suggestedFileName: proposedName)
                #expect(committed.url.lastPathComponent.utf8.count <= 180)
                pending.append(identityEntry(for: committed, in: destination))
                committedCount += 1
                if pending.count == 32 {
                    try identity.recordBatch(pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            try identity.recordBatch(pending)

            #expect(committedCount == 1_200)
            #expect(try identity.count() == 1_200)
            #expect(try transaction.ownedStagingFileCount() == 0)
            #expect(try visibleFiles(in: destination).count == 1_200)

            let duplicateSource = sourceDirectory.appendingPathComponent("duplicate.bin")
            try payload(index: 777).write(to: duplicateSource)
            let stagedDuplicate = try transaction.stageCopy(
                from: duplicateSource,
                originalFileName: "完全不同的文件名.wav"
            )
            #expect(try identity.entry(forSHA256: stagedDuplicate.sha256) != nil)
            transaction.discard(stagedDuplicate)
            #expect(try visibleFiles(in: destination).count == 1_200)
        }
    }

    @Test("Injected copy failure and cancellation leave no importable partial file")
    func failureAndCancellationCleanup() throws {
        try withWorkspace { workspace in
            let source = workspace.appendingPathComponent("large-source.bin")
            try Data(repeating: 0x5A, count: 64 * 1024).write(to: source)
            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(copyBufferSize: 4 * 1024, minimumFreeSpaceReserve: 0)
            )
            try transaction.prepareAndCleanStaging()

            #expect(throws: InjectedCopyFailure.self) {
                _ = try transaction.stageCopy(
                    from: source,
                    originalFileName: "failure-at-250.wav"
                ) { copied in
                    if copied >= 16 * 1024 { throw InjectedCopyFailure() }
                }
            }

            #expect(try transaction.ownedStagingFileCount() == 0)
            #expect(try visibleFiles(in: destination).isEmpty)
        }
    }

    @Test("Cancellation near item 250 retries to completion without duplicates")
    func cancellationAt250AndRetry() throws {
        try withWorkspace { workspace in
            let sourceDirectory = workspace.appendingPathComponent("source", isDirectory: true)
            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(copyBufferSize: 4 * 1024, minimumFreeSpaceReserve: 0)
            )
            try transaction.prepareAndCleanStaging()
            let identity = try LocalImportIdentityStore(
                path: workspace.appendingPathComponent("identity.sqlite").path
            )

            for index in 0..<300 {
                try payload(index: index, count: 8 * 1024).write(
                    to: sourceDirectory.appendingPathComponent("source-\(index).bin")
                )
            }

            for index in 0..<300 {
                let source = sourceDirectory.appendingPathComponent("source-\(index).bin")
                if index == 249 {
                    #expect(throws: InjectedCopyFailure.self) {
                        _ = try transaction.stageCopy(
                            from: source,
                            originalFileName: "track-\(index).wav"
                        ) { _ in throw InjectedCopyFailure() }
                    }
                    break
                }
                let staged = try transaction.stageCopy(
                    from: source,
                    originalFileName: "track-\(index).wav"
                )
                let committed = try transaction.commit(
                    staged,
                    suggestedFileName: "track-\(index).wav"
                )
                try identity.recordBatch([identityEntry(for: committed, in: destination)])
            }

            #expect(try visibleFiles(in: destination).count == 249)
            #expect(try identity.count() == 249)
            #expect(try transaction.ownedStagingFileCount() == 0)

            var duplicateCount = 0
            var retryImportedCount = 0
            for index in 0..<300 {
                let source = sourceDirectory.appendingPathComponent("source-\(index).bin")
                let staged = try transaction.stageCopy(
                    from: source,
                    originalFileName: "track-\(index).wav"
                )
                if try identity.entry(forSHA256: staged.sha256) != nil {
                    duplicateCount += 1
                    transaction.discard(staged)
                    continue
                }
                let committed = try transaction.commit(
                    staged,
                    suggestedFileName: "track-\(index).wav"
                )
                try identity.recordBatch([identityEntry(for: committed, in: destination)])
                retryImportedCount += 1
            }

            #expect(duplicateCount == 249)
            #expect(retryImportedCount == 51)
            #expect(try identity.count() == 300)
            #expect(try visibleFiles(in: destination).count == 300)
            #expect(try transaction.ownedStagingFileCount() == 0)
        }
    }

    @Test("Cold-start cleanup removes only marked Primuse staging files")
    func ownedCleanupBoundary() throws {
        try withWorkspace { workspace in
            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(minimumFreeSpaceReserve: 0)
            )
            try FileManager.default.createDirectory(
                at: transaction.stagingDirectory,
                withIntermediateDirectories: true
            )
            let foreignFile = transaction.stagingDirectory.appendingPathComponent("foreign.partial.wav")
            try Data("keep".utf8).write(to: foreignFile)

            #expect(throws: LocalImportFileTransaction.TransactionError.stagingOwnershipMissing) {
                try transaction.prepareAndCleanStaging()
            }
            #expect(FileManager.default.fileExists(atPath: foreignFile.path))
        }
    }

    @Test("Identity batches are atomic when a uniqueness constraint fails")
    func identityBatchRollback() throws {
        try withWorkspace { workspace in
            let store = try LocalImportIdentityStore(
                path: workspace.appendingPathComponent("identity.sqlite").path
            )
            let first = LocalImportIdentityEntry(
                sha256: String(repeating: "a", count: 64),
                relativePath: "first.wav",
                byteCount: 10,
                modificationDate: nil
            )
            try store.recordBatch([first])

            let valid = LocalImportIdentityEntry(
                sha256: String(repeating: "b", count: 64),
                relativePath: "second.wav",
                byteCount: 20,
                modificationDate: nil
            )
            let conflicting = LocalImportIdentityEntry(
                sha256: String(repeating: "c", count: 64),
                relativePath: "first.wav",
                byteCount: 30,
                modificationDate: nil
            )
            #expect(throws: (any Error).self) {
                try store.recordBatch([valid, conflicting])
            }
            #expect(try store.count() == 1)
            #expect(try store.entry(forSHA256: valid.sha256) == nil)
            #expect(try store.entry(forSHA256: first.sha256) == first)
        }
    }

    @Test("Fixed copy buffer handles a large file without retaining whole-file data")
    func boundedCopyBuffer() throws {
        try withWorkspace { workspace in
            let source = workspace.appendingPathComponent("bounded.bin")
            let handle = try FileHandle(forWritingTo: {
                FileManager.default.createFile(atPath: source.path, contents: nil)
                return source
            }())
            for index in 0..<256 {
                try handle.write(contentsOf: payload(index: index, count: 32 * 1024))
            }
            try handle.close()

            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(copyBufferSize: 8 * 1024, minimumFreeSpaceReserve: 0)
            )
            try transaction.prepareAndCleanStaging()
            var callbackCount = 0
            let staged = try transaction.stageCopy(
                from: source,
                originalFileName: "bounded.wav"
            ) { _ in callbackCount += 1 }
            #expect(callbackCount == 1_024)
            #expect(staged.byteCount == 8 * 1024 * 1024)
            _ = try transaction.commit(staged, suggestedFileName: "bounded.wav")
        }
    }

    @Test("Insufficient space fails before creating a staging file")
    func insufficientSpacePreflight() throws {
        try withWorkspace { workspace in
            let source = workspace.appendingPathComponent("source.bin")
            try payload(index: 1, count: 4 * 1024).write(to: source)
            let destination = workspace.appendingPathComponent("library", isDirectory: true)
            let transaction = LocalImportFileTransaction(
                destinationDirectory: destination,
                configuration: .init(minimumFreeSpaceReserve: Int64.max)
            )
            try transaction.prepareAndCleanStaging()

            #expect(throws: LocalImportFileTransaction.TransactionError.self) {
                _ = try transaction.stageCopy(from: source, originalFileName: "no-space.wav")
            }
            #expect(try transaction.ownedStagingFileCount() == 0)
            #expect(try visibleFiles(in: destination).isEmpty)
        }
    }

    private func withWorkspace(_ body: (URL) throws -> Void) throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-local-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try body(workspace)
    }

    private func payload(index: Int, count: Int = 96) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for offset in 0..<count {
                bytes[offset] = UInt8(truncatingIfNeeded: index &* 31 &+ offset &* 17)
            }
            var identity = UInt64(index).littleEndian
            withUnsafeBytes(of: &identity) { identityBytes in
                for offset in 0..<min(count, identityBytes.count) {
                    bytes[offset] = identityBytes[offset]
                }
            }
        }
        return data
    }

    private func identityEntry(
        for committed: LocalImportFileTransaction.CommittedFile,
        in destination: URL
    ) -> LocalImportIdentityEntry {
        LocalImportIdentityEntry(
            sha256: committed.sha256,
            relativePath: committed.url.lastPathComponent,
            byteCount: committed.byteCount,
            modificationDate: committed.originalModificationDate
        )
    }

    private func visibleFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }
}
