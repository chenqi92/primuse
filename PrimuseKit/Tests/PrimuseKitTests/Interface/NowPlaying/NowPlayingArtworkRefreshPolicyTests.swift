import Foundation
import Testing
@testable import PrimuseKit

@Suite("Now Playing Artwork Refresh Policy")
struct NowPlayingArtworkRefreshPolicyTests {
    private typealias Policy = NowPlayingArtworkRefreshPolicy

    private func identity(
        ref: String? = "cover.jpg",
        source: String = "nas",
        path: String = "/Music/a.flac",
        format: String? = "flac"
    ) -> Policy.ArtworkIdentity {
        .init(songID: "song-1", artworkReference: ref, sourceID: source, filePath: path, fileFormat: format)
    }

    @Test("回填只改了标签时不重载封面")
    func metadataOnlyReplacementKeepsArtwork() {
        #expect(!Policy.replacementRequiresReload(previous: identity(), updated: identity()))
        #expect(!Policy.replacementRequiresReload(previous: identity(ref: ""), updated: identity(ref: nil)))
        #expect(!Policy.replacementRequiresReload(previous: identity(ref: " cover.jpg "), updated: identity()))
    }

    @Test("封面引用、来源、路径、格式变了要重载")
    func artworkIdentityChangeReloads() {
        #expect(Policy.replacementRequiresReload(previous: identity(), updated: identity(ref: "new.jpg")))
        #expect(Policy.replacementRequiresReload(previous: identity(ref: nil), updated: identity()))
        #expect(Policy.replacementRequiresReload(previous: identity(), updated: identity(source: "other")))
        #expect(Policy.replacementRequiresReload(previous: identity(), updated: identity(path: "/Music/b.flac")))
        #expect(Policy.replacementRequiresReload(previous: identity(), updated: identity(format: "mp3")))
        #expect(Policy.replacementRequiresReload(previous: nil, updated: identity()))
    }

    @Test("失效通知点名歌曲或封面引用才重载")
    func invalidationMatching() {
        #expect(Policy.invalidationTargetsSong(
            songID: "song-1", artworkReference: "cover.jpg",
            object: "song-1", tokens: [], isBroadcastToAll: false
        ))
        #expect(Policy.invalidationTargetsSong(
            songID: "song-1", artworkReference: "cover.jpg",
            object: nil, tokens: ["x", "cover.jpg"], isBroadcastToAll: false
        ))
        #expect(!Policy.invalidationTargetsSong(
            songID: "song-1", artworkReference: "cover.jpg",
            object: "song-2", tokens: ["other.jpg"], isBroadcastToAll: false
        ))
        #expect(!Policy.invalidationTargetsSong(
            songID: "song-1", artworkReference: nil,
            object: "", tokens: [""], isBroadcastToAll: false
        ))
    }

    @Test("全部失效不强制重载当前封面")
    func broadcastIsIgnored() {
        #expect(!Policy.invalidationTargetsSong(
            songID: "song-1", artworkReference: "cover.jpg",
            object: nil, tokens: [], isBroadcastToAll: true
        ))
    }
}
