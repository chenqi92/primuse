import Foundation
import Testing
@testable import PrimuseKit

/// DL4:一首一首喂的艺人头像累计与整库 `computeAlbumsAndArtists` 的艺人一段逐个艺人相同(id 与 thumbnailPath)。
@Suite("Library artist thumbnail accumulator")
struct LibraryArtistThumbnailAccumulatorTests {
    static let unknownArtist = "Unknown Artist"

    private static func automatic(_ entries: [(name: String, reference: String)]) -> String? {
        AutomaticArtistArtworkReference.make(entries: entries.map {
            .init(
                normalizedArtistName: SourceArtistArtworkCatalog.normalizedArtistName($0.name),
                reference: $0.reference,
                cacheDiscriminator: "d-\($0.reference)"
            )
        })
    }

    private static func song(
        _ index: Int, artist: String?, sourceNames: [String]? = nil, artistID: String? = nil,
        artwork: String? = nil, source: String = "src"
    ) -> Song {
        Song(
            id: "s\(index)", title: "T\(index)", artistID: artistID, albumTitle: "Album \(index % 5)",
            artistName: artist, sourceArtistNames: sourceNames, fileFormat: .flac,
            filePath: "/m/\(index).flac", sourceID: source, artistArtworkFileName: artwork
        )
    }

    /// 刻意凑出的几种:同一艺人的写法不同(第一次出现的名字决定自动头像查哪个名字)、合唱、源给的多位艺人、
    /// 头像只在后面的歌上、第一首的头像引用做不出来(源 id 为空)、自动头像只对其中一位、未知艺人、受保护的名字。
    static let crafted: [Song] = [
        song(0, artist: "Ada"),
        song(1, artist: "ADA", artwork: "ada-late.jpg"),
        song(2, artist: "Ａｄａ", artwork: automatic([("Ａｄａ", "ada-auto")])),
        song(3, artist: "Ben、Cy", artwork: "ben-cy.jpg"),
        song(4, artist: "Cy", artwork: automatic([("Cy", "cy-auto"), ("Ben", "ben-auto")])),
        song(5, artist: "Dee", artwork: "dee.jpg", source: ""),
        song(6, artist: "Dee", artwork: "dee-2.jpg"),
        song(7, artist: nil, artwork: "unknown.jpg"),
        song(8, artist: "AC/DC", artwork: "acdc.jpg"),
        song(9, artist: "Eve", sourceNames: ["Eve", "Fay"], artwork: automatic([("Fay", "fay-auto")])),
        song(10, artist: "Fay", artwork: "fay.jpg"),
        song(11, artist: "Gus", artistID: "native-gus", artwork: "gus.jpg"),
        song(12, artist: "Gus / Hal", artistID: "native-gus-hal"),
        song(13, artist: "Hal", artwork: automatic([("Somebody", "x")])),
        song(14, artist: "Hal", artwork: "hal.jpg"),
        song(15, artist: "  ada  ", artwork: "ada-spaces.jpg"),
    ]

    private static func reference(_ songs: [Song], _ configuration: ArtistNameConfiguration) -> [String: String?] {
        let artists = LibraryGroupingReference.computeAlbumsAndArtists(
            songs: songs, configuration: configuration, unknownArtist: unknownArtist
        ).artists
        var result: [String: String?] = [:]
        for artist in artists { result[artist.id] = artist.thumbnailPath }
        return result
    }

    private static func accumulated(_ songs: [Song], _ configuration: ArtistNameConfiguration) -> [String: String?] {
        var accumulator = LibraryGroupingReference.ArtistThumbnailAccumulator(
            configuration: configuration, unknownArtist: unknownArtist
        )
        for song in songs { accumulator.include(song) }
        var result: [String: String?] = [:]
        for artist in accumulator.artists { result[artist.id] = artist.thumbnailPath }
        #expect(accumulator.artistCount == result.count)
        return result
    }

    @Test("Crafted cases, in order and reversed, under two configurations")
    func crafted() {
        let separatorsOnly = ArtistNameConfiguration(separators: ["/"], protectedNames: [], displaySeparator: " / ")
        for configuration in [ArtistNameConfiguration.defaultValue, separatorsOnly] {
            for songs in [Self.crafted, Array(Self.crafted.reversed())] {
                let expected = Self.reference(songs, configuration)
                #expect(!expected.isEmpty)
                #expect(expected.values.contains { $0 != nil }, "some artists have a thumbnail")
                #expect(Self.accumulated(songs, configuration) == expected)
            }
        }
    }

    @Test("A generated library of 2,000 songs")
    func generated() {
        var songs: [Song] = []
        for index in 0..<2_000 {
            let main = index % 37
            let names = ["Artist \(main)", "artist \(main)", "Ａｒｔｉｓｔ \(main)"]
            var artist = names[index % 3]
            if index % 11 == 0 { artist += "、Guest \(index % 7)" }
            let artwork: String?
            switch index % 9 {
            case 0: artwork = "plain-\(index).jpg"
            case 1: artwork = Self.automatic([("Guest \(index % 7)", "guest-\(index)"), (artist, "main-\(index)")])
            case 2: artwork = Self.automatic([(names[(index + 1) % 3], "other-form-\(index)")])
            default: artwork = nil
            }
            songs.append(Self.song(index, artist: index % 101 == 0 ? nil : artist,
                                   sourceNames: index % 13 == 0 ? [artist, "Side \(index % 5)"] : nil,
                                   artwork: artwork, source: index % 17 == 0 ? "" : "src-\(index % 3)"))
        }
        let expected = Self.reference(songs, .defaultValue)
        #expect(expected.count > 40)
        #expect(Self.accumulated(songs, .defaultValue) == expected)
    }
}
