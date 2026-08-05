import Foundation
import Testing
@testable import PrimuseKit

@Suite("Internet radio")
struct RadioStationTests {
    @Test("Only credential-free HTTP and HTTPS stream URLs are accepted")
    func validatesStreamURLs() {
        #expect(RadioStationValidation.normalizedURLString(" https://radio.example/live ") == "https://radio.example/live")
        #expect(RadioStationValidation.normalizedURLString("http://radio.example:8000/stream") != nil)
        #expect(RadioStationValidation.normalizedURLString("file:///tmp/stream.mp3") == nil)
        #expect(RadioStationValidation.normalizedURLString("ftp://radio.example/live") == nil)
        #expect(RadioStationValidation.normalizedURLString("https://user:secret@radio.example/live") == nil)
        #expect(!RadioStationValidation.isValid(name: "   ", urlString: "https://radio.example/live"))
    }

    @Test("Stream formats are inferred from URL and MIME type")
    func infersStreamFormat() throws {
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.m3u8"))) == .hls)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live")), mimeType: "audio/flac") == .flac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/mellow-flac"))) == .flac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.aac"))) == .aac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/aac-320"))) == .aac)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/live.mp3"))) == .mp3)
        #expect(RadioStreamFormat.inferred(from: try #require(URL(string: "https://radio.example/mp3-192"))) == .mp3)
    }

    @Test("A station projects a non-library synthetic playback item")
    func projectsPlaybackSong() {
        let station = RadioStation(
            id: "station-id",
            name: "Reference Radio",
            streamURL: "https://radio.example/live.flac",
            streamFormat: .flac,
            bitRate: 1_411_200
        )

        let song = station.playbackSong
        #expect(song.id == "radio:station-id")
        #expect(song.sourceID == RadioStation.playbackSourceID)
        #expect(song.duration == 0)
        #expect(song.fileSize == 0)
        #expect(song.fileFormat == .flac)
        #expect(song.artistName == "FLAC · 1411 kbps")
    }

    @Test("Live playback disables track-only presentation capabilities")
    func exposesLiveCapabilities() {
        let capabilities = PlaybackPresentationCapabilities.capabilities(for: .liveRadio)
        #expect(!capabilities.canSeek)
        #expect(!capabilities.supportsQueue)
        #expect(!capabilities.supportsLyrics)
        #expect(!capabilities.supportsLibraryActions)
        #expect(!capabilities.supportsPlaybackRate)
        #expect(!capabilities.supportsShuffleAndRepeat)
    }

    @Test("Playback state remains compatible with pre-radio snapshots")
    func decodesLegacyPlaybackState() throws {
        let data = try #require("""
        {
          "currentSongID": "song-id",
          "songTitle": "Song",
          "isPlaying": false,
          "currentTime": 12,
          "duration": 180,
          "queueSongIDs": ["song-id"]
        }
        """.data(using: .utf8))

        let state = try JSONDecoder().decode(PlaybackState.self, from: data)
        #expect(state.playbackKind == nil)
        #expect(state.radioStationID == nil)
        #expect(!state.isLiveStream)
    }
}
