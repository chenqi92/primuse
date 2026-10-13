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

    func testTintChoiceRoundTripsThroughItsStoredValue() {
        let choices: [ListeningSpaceTintChoice] = [.standard, .theme, .artwork, .fixed("C25E0C")]
        for choice in choices {
            XCTAssertEqual(ListeningSpaceTintChoice(storedValue: choice.storedValue), choice)
        }
        XCTAssertEqual(ListeningSpaceTintChoice(storedValue: nil), .standard)
        XCTAssertEqual(ListeningSpaceTintChoice(storedValue: " #c25e0c "), .fixed("C25E0C"))
        XCTAssertEqual(ListeningSpaceTintChoice(storedValue: "orange"), .standard)
        XCTAssertEqual(ListeningSpaceTintChoice(storedValue: "12345"), .standard)
        XCTAssertEqual(ListeningSpaceTintChoice.fixed("FF9500").fixedHex, "FF9500")
        XCTAssertNil(ListeningSpaceTintChoice.theme.fixedHex)
    }

    func testTintChoicesAreKeptPerSpaceAndMusicHasNone() throws {
        let suite = "ListeningSpaceTintPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ListeningSpaceTintPreferences.choice(for: .radio, in: defaults), .standard)
        ListeningSpaceTintPreferences.store(.fixed("E8453C"), for: .radio, in: defaults)
        ListeningSpaceTintPreferences.store(.artwork, for: .podcast, in: defaults)
        XCTAssertEqual(ListeningSpaceTintPreferences.choice(for: .radio, in: defaults), .fixed("E8453C"))
        XCTAssertEqual(ListeningSpaceTintPreferences.choice(for: .podcast, in: defaults), .artwork)
        XCTAssertEqual(ListeningSpaceTintPreferences.choice(for: .spokenWord, in: defaults), .standard)

        // Back to the space's own hue leaves nothing behind.
        ListeningSpaceTintPreferences.store(.standard, for: .radio, in: defaults)
        XCTAssertNil(defaults.object(forKey: ListeningSpaceTintPreferences.key(for: .radio)))

        ListeningSpaceTintPreferences.store(.fixed("E8453C"), for: .music, in: defaults)
        XCTAssertNil(defaults.object(forKey: ListeningSpaceTintPreferences.key(for: .music)))
        XCTAssertEqual(ListeningSpaceTintPreferences.choice(for: .music, in: defaults), .theme)
    }

    func testPickedColoursReadOnBothAppearances() throws {
        func rgb(_ hex: UInt32) -> ThemeAccentContrastPolicy.RGB {
            let parts = ListeningSpaceTint.components(hex)
            return ThemeAccentContrastPolicy.RGB(red: parts.red, green: parts.green, blue: parts.blue)
        }
        // Orange and amber are far too pale on white as picked.
        for hex in ["FF9500", "D4A017", "2AAA8A", "0A84FF", "5E5CE6"] {
            let tint = try XCTUnwrap(ListeningSpaceTint.legible(hex: hex))
            XCTAssertGreaterThanOrEqual(
                ThemeAccentContrastPolicy.contrastRatio(rgb(tint.light), .white), 4.5, hex
            )
            XCTAssertGreaterThanOrEqual(
                ThemeAccentContrastPolicy.contrastRatio(rgb(tint.dark), .black), 4.5, hex
            )
        }
        // A colour that already reads is kept as picked.
        XCTAssertEqual(ListeningSpaceTint.legible(hex: "147D8A")?.light, 0x147D8A)
        // White is near-black in light appearance, white in dark.
        XCTAssertEqual(ListeningSpaceTint.legible(hex: "FFFFFF"), ListeningSpaceTint(light: 0x1C1C1C, dark: 0xFFFFFF))
        XCTAssertNil(ListeningSpaceTint.legible(hex: "XYZ123"))
        XCTAssertNil(ListeningSpaceTint.legible(hex: "FFF"))
    }
}
