import XCTest
@testable import PrimuseKit

/// What the radio, podcast and book widgets mark as playing, and the page a
/// tap outside their play keys opens.
final class ListeningWidgetPlaybackTests: XCTestCase {
    private func state(
        songID: String?,
        playing: Bool,
        kind: PlaybackKind? = nil,
        stationID: String? = nil,
        bookID: String? = nil
    ) -> PlaybackState {
        PlaybackState(
            currentSongID: songID,
            isPlaying: playing,
            playbackKind: kind,
            radioStationID: stationID,
            spokenWord: bookID.map {
                SpokenWordPlaybackInfo(skipBackwardSeconds: 15, skipForwardSeconds: 30, bookID: $0)
            }
        )
    }

    func testEpisodeWidgetsMarkTheEpisodePlayingAndNothingWhilePaused() {
        let episode = "podcast:show:1"
        XCTAssertEqual(ListeningWidgetKind.podcast.playingItemID(in: state(songID: episode, playing: true)), episode)
        XCTAssertEqual(ListeningWidgetKind.recentPodcast.playingItemID(in: state(songID: episode, playing: true)), episode)
        XCTAssertNil(ListeningWidgetKind.podcast.playingItemID(in: state(songID: episode, playing: false)))
        XCTAssertNil(ListeningWidgetKind.podcast.playingItemID(in: nil))
    }

    func testStationAndEpisodeWidgetsNeverMarkEachOther() {
        let radio = state(songID: "radio-song", playing: true, kind: .liveRadio, stationID: "station-1")
        XCTAssertEqual(ListeningWidgetKind.radio.playingItemID(in: radio), "station-1")
        XCTAssertNil(ListeningWidgetKind.podcast.playingItemID(in: radio))

        let episode = state(songID: "podcast:show:1", playing: true)
        XCTAssertNil(ListeningWidgetKind.radio.playingItemID(in: episode))
    }

    func testPlayingBookIsTheBookOfTheChapterPlaying() {
        XCTAssertEqual(state(songID: "chapter-3", playing: true, bookID: "book-a").playingSpokenWordBookID, "book-a")
        XCTAssertNil(state(songID: "chapter-3", playing: false, bookID: "book-a").playingSpokenWordBookID)
        XCTAssertNil(state(songID: "song", playing: true).playingSpokenWordBookID)
    }

    func testSnapshotsWrittenBeforeTheBookIDStillDecode() throws {
        let old = #"{"skipBackwardSeconds":15,"skipForwardSeconds":30,"bookTitle":"B"}"#
        let info = try JSONDecoder().decode(SpokenWordPlaybackInfo.self, from: Data(old.utf8))
        XCTAssertNil(info.bookID)
        XCTAssertEqual(info.bookTitle, "B")
    }

    func testSpaceLinksRoundTripAndIgnoreOtherLinks() throws {
        for space in ListeningSpace.allCases {
            let url = try XCTUnwrap(ListeningSpaceLink.url(for: space))
            XCTAssertEqual(ListeningSpaceLink.space(from: url), space)
        }
        XCTAssertEqual(ListeningSpaceLink.url(for: .radio)?.absoluteString, "primuse://open/radio")
        XCTAssertEqual(ListeningSpaceLink.space(from: try XCTUnwrap(URL(string: "PRIMUSE://OPEN/podcast"))), .podcast)
        for other in ["primuse://", "primuse://open", "primuse://open/unknown", "primuse://pair?host=1",
                      "primuse://add-source", "https://open/radio"] {
            XCTAssertNil(ListeningSpaceLink.space(from: try XCTUnwrap(URL(string: other))), other)
        }
    }
}
