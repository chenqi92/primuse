#if os(iOS)
import CarPlay
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

@MainActor
final class CarPlayEditorRenderingTests: XCTestCase {
    func testCanvasRendersMixedLayoutsAndFocusedPlayback() async throws {
        var cards = CarPlayLayoutBlock(id: "cards", kind: .custom, style: .cards)
        cards.title = "出发就听"
        cards.columns = 3
        var list = CarPlayLayoutBlock(id: "list", kind: .recentlyAdded, style: .list)
        list.title = "最近加入"
        let items = [
            CarPlayHomeItem(id: "1", title: "公路音乐", subtitle: "36 首歌曲", symbol: "music.note.list", target: .unavailable),
            CarPlayHomeItem(id: "2", title: "周末现场 · 长标题换行", subtitle: "音乐 / 演唱会", symbol: "folder.fill", target: .unavailable),
            CarPlayHomeItem(id: "3", title: "夜间电台", subtitle: "Ambient Radio", symbol: "radio", target: .unavailable)
        ]
        let blocks = [CarPlayHomeBlock(configuration: cards, items: items),
                      CarPlayHomeBlock(configuration: list, items: Array(items.prefix(2)))]
        var config = CarPlayLayoutConfiguration()
        config.blocks = [cards, list]
        let canvas = CarPlayEditorCanvas(blocks: blocks, configuration: config, selectedID: "cards", editing: true,
                                         playerPage: false, wide: false, previewItem: nil,
                                         select: { _ in }, activate: { _ in }, drop: { _, _, _ in false }, addContent: { _ in })
        try await render(canvas, size: CGSize(width: 1000, height: 600), name: "CarPlay-canvas-edit")
        let preview = CarPlayEditorCanvas(blocks: blocks, configuration: config, selectedID: nil, editing: false,
                                          playerPage: false, wide: true, previewItem: nil,
                                          select: { _ in }, activate: { _ in }, drop: { _, _, _ in false }, addContent: { _ in })
        try await render(preview, size: CGSize(width: 1120, height: 480), name: "CarPlay-canvas-wide")
        for style in [CarPlayVisualStyle.wall, .capsules] {
            var menuConfig = config
            menuConfig.applyVisualStyle(style)
            menuConfig.tabs = [.init(id: "playlists", kind: .playlists)]
            let menu = CarPlayEditorCanvas(blocks: [], configuration: menuConfig, selectedID: nil, editing: false,
                playerPage: false, wide: false, previewItem: nil, select: { _ in }, activate: { _ in },
                drop: { _, _, _ in false }, addContent: { _ in }, catalog: .init(entries: [.playlist: items]))
            try await render(menu, size: CGSize(width: 800, height: 480), name: "CarPlay-playlists-menu-\(style.rawValue)")
        }
        config.minimalNowPlaying = true
        let player = CarPlayEditorCanvas(blocks: [], configuration: config, selectedID: nil, editing: false,
                                         playerPage: true, wide: false, previewItem: items[1],
                                         select: { _ in }, activate: { _ in }, drop: { _, _, _ in false }, addContent: { _ in })
        try await render(player, size: CGSize(width: 800, height: 480), name: "CarPlay-focused-player")
    }

    func testEditorRendersAtPhoneAndTabletWidthsWithoutChangingPreferences() async throws {
        let suite = "CarPlayRenderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CarPlaySettingsStore(defaults: defaults)
        let original = settings.configuration
        try await render(NavigationStack { CarPlaySettingsView(settings: settings) }, size: CGSize(width: 390, height: 844), name: "CarPlay-editor-phone")
        try await render(NavigationStack { CarPlaySettingsView(settings: settings) }, size: CGSize(width: 1194, height: 834), name: "CarPlay-editor-tablet")
        try await render(NavigationStack { CarPlaySettingsView(settings: settings, showsLibrary: true) }, size: CGSize(width: 390, height: 844), name: "CarPlay-style-library")
        let model = CarPlayEditorModel(settings: settings)
        model.select(try XCTUnwrap(model.configuration.blocks.first?.id))
        try await render(NavigationStack { CarPlaySettingsView(settings: settings, model: model) }, size: CGSize(width: 390, height: 844), name: "CarPlay-module-inspector")
        try await render(CarPlayModulePicker(model: model, close: {}), size: CGSize(width: 390, height: 660), name: "CarPlay-add-module")
        let homeModel = CarPlayEditorModel(settings: settings)
        homeModel.selectTab("tab.home")
        for scheme in [ColorScheme.light, .dark] {
            try await render(NavigationStack { CarPlaySettingsView(settings: settings, model: homeModel) },
                size: CGSize(width: 390, height: 844), name: "CarPlay-home-editor-\(scheme)", scheme: scheme)
        }
        XCTAssertEqual(settings.configuration, original)
    }

    func testContinuousEditingUndoReorderVisibilityAndPersistence() throws {
        let suite = "CarPlayInteractionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CarPlaySettingsStore(defaults: defaults)
        let model = CarPlayEditorModel(settings: settings)
        let original = model.configuration
        let id = try XCTUnwrap(original.blocks.first?.id)
        model.select(id)
        XCTAssertTrue(model.inspectorVisible)
        model.continuousChange(true)
        for limit in 1...60 { model.update(id) { $0.itemLimit = limit } }
        model.continuousChange(false)
        XCTAssertEqual(model.selected?.itemLimit, 60)
        model.undo()
        XCTAssertEqual(model.configuration, original, "A slider gesture must undo in one step")
        model.redo()
        XCTAssertEqual(model.selected?.itemLimit, 60)
        model.update(id) { $0.isVisible = false }
        model.move(id, before: nil)
        XCTAssertEqual(model.configuration.blocks.last?.id, id)
        XCTAssertFalse(try XCTUnwrap(model.configuration.blocks.last).isVisible)
        let snapshot = model.configuration
        XCTAssertFalse(model.drop(["carplay-block:deleted"], before: id))
        XCTAssertEqual(model.configuration, snapshot)
        model.flush()
        let restored = CarPlaySettingsStore(defaults: defaults)
        XCTAssertEqual(restored.configuration, model.configuration)
        model.undo()
        XCTAssertEqual(model.configuration.blocks.first?.id, id)
    }

    func testLargeLibraryProjectionIsReusedAcrossCanvasEdits() async throws {
        let suite = "CarPlayPerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CarPlayEditorModel(settings: CarPlaySettingsStore(defaults: defaults))
        let songs = (0..<20_000).map { index in
            Song(id: "s\(index)", title: "Track \(index)", artistName: "Artist", fileFormat: .flac, filePath: "/\(index).flac", sourceID: "test")
        }
        let catalog = CarPlayEditorCatalog()
        catalog.load(.init(songs: songs, albums: [], playlists: [], memberships: [:], stations: [], artistNames: .defaultValue))
        await catalog.waitForLoad()
        XCTAssertEqual(catalog.snapshot.searchItems[.song]?.count, 20_000)
        let projectionCount = catalog.projectionCount
        let id = try XCTUnwrap(model.configuration.blocks.first?.id)
        let start = ContinuousClock.now
        for index in 0..<200 {
            model.select(id)
            model.update(id) { $0.itemLimit = index % 60 + 1; $0.columns = index % 5 + 2 }
            let blocks = catalog.snapshot.blocks(for: model.configuration)
            XCTAssertLessThanOrEqual(blocks.flatMap(\.items).count, 180)
        }
        let duration = start.duration(to: .now)
        XCTAssertEqual(catalog.projectionCount, projectionCount, "Editing must not rebuild the source catalog")
        XCTAssertEqual(projectionCount, 1)
        model.flush()
        let attachment = XCTAttachment(string: "20,000 songs; 200 edits; source projections=\(projectionCount); edit duration=\(duration)")
        attachment.name = "CarPlay-editor-projection-performance"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLatestCatalogWinsAndUnavailableContentKeepsItsIdentity() async {
        let catalog = CarPlayEditorCatalog()
        let first = Song(id: "same", title: "Old", fileFormat: .mp3, filePath: "/one.mp3", sourceID: "test")
        var updated = first
        updated.title = "Renamed"
        catalog.load(.init(songs: [first], albums: [], playlists: [], memberships: [:], stations: [], artistNames: .defaultValue))
        catalog.load(.init(songs: [updated], albums: [], playlists: [], memberships: [:], stations: [], artistNames: .defaultValue))
        await catalog.waitForLoad()
        XCTAssertEqual(catalog.snapshot.searchItems[.song]?.first?.title, "Renamed")
        XCTAssertEqual(catalog.projectionCount, 1)
        let saved = CarPlayLayoutItem(id: "pinned", kind: .song, targetID: "missing", title: "Keep me")
        let resolved = catalog.snapshot.resolve(saved, directly: true)
        XCTAssertEqual(resolved.id, saved.id)
        XCTAssertEqual(resolved.title, saved.title)
        XCTAssertFalse(resolved.enabled)
    }

    func testCustomNowPlayingContentKeepsIdentityAndCanBeRemoved() throws {
        let suite = "CarPlayContentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CarPlayEditorModel(settings: CarPlaySettingsStore(defaults: defaults))
        model.add(.custom)
        let blockID = try XCTUnwrap(model.selectedID)
        let item = CarPlayLayoutItem(kind: .nowPlaying, targetID: "nowPlaying", title: "正在播放")
        XCTAssertTrue(model.addContent(item, to: blockID, resolved: []))
        let savedID = try XCTUnwrap(model.selected?.items.first?.id)
        let catalog = CarPlayEditorCatalog.Snapshot()
        let playing = CarPlayHomeItem(id: "nowPlaying", title: "正在播放", subtitle: "Track", target: .nowPlaying)
        let resolved = try XCTUnwrap(catalog.blocks(for: model.configuration, nowPlaying: playing).first { $0.id == blockID })
        let content = try XCTUnwrap(resolved.items.first)
        XCTAssertEqual(content.id, savedID)
        XCTAssertEqual(content.subtitle, "Track")
        XCTAssertFalse(model.addContent(item, to: blockID, resolved: resolved.items))
        model.removeContent(content, from: blockID, resolved: resolved.items)
        XCTAssertTrue(try XCTUnwrap(model.selected).items.isEmpty)
        model.undo()
        XCTAssertEqual(model.selected?.items.first?.id, savedID)
        let stopped = try XCTUnwrap(catalog.blocks(for: model.configuration).first { $0.id == blockID }?.items.first)
        XCTAssertEqual(stopped.id, savedID)
        XCTAssertFalse(stopped.enabled)
    }

    func testNativeCoverRowsKeepSquareArtworkTitlesAndTapTargets() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("New row elements require iOS 26") }
        let delegate = CarPlaySceneDelegate()
        var selected = [Int]()
        let entries = (0..<3).map { index in
            CarPlaySceneDelegate.CollectionEntry(title: "Playlist \(index)", subtitle: "\(index) songs",
                symbol: index == 0 ? "music.note" : "music.note.list", enabled: index != 2) { selected.append(index) }
        }
        let row = delegate.imageRow(entries, style: .covers)
        XCTAssertEqual(row.elements.count, 3)
        for (index, element) in row.elements.enumerated() {
            let element = try XCTUnwrap(element as? CPListImageRowItemRowElement)
            XCTAssertEqual(element.title, entries[index].title)
            XCTAssertEqual(element.subtitle, entries[index].subtitle)
            XCTAssertEqual(element.image.size.width, element.image.size.height)
            XCTAssertEqual(element.isEnabled, entries[index].enabled)
        }
        for index in [1, 2] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                row.listImageRowHandler?(row, index) { continuation.resume() }
            }
        }
        XCTAssertEqual(selected, [1], "An unavailable card must not invoke its action")
        let legacyCard = delegate.imageRow(entries, style: .cards)
        XCTAssertFalse(try XCTUnwrap(legacyCard.elements.first as? CPListImageRowItemCardElement).showsImageFullHeight)
    }

    func testNativeArtworkHasConsistentInsetsAdaptiveContrastAndUndistortedCrop() throws {
        let delegate = CarPlaySceneDelegate()
        let sizes = ["folder", "music.note", "music.note.list", "square.stack"].map { symbol in
            delegate.collectionItem(.init(title: symbol, symbol: symbol, action: {})).image?.size
        }
        XCTAssertTrue(sizes.allSatisfy { $0 == CPListItem.maximumImageSize }, "CarPlay image sizes: \(sizes)")
        let placeholder = CarPlayTemplateImages.placeholder("music.note.list", side: 100, scale: 1)
        let light = try XCTUnwrap(placeholder.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .light)))
        let dark = try XCTUnwrap(placeholder.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertNotEqual(light.pngData(), dark.pngData())
        let symbol = CarPlayTemplateImages.placeholder("circle.fill", side: 100, scale: 1)
        let daySymbol = try XCTUnwrap(symbol.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .light)))
        let nightSymbol = try XCTUnwrap(symbol.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertLessThan(pixel(daySymbol, x: 50, y: 50)[0], 30)
        XCTAssertGreaterThan(pixel(nightSymbol, x: 50, y: 50)[0], 225)
        for (name, image) in [("CarPlay-placeholder-light", light), ("CarPlay-placeholder-dark", dark)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(pixel(light, x: 0, y: 0)[3], 255)
        XCTAssertEqual(pixel(dark, x: 0, y: 0)[3], 255)
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
            UIColor.red.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 80, y: 30, width: 40, height: 40))
        }
        let square = CarPlayTemplateImages.square(fixture, side: 100, scale: 1)
        XCTAssertEqual(square.size, light.size)
        XCTAssertGreaterThan(pixel(square, x: 35, y: 50)[0], 240, "Center crop must preserve the circle's horizontal radius")
        XCTAssertGreaterThan(pixel(square, x: 50, y: 35)[0], 240, "Center crop must preserve the circle's vertical radius")
        XCTAssertGreaterThan(pixel(square, x: 20, y: 50)[1], 240)
    }

    func testNativeSearchButtonDoesNotRequireAnAssistantRowAndRejectsMusicKitURLs() {
        let delegate = CarPlaySceneDelegate()
        let template = CPListTemplate(title: "Library", sections: [])
        var configuration = CarPlayLayoutConfiguration()
        delegate.configureNavigation(on: template, configuration: configuration, isTabRoot: true)
        XCTAssertTrue(template.trailingNavigationBarButtons.isEmpty, "Tab roots do not support custom navigation buttons")
        if #available(iOS 26.0, *) { XCTAssertNil(template.headerGridButtons, "Search no longer takes a row of its own above tab roots") }
        delegate.configureNavigation(on: template, configuration: configuration)
        XCTAssertNil(template.assistantCellConfiguration)
        XCTAssertEqual(template.trailingNavigationBarButtons.count, 1)
        configuration.blocks.append(.init(id: "siri", kind: .siri))
        delegate.configureNavigation(on: template, configuration: configuration)
        if #available(iOS 26.0, *) {
            XCTAssertNil(template.assistantCellConfiguration)
            XCTAssertEqual(template.trailingNavigationBarButtons.count, 2)
            delegate.configureNavigation(on: template, configuration: configuration, isTabRoot: true)
            XCTAssertEqual(template.headerGridButtons?.count, 1)
            XCTAssertTrue(template.trailingNavigationBarButtons.isEmpty)
        }
        configuration.siriPresentation = .row
        delegate.configureNavigation(on: template, configuration: configuration)
        XCTAssertNotNil(template.assistantCellConfiguration)
        XCTAssertEqual(template.trailingNavigationBarButtons.count, 1)
        XCTAssertNil(CarPlayHomeContent.httpArtworkReference("musicKit://artwork/123"))
        XCTAssertNil(CarPlayHomeContent.httpArtworkReference("file:///artwork.jpg"))
        XCTAssertNil(CarPlayHomeContent.httpArtworkReference("https:///"))
        XCTAssertEqual(CarPlayHomeContent.httpArtworkReference("https://example.com/cover.jpg"), "https://example.com/cover.jpg")
    }

    func testMainMenuEditingPersistsAndProjectsToNativeTabs() async throws {
        let suite = "CarPlayMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CarPlayEditorModel(settings: CarPlaySettingsStore(defaults: defaults))
        let initial = model.configuration
        XCTAssertFalse(model.homeEditorVisible)
        model.selectTab("tab.home")
        XCTAssertTrue(model.homeEditorVisible)
        model.select(try XCTUnwrap(model.selectedID))
        XCTAssertTrue(model.inspectorVisible)
        model.selectTab("tab.library")
        XCTAssertFalse(model.homeEditorVisible)
        XCTAssertFalse(model.inspectorVisible)
        model.showMainMenu()
        XCTAssertEqual(model.configuration, initial)
        model.toggleTab(try XCTUnwrap(model.configuration.tabs.first { $0.kind == .radio }))
        XCTAssertTrue(model.addTab(.collection, content: .init(kind: .playlist, targetID: "commute", title: "Commute")))
        let id = try XCTUnwrap(model.selectedTabID)
        model.renameTab(id, title: "出发就听")
        XCTAssertTrue(model.dropTab(["carplay-tab:" + id], before: "tab.home"))
        XCTAssertEqual(model.visibleTabs.first?.id, id)
        model.undo()
        XCTAssertEqual(model.visibleTabs.last?.id, id)
        model.redo()
        model.flush()
        XCTAssertEqual(CarPlaySettingsStore(defaults: defaults).configuration, model.configuration)
        let delegate = CarPlaySceneDelegate()
        let tabs = delegate.makeRootTabBar(configuration: model.configuration)
        XCTAssertEqual(tabs.templates.map(\.tabTitle), model.visibleTabs.map { Optional($0.displayTitle) })
        XCTAssertEqual(tabs.templates.count, model.visibleTabs.count)
        XCTAssertLessThanOrEqual(tabs.templates.count, model.maximumTabCount)
        model.showMainMenu()
        try await render(NavigationStack { CarPlaySettingsView(settings: model.settings, model: model) },
            size: CGSize(width: 390, height: 844), name: "CarPlay-main-menu-editor")
    }

    func testNavigationAndArtworkPoliciesStayInsideSystemBudgets() {
        XCTAssertEqual(CarPlayNavigationStackPolicy.action(currentDepth: 1), .push)
        XCTAssertEqual(CarPlayNavigationStackPolicy.action(currentDepth: 4), .push)
        XCTAssertEqual(CarPlayNavigationStackPolicy.action(currentDepth: 5), .replaceTop)
        XCTAssertEqual(CarPlayNavigationStackPolicy.action(currentDepth: 6), .resetToRoot)
        XCTAssertTrue(CarPlayArtworkLoadPolicy.shouldLoad(index: 0))
        XCTAssertTrue(CarPlayArtworkLoadPolicy.shouldLoad(index: 63))
        XCTAssertFalse(CarPlayArtworkLoadPolicy.shouldLoad(index: 64))
        XCTAssertFalse(CarPlayArtworkLoadPolicy.shouldLoad(index: -1))
    }

    private actor ArtworkDecodeProbe {
        var active = 0
        var maximumActive = 0

        func load() async -> UIImage? {
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            try? await Task.sleep(for: .milliseconds(20))
            return UIImage()
        }
    }

    func testCarPlayArtworkSchedulerSerializesDecodeWork() async {
        let scheduler = CarPlayArtworkScheduler(
            minimumCooldown: 0,
            maximumCooldown: 0,
            dynamicCooldownMultiplier: 0
        )
        let probe = ArtworkDecodeProbe()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = await scheduler.image { await probe.load() }
                }
            }
        }
        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 1)
    }

    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
        let context = CGContext(data: &bytes, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 100, height: 100))
        let offset = (y * 100 + x) * 4
        return Array(bytes[offset..<offset + 4])
    }

    private actor ArtworkRequestProbe {
        var urls: [URL] = []
        var active = 0
        var maximumActive = 0
        func fetch(_ url: URL) async throws -> Data {
            urls.append(url)
            active += 1
            maximumActive = max(maximumActive, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(40))
            if url.path.hasSuffix("i.missing") { throw URLError(.notConnectedToInternet) }
            if url.path.hasSuffix("i.catalog") {
                return Data(#"{"data":[{"relationships":{"catalog":{"data":[{"attributes":{"artwork":{"url":"https://example.com/catalog/{w}x{h}.jpg"}}}]}}}]}"#.utf8)
            }
            return Data(#"{"data":[{"attributes":{"artwork":{"width":null,"height":null,"url":"https://example.com/library/{w}x{h}.jpg"}}}]}"#.utf8)
        }
    }

    func testAppleMusicArtworkUsesExactLibraryResourcesAndCoalescesRequests() async throws {
        let probe = ArtworkRequestProbe()
        let loader = CarPlayAppleMusicArtwork(fetch: { try await probe.fetch($0) }, isAuthorized: { true })
        let images = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<8 { group.addTask { await loader.reference(kind: .songs, id: "i.song", pixelSize: 88) } }
            var results: [String?] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(images.count, 8)
        XCTAssertTrue(images.allSatisfy { $0 == "https://example.com/library/88x88.jpg" })
        let resized = await loader.reference(kind: .songs, id: "i.song", pixelSize: 320)
        XCTAssertEqual(resized, "https://example.com/library/320x320.jpg")
        let firstRequests = await probe.urls
        XCTAssertEqual(firstRequests.count, 1, "Different thumbnail sizes must share one metadata request")
        XCTAssertEqual(firstRequests.first?.path, "/v1/me/library/songs/i.song")
        let playlist = await loader.reference(kind: .playlists, id: "p.playlist", pixelSize: 160)
        XCTAssertEqual(playlist, "https://example.com/library/160x160.jpg", "Null artwork dimensions must not discard a playlist cover")
        let catalog = await loader.reference(kind: .songs, id: "i.catalog", pixelSize: 100)
        XCTAssertEqual(catalog, "https://example.com/catalog/100x100.jpg")
        for _ in 0..<2 {
            let missing = await loader.reference(kind: .songs, id: "i.missing", pixelSize: 100)
            XCTAssertNil(missing)
        }
        let requests = await probe.urls
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("i.missing") }.count, 1, "Offline misses must not cause repeated requests")
        XCTAssertEqual(requests.filter { $0.path.contains("/playlists/") }.count, 1)
        XCTAssertNil(CarPlayAppleMusicArtwork.resourceURL(kind: .songs, id: "i.song/../../me"))
        XCTAssertNil(CarPlayAppleMusicArtwork.resourceURL(kind: .playlists, id: "i.song"))
        let unauthorized = CarPlayAppleMusicArtwork(fetch: { _ in XCTFail("Unauthorized artwork must not request access or load data"); return Data() }, isAuthorized: { false })
        let denied = await unauthorized.reference(kind: .songs, id: "i.song", pixelSize: 100)
        XCTAssertNil(denied)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask { _ = await loader.reference(kind: .songs, id: "i.bound\(index)", pixelSize: 88) }
            }
        }
        let maximumActive = await probe.maximumActive
        XCTAssertLessThanOrEqual(maximumActive, 4)
    }

    func testArtworkCacheUpdatesOnlyMatchingLiveRows() async throws {
        let center = NotificationCenter()
        let updates = CarPlayArtworkUpdates(center: center)
        var owner: NSObject? = NSObject()
        weak var weakOwner = owner
        var refreshes = 0
        updates.bind(owner: try XCTUnwrap(owner), songIDs: ["target"]) { refreshes += 1 }
        center.post(name: .primuseArtworkDidCache, object: "unrelated")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(refreshes, 0)
        center.post(name: .primuseArtworkDidCache, object: "target")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(refreshes, 1)
        owner = nil
        XCTAssertNil(weakOwner, "Observing artwork must not retain a removed template row")
        center.post(name: .primuseArtworkDidCache, object: "target")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(refreshes, 1)

        let delegate = CarPlaySceneDelegate()
        let songID = "carplay-artwork-test-\(UUID().uuidString)"
        let item = delegate.collectionItem(.init(title: "Cached later", artwork: .songReference(id: songID, coverRef: nil), action: {}))
        try await Task.sleep(for: .milliseconds(80))
        let placeholder = item.image?.pngData()
        let projectionCount = CarPlayEditorCatalog.shared.projectionCount
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        await MetadataAssetStore.shared.cacheCover(try XCTUnwrap(fixture.pngData()), forSongID: songID)
        for _ in 0..<100 where item.image?.pngData() == placeholder { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(item.image?.pngData(), placeholder, "A displayed list row must receive artwork cached during playback")
        XCTAssertGreaterThan(pixel(try XCTUnwrap(item.image), x: 50, y: 50)[0], 240)
        XCTAssertEqual(CarPlayEditorCatalog.shared.projectionCount, projectionCount)
    }

    func testSongWithoutCoverReferenceReadsEmbeddedArtworkFromCachedAudio() async throws {
        let source = MusicSource(id: "carplay-embedded-\(UUID().uuidString)", name: "Embedded art", type: .local)
        let manager = SourceManager(sourcesProvider: { [source] })
        let song = Song(id: UUID().uuidString, title: "Embedded cover", fileFormat: .mp3,
                        filePath: "/embedded.mp3", sourceID: source.id)
        await manager.ensureOfflineAudioSnapshot(for: song)
        let url = manager.audioCacheTargetURL(for: song)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let fixture = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        var payload = Data([0]) + Data("image/png".utf8) + Data([0, 3, 0])
        payload.append(try XCTUnwrap(fixture.pngData()))
        var frame = Data("APIC".utf8)
        let length = UInt32(payload.count)
        frame.append(contentsOf: [UInt8(length >> 24), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255), 0, 0])
        frame.append(payload)
        let count = frame.count
        var file = Data([0x49, 0x44, 0x33, 3, 0, 0,
                         UInt8((count >> 21) & 127), UInt8((count >> 14) & 127), UInt8((count >> 7) & 127), UInt8(count & 127)])
        file.append(frame)
        file.append(Data(repeating: 0, count: 4_096))
        try file.write(to: url)
        let cachedAudio = await manager.cachedURLForBackgroundRead(for: song)
        XCTAssertNotNil(cachedAudio)
        let image = await CarPlayHomeContent.songArtwork(song, pixelSize: 100, sourceManager: manager)
        XCTAssertGreaterThan(pixel(try XCTUnwrap(image), x: 50, y: 50)[1], 240)
        let cachedArt = await MetadataAssetStore.shared.cachedCoverData(forSongID: song.id)
        XCTAssertNotNil(cachedArt, "Listing cached audio must populate the same cover cache as playback")
    }

    private func render(_ view: some View, size: CGSize, name: String, scheme: ColorScheme = .light,
                        interact: ((UIView) async throws -> Void)? = nil) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
        let host = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: "zh-Hans")).preferredColorScheme(scheme))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        try await interact?(host.view)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            host.view.layer.render(in: context.cgContext)
        }
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
