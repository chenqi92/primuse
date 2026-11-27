import Foundation
import Testing
@testable import PrimuseKit

@Suite("Displayed folder counts")
struct LibraryFolderDisplayedCountTests {
    @Test("Counts match browsing for collapsed roots, multiple roots and unresolved songs", arguments: [
        ["/"], ["/One", "/Two"]
    ])
    func matchesVisibleFolders(roots: [String]) throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "local", displayName: "Music", scanRoots: roots,
            pathSemantics: .hierarchical, pathEncoding: .native
        )
        let paths = ["/One/Album/a.flac", "/One/Album/Disc/b.flac", "/Two/c.flac", "", "../unknown.flac"]
        let songs = paths.enumerated().map { offset, path in
            Song(id: "song-\(offset)", title: "Track \(offset)", duration: 180,
                 fileFormat: .flac, filePath: path, sourceID: "local",
                 dateAdded: Date(timeIntervalSince1970: 0))
        }
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: songs)
        let sourceNode = try #require(index.sourceNode(for: "local"))
        var nodes = [sourceNode]
        var cursor = 0
        while cursor < nodes.count {
            let node = nodes[cursor]
            #expect(LibraryFolderBrowsePolicy.displayedChildCount(in: index, of: node.id)
                == LibraryFolderBrowsePolicy.displayedChildren(in: index, of: node.id).count)
            nodes.append(contentsOf: index.children(of: node.id))
            cursor += 1
        }
        #expect(LibraryFolderBrowsePolicy.displayedChildCount(in: index, of: sourceNode.id) == 2)
        let missing = LibraryFolderNodeID(sourceID: "missing", kind: .source, normalizedRelativePath: "/")
        #expect(LibraryFolderBrowsePolicy.displayedChildCount(in: index, of: missing) == 0)
    }

    @Test("Virtual collections count as separate entries")
    func countsVirtualCollections() throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "remote", displayName: "Music", scanRoots: ["/"],
            pathSemantics: .hierarchical, pathEncoding: .native
        )
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: [], virtualCollections: [
            .init(sourceID: "remote", identity: "all", displayName: "Songs", kind: .librarySongs, songIDs: []),
            .init(sourceID: "remote", identity: "favorites", displayName: "Favorites", kind: .playlist, songIDs: [])
        ])
        let sourceNode = try #require(index.sourceNode(for: "remote"))
        #expect(LibraryFolderBrowsePolicy.displayedChildCount(in: index, of: sourceNode.id) == 2)
    }
}
