import Foundation
import Testing
@testable import PrimuseKit

struct CarPlayListRefreshPolicyTests {
    private func state(
        songID: String? = "song-a",
        currentIndex: Int = 3,
        isPlaying: Bool = true,
        shuffleEnabled: Bool = false,
        repeatMode: String = "off",
        radioMetadataTitle: String? = nil
    ) -> CarPlayPlayerState {
        CarPlayPlayerState(
            songID: songID,
            songTitle: songID,
            isPlaying: isPlaying,
            shuffleEnabled: shuffleEnabled,
            repeatModeRawValue: repeatMode,
            currentIndex: currentIndex,
            radioMetadataTitle: radioMetadataTitle
        )
    }

    @Test("Root and detail lists only rebuild when the playing song or station changes")
    func listsIgnoreTransportAndOrderChanges() {
        let base = state()
        #expect(CarPlayListRefreshPolicy.listsNeedRebuild(from: nil, to: base))
        #expect(!CarPlayListRefreshPolicy.listsNeedRebuild(from: base, to: state(isPlaying: false)))
        #expect(!CarPlayListRefreshPolicy.listsNeedRebuild(from: base, to: state(shuffleEnabled: true)))
        #expect(!CarPlayListRefreshPolicy.listsNeedRebuild(from: base, to: state(repeatMode: "all")))
        #expect(!CarPlayListRefreshPolicy.listsNeedRebuild(from: base, to: state(currentIndex: 4)))
        #expect(CarPlayListRefreshPolicy.listsNeedRebuild(from: base, to: state(songID: "song-b")))
    }

    @Test("The Up Next page also follows queue position, shuffle and repeat")
    func queuePageFollowsOrderChanges() {
        let base = state()
        #expect(CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: nil, to: base))
        #expect(!CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: base))
        #expect(!CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: state(isPlaying: false)))
        #expect(!CarPlayListRefreshPolicy.queuePageNeedsRebuild(
            from: base, to: state(radioMetadataTitle: "Live title")
        ))
        #expect(CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: state(currentIndex: 4)))
        #expect(CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: state(shuffleEnabled: true)))
        #expect(CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: state(repeatMode: "all")))
        #expect(CarPlayListRefreshPolicy.queuePageNeedsRebuild(from: base, to: state(songID: "song-b")))
    }
}
