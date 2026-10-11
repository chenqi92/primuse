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
    }

    private func song(sourceID: String) -> Song {
        Song(id: "song-" + sourceID, title: "Track", fileFormat: .flac, filePath: "/track.flac", sourceID: sourceID)
    }
}
