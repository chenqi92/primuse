import Foundation
import Testing
@testable import PrimuseKit

@Test func splitsDefaultSemicolonArtistText() {
    let names = ArtistNameParser.names(rawName: "周杰伦; 潘儿")

    #expect(names == ["周杰伦", "潘儿"])
    #expect(ArtistNameParser.displayName(rawName: "周杰伦; 潘儿") == "周杰伦 / 潘儿")
}

@Test func acceptsFullWidthDefaultSeparatorAndDeduplicatesNames() {
    let names = ArtistNameParser.names(rawName: "A； B; a")

    #expect(names == ["A", "B"])
}

@Test func splitsDefaultSlashAndIdeographicCommaArtistText() {
    #expect(ArtistNameParser.names(rawName: "周杰伦/费玉清") == ["周杰伦", "费玉清"])
    #expect(ArtistNameParser.names(rawName: "周杰伦、费玉清") == ["周杰伦", "费玉清"])
}

@Test func defaultProtectedNameKeepsSlashedBandTogether() {
    #expect(ArtistNameParser.names(rawName: "AC/DC") == ["AC/DC"])
    #expect(ArtistNameParser.names(rawName: "AC/DC/周杰伦") == ["AC/DC", "周杰伦"])
}

@Test func configuredSeparatorsMatchWidthVariants() {
    let configuration = ArtistNameConfiguration(
        separators: [";", "；", "/", ",", "&"],
        protectedNames: [],
        displaySeparator: " / "
    )
    #expect(ArtistNameParser.names(rawName: "蒋志光，罗大佑", configuration: configuration)
        == ["蒋志光", "罗大佑"])
    #expect(ArtistNameParser.names(rawName: "Artist＆Guest", configuration: configuration)
        == ["Artist", "Guest"])
    #expect(ArtistNameParser.names(rawName: "Ａ／Ｂ", configuration: configuration) == ["Ａ", "Ｂ"])
    #expect(ArtistNameParser.displayName(rawName: "Artist＆Guest，Third", configuration: configuration)
        == "Artist / Guest / Third")
}

@Test func fullWidthConfiguredSeparatorsAlsoMatchHalfWidthText() {
    let configuration = ArtistNameConfiguration(
        separators: ["＆", "，"], protectedNames: [], displaySeparator: " / "
    )
    #expect(ArtistNameParser.names(rawName: "Artist&Guest,Third", configuration: configuration)
        == ["Artist", "Guest", "Third"])
}

@Test func separatorWidthVariantsUseTheSameMatchingRules() {
    for (halfWidth, fullWidth) in [(";", "；"), ("/", "／"), (",", "，"), ("&", "＆"), ("､", "、")] {
        for (rule, input) in [(halfWidth, fullWidth), (fullWidth, halfWidth)] {
            let configuration = ArtistNameConfiguration(
                separators: [rule], protectedNames: [], displaySeparator: " / "
            )
            #expect(ArtistNameParser.names(rawName: "One\(input)Two", configuration: configuration)
                == ["One", "Two"])
        }
    }
}

@Test func widthMatchingHonorsProtectedNamesAndUnconfiguredSymbols() {
    let configuration = ArtistNameConfiguration(
        separators: ["&", ","], protectedNames: ["接个吻，开一枪"], displaySeparator: " / "
    )
    #expect(ArtistNameParser.names(rawName: "接个吻,开一枪＆Guest", configuration: configuration)
        == ["接个吻,开一枪", "Guest"])
    #expect(ArtistNameParser.names(rawName: "Artist、Guest", configuration: configuration)
        == ["Artist、Guest"])
    #expect(ArtistNameParser.names(rawName: "Artist/Guest", configuration: configuration)
        == ["Artist/Guest"])
}

@Test func separatorWidthMatchingInvalidatesPreviouslyDerivedIndexes() {
    let configuration = ArtistNameConfiguration(
        separators: ["&", ","], protectedNames: [], displaySeparator: " / "
    )
    let previousSignature = "1:1|3: / |1:&|1:,|1:\u{1F}"
    #expect(configuration.cacheSignature != previousSignature)
}

@Test func preservesAuthoritativeNativeArtistBoundaries() {
    let configuration = ArtistNameConfiguration(
        separators: ["/", "&", ";"],
        protectedNames: [],
        displaySeparator: " + "
    )

    let names = ArtistNameParser.names(
        rawName: "AC/DC & Simon & Garfunkel",
        sourceNames: ["AC/DC", "Simon & Garfunkel"],
        configuration: configuration
    )

    #expect(names == ["AC/DC", "Simon & Garfunkel"])
    #expect(ArtistNameParser.displayName(
        rawName: nil,
        sourceNames: ["AC/DC", "Simon & Garfunkel"],
        configuration: configuration
    ) == "AC/DC + Simon & Garfunkel")
}

@Test func protectedNameWinsBeforeConfiguredSeparator() {
    let configuration = ArtistNameConfiguration(
        separators: ["/", ";"],
        protectedNames: ["AC/DC"],
        displaySeparator: " / "
    )

    #expect(ArtistNameParser.names(
        rawName: "AC/DC; Guest",
        configuration: configuration
    ) == ["AC/DC", "Guest"])
}

@Test func matchesLongestRuleFirstAndIgnoresEmptyFragments() {
    let configuration = ArtistNameConfiguration(
        separators: ["feat.", "feat", ";"],
        protectedNames: [],
        displaySeparator: " · "
    )

    #expect(ArtistNameParser.names(
        rawName: "Artist feat. Guest;; Third",
        configuration: configuration
    ) == ["Artist", "Guest", "Third"])
}

@Test func emptySeparatorListDisablesTextSplitting() {
    let configuration = ArtistNameConfiguration(
        separators: [],
        protectedNames: [],
        displaySeparator: " / "
    )

    #expect(ArtistNameParser.names(
        rawName: "One; Two",
        configuration: configuration
    ) == ["One; Two"])
}

@Test func artistConfigurationNormalizesAndRoundTrips() throws {
    let value = ArtistNameConfiguration(
        separators: [" ; ", ";", "；", ""],
        protectedNames: [" AC/DC ", "ac/dc", ""],
        displaySeparator: " · "
    ).normalized()

    #expect(value.separators == [";", "；"])
    #expect(value.protectedNames == ["AC/DC"])
    #expect(value.displaySeparator == " · ")

    let data = try JSONEncoder().encode(value)
    #expect(try JSONDecoder().decode(ArtistNameConfiguration.self, from: data) == value)
    #expect(value.cacheSignature == value.cacheSignature)
}

@Test func futureArtistConfigurationIsRecognizedAsUnsupported() {
    let value = ArtistNameConfiguration(
        schemaVersion: ArtistNameConfiguration.currentSchemaVersion + 1,
        separators: [";"],
        protectedNames: [],
        displaySeparator: " / "
    )

    #expect(!value.isSupported)
}

@Test func collaborationAlbumSettingDefaultsOffForExistingRulesAndPersists() throws {
    let data = Data(#"{"schemaVersion":1,"separators":["|"],"protectedNames":["AC/DC"],"displaySeparator":" + "}"#.utf8)
    var value = try JSONDecoder().decode(ArtistNameConfiguration.self, from: data)
    #expect(!value.mergesCollaborativeAlbums)
    #expect(value.separators == ["|"])
    let originalSignature = value.cacheSignature
    value.mergesCollaborativeAlbums = true
    let restored = try JSONDecoder().decode(ArtistNameConfiguration.self, from: value.encodedData())
    #expect(restored.mergesCollaborativeAlbums)
    #expect(restored.cacheSignature != originalSignature)
    #expect(restored.protectedNames == ["AC/DC"])
    value.mergesCollaborativeAlbums = false
    #expect(value.cacheSignature == originalSignature)
}

@Test func songSnapshotsFromOlderVersionsDecodeWithoutNativeArtists() throws {
    let original = Song(
        id: "legacy",
        title: "Legacy",
        artistName: "Artist A; Artist B",
        fileFormat: .mp3,
        filePath: "/legacy.mp3",
        sourceID: "source"
    )
    let encoded = try JSONEncoder().encode(original)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "sourceArtistNames")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(Song.self, from: legacyData)
    #expect(decoded.sourceArtistNames == nil)
    #expect(decoded.effectiveArtistNames() == ["Artist A", "Artist B"])
}
