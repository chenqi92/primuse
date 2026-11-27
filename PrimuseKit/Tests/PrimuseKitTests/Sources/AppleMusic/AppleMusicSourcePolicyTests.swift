import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music source policy")
struct AppleMusicSourcePolicyTests {
    @Test("Only a live source record counts as added")
    func installedIgnoresMissingAndDeletedRecords() {
        #expect(AppleMusicSourcePolicy.isInstalled(
            activeSourceIDs: ["nas-1", AppleMusicSourcePolicy.sourceID]
        ))
        #expect(!AppleMusicSourcePolicy.isInstalled(activeSourceIDs: ["nas-1"]))
        #expect(!AppleMusicSourcePolicy.isInstalled(activeSourceIDs: []))
        #expect(AppleMusicSourcePolicy.sourceID == AppleMusicLibraryIdentity.sourceID)
    }

    @Test("Removing the source stops the sync, not only disabling it")
    func syncRequiresAnInstalledEnabledSource() {
        #expect(AppleMusicSourcePolicy.isSyncable(
            isInstalled: true,
            isSourceEnabled: true,
            isSyncPreferenceEnabled: true
        ))
        // 源被移除后继续同步,拉回来的歌会被启动对账当成孤儿再删一次。
        #expect(!AppleMusicSourcePolicy.isSyncable(
            isInstalled: false,
            isSourceEnabled: true,
            isSyncPreferenceEnabled: true
        ))
        #expect(!AppleMusicSourcePolicy.isSyncable(
            isInstalled: true,
            isSourceEnabled: false,
            isSyncPreferenceEnabled: true
        ))
        #expect(!AppleMusicSourcePolicy.isSyncable(
            isInstalled: true,
            isSourceEnabled: true,
            isSyncPreferenceEnabled: false
        ))
    }

    @Test("Removal takes the library mirror and every user playlist mirror")
    func mirrorPlaylistIDsCoverBothMirrorKinds() {
        let userMirror = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.abc123"
        let otherUserMirror = AppleMusicLibraryIdentity.userPlaylistIDPrefix + "p.def456"
        let serverMirror = ServerPlaylistIdentity.playlistIDPrefix(sourceID: "nas-1") + "42"
        let handMade = "user-made-playlist"

        let removed = AppleMusicSourcePolicy.mirrorPlaylistIDs(in: [
            AppleMusicLibraryIdentity.systemPlaylistID,
            userMirror,
            otherUserMirror,
            serverMirror,
            handMade,
        ])

        #expect(removed == [
            AppleMusicLibraryIdentity.systemPlaylistID,
            userMirror,
            otherUserMirror,
        ])
        // 用户自建歌单和别的源的镜像不能被牵连。
        #expect(!removed.contains(handMade))
        #expect(!removed.contains(serverMirror))
        #expect(AppleMusicSourcePolicy.mirrorPlaylistIDs(in: [String]()).isEmpty)
    }
}
