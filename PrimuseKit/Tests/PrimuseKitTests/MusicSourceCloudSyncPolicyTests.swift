import Foundation
import Testing
@testable import PrimuseKit

struct MusicSourceCloudSyncPolicyTests {
    @Test func deviceLocalSourcesAreExcludedFromCloudSync() {
        let filesImport = MusicSource(name: "iPhone files", type: .local)
        let musicAppLibrary = MusicSource(name: "Music.app", type: .appleMusicLibrary)
        let synology = MusicSource(name: "NAS", type: .synology)
        let appleMusic = MusicSource(name: "Apple Music", type: .appleMusic)

        #expect(!MusicSourceCloudSyncPolicy.isEligible(filesImport))
        #expect(!MusicSourceCloudSyncPolicy.isEligible(musicAppLibrary))
        #expect(MusicSourceCloudSyncPolicy.isEligible(synology))
        #expect(MusicSourceCloudSyncPolicy.isEligible(appleMusic))
        #expect(
            MusicSourceCloudSyncPolicy.eligibleSources([
                filesImport,
                synology,
                musicAppLibrary,
                appleMusic,
            ]).map(\.id) == [synology.id, appleMusic.id]
        )

        let ownedImport = MusicSource(id: "owned", name: "Owned", type: .local)
        let foreignImport = MusicSource(id: "foreign", name: "Foreign", type: .local)
        #expect(
            MusicSourceCloudSyncPolicy.foreignDeviceLocalSourceIDs(
                in: [ownedImport, foreignImport, synology],
                ownedSourceIDs: [ownedImport.id]
            ) == [foreignImport.id]
        )
    }

    @Test func localHandshakeGetsDeadlineOnlyWhenRemoteFallbackExists() {
        #expect(
            SourceConnectionHandshakePolicy.timeout(
                for: .localAddress,
                availableKinds: [.localAddress, .publicAddress]
            ) == SourceConnectionHandshakePolicy.localFallbackTimeout
        )
        #expect(
            SourceConnectionHandshakePolicy.timeout(
                for: .localAddress,
                availableKinds: [.localAddress, .vendorRemote]
            ) == SourceConnectionHandshakePolicy.localFallbackTimeout
        )
        #expect(
            SourceConnectionHandshakePolicy.timeout(
                for: .localAddress,
                availableKinds: [.localAddress]
            ) == nil
        )
        #expect(
            SourceConnectionHandshakePolicy.timeout(
                for: .publicAddress,
                availableKinds: [.localAddress, .publicAddress]
            ) == nil
        )
    }
}
