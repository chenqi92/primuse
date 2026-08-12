import Foundation
import Testing
@testable import PrimuseKit

@Suite("Library folder path policy")
struct LibraryFolderPathPolicyTests {
    @Test("Normalizes separators, dot segments, percent encoding, Unicode, and case")
    func normalizesPathRepresentations() throws {
        let policy = LibraryFolderPathPolicy(scanRoots: ["/Music/Café/"])

        let encoded = policy.placement(
            for: "/MUSIC/Cafe%CC%81//./Live/song.flac"
        )
        #expect(encoded.category == .folder)
        #expect(encoded.scanRoot?.normalizedPath == "/Music/Café")
        #expect(encoded.scanRoot?.identityPath == "/music/café")
        #expect(encoded.folderComponents == ["Live"])
        #expect(encoded.normalizedFolderPath == "/Music/Café/Live")
        #expect(encoded.identityFolderPath == "/music/café/live")

        let backslashes = policy.placement(
            for: "\\music\\café\\Studio\\song.flac"
        )
        #expect(backslashes.category == .folder)
        #expect(backslashes.folderComponents == ["Studio"])
    }

    @Test("Rejects raw and encoded traversal plus component-prefix escapes")
    func rejectsOutsideRootPaths() {
        let policy = LibraryFolderPathPolicy(scanRoots: ["/Music"])
        let rejected = [
            "/Music/../private/song.flac",
            "/Music/%2e%2e/private/song.flac",
            "/Music/%252e%252e/private/song.flac",
            "/Music-old/Album/song.flac",
            "../Music/song.flac",
        ]

        for path in rejected {
            #expect(policy.placement(for: path).category == .other)
        }
        #expect(policy.placement(for: "/Music/Album/track.flac").category == .folder)
    }

    @Test("Nested scan roots use the most specific stable root")
    func prefersMostSpecificRoot() {
        let policy = LibraryFolderPathPolicy(scanRoots: [
            "/Music",
            "/Music/Live",
            "/MUSIC/LIVE/",
        ])
        let placement = policy.placement(for: "/music/live/Concert/song.flac")

        #expect(policy.scanRoots.count == 2)
        #expect(placement.scanRoot?.normalizedPath == "/Music/Live")
        #expect(placement.folderComponents == ["Concert"])
        #expect(placement.identityFolderPath == "/music/live/concert")
    }

    @Test("Credentials, signed URLs, UNC locations, and cache paths never become labels")
    func rejectsSensitiveLocations() throws {
        let policy = LibraryFolderPathPolicy(scanRoots: ["/"])
        let rejected = [
            "https://user:password@example.test/Music/song.flac?X-Amz-Signature=secret",
            "smb://user:password@nas.local/share/song.flac",
            "file:///Users/alice/Music/song.flac",
            "\\\\nas.local\\private\\song.flac",
            "/Users/alice/Library/Caches/Primuse/audio/song.flac",
            "/Users/alice/Library/Application Support/Primuse/audio/song.flac",
            "/private/var/folders/ab/cache/song.flac",
            "/Music/user@example.test/song.flac",
        ]

        for path in rejected {
            #expect(policy.placement(for: path).category == .other)
        }

        let source = LibraryFolderSourceDescriptor(
            sourceID: "secure",
            displayName: "NAS",
            scanRoots: ["/"],
            pathSemantics: .hierarchical
        )
        let songs = rejected.enumerated().map { index, path in
            testSong(id: "unsafe-\(index)", path: path, sourceID: "secure")
        }
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: songs)
        let sourceNode = try #require(index.sourceNode(for: "secure"))
        let children = index.children(of: sourceNode.id)
        let other = try #require(children.first { $0.kind == .other })

        #expect(other.directSongCount == rejected.count)
        #expect(other.displayName == nil)
        #expect(children.compactMap(\.displayName).allSatisfy {
            !$0.contains("user") && !$0.contains("password") && !$0.contains("Signature")
        })

        #expect(policy.placement(for: "/Users/alice/Music/song.flac").category == .other)
    }

    @Test("Source labels never echo credentialed endpoints")
    func sanitizesSourceDisplayNames() {
        let credentialed = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "credentialed",
            name: "smb://user:password@nas.local/Music",
            type: .smb
        ))
        let encodedURL = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "signed",
            name: "https%3A%2F%2Fexample.test%2Fmusic%3Fsignature%3Dsecret",
            type: .webdav
        ))
        let ordinary = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "ordinary",
            name: "Home NAS",
            type: .smb
        ))
        let absoluteLocal = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "absolute-local",
            name: "/Users/alice/Music",
            type: .local
        ))
        let windowsLocal = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "windows-local",
            name: "C:\\Users\\alice\\Music",
            type: .smb
        ))
        let relativeDisplayName = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "relative-name",
            name: "AC/DC Archive",
            type: .smb
        ))

        #expect(credentialed.displayName == MusicSourceType.smb.displayName)
        #expect(encodedURL.displayName == MusicSourceType.webdav.displayName)
        #expect(ordinary.displayName == "Home NAS")
        #expect(absoluteLocal.displayName == MusicSourceType.local.displayName)
        #expect(windowsLocal.displayName == MusicSourceType.smb.displayName)
        #expect(relativeDisplayName.displayName == "AC/DC Archive")
    }

    @Test("Missing directories and opaque provider paths stay uncategorized")
    func keepsMissingHierarchyUncategorized() {
        let noRoots = LibraryFolderPathPolicy(scanRoots: [])
        let opaque = LibraryFolderPathPolicy(
            scanRoots: ["/fake/root"],
            semantics: .opaque
        )

        #expect(noRoots.placement(for: "/Music/Album/song.flac").category == .uncategorized)
        #expect(noRoots.placement(for: "").category == .uncategorized)
        #expect(opaque.placement(for: "/media/items/opaque-id.m4a").category == .uncategorized)
        #expect(opaque.scanRoots.isEmpty)

        let emptyRootSentinel = LibraryFolderPathPolicy(scanRoots: [""])
        let rootPlacement = emptyRootSentinel.placement(for: "Album/song.flac")
        #expect(emptyRootSentinel.scanRoots.first?.normalizedPath == "/")
        #expect(rootPlacement.folderComponents == ["Album"])
    }
}

@Suite("Immutable library folder index")
struct LibraryFolderIndexTests {
    @Test("Supports multiple roots, root files, duplicate names, and safe fallbacks")
    func buildsMultipleScanRoots() throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "nas",
            displayName: "Home NAS",
            scanRoots: ["/volume1/Music", "/volume2/Music"],
            pathSemantics: .hierarchical
        )
        let songs = [
            testSong(id: "root-1", title: "Same", path: "/volume1/Music/root.flac", sourceID: "nas"),
            testSong(id: "root-2", title: "Same", path: "/volume2/Music/root.flac", sourceID: "nas"),
            testSong(id: "live-1", title: "Same", path: "/volume1/Music/Live/song.flac", sourceID: "nas"),
            testSong(id: "live-2", title: "Same", path: "/volume2/Music/Live/song.flac", sourceID: "nas"),
            testSong(id: "live-1-copy", title: "Same", path: "/volume1/Music/Live/copy.flac", sourceID: "nas"),
            testSong(id: "outside", path: "/volume3/Music/private.flac", sourceID: "nas"),
            testSong(id: "missing", path: "", sourceID: "nas"),
        ]

        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: songs)
        let sourceNode = try #require(index.sourceNode(for: "nas"))
        let sourceChildren = index.children(of: sourceNode.id)
        let roots = sourceChildren.filter { $0.kind == .scanRoot }
        let root1 = try #require(roots.first {
            $0.id.normalizedRelativePath == "/volume1/music"
        })
        let root2 = try #require(roots.first {
            $0.id.normalizedRelativePath == "/volume2/music"
        })
        let live1 = try #require(index.children(of: root1.id).first {
            $0.displayName == "Live"
        })
        let live2 = try #require(index.children(of: root2.id).first {
            $0.displayName == "Live"
        })

        #expect(index.songCount == 7)
        #expect(sourceNode.descendantSongCount == 7)
        #expect(roots.count == 2)
        #expect(roots.map(\.displayName) == ["Music", "Music"])
        #expect(root1.id != root2.id)
        #expect(live1.id != live2.id)
        #expect(live1.displayName == live2.displayName)
        #expect(index.directSongIDs(in: root1.id) == ["root-1"])
        #expect(index.directSongIDs(in: root2.id) == ["root-2"])
        #expect(Set(index.directSongIDs(in: live1.id)) == ["live-1", "live-1-copy"])
        #expect(sourceChildren.contains { $0.kind == .other && $0.directSongCount == 1 })
        #expect(sourceChildren.contains { $0.kind == .uncategorized && $0.directSongCount == 1 })

        let ordered = index.orderedSongIDs(
            in: live1.id,
            scope: .direct,
            orderedBy: ["root-2", "live-1-copy", "live-2", "live-1", "root-1"]
        )
        #expect(ordered == ["live-1-copy", "live-1"])
    }

    @Test("Expands only requested nodes and materializes descendant scopes on demand")
    func queriesDeepHierarchyLazily() throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "local",
            displayName: "Local",
            scanRoots: ["/"],
            pathSemantics: .hierarchical
        )
        let songs = [
            testSong(id: "root", path: "/root.flac", sourceID: "local"),
            testSong(id: "peer", path: "/A/B/peer.flac", sourceID: "local"),
            testSong(id: "deep", path: "/A/B/C/deep.flac", sourceID: "local"),
        ]
        let index = LibraryFolderIndexBuilder.build(sources: [source], songs: songs)
        let sourceNode = try #require(index.sourceNode(for: "local"))
        let root = try #require(index.children(of: sourceNode.id).first {
            $0.kind == .scanRoot
        })
        let a = try #require(index.children(of: root.id).first { $0.displayName == "A" })
        let b = try #require(index.children(of: a.id).first { $0.displayName == "B" })
        let c = try #require(index.children(of: b.id).first { $0.displayName == "C" })

        #expect(index.directSongIDs(in: root.id) == ["root"])
        #expect(index.children(of: root.id).map(\.displayName) == ["A"])
        #expect(a.directSongCount == 0)
        #expect(a.descendantSongCount == 2)
        #expect(b.directSongCount == 1)
        #expect(b.descendantSongCount == 2)
        #expect(c.directSongCount == 1)
        #expect(index.songIDs(in: b.id, scope: .direct) == ["peer"])
        #expect(Set(index.songIDs(in: b.id, scope: .descendants)) == ["peer", "deep"])
        #expect(index.orderedSongIDs(
            in: b.id,
            scope: .descendants,
            orderedBy: ["deep", "root", "peer"]
        ) == ["deep", "peer"])
    }

    @Test("Source details skip the source wrapper and queues stay in the visible folder")
    func appliesFolderBrowseScopes() throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "nas",
            displayName: "NAS",
            scanRoots: ["/Music"],
            pathSemantics: .hierarchical
        )
        let index = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: [
                testSong(id: "root", path: "/Music/root.flac", sourceID: "nas"),
                testSong(id: "album", path: "/Music/Album/album.flac", sourceID: "nas"),
                testSong(id: "disc", path: "/Music/Album/Disc/disc.flac", sourceID: "nas"),
            ]
        )
        let libraryRoot = try #require(LibraryFolderBrowsePolicy.rootNodes(
            in: index,
            sourceID: nil
        ).first)
        let sourceDetailRoot = LibraryFolderBrowsePolicy.rootNodes(
            in: index,
            sourceID: "nas"
        )
        let scanRoot = try #require(sourceDetailRoot.first)
        let album = try #require(index.children(of: scanRoot.id).first)
        let order = ["disc", "root", "album"]

        #expect(libraryRoot.kind == .source)
        #expect(sourceDetailRoot.map(\.kind) == [.scanRoot])
        #expect(LibraryFolderBrowsePolicy.visibleSongIDs(
            in: scanRoot.id,
            index: index,
            orderedBy: order
        ) == ["root"])
        #expect(LibraryFolderBrowsePolicy.visibleSongIDs(
            in: album.id,
            index: index,
            orderedBy: order
        ) == ["album"])
        #expect(LibraryFolderBrowsePolicy.actionSongIDs(
            in: album.id,
            index: index,
            orderedBy: order
        ) == ["disc", "album"])

        let currentNodeID = index.nodeID(containingSongID: "album")
        #expect(source.placementNodeID(for: testSong(
            id: "album",
            path: "/Music/Album/renamed.flac",
            sourceID: "nas"
        )) == currentNodeID)
        #expect(source.placementNodeID(for: testSong(
            id: "album",
            path: "/Music/Moved/album.flac",
            sourceID: "nas"
        )) != currentNodeID)
    }

    @Test("Other node actions include every out-of-root song in library order")
    func selectsAllSongsInOtherNode() throws {
        let source = LibraryFolderSourceDescriptor(
            sourceID: "hierarchical",
            displayName: "Hierarchical",
            scanRoots: ["/Music"],
            pathSemantics: .hierarchical
        )
        let songs = (0..<82).map { index in
            testSong(
                id: "other-\(index)",
                path: "/Outside/track-\(index).flac",
                sourceID: "hierarchical"
            )
        }
        let folderIndex = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: songs
        )
        let other = try #require(folderIndex.sourceNode(for: "hierarchical").flatMap {
            folderIndex.children(of: $0.id).first { $0.kind == .other }
        })
        let order = songs.map(\.id).reversed()

        #expect(other.descendantSongCount == 82)
        #expect(LibraryFolderBrowsePolicy.actionSongIDs(
            in: other.id,
            index: folderIndex,
            orderedBy: Array(order)
        ) == Array(order))
    }

    @Test("Provider item IDs and stream URLs do not fabricate media-server folders")
    func keepsVirtualSourcesUncategorized() throws {
        let sourceTypes: [MusicSourceType] = [
            .appleMusic, .appleMusicLibrary, .upnp,
            .jellyfin, .navidrome, .fnMusic, .daoliyu,
        ]
        let sources = sourceTypes.enumerated().map { index, type in
            LibraryFolderSourceDescriptor(source: MusicSource(
                id: "opaque-\(index)",
                name: type.rawValue,
                type: type,
                extraConfig: MusicSource.encodeScannedDirectories(
                    ["/fake/root"],
                    into: nil,
                    type: type
                )
            ))
        }
        let paths = [
            "1234567890",
            "persistent-item-id",
            "http://server.local/media/song.flac?token=secret",
            "/media/items/item-id.m4a",
            "/subsonic/tracks/item-id.flac",
            "/fnmusic/tracks/item-id.flac",
            "/daoliyu/tracks/item-id.flac",
        ]
        let songs = sources.enumerated().map { index, source in
            testSong(
                id: "song-\(index)",
                path: paths[index],
                sourceID: source.sourceID
            )
        }

        #expect(sources.allSatisfy { $0.pathSemantics == .opaque })
        let index = LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        for source in sources {
            let sourceNode = try #require(index.sourceNode(for: source.sourceID))
            let children = index.children(of: sourceNode.id)
            #expect(children.count == 1)
            #expect(children.first?.kind == .uncategorized)
            #expect(children.first?.displayName == nil)
            #expect(children.first?.directSongCount == 1)
        }

        let smb = LibraryFolderSourceDescriptor(source: MusicSource(
            id: "smb",
            name: "SMB",
            type: .smb,
            extraConfig: MusicSource.encodeScannedDirectories(
                ["/Music"],
                into: nil,
                type: .smb
            )
        ))
        #expect(smb.pathSemantics == .hierarchical)
        #expect(smb.scanRoots == ["/Music"])
    }

    @Test("Apple Music mirrors form stable multi-membership collection nodes")
    func buildsAppleMusicPlaylistHierarchy() throws {
        let sourceID = AppleMusicLibraryIdentity.sourceID
        let source = LibraryFolderSourceDescriptor(
            sourceID: sourceID,
            displayName: "Apple Music",
            scanRoots: [],
            pathSemantics: .opaque
        )
        let songs = [
            testSong(id: "a", path: "i.a", sourceID: sourceID),
            testSong(id: "b", path: "i.b", sourceID: sourceID),
            testSong(id: "c", path: "i.c", sourceID: sourceID),
        ]
        let firstPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.first"
        let secondPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.second"
        let emptyPlaylistID = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.empty"
        let collections = [
            LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: AppleMusicLibraryIdentity.systemPlaylistID,
                displayName: "Library Songs",
                kind: .librarySongs,
                songIDs: ["a", "b", "c", "a"]
            ),
            LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: firstPlaylistID,
                displayName: "Shared Name",
                kind: .playlist,
                songIDs: ["a", "b", "a"]
            ),
            LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: secondPlaylistID,
                displayName: "Shared Name",
                kind: .playlist,
                songIDs: ["a", "c"]
            ),
            LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: emptyPlaylistID,
                displayName: "Empty",
                kind: .playlist,
                songIDs: []
            ),
            LibraryFolderVirtualCollectionDescriptor(
                sourceID: sourceID,
                identity: AppleMusicLibraryIdentity.notInPlaylistCollectionID,
                displayName: "Not in a Playlist",
                kind: .notInPlaylist,
                songIDs: ["b"]
            ),
        ]
        let index = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: songs,
            virtualCollections: collections
        )
        let sourceNode = try #require(index.sourceNode(for: sourceID))
        let children = index.children(of: sourceNode.id)
        let libraryNode = try #require(children.first { $0.kind == .librarySongs })
        let firstPlaylist = try #require(children.first {
            $0.id.normalizedRelativePath == firstPlaylistID
        })
        let secondPlaylist = try #require(children.first {
            $0.id.normalizedRelativePath == secondPlaylistID
        })
        let emptyPlaylist = try #require(children.first {
            $0.id.normalizedRelativePath == emptyPlaylistID
        })
        let unassigned = try #require(children.first { $0.kind == .notInPlaylist })

        #expect(children.contains { $0.kind == .uncategorized } == false)
        #expect(sourceNode.descendantSongCount == 3)
        #expect(libraryNode.directSongCount == 3)
        #expect(index.directSongIDs(in: firstPlaylist.id) == ["a", "b"])
        #expect(index.directSongIDs(in: secondPlaylist.id) == ["a", "c"])
        #expect(emptyPlaylist.directSongCount == 0)
        #expect(index.directSongIDs(in: unassigned.id) == ["b"])
        #expect(firstPlaylist.id != secondPlaylist.id)
        #expect(firstPlaylist.displayName == secondPlaylist.displayName)
        #expect(index.nodeID(containingSongID: "a") == libraryNode.id)
        #expect(LibraryFolderBrowsePolicy.visibleSongIDs(
            in: firstPlaylist.id,
            index: index,
            orderedBy: ["c", "b", "a"]
        ) == ["b", "a"])
        #expect(LibraryFolderBrowsePolicy.actionSongIDs(
            in: sourceNode.id,
            index: index,
            orderedBy: ["c", "b", "a"]
        ) == ["c", "b", "a"])

        let renamed = LibraryFolderIndexBuilder.build(
            sources: [source],
            songs: songs,
            virtualCollections: collections.map { collection in
                guard collection.identity == firstPlaylistID else { return collection }
                return LibraryFolderVirtualCollectionDescriptor(
                    sourceID: collection.sourceID,
                    identity: collection.identity,
                    displayName: "Renamed",
                    kind: collection.kind,
                    songIDs: collection.songIDs
                )
            }
        )
        #expect(renamed.node(withID: firstPlaylist.id)?.displayName == "Renamed")
    }

    @Test("Source-local replacement handles scan additions, deletion, rename, and disable")
    func appliesSourceIncrementally() throws {
        let sourceA = LibraryFolderSourceDescriptor(
            sourceID: "a",
            displayName: "A",
            scanRoots: ["/A"],
            pathSemantics: .hierarchical
        )
        let sourceB = LibraryFolderSourceDescriptor(
            sourceID: "b",
            displayName: "B",
            scanRoots: ["/B"],
            pathSemantics: .hierarchical
        )
        let original = LibraryFolderIndexBuilder.build(
            sources: [sourceA, sourceB],
            songs: [
                testSong(id: "a-1", path: "/A/one.flac", sourceID: "a"),
                testSong(id: "b-1", path: "/B/one.flac", sourceID: "b"),
            ]
        )
        let originalAID = try #require(original.sourceNode(for: "a")?.id)
        let originalB = try #require(original.sourceNode(for: "b"))

        let renamedA = LibraryFolderSourceDescriptor(
            sourceID: "a",
            displayName: "Renamed A",
            scanRoots: ["/A"],
            pathSemantics: .hierarchical
        )
        let added = original.replacingSource(renamedA, songs: [
            testSong(id: "a-1", path: "/A/one.flac", sourceID: "a"),
            testSong(id: "a-2", path: "/A/two.flac", sourceID: "a"),
        ])

        #expect(added.songCount == 3)
        #expect(added.sourceNode(for: "a")?.id == originalAID)
        #expect(added.sourceNode(for: "a")?.displayName == "Renamed A")
        #expect(added.sourceNode(for: "b") == originalB)
        #expect(added.nodeID(containingSongID: "a-2") != nil)

        let deleted = added.replacingSource(renamedA, songs: [
            testSong(id: "a-2", path: "/A/two.flac", sourceID: "a"),
        ])
        #expect(deleted.songCount == 2)
        #expect(deleted.nodeID(containingSongID: "a-1") == nil)

        let disabledA = LibraryFolderSourceDescriptor(
            sourceID: "a",
            displayName: "Renamed A",
            scanRoots: ["/A"],
            pathSemantics: .hierarchical,
            isEnabled: false
        )
        let disabled = deleted.replacingSource(disabledA, songs: [])
        #expect(disabled.sourceNode(for: "a") == nil)
        #expect(disabled.songCount == 1)

        let reenabled = disabled.replacingSource(renamedA, songs: [
            testSong(id: "a-2", path: "/A/two.flac", sourceID: "a"),
        ])
        #expect(reenabled.sourceNode(for: "a")?.id == originalAID)
        #expect(reenabled.removingSource("b").sourceNode(for: "b") == nil)
    }

    @Test("Detached store caches immutable indexes by collection version")
    func cachesBackgroundBuilds() async {
        let store = LibraryFolderIndexStore()
        let source = LibraryFolderSourceDescriptor(
            sourceID: "source",
            displayName: "Source",
            scanRoots: ["/"],
            pathSemantics: .hierarchical
        )
        let songs = [testSong(id: "one", path: "/one.flac", sourceID: "source")]
        let firstVersion = LibraryFolderIndexVersion(
            collectionRevision: 1,
            replacementToken: UUID()
        )
        let secondVersion = LibraryFolderIndexVersion(
            collectionRevision: 2,
            replacementToken: UUID()
        )
        let renamedSourceVersion = LibraryFolderIndexVersion(
            collectionRevision: 2,
            replacementToken: secondVersion.replacementToken,
            sourceRevision: 1
        )
        let virtualCollectionVersion = LibraryFolderIndexVersion(
            collectionRevision: 2,
            replacementToken: secondVersion.replacementToken,
            sourceRevision: 1,
            virtualCollectionRevision: 1
        )

        let first = await store.index(version: firstVersion, sources: [source], songs: songs)
        let firstAgain = await store.index(version: firstVersion, sources: [source], songs: songs)
        let second = await store.index(version: secondVersion, sources: [source], songs: songs)
        let renamed = await store.index(
            version: renamedSourceVersion,
            sources: [LibraryFolderSourceDescriptor(
                sourceID: "source",
                displayName: "Renamed Source",
                scanRoots: ["/"],
                pathSemantics: .hierarchical
            )],
            songs: songs
        )
        let virtual = await store.index(
            version: virtualCollectionVersion,
            sources: [source],
            songs: songs,
            virtualCollections: [LibraryFolderVirtualCollectionDescriptor(
                sourceID: "source",
                identity: "library",
                displayName: "Library Songs",
                kind: .librarySongs,
                songIDs: ["one"]
            )]
        )

        #expect(first === firstAgain)
        #expect(first !== second)
        #expect(second !== renamed)
        #expect(renamed !== virtual)
        #expect(renamed.sourceNode(for: "source")?.displayName == "Renamed Source")
        #expect(virtual.sourceNode(for: "source").flatMap {
            virtual.children(of: $0.id).first
        }?.kind == .librarySongs)
    }

    @Test("Builds a compact 100k-song prefix index within the regression budget")
    func buildsHundredThousandSongs() throws {
        let roots = (0..<8).map { "/root-\($0)" }
        let source = LibraryFolderSourceDescriptor(
            sourceID: "large",
            displayName: "Large Library",
            scanRoots: roots,
            pathSemantics: .hierarchical
        )
        var songs: [Song] = []
        songs.reserveCapacity(100_000)
        for index in 0..<100_000 {
            songs.append(testSong(
                id: "song-\(index)",
                path: "/root-\(index % 8)/Artist-\(index % 1_000)/Album-\(index % 5_000)/song-\(index).flac",
                sourceID: "large"
            ))
        }

        let clock = ContinuousClock()
        let start = clock.now
        let folderIndex = LibraryFolderIndexBuilder.build(sources: [source], songs: songs)
        let elapsed = start.duration(to: clock.now)
        let sourceNode = try #require(folderIndex.sourceNode(for: "large"))

        #expect(folderIndex.songCount == 100_000)
        #expect(sourceNode.descendantSongCount == 100_000)
        #expect(folderIndex.nodeCount < 7_000)
        #expect(elapsed < .seconds(15))
    }
}

@Suite("Song library browse-mode preference")
struct LibrarySongBrowseModePreferenceTests {
    @Test("First upgrade persists folder mode as the default")
    func defaultsToFolderOnUpgrade() throws {
        let suiteName = "LibrarySongBrowseModePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: LibrarySongBrowseModePreference.storageKey) == nil)
        #expect(LibrarySongBrowseModePreference.load(from: defaults) == .folder)
        #expect(defaults.string(forKey: LibrarySongBrowseModePreference.storageKey) == "folder")
    }

    @Test("An explicit flat choice survives a new defaults instance")
    func persistsFlatChoice() throws {
        let suiteName = "LibrarySongBrowseModePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LibrarySongBrowseModePreference.save(.flat, to: defaults)
        let reopened = try #require(UserDefaults(suiteName: suiteName))

        #expect(LibrarySongBrowseModePreference.load(from: reopened) == .flat)
    }

    @Test("Unknown persisted values migrate safely to folder mode")
    func repairsUnknownValue() throws {
        let suiteName = "LibrarySongBrowseModePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("legacy-flat-only", forKey: LibrarySongBrowseModePreference.storageKey)

        #expect(LibrarySongBrowseModePreference.load(from: defaults) == .folder)
        #expect(defaults.string(forKey: LibrarySongBrowseModePreference.storageKey) == "folder")
    }
}

private func testSong(
    id: String,
    title: String? = nil,
    path: String,
    sourceID: String
) -> Song {
    Song(
        id: id,
        title: title ?? id,
        duration: 180,
        fileFormat: .flac,
        filePath: path,
        sourceID: sourceID,
        dateAdded: Date(timeIntervalSince1970: 0)
    )
}
