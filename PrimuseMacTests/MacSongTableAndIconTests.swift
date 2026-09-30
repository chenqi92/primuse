import AppKit
import XCTest
@testable import Primuse

@MainActor
final class MacSongTableAndIconTests: XCTestCase {
    func testExistingColumnPreferencesRecoverUnknownAndDuplicateValues() throws {
        let defaults = try fixtureDefaults()
        defaults.set(["artist", "removed-column"], forKey: "library.macSongTable.visibleColumns.v1")
        defaults.set(["album", "album", "removed-column", "title"], forKey: "library.macSongTable.columnOrder.v1")
        defaults.set(["title": 900, "artist": -1], forKey: "library.macSongTable.columnWidths.v1")

        let layout = MacSongTableLayout(scope: .library, defaults: defaults)
        XCTAssertEqual(layout.visibleColumns, [.title, .artist])
        XCTAssertEqual(Array(layout.columnOrder.prefix(2)), [.album, .title])
        XCTAssertEqual(Set(layout.columnOrder).count, MacSongsColumn.allCases.count)
        XCTAssertEqual(layout.width(.title), 520)
        XCTAssertEqual(layout.width(.artist), MacSongsColumn.artist.minimumWidth)
        layout.resize(.title, to: .nan)
        XCTAssertEqual(layout.width(.title), MacSongsColumn.title.defaultWidth)
    }

    func testPlaylistColumnsPersistIndependentlyFromLibrary() throws {
        let defaults = try fixtureDefaults()
        let library = MacSongTableLayout(scope: .library, defaults: defaults)
        let playlist = MacSongTableLayout(scope: .playlist, defaults: defaults)
        playlist.toggle(.album)
        playlist.move(.duration, relativeTo: .title, after: false)
        playlist.resize(.title, to: 350)
        playlist.saveWidths()
        playlist.showsHeader = false

        let restored = MacSongTableLayout(scope: .playlist, defaults: defaults)
        XCTAssertFalse(restored.visibleColumns.contains(.album))
        XCTAssertEqual(restored.activeColumns.first, .duration)
        XCTAssertEqual(restored.width(.title), 350)
        XCTAssertFalse(restored.showsHeader)
        XCTAssertTrue(library.visibleColumns.contains(.album))
        XCTAssertEqual(library.width(.title), MacSongsColumn.title.defaultWidth)
        XCTAssertTrue(library.showsHeader)
        restored.toggle(.title)
        XCTAssertTrue(restored.visibleColumns.contains(.title))
        restored.reset()
        let reset = MacSongTableLayout(scope: .playlist, defaults: defaults)
        XCTAssertTrue(reset.showsHeader)
        XCTAssertEqual(reset.visibleColumns, [.title, .artist, .album, .format, .duration, .plays, .source])
    }

    func testResizeOnlyChangesSelectedColumnAndKeepsReorderedHiddenColumns() throws {
        let defaults = try fixtureDefaults()
        let layout = MacSongTableLayout(scope: .library, defaults: defaults)
        layout.toggle(.artist)
        layout.move(.artist, relativeTo: .duration, after: true)
        let widthBefore = layout.contentWidth(ordinalWidth: 48)
        let albumWidth = layout.width(.album)
        layout.resize(.title, to: layout.width(.title) + 40)
        XCTAssertEqual(layout.contentWidth(ordinalWidth: 48) - widthBefore, 40)
        XCTAssertEqual(layout.width(.album), albumWidth)
        layout.toggle(.artist)
        let durationIndex = try XCTUnwrap(layout.activeColumns.firstIndex(of: .duration))
        XCTAssertEqual(layout.activeColumns[durationIndex + 1], .artist)
    }

    func testDockIconsResolveExplicitAppearanceInsteadOfCachedNSImageAppearance() throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        defer { NSApp.appearance = previous }
        for icon in MacAppIcon.all {
            let light = try XCTUnwrap(MacAppIcon.dockIconImage(
                previewAsset: icon.previewAsset, appearance: NSAppearance(named: .aqua)
            )?.tiffRepresentation)
            let dark = try XCTUnwrap(MacAppIcon.dockIconImage(
                previewAsset: icon.previewAsset, appearance: NSAppearance(named: .darkAqua)
            )?.tiffRepresentation)
            XCTAssertNotEqual(light, dark, "\(icon.id) must render its dark asset without restarting")
        }
    }

    func testApplicationAppearanceChangeRefreshesDockIconWithoutViewCallbacks() async throws {
        let preferences = MacUIPreferences.shared
        let previousAppearance = NSApp.appearance
        let previousIcon = preferences.appIconID
        defer {
            NSApp.appearance = previousAppearance
            preferences.appIconID = previousIcon
        }
        preferences.applyOnLaunch()
        NSApp.appearance = NSAppearance(named: .aqua)
        preferences.appIconID = "AppIcon19"
        let light = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(250))
        let dark = try XCTUnwrap(NSApp.applicationIconImage.tiffRepresentation)
        XCTAssertNotEqual(light, dark)
    }

    func testMenuBarTextStaysVisibleWithIslandByDefault() throws {
        let defaults = try fixtureDefaults()
        for islandVisible in [false, true] {
            XCTAssertEqual(MacMenuBarController.statusTitle(
                songTitle: "Song", lyric: "Current lyric", showsTitle: true,
                islandVisible: islandVisible, defaults: defaults
            ), " Current lyric")
            XCTAssertEqual(MacMenuBarController.statusTitle(
                songTitle: "Song", lyric: nil, showsTitle: true,
                islandVisible: islandVisible, defaults: defaults
            ), " Song")
        }
    }

    func testMenuBarIconOnlyModeRequiresOptInAndTitleSwitchStaysIndependent() throws {
        let defaults = try fixtureDefaults()
        defaults.set(true, forKey: MacMenuBarController.compactWithIslandKey)
        XCTAssertEqual(MacMenuBarController.statusTitle(
            songTitle: "Song", lyric: "Current lyric", showsTitle: true,
            islandVisible: true, defaults: defaults
        ), "")
        XCTAssertEqual(MacMenuBarController.statusTitle(
            songTitle: "Song", lyric: "Current lyric", showsTitle: true,
            islandVisible: false, defaults: defaults
        ), " Current lyric")
        defaults.set(false, forKey: MacMenuBarController.compactWithIslandKey)
        XCTAssertEqual(MacMenuBarController.statusTitle(
            songTitle: "Song", lyric: nil, showsTitle: false,
            islandVisible: true, defaults: defaults
        ), "")
        XCTAssertEqual(MacMenuBarController.statusTitle(
            songTitle: "Song", lyric: "Current lyric", showsTitle: false,
            islandVisible: true, defaults: defaults
        ), " Current lyric")
    }

    private func fixtureDefaults() throws -> UserDefaults {
        let name = "MacSongTableAndIconTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
