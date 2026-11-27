import Foundation
import Testing
@testable import PrimuseKit

@Suite("tvOS decoded temporary file policy")
struct TVDecodedTemporaryFilePolicyTests {
    @Test("Generated names stay in the managed directory and sanitize extensions")
    func generatedURLIsManaged() {
        let directory = URL(fileURLWithPath: "/tmp/primuse-tv-policy", isDirectory: true)
        let identifier = UUID(uuidString: "8DB1D93C-6E2D-47F4-A045-6A48E33A4A5D")!

        let url = TVDecodedTemporaryFilePolicy.makeURL(
            in: directory,
            fileExtension: "../A Pe!",
            identifier: identifier
        )

        #expect(url.lastPathComponent == "tvsfb-8DB1D93C-6E2D-47F4-A045-6A48E33A4A5D.ape")
        #expect(TVDecodedTemporaryFilePolicy.isManagedFile(url, in: directory))
        #expect(!TVDecodedTemporaryFilePolicy.isManagedFile(
            directory.appendingPathComponent("nested/\(url.lastPathComponent)"),
            in: directory
        ))
    }

    @Test("Cleanup removes only app-owned files from the immediate temporary directory")
    func cleanupIsScoped() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("primuse-tv-policy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let managed = TVDecodedTemporaryFilePolicy.makeURL(
            in: directory,
            fileExtension: "ape"
        )
        let unrelated = directory.appendingPathComponent("keep.ape")
        try Data("managed".utf8).write(to: managed)
        try Data("unrelated".utf8).write(to: unrelated)

        #expect(try TVDecodedTemporaryFilePolicy.removeIfManaged(managed, in: directory))
        #expect(!fileManager.fileExists(atPath: managed.path))
        #expect(!(try TVDecodedTemporaryFilePolicy.removeIfManaged(unrelated, in: directory)))
        #expect(fileManager.fileExists(atPath: unrelated.path))
    }

    @Test("Whole-file downloads require a valid and exact final byte count")
    func exactDownloadLengthValidation() {
        #expect(!ExactChunkedDownloadPolicy.contentLengthIsValid(-1))
        #expect(ExactChunkedDownloadPolicy.contentLengthIsValid(0))
        #expect(ExactChunkedDownloadPolicy.isComplete(expectedLength: 0, writtenLength: 0))
        #expect(ExactChunkedDownloadPolicy.isComplete(expectedLength: 1_024, writtenLength: 1_024))
        #expect(!ExactChunkedDownloadPolicy.isComplete(expectedLength: 1_024, writtenLength: 1_023))
        #expect(!ExactChunkedDownloadPolicy.isComplete(expectedLength: -1, writtenLength: 0))
    }

    @Test("Chunk validation rejects empty and oversized reader responses")
    func chunkValidation() {
        #expect(ExactChunkedDownloadPolicy.chunkDecision(
            requestedLength: 1_024,
            receivedLength: 0
        ) == .rejectEmpty)
        #expect(ExactChunkedDownloadPolicy.chunkDecision(
            requestedLength: 1_024,
            receivedLength: 1_025
        ) == .rejectOversized)
        #expect(ExactChunkedDownloadPolicy.chunkDecision(
            requestedLength: 1_024,
            receivedLength: 512
        ) == .append)
        #expect(ExactChunkedDownloadPolicy.chunkDecision(
            requestedLength: 1_024,
            receivedLength: 1_024
        ) == .append)
    }
}
