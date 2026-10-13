import XCTest
@testable import PrimuseKit

/// The colour and symbol each listening space is drawn with, shared by the
/// app, Apple TV and the widgets.
final class ListeningSpaceAppearanceTests: XCTestCase {
    func testFixedTintsBelongToEverySpaceButMusic() {
        XCTAssertNil(ListeningSpace.music.fixedTint)
        let tints = [ListeningSpace.radio, .spokenWord, .podcast].compactMap(\.fixedTint)
        XCTAssertEqual(tints.count, 3)
        XCTAssertEqual(Set(tints.map(\.light)).count, 3)
        XCTAssertEqual(Set(tints.map(\.dark)).count, 3)
        let orange = ListeningSpaceTint.components(0xFF8000)
        XCTAssertEqual(orange.red, 1)
        XCTAssertEqual(orange.green, 128.0 / 255, accuracy: 0.0001)
        XCTAssertEqual(orange.blue, 0)
    }

    func testWidgetKindsBelongToTheirSpaces() {
        XCTAssertEqual(ListeningWidgetKind.radio.space, .radio)
        XCTAssertEqual(ListeningWidgetKind.podcast.space, .podcast)
        XCTAssertEqual(ListeningWidgetKind.recentPodcast.space, .podcast)
        XCTAssertEqual(ListeningSpace.podcast.systemImage, "antenna.radiowaves.left.and.right")
        XCTAssertEqual(ListeningSpace.spokenWord.systemImage, "books.vertical.fill")
    }

    func testListeningSpaceOfTheCurrentItem() {
        XCTAssertEqual(PlaybackState(currentSongID: "x", isPlaying: true, playbackKind: .liveRadio,
                                     radioStationID: "s").listeningSpace, .radio)
        let info = SpokenWordPlaybackInfo(skipBackwardSeconds: 15, skipForwardSeconds: 30)
        XCTAssertEqual(PlaybackState(currentSongID: "podcast:show:1", isPlaying: true, spokenWord: info).listeningSpace,
                       .podcast)
        XCTAssertEqual(PlaybackState(currentSongID: "chapter", isPlaying: true, spokenWord: info).listeningSpace,
                       .spokenWord)
        XCTAssertEqual(PlaybackState(currentSongID: "song", isPlaying: true).listeningSpace, .music)
    }
}
