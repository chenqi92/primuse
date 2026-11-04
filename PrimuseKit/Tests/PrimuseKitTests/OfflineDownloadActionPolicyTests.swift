import Testing
@testable import PrimuseKit

struct OfflineDownloadActionPolicyTests {
    @Test func localAudioDoesNotNeedDownloading() {
        for root in ["/Volumes/External/Music", "/Users/listener/Music", "/unmounted/Music"] {
            let source = MusicSource(id: "local", name: "Local", type: .local, basePath: root)
            let song = song(sourceID: source.id)
            #expect(!OfflineDownloadActionPolicy.allowsDownload(for: song, source: source))
        }
    }

    @Test func remoteAudioStillOffersDownloading() {
        for type in [MusicSourceType.webdav, .smb, .navidrome, .googleDrive] {
            let source = MusicSource(id: type.rawValue, name: "Remote", type: type)
            #expect(OfflineDownloadActionPolicy.allowsDownload(for: song(sourceID: source.id), source: source))
        }
    }

    @Test func localStreamDescriptorsStillOfferDownloadingTheirTarget() {
        let source = MusicSource(id: "local", name: "Local", type: .local)
        var descriptor = song(sourceID: source.id)
        descriptor.filePath = "/remote.STRM"
        #expect(OfflineDownloadActionPolicy.allowsDownload(for: descriptor, source: source))
    }

    @Test func appleLibrariesDoNotOfferDownloading() {
        for type in [MusicSourceType.appleMusic, .appleMusicLibrary] {
            let source = MusicSource(id: type.rawValue, name: "Music", type: type)
            #expect(!OfflineDownloadActionPolicy.allowsDownload(for: song(sourceID: source.id), source: source))
        }
        #expect(!OfflineDownloadActionPolicy.allowsDownload(
            for: song(sourceID: AppleMusicLibraryIdentity.sourceID), source: nil
        ))
    }

    @Test func unavailableSourcesAndUnplayableRowsDoNotOfferDownloading() {
        var source = MusicSource(id: "remote", name: "Remote", type: .webdav)
        let track = song(sourceID: source.id)
        #expect(!OfflineDownloadActionPolicy.allowsDownload(for: track, source: nil))
        source.isEnabled = false
        #expect(!OfflineDownloadActionPolicy.allowsDownload(for: track, source: source))
        source.isEnabled = true
        source.isDeleted = true
        #expect(!OfflineDownloadActionPolicy.allowsDownload(for: track, source: source))
        source.isDeleted = false
        #expect(!OfflineDownloadActionPolicy.allowsDownload(for: song(sourceID: "different"), source: source))
        var unplayable = track
        unplayable.filePath = ""
        #expect(!OfflineDownloadActionPolicy.allowsDownload(for: unplayable, source: source))
    }

    @Test func mixedSelectionDownloadsOnlyEligibleSongsInOrder() {
        let local = MusicSource(id: "local", name: "Local", type: .local)
        let remote = MusicSource(id: "remote", name: "Remote", type: .webdav)
        let music = MusicSource(id: "music", name: "Music", type: .appleMusic)
        let tracks = [song(sourceID: local.id), song(sourceID: remote.id), song(sourceID: music.id)]
        #expect(OfflineDownloadActionPolicy.downloadableSongs(in: tracks, sources: [local, remote, music]).map(\.id)
                == [tracks[1].id])
        #expect(OfflineDownloadActionPolicy.downloadableSongs(in: [tracks[0]], sources: [local]).isEmpty)
        #expect(OfflineDownloadActionPolicy.downloadableSongs(in: [], sources: [remote]).isEmpty)
        #expect(OfflineDownloadActionPolicy.containsDownloadableSong(in: tracks, sources: [local, remote, music]))
        #expect(!OfflineDownloadActionPolicy.containsDownloadableSong(in: [tracks[0], tracks[2]], sources: [local, remote, music]))
        #expect(!OfflineDownloadActionPolicy.containsDownloadableSong(in: [], sources: [remote]))
    }

    private func song(sourceID: String) -> Song {
        Song(id: "song-" + sourceID, title: "Track", fileFormat: .flac, filePath: "/track.flac", sourceID: sourceID)
    }
}

struct FolderOfflineDownloadRequestTests {
    private let source = MusicSource(id: "nas", name: "NAS", type: .smb)

    @Test func includesDescendantsWithoutSiblingsOrOtherSources() throws {
        let songs = [
            song("direct", path: "/Music/Live/one.flac"),
            song("nested", path: "/Music/Live/Disc 2/two.flac"),
            song("sibling", path: "/Music/Lively/three.flac"),
            song("other-source", path: "/Music/Live/four.flac", sourceID: "other")
        ]
        let request = try #require(request(songs: songs))
        #expect(Set(request.songs.map(\.id)) == ["direct", "nested"])
        #expect(request.songs.count == 2)
    }

    @Test func confirmationCountsOnlyCurrentDownloadableSongs() throws {
        let songs = [song("kept"), song("removed"), song("unplayable")]
        var lookup = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        lookup["removed"] = nil
        lookup["unplayable"]?.filePath = ""
        let request = try #require(request(songs: songs, lookup: lookup))
        #expect(request.songs.map(\.id) == ["kept"])
    }

    @Test func emptyUnavailableAndSystemMusicFoldersDoNotProduceRequests() {
        #expect(request(songs: []) == nil)
        let songs = [song("one")]
        var unavailable = source
        unavailable.isEnabled = false
        #expect(request(songs: songs, source: unavailable) == nil)
        unavailable.isEnabled = true
        unavailable.isDeleted = true
        #expect(request(songs: songs, source: unavailable) == nil)
        for type in [MusicSourceType.appleMusic, .appleMusicLibrary, .local] {
            #expect(request(songs: songs, source: MusicSource(id: "nas", name: "Music", type: type)) == nil)
        }
    }

    @Test func sourceRootIncludesAllItsFolders() throws {
        let songs = [song("a"), song("b", path: "/Music/Studio/b.flac")]
        let rootID = LibraryFolderNodeID(sourceID: "nas", kind: .source, normalizedRelativePath: "")
        let request = try #require(request(songs: songs, nodeID: rootID))
        #expect(Set(request.songs.map(\.id)) == ["a", "b"])
    }

    @Test func ownerIdentityIsStableAndSeparatesSourcesPathsAndNodeKinds() {
        let folder = folderID()
        let owner = FolderOfflineDownloadRequest.ownerID(for: folder)
        for _ in 0..<20 { #expect(FolderOfflineDownloadRequest.ownerID(for: folder) == owner) }
        let others = [
            folderID(sourceID: "other"), folderID(path: "/music/live/disc 2"),
            LibraryFolderNodeID(sourceID: "nas", kind: .scanRoot, normalizedRelativePath: "/music/live"),
            folderID(sourceID: "nas:folder", path: "live"), folderID(sourceID: "nas", path: "folder:live")
        ].map { FolderOfflineDownloadRequest.ownerID(for: $0) }
        #expect(Set(others + [owner]).count == others.count + 1)
    }

    @Test func cancellingOneFolderKeepsAnotherAndReplacementRegistered() async {
        let owner = FolderOfflineDownloadRequest.ownerID(for: folderID())
        let otherOwner = FolderOfflineDownloadRequest.ownerID(for: folderID(path: "/music/studio"))
        let first = Task { try? await Task.sleep(for: .seconds(60)) }
        let other = Task { try? await Task.sleep(for: .seconds(60)) }
        let replacement = Task { try? await Task.sleep(for: .seconds(60)) }
        defer { first.cancel(); other.cancel(); replacement.cancel() }
        var registry = KeyedRunRegistry<Task<Void?, Never>>()
        let oldRunID = registry.register(key: owner, value: first)
        registry.register(key: otherOwner, value: other)
        registry.cancelAndRemoveAll { $0 == owner }
        #expect(first.isCancelled)
        #expect(!other.isCancelled)
        registry.register(key: owner, value: replacement)
        #expect(registry.finish(key: owner, runID: oldRunID) == nil)
        #expect(registry.value(forKey: owner) != nil)
        #expect(registry.value(forKey: otherOwner) != nil)
    }

    private func folderID(sourceID: String = "nas", path: String = "/music/live") -> LibraryFolderNodeID {
        LibraryFolderNodeID(sourceID: sourceID, kind: .folder, normalizedRelativePath: path)
    }

    private func request(
        songs: [Song], lookup: [String: Song]? = nil,
        source: MusicSource? = nil, nodeID: LibraryFolderNodeID? = nil
    ) -> FolderOfflineDownloadRequest? {
        let index = LibraryFolderIndexBuilder.build(sources: [
            LibraryFolderSourceDescriptor(sourceID: "nas", displayName: "NAS", scanRoots: ["/Music"], pathSemantics: .hierarchical),
            LibraryFolderSourceDescriptor(sourceID: "other", displayName: "Other", scanRoots: ["/Music"], pathSemantics: .hierarchical)
        ], songs: songs)
        let lookup = lookup ?? Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return FolderOfflineDownloadRequest(
            nodeID: nodeID ?? folderID(), index: index, source: source ?? self.source,
            songForID: { lookup[$0] }
        )
    }

    private func song(_ id: String, path: String? = nil, sourceID: String = "nas") -> Song {
        Song(id: id, title: id, fileFormat: .flac, filePath: path ?? "/Music/Live/\(id).flac", sourceID: sourceID)
    }
}
