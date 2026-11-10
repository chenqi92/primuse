import AppKit
import ImageIO
import PrimuseKit
import SwiftUI
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

@MainActor
final class MacHomePerformanceDiagnosticsTests: XCTestCase {
    func testIdleAndBackgroundTimeDoNotBecomeBusyTurns() {
        var time: TimeInterval = 100
        var lines: [String] = []
        let diagnostics = MacHomePerformanceDiagnostics(now: { time }, applicationIsActive: { true }, emit: { lines.append($0) })
        diagnostics.setVisible(true)
        diagnostics.setActive(true)
        diagnostics.observe(.beforeWaiting)
        time += 30
        diagnostics.observe(.afterWaiting)
        time += 0.02
        diagnostics.observe(.beforeWaiting)
        diagnostics.setActive(false)
        XCTAssertFalse(diagnostics.isMonitoring)
        time += 60
        diagnostics.setActive(true)
        diagnostics.observe(.beforeWaiting)
        diagnostics.setCovered(true)
        XCTAssertFalse(diagnostics.isMonitoring)
        time += 30
        diagnostics.setCovered(false)
        diagnostics.observe(.beforeWaiting)
        diagnostics.setVisible(false)
        XCTAssertFalse(diagnostics.isMonitoring)
        XCTAssertFalse(lines.contains { $0.contains("event=main_busy") })
    }

    func testBusyTurnsKeepScrollContextAndBoundLogVolume() {
        var time: TimeInterval = 100
        var lines: [String] = []
        let diagnostics = MacHomePerformanceDiagnostics(now: { time }, applicationIsActive: { true }, emit: { lines.append($0) })
        diagnostics.setVisible(true, context: { "scanning=1" })
        diagnostics.setActive(true)
        diagnostics.scrollChanged(isScrolling: true)
        for _ in 0..<6 {
            diagnostics.observe(.afterWaiting)
            time += 0.2
            diagnostics.observe(.beforeWaiting)
        }
        let busy = lines.filter { $0.contains("event=main_busy") }
        XCTAssertEqual(busy.count, 4)
        XCTAssertTrue(busy.allSatisfy { $0.contains("busy_ms=200") && $0.contains("scrolling=true") && $0.contains("scanning=1") })
        diagnostics.setVisible(false)
        XCTAssertTrue(lines.last?.contains("busy_turns=6 worst_busy_ms=200 suppressed=2") == true)
        XCTAssertFalse(diagnostics.isMonitoring)
        let count = lines.count
        time += 20
        diagnostics.observe(.beforeWaiting)
        diagnostics.scrollChanged(isScrolling: false)
        XCTAssertEqual(lines.count, count)
    }

    func testNavigationTimingIsConsumedAndModalWaitIsExcluded() {
        var time: TimeInterval = 100
        var lines: [String] = []
        let diagnostics = MacHomePerformanceDiagnostics(now: { time }, applicationIsActive: { true }, emit: { lines.append($0) })
        diagnostics.navigationRequested()
        time += 0.25
        diagnostics.setVisible(true)
        XCTAssertTrue(lines.last?.contains("navigation_ms=250") == true)
        diagnostics.setActive(true)
        diagnostics.observe(.entry)
        diagnostics.observe(.beforeWaiting)
        time += 20
        diagnostics.observe(.afterWaiting)
        time += 0.01
        diagnostics.observe(.exit)
        diagnostics.observe(.beforeWaiting)
        diagnostics.setVisible(false)
        diagnostics.setVisible(true)
        XCTAssertTrue(lines.last?.contains("navigation_ms=-1") == true)
        diagnostics.setVisible(false)
        XCTAssertFalse(lines.contains { $0.contains("event=main_busy") })
    }

    func testCommitCallbackDoesNotCrossVisitsOrWaitForUserInput() async {
        let committed = expectation(description: "Current visit commits")
        var lines: [String] = []
        let diagnostics = MacHomePerformanceDiagnostics(applicationIsActive: { true }, emit: {
            lines.append($0)
            if $0.contains("event=current_commit") { committed.fulfill() }
        })
        diagnostics.setVisible(true)
        diagnostics.setActive(true)
        let start = ProcessInfo.processInfo.systemUptime
        diagnostics.markAfterCommit("stale_commit", since: start)
        diagnostics.setVisible(false)
        diagnostics.setVisible(true)
        defer { diagnostics.setVisible(false) }
        diagnostics.markAfterCommit("current_commit", since: start)
        await fulfillment(of: [committed], timeout: 3)
        XCTAssertFalse(lines.contains { $0.contains("event=stale_commit") })
    }

    func testMainRunLoopReportsRealWorkAndStopsAfterLeaving() async {
        let reported = expectation(description: "Main loop busy turn")
        reported.assertForOverFulfill = false
        let diagnostics = MacHomePerformanceDiagnostics(applicationIsActive: { true }, emit: {
            if $0.contains("event=main_busy") { reported.fulfill() }
        })
        diagnostics.setVisible(true)
        diagnostics.setActive(true)
        defer { diagnostics.setVisible(false) }
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.15) }
        await fulfillment(of: [reported], timeout: 3)
    }
}

@MainActor
final class MacHomeScrollingTests: XCTestCase {
    func testDashboardDefersOffscreenSectionsAndTheirUpdates() async throws {
        let probe = MacHomeScrollProbe()
        let window = makeWindow(probe: probe, width: 880)
        defer { window.contentView = nil; window.close() }
        try await settle(window)
        XCTAssertTrue(probe.active.contains(0))
        XCTAssertFalse(probe.evaluations.keys.contains(9), "The last section must not be built at the top")
        XCTAssertLessThan(probe.active.count, 10)

        let initial = probe.evaluations
        probe.revision += 1
        try await settle(window)
        XCTAssertGreaterThan(probe.evaluations[0, default: 0], initial[0, default: 0])
        XCTAssertNil(probe.evaluations[9], "Offscreen sections must not observe live updates yet")
        print("HOME_SCROLL initialSections=\(initial.count) activeSections=\(probe.active.count)")
    }

    func testDashboardReachesLastSectionAndReturnsWithoutChangingLayout() async throws {
        for width: CGFloat in [640, 1280] {
            let probe = MacHomeScrollProbe()
            probe.hiddenSections = [1, 4, 7]
            let window = makeWindow(probe: probe, width: width)
            defer { window.contentView = nil; window.close() }
            try await settle(window)
            let scroll = try XCTUnwrap(findScrollView(in: window.contentView!))
            let document = try XCTUnwrap(scroll.documentView)
            let initialHeight = document.frame.height
            XCTAssertLessThanOrEqual(document.frame.width, width + 1)

            for _ in 0..<3 {
                scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, document.frame.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                try await settle(window)
            }
            XCTAssertTrue(probe.active.contains(9), "The last section must be reachable")
            XCTAssertFalse(probe.active.contains(0), "The hero must leave the active view tree")

            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(window)
            XCTAssertTrue(probe.active.contains(0))
            XCTAssertFalse(probe.active.contains(9))
            XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
            XCTAssertEqual(document.frame.height, initialHeight, accuracy: 1)
            XCTAssertEqual(document.frame.height, 7 * 300 + 6 * PMSpace.xxl + PMSpace.l24 + 104, accuracy: 1,
                           "Hidden sections must not leave extra spacing")
        }
    }

    private func makeWindow(probe: MacHomeScrollProbe, width: CGFloat) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: MacHomeDashboardScroll {
            // Match the dashboard's conditional content and section loop.
            if probe.hasContent {
                ForEach(0..<10) { index in
                    if !probe.hiddenSections.contains(index) {
                        MacHomeScrollProbeSection(index: index, probe: probe)
                    }
                }
            }
        })
        host.sizingOptions = []
        host.frame = window.contentLayoutRect
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(150))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.findScrollView(in: $0) }.first
    }
}

@MainActor @Observable
private final class MacHomeScrollProbe {
    var hasContent = true
    var revision = 0
    var hiddenSections: Set<Int> = []
    @ObservationIgnored var evaluations: [Int: Int] = [:]
    @ObservationIgnored var active: Set<Int> = []
}

private struct MacHomeScrollProbeSection: View {
    let index: Int
    let probe: MacHomeScrollProbe

    var body: some View {
        let _ = { probe.evaluations[index, default: 0] += 1 }()
        Text("Section \(index), revision \(probe.revision)")
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .background(.blue.opacity(0.1))
            .onAppear { probe.active.insert(index) }
            .onDisappear { probe.active.remove(index) }
    }
}

@MainActor
final class MacWidgetArtworkRefreshTests: XCTestCase {
    private func request(_ id: String, position: Double = 0, cover: String? = nil) -> MacWidgetPlaybackPublishRequest {
        let song = PrimuseKit.Song(id: id, title: "纸船", fileFormat: .aac, filePath: "i.\(id)",
                                   sourceID: AppleMusicLibraryService.systemSourceID, coverArtFileName: cover)
        return MacWidgetPlaybackPublishRequest(currentSong: song, artistDisplayName: "河岸", isPlaying: false,
            sampledAt: Date(), currentTime: position, duration: 180, queueSongIDs: [id], playbackKind: .track,
            radioStationID: nil, repeatMode: .off, isLiked: false, spokenWord: nil, listeningSpace: .music)
    }

    func testLateArtworkRepublishesLatestPausedPositionWithoutAnotherTrackChange() async {
        let started = expectation(description: "Artwork requested")
        let published = expectation(description: "Artwork published")
        let gate = MacWidgetArtworkTestGate(started: started)
        let log = MacWidgetArtworkTestLog()
        let publisher = MacWidgetPlaybackPublisher(publication: { request, context in
            log.record(request, context)
            if context.appleMusicArtwork != nil { published.fulfill() }
            return .init(lastCoverKey: context.appleMusicArtwork == nil ? nil : "cover",
                         lastTimelineSignature: nil, albumCoverContents: [:],
                         needsAppleMusicArtwork: context.appleMusicArtwork == nil)
        }, loadArtwork: { song in await gate.load(song.id) })
        await publisher.enqueue(request("a"))
        await fulfillment(of: [started], timeout: 3)
        await publisher.enqueue(request("a", position: 42))
        await publisher.waitForPendingPublication()
        await gate.finish("a", data: Data([7]))
        await fulfillment(of: [published], timeout: 3)
        await publisher.waitForPendingPublication()
        XCTAssertEqual(log.entries.last?.position, 42)
        XCTAssertEqual(log.entries.last?.data, Data([7]))
        XCTAssertEqual(log.entries.last?.isPlaying, false)
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
    }

    func testSlowPreviousTrackCannotReplaceNewTracksArtwork() async {
        let started = expectation(description: "Both requests started")
        started.expectedFulfillmentCount = 2
        let currentPublished = expectation(description: "Current artwork published")
        let stalePublished = expectation(description: "Previous artwork rejected")
        stalePublished.isInverted = true
        let gate = MacWidgetArtworkTestGate(started: started)
        let log = MacWidgetArtworkTestLog()
        let publisher = MacWidgetPlaybackPublisher(publication: { request, context in
            log.record(request, context)
            if context.appleMusicArtwork == Data([2]) { currentPublished.fulfill() }
            if context.appleMusicArtwork == Data([1]) { stalePublished.fulfill() }
            return .init(lastCoverKey: nil, lastTimelineSignature: nil, albumCoverContents: [:],
                         needsAppleMusicArtwork: context.appleMusicArtwork == nil)
        }, loadArtwork: { song in await gate.load(song.id) })
        await publisher.enqueue(request("a"))
        await publisher.waitForPendingPublication()
        await gate.waitUntilStarted("a")
        await publisher.enqueue(request("b"))
        await fulfillment(of: [started], timeout: 3)
        await gate.finish("b", data: Data([2]))
        await fulfillment(of: [currentPublished], timeout: 3)
        await gate.finish("a", data: Data([1]))
        await fulfillment(of: [stalePublished], timeout: 0.1)
        await publisher.waitForPendingPublication()
        XCTAssertFalse(log.entries.contains { $0.data == Data([1]) })
        XCTAssertEqual(log.entries.last?.songID, "b")
    }

    func testFailedLookupDoesNotRetryOnEveryProgressSample() async {
        let started = expectation(description: "One lookup")
        let gate = MacWidgetArtworkTestGate(started: started)
        let publisher = MacWidgetPlaybackPublisher(publication: { _, _ in
            .init(lastCoverKey: nil, lastTimelineSignature: nil, albumCoverContents: [:], needsAppleMusicArtwork: true)
        }, loadArtwork: { song in await gate.load(song.id) })
        await publisher.enqueue(request("a"))
        await fulfillment(of: [started], timeout: 3)
        await gate.finish("a", data: nil)
        for position in 1...6 {
            await publisher.enqueue(request("a", position: Double(position)))
            await publisher.waitForPendingPublication()
        }
        let count = await gate.requestCount
        XCTAssertEqual(count, 1)
    }

    func testAvailableLocalArtworkDoesNotStartNetworkLookup() async {
        let unexpected = expectation(description: "No artwork lookup")
        unexpected.isInverted = true
        let publisher = MacWidgetPlaybackPublisher(publication: { _, _ in
            .init(lastCoverKey: "local", lastTimelineSignature: "local", albumCoverContents: [:])
        }, loadArtwork: { _ in unexpected.fulfill(); return nil })
        await publisher.enqueue(request("local"))
        await publisher.waitForPendingPublication()
        await fulfillment(of: [unexpected], timeout: 0.1)
    }
}

private actor MacWidgetArtworkTestGate {
    let started: XCTestExpectation
    var requestCount = 0
    var pending: [String: CheckedContinuation<Data?, Never>] = [:]
    var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    init(started: XCTestExpectation) { self.started = started }
    func load(_ id: String) async -> Data? {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            started.fulfill()
            waiters.removeValue(forKey: id)?.resume()
        }
    }
    func waitUntilStarted(_ id: String) async {
        if pending[id] != nil { return }
        await withCheckedContinuation { waiters[id] = $0 }
    }
    func finish(_ id: String, data: Data?) { pending.removeValue(forKey: id)?.resume(returning: data) }
}

private final class MacWidgetArtworkTestLog: @unchecked Sendable {
    struct Entry { let songID: String?; let position: Double; let isPlaying: Bool; let data: Data? }
    private let lock = NSLock()
    private var storage: [Entry] = []
    var entries: [Entry] { lock.withLock { storage } }
    func record(_ request: MacWidgetPlaybackPublishRequest, _ context: MacWidgetPlaybackPublisher.PublicationContext) {
        lock.withLock { storage.append(.init(songID: request.currentSong?.id, position: request.currentTime,
                                           isPlaying: request.isPlaying, data: context.appleMusicArtwork)) }
    }
}

@MainActor
final class MacPlayerFeedbackLayoutTests: XCTestCase {
    func testCommentsListOffersExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let song = Song(id: "export-fixture", title: "晚风里的纸船", artistName: "河岸乐队",
                        fileFormat: .mp3, filePath: "/fixture.mp3", sourceID: "fixture")
        try store.save(songID: song.id, anchor: .init(text: "纸船载着星光", occurrence: 0, timestamp: 5),
                       text: "想起从前的河岸。")
        let host = NSHostingView(rootView: LyricLineCommentsSheet(
            presentation: .init(songID: song.id), store: store, song: song
        ).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "comments-export-sheet"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLyricsAndSidebarAtRegularAndShortWindowSizes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "MacPlayerFeedbackLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(1.4, forKey: "lyricsFontScale")
        defaults.set("{}", forKey: LyricsFontLanguage.preferencesKey)
        let library = MusicLibrary(storageDirectory: directory.appendingPathComponent("library"))
        await library.whenReady()
        let sources = SourcesStore(storageDirectoryURL: directory.appendingPathComponent("sources"))
        let manager = SourceManager(sourcesProvider: { [] })
        let scraper = MusicScraperService(sourceManager: manager, checkpointDirectory: directory.appendingPathComponent("scrape"))
        let scraperSettings = ScraperSettingsStore(defaults: defaults)
        let intelligence = MusicIntelligenceService(
            settingsStore: AISettingsStore(defaults: defaults, syncsThroughICloud: false),
            lyricsTranscriptionSettingsStore: LyricsTranscriptionSettingsStore(defaults: defaults, syncsThroughICloud: false),
            recommendationReuseDefaults: defaults
        )
        let previousPlayback = PlaybackState.load()
        let previousLyrics = LyricsSnapshot.load()
        let player = AudioPlayerService(library: library, playbackSettings: PlaybackSettingsStore(defaults: defaults),
            playbackSessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")),
            activateAudioSession: { _ in XCTFail("Layout preview must stay silent") })
        let songID = "feedback-layout-\(UUID().uuidString)"
        let song = Song(id: songID, title: "晚风里的纸船", albumTitle: "窗边的光", artistName: "河岸乐队",
                        fileFormat: .mp3, filePath: "/fixture.mp3", sourceID: "fixture")
        let lines = (0..<24).map { LyricLine(id: "line-\($0)", timestamp: Double($0 * 5),
                                             text: "纸船载着星光，慢慢经过桥边 \($0 + 1)") }
        let cached = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: songID)
        XCTAssertTrue(cached)
        addTeardownBlock {
            _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: songID)
        }
        player.currentSong = song
        player.currentTime = 50
        defer {
            player.currentSong = nil
            if let previousPlayback { previousPlayback.save() } else { PlaybackState.clear() }
            if let previousLyrics { previousLyrics.save() } else { LyricsSnapshot.clear() }
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        for (name, height, scheme, appearance) in [("regular-dark", 720.0, ColorScheme.dark, PMAppearanceMode.classic),
            ("short-dark", 480.0, .dark, .classic), ("regular-light", 720.0, .light, .classic),
            ("glass-dark", 720.0, .dark, .glass)] {
            let content = HStack(spacing: 0) {
                MacSidebarBackdrop().frame(width: 220)
                MacNowPlayingView(showsSidebar: true, onClose: {}, isScrapingCurrentSong: false,
                                  canTranscribeAudio: false, onScrapeCurrentSong: {}, onTranscribeAudio: {}, onToggleQueue: {})
            }
            .environment(player).environment(library).environment(manager).environment(sources)
            .environment(scraper).environment(scraperSettings)
            .environment(intelligence)
            .environment(ThemeService()).environment(\.colorScheme, scheme).environment(\.pmAppearance, appearance)
            .defaultAppStorage(defaults)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.orderOut(nil); window.close() }
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
            attachment.name = "feedback-layout-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(host.bounds.height, height, accuracy: 1)
        }
    }
}
