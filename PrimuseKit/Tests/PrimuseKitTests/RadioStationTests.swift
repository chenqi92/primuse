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

    @Test("Server mirrors preserve provenance without persisting credentials")
    func projectsServerMirrorPlayback() {
        let station = RadioStation(
            id: ServerRadioStationIdentity.stationID(sourceID: "jf", serverStationID: "radio-1"),
            name: "Server Radio",
            streamURL: "",
            sourceID: "jf",
            serverStationID: "radio-1",
            sourceName: "Jellyfin",
            sourcePlaybackPath: "/items/radio-1.mp3"
        )

        #expect(station.isServerMirror)
        #expect(station.requiresSourceStreamResolution)
        #expect(RadioStationValidation.hasConsistentServerIdentity(station))
        #expect(station.displayEndpoint == "Jellyfin")
        #expect(RadioStationValidation.hasValidPlaybackReference(station))
        #expect(station.playbackSong.sourceID == "jf")
        #expect(station.playbackSong.filePath == "/items/radio-1.mp3")
    }

    @Test("Server mirror identity must match its provenance")
    func rejectsInconsistentServerIdentity() {
        let station = RadioStation(
            id: "unrelated",
            name: "Server Radio",
            streamURL: "https://radio.example.com/live",
            sourceID: "source",
            serverStationID: "station"
        )

        #expect(station.isServerMirror)
        #expect(!RadioStationValidation.hasConsistentServerIdentity(station))
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

    @Test("Explicit station priority is stable and precedes legacy stations")
    func sortsByPriority() {
        let now = Date()
        let stations = [
            RadioStation(id: "legacy", name: "Legacy", streamURL: "https://radio.example/legacy", lastPlayedAt: now),
            RadioStation(id: "second", name: "Second", streamURL: "https://radio.example/second", sortOrder: 1),
            RadioStation(id: "first", name: "First", streamURL: "https://radio.example/first", sortOrder: 0)
        ]

        #expect(RadioStationOrdering.sorted(stations).map(\.id) == ["first", "second", "legacy"])
    }

    @Test("Legacy stations remain ordered by recency and then name")
    func sortsLegacyStations() {
        let now = Date()
        let stations = [
            RadioStation(id: "alpha", name: "Alpha", streamURL: "https://radio.example/alpha"),
            RadioStation(id: "recent", name: "Recent", streamURL: "https://radio.example/recent", lastPlayedAt: now),
            RadioStation(id: "beta", name: "Beta", streamURL: "https://radio.example/beta")
        ]

        #expect(RadioStationOrdering.sorted(stations).map(\.id) == ["recent", "alpha", "beta"])
    }

    @Test("Stations decode from snapshots created before priority was added")
    func decodesLegacyStation() throws {
        let data = try #require("""
        {
          "id": "legacy",
          "name": "Legacy Radio",
          "streamURL": "https://radio.example/live",
          "streamFormat": "automatic",
          "createdAt": 0,
          "modifiedAt": 0,
          "isDeleted": false
        }
        """.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let station = try decoder.decode(RadioStation.self, from: data)
        #expect(station.sortOrder == nil)
        #expect(station.sourceID == nil)
        #expect(!station.isServerMirror)
    }

    @Test("Server radio identities reconcile within one source")
    func reconcilesServerRadioIdentities() {
        let first = ServerRadioStationIdentity.stationID(sourceID: "src-a", serverStationID: "1")
        let second = ServerRadioStationIdentity.stationID(sourceID: "src-a", serverStationID: "2")
        let keep = ServerRadioReconciliationPolicy.mirrorIDsToKeep(
            sourceID: "src-a",
            serverStationIDs: [" 1 "],
            failedServerStationIDs: ["2"]
        )

        #expect(keep == [first, second])
        #expect(first.hasPrefix(ServerRadioStationIdentity.stationIDPrefix(sourceID: "src-a")))
        #expect(!first.hasPrefix(ServerRadioStationIdentity.stationIDPrefix(sourceID: "src-b")))
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
        #expect(state.updatedAt == nil)
        #expect(!state.isLiveStream)
    }
}
