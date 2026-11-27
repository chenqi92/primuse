import Foundation
import Testing
@testable import PrimuseKit

@Suite("Folder playlist membership")
struct FolderPlaylistMembershipTests {
    @Test("Native filename repairs retain existing root bindings and distinguish literal percent directories")
    func nativePathsPreserveBoundFolderMembership() throws {
        let source = MusicSource(id: "nas", name: "Music", type: .local, extraConfig: "[\"/\"]")
        let rootID = LibraryFolderNodeID(sourceID: "nas", kind: .scanRoot, normalizedRelativePath: "/")
        let sourceID = LibraryFolderNodeID(sourceID: "nas", kind: .source, normalizedRelativePath: "")
        let literalID = LibraryFolderNodeID(sourceID: "nas", kind: .folder, normalizedRelativePath: "/a%2fb")
        let nestedID = LibraryFolderNodeID(sourceID: "nas", kind: .folder, normalizedRelativePath: "/a/b")
        let songs = [song("normal", "/normal.mp3"), song("special", "/Live #1?@%2F.mp3"),
                     song("literal", "/A%2FB/song.mp3"), song("nested", "/A/B/song.mp3")]
        let bindings = ["root": PlaylistFolderBinding(nodeID: rootID),
                        "source": PlaylistFolderBinding(nodeID: sourceID),
                        "literal": PlaylistFolderBinding(nodeID: literalID),
                        "nested": PlaylistFolderBinding(nodeID: nestedID)]
        let members = FolderPlaylistMembershipPolicy.memberships(bindings: bindings, source: source, songs: songs, syncIndex: nil)
        #expect(Set(try #require(members["root"])) == Set(songs.map(\.id)))
        #expect(members["source"] == members["root"])
        #expect(members["literal"] == ["literal"])
        #expect(members["nested"] == ["nested"])
        let refreshed = FolderPlaylistMembershipPolicy.memberships(bindings: bindings, source: source, songs: Array(songs.dropLast()), syncIndex: nil)
        #expect(refreshed["nested"] == [])
        #expect(refreshed["literal"] == ["literal"])
    }

    @Test("Rescans add and remove descendants without matching sibling prefixes or other sources")
    func hierarchicalMembershipTracksCurrentDirectory() throws {
        let source = MusicSource(id: "nas", name: "NAS", type: .webdav,
                                 extraConfig: "[\"/Music\"]")
        let binding = PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
            sourceID: "nas", kind: .folder, normalizedRelativePath: "/music/live"
        ))
        let first = FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source,
            songs: [song("a", "/Music/Live/a.mp3"), song("b", "/Music/Live/Disc/b.mp3"),
                    song("sibling", "/Music/Live-old/c.mp3"), song("other", "/Music/Live/a.mp3", sourceID: "other")],
            syncIndex: nil
        )
        #expect(Set(try #require(first["playlist"])) == ["a", "b"])
        let refreshed = FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source,
            songs: [song("b", "/Music/Live/Disc/b.mp3"), song("new", "/Music/Live/new.mp3")],
            syncIndex: nil
        )
        #expect(Set(try #require(refreshed["playlist"])) == ["b", "new"])
        #expect(FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source, songs: [], syncIndex: nil
        )["playlist"] == [])
    }

    @Test("Opaque directory bindings survive renames and update when tracks move")
    func providerIdentitySurvivesRenameAndMove() throws {
        let source = MusicSource(id: "nas", name: "Drive", type: .googleDrive,
                                 extraConfig: "[\"root\"]", cloudAccountID: "account")
        let binding = PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
            sourceID: "old-mount", kind: .folder, normalizedRelativePath: "folder-id"
        ), cloudAccountID: "account")
        let items = [item("root", parent: nil, directory: true),
                     item("folder-id", parent: "root", directory: true, name: "Renamed folder"),
                     item("a", parent: "root", directory: false),
                     item("b", parent: "folder-id", directory: false)]
        let memberships = FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source,
            songs: [song("a", "a"), song("b", "b")],
            syncIndex: SourceSyncIndex(Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) }))
        )
        #expect(memberships["playlist"] == ["b"])
        var otherAccount = source
        otherAccount.cloudAccountID = "another-account"
        #expect(FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: otherAccount, songs: [], syncIndex: [:]
        ).isEmpty)
    }

    @Test("Unavailable topology is not an authoritative empty directory")
    func missingProviderSnapshotDoesNotClearMembership() {
        let source = MusicSource(id: "nas", name: "Server", type: .navidrome)
        let binding = PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
            sourceID: "nas", kind: .folder, normalizedRelativePath: "folder-id"
        ))
        #expect(FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source, songs: [], syncIndex: nil
        ).isEmpty)
        #expect(FolderPlaylistMembershipPolicy.memberships(
            bindings: ["playlist": binding], source: source, songs: [], syncIndex: [:]
        )["playlist"] == [])
    }

    @Test("Cloud sync preserves a folder binding and legacy playlists stay editable")
    func bindingRoundTripsThroughPlaylistEnvelope() throws {
        let binding = PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
            sourceID: "nas", kind: .folder, normalizedRelativePath: "/music/live"
        ))
        let playlist = Playlist(name: "Live", folderBinding: binding)
        let envelope = PlaylistCloudSyncEnvelope(playlist: playlist, songIdentities: [])
        let decoded = try JSONDecoder().decode(PlaylistCloudSyncEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(decoded.playlist.folderBinding == binding)
        #expect(!decoded.playlist.allowsManualSongMembership)
        let old = try JSONDecoder().decode(Playlist.self, from: Data(
            "{\"id\":\"legacy\",\"name\":\"Legacy\",\"createdAt\":0,\"updatedAt\":1}".utf8
        ))
        #expect(old.folderBinding == nil)
        #expect(old.allowsManualSongMembership)
    }

    @Test("Memberships built on the catalog match the ones built from the songs", arguments: [1, 2, 3] as [UInt64])
    func catalogMatchesSongs(seed: UInt64) throws {
        var rng = CatalogTestRandom(seed: seed)
        let temporary = try TemporaryCatalog()
        let source = MusicSource(id: "nas", name: "NAS", type: .webdav, extraConfig: "[\"/Music\", \"/Audio\"]")
        let folders = ["/Music", "/Music/Live", "/Music/Live/Disc 2", "/Music/Live-old", "/Music/周杰伦", "/music/live",
                       "/Audio/Books/第一季", "/Other", "/Music/A%2FB"]
        var songs: [Song] = []
        for index in 0..<320 {
            let format: AudioFormat = rng.chance(50) ? .flac : .mp3
            songs.append(Song(
                id: "member-\(seed)-\(index)", title: rng.pick(["Intro", "Song 2", "Song 10", "第1集", ""]),
                trackNumber: rng.chance(60) ? rng.int(1...12) : nil, discNumber: rng.chance(20) ? 2 : nil,
                fileFormat: format,
                filePath: "\(rng.pick(folders))/\(rng.pick(["01 Song", "2 Song", "第2集", "Live @ Home"])) \(index).\(rng.pick(["flac", "mp3", "m4b"]))",
                sourceID: rng.chance(85) ? "nas" : "other"
            ))
        }
        try temporary.catalog.apply(upserts: songs)
        var ordered: [Song] = []
        try temporary.catalog.forEachSong(.everything) { _, song in
            ordered.append(song)
            return true
        }

        // 每个节点都绑一个歌单,再加一个已经没有了的文件夹。
        let index = LibraryFolderIndexBuilder.build(sources: [LibraryFolderSourceDescriptor(source: source)], songs: ordered)
        var nodes = index.sourceNodes.map(\.id)
        var cursor = 0
        while cursor < nodes.count {
            nodes.append(contentsOf: index.children(of: nodes[cursor]).map(\.id))
            cursor += 1
        }
        #expect(nodes.count > 6)
        var bindings: [String: PlaylistFolderBinding] = [:]
        for (position, node) in nodes.enumerated() { bindings["p\(position)"] = PlaylistFolderBinding(nodeID: node) }
        bindings["gone"] = PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
            sourceID: "nas", kind: .folder, normalizedRelativePath: "/music/gone"
        ))

        let fromSongs = FolderPlaylistMembershipPolicy.memberships(bindings: bindings, source: source, songs: ordered, syncIndex: nil)
        let fromCatalog = try FolderPlaylistMembershipPolicy.memberships(
            bindings: bindings, source: source, catalog: temporary.catalog, syncIndex: nil
        )
        #expect(fromCatalog == fromSongs)
        #expect(fromSongs.values.contains { $0.count > 10 })
        #expect(throws: CancellationError.self) {
            try FolderPlaylistMembershipPolicy.memberships(
                bindings: bindings, source: source, catalog: temporary.catalog, syncIndex: nil, isCancelled: { true }
            )
        }
    }

    @Test("Provider-hierarchy memberships built on the catalog match the ones built from the songs")
    func providerHierarchyCatalogMatchesSongs() throws {
        let temporary = try TemporaryCatalog()
        let source = MusicSource(id: "nas", name: "Drive", type: .googleDrive,
                                 extraConfig: "[\"root\"]", cloudAccountID: "account")
        var items = [item("root", parent: nil, directory: true),
                     item("folder-id", parent: "root", directory: true, name: "Renamed folder"),
                     item("nested-id", parent: "folder-id", directory: true, name: "Disc 2")]
        var songs: [Song] = []
        for index in 0..<30 {
            let parent = ["root", "folder-id", "nested-id"][index % 3]
            items.append(item("file-\(index)", parent: parent, directory: false, name: "\(index % 7) Track.flac"))
            songs.append(song("drive-\(index)", "file-\(index)"))
        }
        try temporary.catalog.apply(upserts: songs)
        let syncIndex = SourceSyncIndex(Dictionary(uniqueKeysWithValues: items.map { ($0.stableKey, $0) }))
        let bindings = [
            "folder": PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
                sourceID: "old-mount", kind: .folder, normalizedRelativePath: "folder-id"
            ), cloudAccountID: "account"),
            "nested": PlaylistFolderBinding(nodeID: LibraryFolderNodeID(
                sourceID: "nas", kind: .folder, normalizedRelativePath: "nested-id"
            )),
        ]
        let fromSongs = FolderPlaylistMembershipPolicy.memberships(bindings: bindings, source: source, songs: songs, syncIndex: syncIndex)
        let fromCatalog = try FolderPlaylistMembershipPolicy.memberships(
            bindings: bindings, source: source, catalog: temporary.catalog, syncIndex: syncIndex
        )
        #expect(fromCatalog == fromSongs)
        #expect(fromSongs["folder"]?.count == 20)
        #expect(try FolderPlaylistMembershipPolicy.memberships(
            bindings: bindings, source: source, catalog: temporary.catalog, syncIndex: nil
        ).isEmpty, "unavailable topology is not an empty directory")
    }

    private func song(_ id: String, _ path: String, sourceID: String = "nas") -> Song {
        Song(id: id, title: id, fileFormat: .mp3, filePath: path, sourceID: sourceID)
    }

    private func item(_ id: String, parent: String?, directory: Bool, name: String? = nil) -> SourceSyncIndexedItem {
        SourceSyncIndexedItem(stableKey: id, path: id, displayName: name,
                             parentPath: parent, isDirectory: directory,
                             size: 0, modifiedDate: nil, revision: nil)
    }
}
