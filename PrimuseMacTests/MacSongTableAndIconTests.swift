import AppKit
import ImageIO
import XCTest
@testable import Primuse

@MainActor
final class MacSongTableAndIconTests: XCTestCase {
    func testHiddenIconSurvivesLaunchWithoutAppearingInRegularCatalog() throws {
        let defaults = try fixtureDefaults()
        defaults.set(MacAppIcon.hidden.id, forKey: "pm.mac.appIcon")
        let preferences = MacUIPreferences(defaults: defaults)
        XCTAssertEqual(preferences.appIconID, MacAppIcon.hidden.id)
        XCTAssertEqual(MacAppIcon.option(for: preferences.appIconID), MacAppIcon.hidden)
        XCTAssertFalse(MacAppIcon.all.contains(MacAppIcon.hidden))
    }
    func testRetiredIconsFallBackToPrimaryOnLaunch() throws {
        let defaults = try fixtureDefaults()
        for retired in ["AppIcon21", "AppIcon14"] {
            defaults.set(retired, forKey: "pm.mac.appIcon")
            let preferences = MacUIPreferences(defaults: defaults)
            XCTAssertEqual(preferences.appIconID, "")
            XCTAssertEqual(MacAppIcon.option(for: retired).id, "")
            XCTAssertFalse(MacAppIcon.all.contains { $0.id == retired })
        }
    }

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
        for icon in MacAppIcon.available {
            let light = try XCTUnwrap(MacAppIcon.dockIconImage(
                previewAsset: icon.previewAsset, appearance: NSAppearance(named: .aqua)
            )?.tiffRepresentation)
            let dark = try XCTUnwrap(MacAppIcon.dockIconImage(
                previewAsset: icon.previewAsset, appearance: NSAppearance(named: .darkAqua)
            )?.tiffRepresentation)
            if icon.id == "AppIcon20" || icon.id == MacAppIcon.hidden.id {
                XCTAssertEqual(light, dark, "Single-variant icons keep the same artwork in both appearances")
            } else {
                XCTAssertNotEqual(light, dark, "\(icon.id) must render its dark asset without restarting")
            }
        }
    }

    /// Dock 在启动前和退出后显示的是包里只有浅色的那张；运行时跟着 App 明暗换成深色版，
    /// 深色模式下每次启动、退出都会跳一下。
    func testDockIconStaysOnLightVariantWhenAppAppearanceChanges() async throws {
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
        XCTAssertEqual(NSApp.applicationIconImage.tiffRepresentation, light)
        preferences.applyAppIcon()
        XCTAssertEqual(NSApp.applicationIconImage.tiffRepresentation, light)
    }

    /// 默认图标要和启动前 Dock 上那张是同一套：直接用包里的图标集，而不是从预览图放大重画。
    func testDefaultDockIconIsTheBundledIconSet() throws {
        let bundled = try XCTUnwrap(Bundle.main.image(forResource: MacAppIcon.bundleIconName))
        let dock = try XCTUnwrap(MacAppIcon.dockIconImage(for: MacAppIcon.option(for: "")))
        XCTAssertEqual(dock.tiffRepresentation, bundled.tiffRepresentation)
        XCTAssertTrue(dock.representations.contains { $0.pixelsWide >= 1024 })
    }

    func testExportedIconsIncludeStandardAndRetinaRepresentations() throws {
        let expected = Set(["16@72", "32@72", "128@72", "256@72", "512@72",
                            "32@144", "64@144", "256@144", "512@144", "1024@144"])
        for icon in MacAppIcon.available {
            let data = try MacAppIcon.icnsData(for: icon)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetType(source) as String?, "com.apple.icns")
            var representations = Set<String>()
            for index in 0..<CGImageSourceGetCount(source) {
                let properties = try XCTUnwrap(
                    CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                )
                let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
                let dpi = try XCTUnwrap(properties[kCGImagePropertyDPIWidth] as? Int)
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
                XCTAssertEqual(image.width, image.height)
                representations.insert("\(width)@\(dpi)")
            }
            XCTAssertEqual(representations, expected, icon.id)
        }
    }

    func testExportedIconsMatchDockArtworkAndTransparentMargins() throws {
        for icon in MacAppIcon.available {
            let data = try MacAppIcon.icnsData(for: icon)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let images = (0..<CGImageSourceGetCount(source)).compactMap {
                CGImageSourceCreateImageAtIndex(source, $0, nil)
            }
            let exported = NSBitmapImageRep(cgImage: try XCTUnwrap(images.first { $0.width == 1024 }))
            let dock = try XCTUnwrap(MacAppIcon.dockIconImage(for: icon))
            var sourceRect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            let dockImage = try XCTUnwrap(dock.cgImage(forProposedRect: &sourceRect, context: nil, hints: nil))
            let expected = NSBitmapImageRep(cgImage: dockImage)
            XCTAssertEqual(expected.pixelsWide, 1024)
            for (x, y) in [(0, 0), (50, 512), (100, 100), (1023, 1023)] {
                XCTAssertEqual(try XCTUnwrap(exported.colorAt(x: x, y: y)).alphaComponent, 0,
                               accuracy: 0.01, icon.id)
            }
            for (x, y) in [(512, 512), (256, 512), (768, 512), (512, 256)] {
                let actual = try XCTUnwrap(exported.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                let target = try XCTUnwrap(expected.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                XCTAssertGreaterThan(actual.alphaComponent, 0.99)
                XCTAssertEqual(actual.redComponent, target.redComponent, accuracy: 0.02, icon.id)
                XCTAssertEqual(actual.greenComponent, target.greenComponent, accuracy: 0.02, icon.id)
                XCTAssertEqual(actual.blueComponent, target.blueComponent, accuracy: 0.02, icon.id)
            }
        }
    }

    func testIconExportRejectsMissingArtwork() {
        let missing = MacAppIcon(id: "missing", previewAsset: "missing-icon-export-fixture",
                                 nameKey: "icon_default", tint: .clear)
        XCTAssertThrowsError(try MacAppIcon.icnsData(for: missing))
    }

    /// 侧栏左上角放的是去掉底板的图形：每款可选图标都要有，四角透明。
    func testEverySelectableIconHasTransparentSidebarMark() throws {
        for icon in MacAppIcon.available {
            let image = try XCTUnwrap(NSImage(named: icon.markAsset), icon.id)
            var rect = CGRect(origin: .zero, size: image.size)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(
                image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            ))
            let (maxX, maxY) = (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1)
            for (x, y) in [(0, 0), (maxX, 0), (0, maxY), (maxX, maxY)] {
                XCTAssertEqual(try XCTUnwrap(bitmap.colorAt(x: x, y: y)).alphaComponent, 0,
                               accuracy: 0.01, icon.id)
            }
        }
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
