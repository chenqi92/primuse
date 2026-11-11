import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library folder index reuse across song pages")
struct LibraryFolderIndexReuseTests {
    private let source = LibraryFolderSourceDescriptor(
        sourceID: "source",
        displayName: "Source",
        scanRoots: ["/"],
        pathSemantics: .hierarchical
    )

    private func key(
        songsRevision: UInt64 = 1,
        collectionRevision: Int = 1,
        token: UUID,
        virtualCollectionRevision: Int = 0,
        hierarchyRevision: Int = 0,
        sources: [LibraryFolderSourceDescriptor]? = nil
    ) -> LibraryFolderIndexReuseKey {
        LibraryFolderIndexReuseKey(
            songsRevision: songsRevision,
            collectionRevision: collectionRevision,
            replacementToken: token,
            virtualCollectionRevision: virtualCollectionRevision,
            hierarchyRevision: hierarchyRevision,
            sources: sources ?? [source]
        )
    }

    private func index(_ paths: [String]) -> LibraryFolderIndex {
        LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: paths.enumerated().map { offset, path in
                Song(
                    id: "song-\(offset)",
                    title: path,
                    duration: 180,
                    fileFormat: .flac,
                    filePath: path,
                    sourceID: "source",
                    dateAdded: Date(timeIntervalSince1970: 0)
                )
            }
        )
    }

    @Test("A new page gets the index built from the same inputs")
    func reusesMatchingInputs() {
        let cache = LibraryFolderIndexReuseCache()
        let token = UUID()
        let built = index(["/A/one.flac", "/B/two.flac"])
        #expect(cache.index(for: key(token: token)) == nil)
        #expect(cache.store(built, for: key(token: token)) == nil)
        #expect(cache.index(for: key(token: token)) === built)
    }

    @Test("Any changed input means building again", arguments: [
        "songs", "collection", "token", "playlists", "hierarchy", "sources",
    ])
    func rejectsChangedInputs(input: String) {
        let cache = LibraryFolderIndexReuseCache()
        let token = UUID()
        cache.store(index(["/A/one.flac"]), for: key(token: token))
        let changed: LibraryFolderIndexReuseKey = switch input {
        case "songs": key(songsRevision: 2, token: token)
        case "collection": key(collectionRevision: 2, token: token)
        case "token": key(token: UUID())
        case "playlists": key(token: token, virtualCollectionRevision: 1)
        case "hierarchy": key(token: token, hierarchyRevision: 1)
        default: key(token: token, sources: [LibraryFolderSourceDescriptor(
            sourceID: "source",
            displayName: "Renamed",
            scanRoots: ["/"],
            pathSemantics: .hierarchical
        )])
        }
        #expect(cache.index(for: changed) == nil)
    }

    @Test("Storing a newer index hands back the one it replaces")
    func storeReturnsReplacedIndex() {
        let cache = LibraryFolderIndexReuseCache()
        let first = index(["/A/one.flac"])
        let second = index(["/A/one.flac", "/C/three.flac"])
        let oldKey = key(token: UUID())
        let newKey = key(collectionRevision: 2, token: UUID())
        cache.store(first, for: oldKey)
        #expect(cache.store(first, for: oldKey) == nil)
        #expect(cache.store(second, for: newKey) === first)
        #expect(cache.index(for: oldKey) == nil)
        #expect(cache.index(for: newKey) === second)
    }

    @Test("A tag-only replacement moves the same index to the new token")
    func rekeysOnlyTheSameIndexUnderTheSameInputs() {
        let cache = LibraryFolderIndexReuseCache()
        let built = index(["/A/one.flac"])
        let oldKey = key(token: UUID())
        let newKey = oldKey.replacingToken(UUID())
        cache.store(built, for: oldKey)

        // 另一份索引、或者记在别的输入下时不动。
        #expect(!cache.rekey(index(["/A/one.flac"]), from: oldKey, to: newKey))
        #expect(!cache.rekey(built, from: key(collectionRevision: 9, token: oldKey.replacementToken), to: newKey))
        #expect(cache.index(for: oldKey) === built)

        #expect(cache.rekey(built, from: oldKey, to: newKey))
        #expect(cache.index(for: oldKey) == nil)
        #expect(cache.index(for: newKey) === built)
        #expect(newKey.collectionRevision == oldKey.collectionRevision)
        #expect(newKey.sources == oldKey.sources)
    }

    @Test("Inputs outside the key drop the cached index")
    func removeAllDropsIndex() {
        let cache = LibraryFolderIndexReuseCache()
        let built = index(["/A/one.flac"])
        let token = UUID()
        cache.store(built, for: key(token: token))
        #expect(cache.removeAll() === built)
        #expect(cache.index(for: key(token: token)) == nil)
        #expect(cache.removeAll() == nil)
    }
}
