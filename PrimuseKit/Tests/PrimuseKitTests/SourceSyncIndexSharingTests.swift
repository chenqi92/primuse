import Foundation
import Testing
@testable import PrimuseKit

@Suite("Committed sync index shares repeated folder paths")
struct SourceSyncIndexSharingTests {
    private func storage(_ value: String?) -> UnsafeRawPointer? {
        var copy = value
        return copy?.withUTF8 { UnsafeRawPointer($0.baseAddress) }
    }

    /// A decoded server-catalogue index: an album folder and one item per song,
    /// every song carrying its own copy of the folder's path.
    private func decodedIndex(songs: Int) throws -> [String: SourceSyncIndexedItem] {
        let folderPath = "server-folder:0123456789abcdef0123456789abcdef"
        var items: [String: SourceSyncIndexedItem] = [
            "hierarchy-folder:\(folderPath)": SourceSyncIndexedItem(
                stableKey: "hierarchy-folder:\(folderPath)", path: folderPath, displayName: "专辑",
                parentPath: "server-root:fedcba9876543210fedcba9876543210", isDirectory: true,
                size: 0, modifiedDate: nil, revision: nil
            ),
        ]
        for index in 0..<songs {
            let key = "hierarchy-song:song-\(index)-0123456789abcdef"
            items[key] = SourceSyncIndexedItem(
                stableKey: key, path: "/songs/\(index).flac", displayName: "Song \(index)",
                parentPath: folderPath, isDirectory: false, songIDs: ["song-\(index)"],
                size: 1_000, modifiedDate: Date(timeIntervalSince1970: Double(index)), revision: nil
            )
        }
        // Round-trip so every string is a separate decoded copy, as on launch.
        let data = try JSONEncoder().encode(items)
        return try JSONDecoder().decode([String: SourceSyncIndexedItem].self, from: data)
    }

    @Test func valuesAreUnchangedAndCopiesShareOneString() throws {
        let decoded = try decodedIndex(songs: 50)
        var shared = decoded
        shared.shareRepeatedFolderPaths()
        #expect(shared == decoded)

        let songParents = shared.values.filter { !$0.isDirectory }.map { storage($0.parentPath) }
        let folder = try #require(shared.values.first { $0.isDirectory })
        #expect(Set(songParents.compactMap { $0 }).count == 1)
        #expect(songParents.first == storage(folder.path))
        #expect(storage(decoded.values.first { !$0.isDirectory }?.parentPath)
            != storage(decoded.values.filter { !$0.isDirectory }.last?.parentPath))
        // Each item's stable key is the string its dictionary entry is stored under.
        for (key, item) in shared where key.utf8.count > 15 {
            #expect(storage(item.stableKey) == storage(key))
        }
    }

    @Test func shortPathsAndRootsAreLeftAsTheyAre() {
        var index: [String: SourceSyncIndexedItem] = [
            "a": SourceSyncIndexedItem(stableKey: "a", path: "/a/1.mp3", parentPath: "/a", isDirectory: false,
                                       size: 1, modifiedDate: nil, revision: nil),
            "root": SourceSyncIndexedItem(stableKey: "root", path: "/a", parentPath: nil, isDirectory: true,
                                          size: 0, modifiedDate: nil, revision: nil),
        ]
        let before = index
        index.shareRepeatedFolderPaths()
        #expect(index == before)
    }
}
