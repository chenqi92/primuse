import Foundation
import XCTest
@testable import Primuse

@MainActor
final class LibraryPreviewSessionTests: XCTestCase {
    func testSuccessfulSourceSyncAdvancesPreviewInvalidationRevision() throws {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PrimuseSourceSyncRevisionTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let initialRevision = library.sourceSyncCompletionRevision

        library.sourceSyncDidComplete()

        XCTAssertEqual(library.sourceSyncCompletionRevision, initialRevision + 1)
    }
}
