import Foundation
import Testing
@testable import PrimuseKit

@Suite("Album grouping policy")
struct AlbumGroupingPolicyTests {
    @Test("共同专辑按专辑艺术家合并不同曲目艺术家")
    func compilationUsesAlbumArtist() throws {
        let first = try #require(AlbumGroupingPolicy.identity(
            albumTitle: "Together",
            albumArtistName: "Various Artists",
            trackArtistName: "Artist A",
            unknownArtistName: "Unknown Artist"
        ))
        let second = try #require(AlbumGroupingPolicy.identity(
            albumTitle: "Together",
            albumArtistName: "Various Artists",
            trackArtistName: "Artist B",
            unknownArtistName: "Unknown Artist"
        ))

        #expect(first == second)
    }

    @Test("无专辑艺术家时保留原有曲目艺术家分组")
    func trackArtistRemainsFallback() throws {
        let first = try #require(AlbumGroupingPolicy.identity(
            albumTitle: "Shared Name",
            albumArtistName: nil,
            trackArtistName: "Artist A",
            unknownArtistName: "Unknown Artist"
        ))
        let second = try #require(AlbumGroupingPolicy.identity(
            albumTitle: "Shared Name",
            albumArtistName: nil,
            trackArtistName: "Artist B",
            unknownArtistName: "Unknown Artist"
        ))

        #expect(first != second)
    }

    @Test("完整读取后记录曲目艺术家作为专辑艺术家兜底")
    func resolvedAlbumArtistFallback() {
        #expect(AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: "Various Artists",
            trackArtistName: "Artist A"
        ) == "Various Artists")
        #expect(AlbumGroupingPolicy.resolvedAlbumArtistName(
            albumArtistName: nil,
            trackArtistName: "Artist A"
        ) == "Artist A")
    }

    @Test("曲目艺术家兜底随艺术家更新且显式专辑艺术家保持不变")
    func trackArtistFallbackFollowsEdits() {
        #expect(AlbumGroupingPolicy.updatedAlbumArtistName(
            existingAlbumArtistName: "Artist A",
            previousTrackArtistName: "artist a",
            updatedTrackArtistName: "Artist B"
        ) == "Artist B")
        #expect(AlbumGroupingPolicy.updatedAlbumArtistName(
            existingAlbumArtistName: "Various Artists",
            previousTrackArtistName: "Artist A",
            updatedTrackArtistName: "Artist B"
        ) == "Various Artists")
    }

    @Test("旧歌曲仅在存在专辑且尚未读取专辑艺术家时刷新")
    func legacyRowsRequireOneRefresh() {
        #expect(AlbumGroupingPolicy.requiresMetadataRefresh(
            albumTitle: "Together",
            albumArtistName: nil,
            metadataInspectionComplete: false
        ))
        #expect(!AlbumGroupingPolicy.requiresMetadataRefresh(
            albumTitle: "Together",
            albumArtistName: "Artist A",
            metadataInspectionComplete: false
        ))
        #expect(!AlbumGroupingPolicy.requiresMetadataRefresh(
            albumTitle: nil,
            albumArtistName: nil,
            metadataInspectionComplete: false
        ))
        #expect(!AlbumGroupingPolicy.requiresMetadataRefresh(
            albumTitle: "Together",
            albumArtistName: nil,
            metadataInspectionComplete: true
        ))
    }

    @Test("旧版歌曲 JSON 缺少专辑艺术家时仍可解码")
    func legacySongJSONRemainsDecodable() throws {
        let json = #"{"id":"song","title":"Track","albumTitle":"Together","artistName":"Artist A","duration":1,"fileFormat":"mp3","filePath":"track.mp3","sourceID":"source","fileSize":1,"dateAdded":0}"#.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let song = try decoder.decode(Song.self, from: json)

        #expect(song.albumArtistName == nil)
    }
}
