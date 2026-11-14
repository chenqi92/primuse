import CoreGraphics
import Foundation
import ImageIO
import PrimuseKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import Primuse

@MainActor
final class PlayerBackdropImagingTests: XCTestCase {
    func testRadioLongTitlesLayoutAtNarrowAndStandardWidths() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        let stations = [
            RadioStation(name: "江畔城市音乐广播长名称", streamURL: "https://example.com/radio", subscriptionID: "test"),
            RadioStation(name: "Quiet River Evening Radio", streamURL: "https://example.com/radio")
        ]
        for width in [CGFloat(320), 393] {
            let content = VStack(spacing: 12) {
                ForEach(Array(stations.enumerated()), id: \.element.id) { index, station in
                    RadioStationCard(station: station, priority: index + 1, isCurrent: index == 0,
                        isPlaying: false, metadataTitle: nil, onPlay: {}) {
                        EmptyView()
                    }
                }
            }
            .padding(16)
            .frame(width: width)
            .background(Color.white)
            .environment(ThemeService())
            .environment(SourceManager(sourcesProvider: { [] }))
            .environment(\.colorScheme, .light)
            let host = UIHostingController(rootView: content)
            root.addChild(host)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
            let size = host.sizeThatFits(in: CGSize(width: width, height: 800))
            host.view.frame = CGRect(origin: CGPoint(x: 0, y: 80), size: size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "radio-long-titles-\(Int(width))"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(image.size.height, 250)
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
        }
    }

    func testLyricsSurfaceSurvivesRepeatedCoverSwitchesWithoutResettingScroll() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let suite = "PlayerCoverLyrics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: PlayerAppearancePreferences.showsLyricsInterludeKey)
        let player = AudioPlayerService(playbackSettings: PlaybackSettingsStore(defaults: defaults),
                                       activateAudioSession: { _ in XCTFail("No audio should start") })
        player.currentTime = 130
        let lyrics = (0..<80).map {
            LyricLine(id: "switch-\($0)", timestamp: Double($0 * 5),
                      text: "A paper lantern follows the quiet river \($0)", isSynchronized: true)
        }
        let fixture = PlayerCoverLyricsFixture()
        let probe = PlayerLyricsLifecycleProbe.State()
        let host = UIHostingController(rootView: PlayerCoverLyricsProbeView(
            fixture: fixture, probe: probe, player: player, lyrics: lyrics, defaults: defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.mountCount, 0, "Opening the cover must not lay out hidden lyrics")
        var scrollIdentity: ObjectIdentifier?
        var settledOffset: CGFloat?
        for _ in 0..<3 {
            fixture.visible = true
            try await Task.sleep(for: .milliseconds(500))
            let scroll = try XCTUnwrap(playerLyricsScrollView(in: host.view))
            XCTAssertEqual(probe.mountCount, 1)
            XCTAssertEqual(probe.unmountCount, 0)
            if let scrollIdentity { XCTAssertEqual(ObjectIdentifier(scroll), scrollIdentity) }
            else { scrollIdentity = ObjectIdentifier(scroll) }
            XCTAssertGreaterThan(scroll.contentOffset.y, 500)
            if let settledOffset { XCTAssertEqual(scroll.contentOffset.y, settledOffset, accuracy: 2) }
            else { settledOffset = scroll.contentOffset.y }
            fixture.visible = false
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertEqual(probe.unmountCount, 0, "Cover transitions must retain lyric layout and scroll state")
            XCTAssertGreaterThan(scroll.bounds.width, 0)
            XCTAssertGreaterThan(scroll.bounds.height, 0)
        }
    }

    func testRapidCoverSwitchesDisableHiddenLyricsHitTestingWithoutRemounting() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let suite = "PlayerCoverLyricsHitTesting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: PlayerAppearancePreferences.showsLyricsInterludeKey)
        defaults.set(true, forKey: PlayerAppearancePreferences.tapLyricsToSeekKey)
        let player = AudioPlayerService(playbackSettings: PlaybackSettingsStore(defaults: defaults),
                                       activateAudioSession: { _ in XCTFail("No audio should start") })
        player.currentTime = 130
        let lyrics = (0..<80).map {
            LyricLine(id: "rapid-switch-\($0)", timestamp: Double($0 * 5),
                      text: "Paper lanterns cross the moonlit bridge \($0)", isSynchronized: true)
        }
        let fixture = PlayerCoverLyricsFixture()
        let probe = PlayerLyricsLifecycleProbe.State()
        let host = UIHostingController(rootView: PlayerCoverLyricsProbeView(
            fixture: fixture, probe: probe, player: player, lyrics: lyrics, defaults: defaults))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        fixture.visible = true
        try await Task.sleep(for: .milliseconds(500))
        let scroll = try XCTUnwrap(playerLyricsScrollView(in: host.view))
        let settledOffset = scroll.contentOffset.y
        XCTAssertGreaterThan(settledOffset, 500)

        func lyricsReceiveHit() -> Bool {
            let point = scroll.convert(CGPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: window)
            let target = window.hitTest(point, with: nil)
            return target === scroll || target?.isDescendant(of: scroll) == true
        }

        XCTAssertTrue(lyricsReceiveHit(), "Visible lyrics must remain interactive")
        for _ in 0..<8 {
            fixture.visible = false
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertFalse(lyricsReceiveHit(), "Fading lyrics must stop intercepting cover taps immediately")
            fixture.visible = true
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(lyricsReceiveHit(), "Reversing the transition must restore lyric interaction")
            XCTAssertEqual(probe.mountCount, 1)
            XCTAssertEqual(probe.unmountCount, 0)
            XCTAssertTrue(playerLyricsScrollView(in: host.view) === scroll)
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(scroll.contentOffset.y, settledOffset, accuracy: 2)
        fixture.visible = false
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(lyricsReceiveHit(), "The settled cover must not expose hidden lyric tap targets")
    }

    func testFullBleedExtensionHasNoHardEdgeWhileCoverMovesAway() throws {
        let suite = "PlayerExtensionSeam.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: PlayerAppearancePreferences.fullBleedMiddleSofteningKey)
        let song = Song(id: suite, title: "Paper Lantern", fileFormat: .mp3, filePath: "", sourceID: "test")
        let cover = try XCTUnwrap(ImageRenderer(content: Color.red.frame(width: 200, height: 200)).uiImage?.cgImage)
        for edge in [FullBleedArtworkExtension.Edge.bottom, .trailing] {
            let combined = try XCTUnwrap(edge == .bottom
                ? PlayerBackdropImaging.fullBleedExtension(from: cover, fraction: 0.3)
                : PlayerBackdropImaging.fullBleedTrailingExtension(from: cover, fraction: 0.3))
            PlayerBackdropMemoryCache.shared.insert(combined, forKey:
                FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, edge: edge))
            for opacity in [0.25, 0.5, 1.0] {
                let size = edge == .bottom ? CGSize(width: 200, height: 400) : CGSize(width: 400, height: 200)
                let content = ZStack {
                    Color.green
                    FullBleedArtworkExtension(song: song, coverRevision: 0,
                        artworkRect: CGRect(x: 0, y: 0, width: 200, height: 200), pageSize: size,
                        isLight: false, strength: 0.7, usesIncreasedContrast: false,
                        allowsLoading: false, edge: edge)
                        .opacity(opacity)
                }
                .frame(width: size.width, height: size.height)
                .environment(SourceManager(sourcesProvider: { [] }))
                .defaultAppStorage(defaults)
                let rendered = try XCTUnwrap(ImageRenderer(content: content).uiImage?.cgImage)
                let pixels = try rgbaPixels(of: rendered)
                let extent = edge == .bottom ? rendered.height : rendered.width
                let values = (1..<(extent - 1)).map { position in
                    let x = edge == .bottom ? 100 : position
                    let y = edge == .bottom ? position : 100
                    return Int(pixels[(y * rendered.width + x) * 4])
                }
                let largestStep = zip(values, values.dropFirst()).map { abs($0 - $1) }.max() ?? 0
                XCTAssertLessThan(largestStep, 12, "A fading background must not reveal a horizontal or vertical color seam")
                XCTAssertGreaterThan(values.max() ?? 0, 40, "The extension should still preserve the cover color")
            }
        }
    }

    func testHomeCarouselReusesCardsAcrossLoopsAndResizing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let suite = "HomeCarouselRotation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let library = MusicLibrary(storageDirectory: directory, startsPreparing: true)
        let player = AudioPlayerService(
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            activateAudioSession: { _ in }
        )
        let songs = (0..<20).map {
            Song(id: "carousel-\($0)", title: "Paper Lantern \($0)", fileFormat: .mp3,
                 filePath: "", sourceID: suite)
        }
        let fixture = HomeCarouselTestData(songs: songs)
        var builtCards = 0
        HomeHeroCarouselDiagnostics.didBuildCard = { builtCards += 1 }
        let host = UIHostingController(rootView:
            GeometryReader { geometry in
                HomeHeroCarousel(
                    songs: fixture.songs,
                    compactCanvasHeight: geometry.size.width > geometry.size.height ? geometry.size.height : nil,
                    isInteractive: false, playFromSong: { _ in }, shuffleAll: {}, playAll: {}
                )
                .environment(\.layoutDirection, fixture.direction)
            }
            .environment(library)
            .environment(player)
            .environment(CoverTintProvider())
            .environment(SourceManager(sourcesProvider: { [] }))
            .defaultAppStorage(defaults)
        )
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.didMove(toParent: root)
        defer {
            HomeHeroCarouselDiagnostics.didBuildCard = nil
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        var scrollIdentity: ObjectIdentifier?
        var cardIdentities: Set<ObjectIdentifier>?
        for size in [CGSize(width: 393, height: 740), CGSize(width: 852, height: 300),
                     CGSize(width: 393, height: 740)] {
            let before = builtCards
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(750))
            XCTAssertLessThan(builtCards - before, 100,
                              "Resizing must not construct the carousel's 4,000 virtual artwork cards")
            let scroll = try XCTUnwrap(playerLyricsScrollView(in: host.view))
            let carousel = try XCTUnwrap(scroll as? HomeHeroCarouselScrollView)
            let cards = scroll.subviews.filter { $0.accessibilityIdentifier == "home.hero.card" }
            XCTAssertEqual(cards.count, 13)
            let identities = Set(cards.map(ObjectIdentifier.init))
            if let cardIdentities { XCTAssertEqual(identities, cardIdentities) }
            else { cardIdentities = identities }
            XCTAssertLessThan(scroll.contentSize.width, scroll.bounds.width + 13 * carousel.cardStep)
            let initialIndex = carousel.centeredItemIndex
            for direction in [1, -1] {
                for lap in 1...40 {
                    scroll.contentOffset.x += CGFloat(direction * 3) * carousel.cardStep
                    scroll.layoutIfNeeded()
                    let expected = HomeHeroCarouselLoop.index(
                        ofSlot: initialIndex + (direction == 1 ? lap * 3 : 120 - lap * 3),
                        itemCount: songs.count
                    )
                    XCTAssertEqual(carousel.centeredItemIndex, expected)
                    XCTAssertEqual(Set(scroll.subviews.filter {
                        $0.accessibilityIdentifier == "home.hero.card"
                    }.map(ObjectIdentifier.init)), identities, "Scrolling must reuse the same native card containers")
                    XCTAssertEqual(scroll.contentOffset.x, 6 * carousel.cardStep, accuracy: 0.1)
                }
            }
            XCTAssertEqual(carousel.centeredItemIndex, initialIndex)
            if let scrollIdentity {
                XCTAssertEqual(ObjectIdentifier(scroll), scrollIdentity)
            } else {
                scrollIdentity = ObjectIdentifier(scroll)
            }
        }

        let carousel = try XCTUnwrap(playerLyricsScrollView(in: host.view) as? HomeHeroCarouselScrollView)
        for decelerates in [false, true] {
            for fraction in [0.35, -0.35, 0.7, -0.7] {
                let start = carousel.centeredItemIndex
                carousel.contentOffset.x += (3 + fraction) * carousel.cardStep
                carousel.layoutIfNeeded()
                if decelerates {
                    carousel.delegate?.scrollViewDidEndDecelerating?(carousel)
                } else {
                    carousel.delegate?.scrollViewDidEndDragging?(carousel, willDecelerate: false)
                }
                try await Task.sleep(for: .milliseconds(400))
                XCTAssertEqual(carousel.centeredItemIndex,
                               HomeHeroCarouselLoop.index(ofSlot: start + Int((3 + fraction).rounded()),
                                                          itemCount: songs.count))
                XCTAssertEqual(carousel.contentOffset.x, 6 * carousel.cardStep, accuracy: 0.1,
                               "Ending a drag or deceleration must center the nearest card after recycling")
            }
        }
        let selectedID = fixture.songs[carousel.centeredItemIndex].id
        fixture.songs.reverse()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.songs[carousel.centeredItemIndex].id, selectedID,
                       "Refreshing the recommendations must retain the selected song")
        fixture.direction = .rightToLeft
        try await Task.sleep(for: .milliseconds(150))
        let rtlStart = carousel.centeredItemIndex
        carousel.contentOffset.x += 3 * carousel.cardStep
        carousel.layoutIfNeeded()
        XCTAssertEqual(carousel.centeredItemIndex,
                       HomeHeroCarouselLoop.index(ofSlot: rtlStart - 3, itemCount: songs.count))
        fixture.songs = [fixture.songs[carousel.centeredItemIndex]]
        try await Task.sleep(for: .milliseconds(150))
        for _ in 0..<20 {
            carousel.contentOffset.x += 5 * carousel.cardStep
            carousel.layoutIfNeeded()
            XCTAssertEqual(carousel.centeredItemIndex, 0)
        }
        fixture.songs = []
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(carousel.subviews.filter { $0.accessibilityIdentifier == "home.hero.card" }.isEmpty)
        fixture.songs = songs
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(carousel.subviews.filter { $0.accessibilityIdentifier == "home.hero.card" }.count, 13)
        XCTAssertTrue(songs.indices.contains(carousel.centeredItemIndex))
    }

    func testManualOrientationCompletesTheSystemRotationTransition() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Manual player orientation is only available on iPhone")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive && $0.session.role == .windowApplication })
        let previousWindow = scene.keyWindow
        let preference = InterfaceOrientationPreference(
            storedValue: UserDefaults.standard.string(forKey: InterfaceOrientationPreference.storageKey)
        )
        let suite = "PlayerRotationLyrics.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PlayerAppearancePreferences.showsLyricsInterludeKey)
        let player = AudioPlayerService(
            playbackSettings: PlaybackSettingsStore(defaults: defaults),
            activateAudioSession: { _ in }
        )
        player.currentTime = 130
        let lines = (0..<80).map { index in
            LyricLine(
                id: "rotation-line-\(index)", timestamp: Double(index * 5),
                text: index.isMultiple(of: 3)
                    ? "The morning train carries a paper lantern beyond the quiet valley \(index)"
                    : "A silver cloud follows the river \(index)",
                isSynchronized: true
            )
        }
        let lyricsProbe = PlayerLyricsLifecycleProbe.State()
        let controller = PlayerRotationProbeController(rootView: PlayerRotationProbeView(
            lyricsProbe: lyricsProbe, player: player, lyrics: lines, defaults: defaults
        ))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        UIView.performWithoutAnimation {
            PlayerOrientationControl.preferenceChanged(.automatic)
            window.layoutIfNeeded()
        }
        defer {
            PlayerOrientationControl.playerBecameInactive()
            PlayerOrientationControl.preferenceChanged(preference)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }

        var scrollIdentity: ObjectIdentifier?
        var settledAnchors: [Bool: CGFloat] = [:]
        for followsDevice in [false, true, false, true] {
            let wasLandscape = scene.interfaceOrientation.isLandscape
            controller.animatedTransitions.removeAll()
            controller.completedTransitions = 0
            PlayerOrientationControl.toggle(fromLandscape: wasLandscape, followsDevice: followsDevice)
            let deadline = Date.now.addingTimeInterval(3)
            while Date.now < deadline {
                if scene.interfaceOrientation.isLandscape != wasLandscape,
                   (controller.view.bounds.width > controller.view.bounds.height) != wasLandscape,
                   controller.completedTransitions > 0 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertNotEqual(scene.interfaceOrientation.isLandscape, wasLandscape)
            XCTAssertNotEqual(controller.view.bounds.width > controller.view.bounds.height, wasLandscape)
            XCTAssertFalse(controller.animatedTransitions.isEmpty, "The test must observe an actual window transition")
            XCTAssertTrue(controller.animatedTransitions.contains(true), "Manual rotation must preserve the system transition")
            XCTAssertGreaterThan(
                controller.completedTransitions, 0,
                "The transition to \(wasLandscape ? "portrait" : "landscape") must finish; followsDevice=\(followsDevice)"
            )
            XCTAssertEqual(lyricsProbe.mountCount, 1, "The lyric scroll surface must survive layout changes")
            XCTAssertEqual(lyricsProbe.unmountCount, 0)
            let lyricView = try XCTUnwrap(lyricsProbe.view)
            XCTAssertGreaterThan(lyricView.bounds.width, 0)
            XCTAssertGreaterThan(lyricView.bounds.height, 0)
            try await Task.sleep(for: .milliseconds(100))
            let scroll = try XCTUnwrap(playerLyricsScrollView(in: controller.view))
            if let scrollIdentity {
                XCTAssertEqual(ObjectIdentifier(scroll), scrollIdentity, "Rotation must retain the native lyric scroll view")
            } else {
                scrollIdentity = ObjectIdentifier(scroll)
            }
            XCTAssertGreaterThan(scroll.contentOffset.y, 500, "The current lyric must remain midway through the song")
            let anchor = try currentLyricInkAnchor(in: scroll)
            XCTAssertGreaterThan(anchor, 0, "The current lyric must remain visible")
            XCTAssertLessThan(anchor, scroll.bounds.height)
            let landscape = scene.interfaceOrientation.isLandscape
            if let settledAnchor = settledAnchors[landscape] {
                XCTAssertEqual(anchor, settledAnchor, accuracy: 2, "Returning to a layout must restore the current lyric anchor")
            }
            settledAnchors[landscape] = anchor
            XCTAssertTrue(UIView.areAnimationsEnabled, "Other app animations must remain enabled")
        }
    }

    private func currentLyricInkAnchor(in scroll: UIScrollView) throws -> CGFloat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: scroll.bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: scroll.bounds.size))
            scroll.drawHierarchy(in: CGRect(origin: .zero, size: scroll.bounds.size), afterScreenUpdates: true)
        }
        add(XCTAttachment(image: image))
        let bitmap = try XCTUnwrap(image.cgImage)
        let pixels = try rgbaPixels(of: bitmap)
        var inkRows: [Int] = []
        for y in 0..<bitmap.height {
            let hasInk = (0..<bitmap.width).contains { x in
                let offset = (y * bitmap.width + x) * 4
                return pixels[offset] < 45 && pixels[offset + 1] < 45 && pixels[offset + 2] < 45
            }
            if hasInk { inkRows.append(y) }
        }
        let first = try XCTUnwrap(inkRows.first, "The active lyric must be rendered inside the viewport")
        let last = try XCTUnwrap(inkRows.last)
        return CGFloat(first + last) / 2
    }

    func testDiscPNGPreservesTransparentCenterThroughDiskCache() throws {
        let original = try transparentDiscPNG()
        let encoded = try XCTUnwrap(PlayerBackdropImaging.downscaledPNG(from: original, maxPixel: 100))
        let key = "disc-alpha-test-\(UUID().uuidString)"
        let url = PlayerBackdropAlbumBackCache.fileURL(forKey: key, preservingAlpha: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNotEqual(url, PlayerBackdropAlbumBackCache.fileURL(forKey: key))
        PlayerBackdropAlbumBackCache.store(encoded, forKey: key, preservingAlpha: true)
        let image = try XCTUnwrap(PlayerBackdropImaging.decodedImage(url: url, maxPixel: 100))
        XCTAssertEqual(image.width, 100)
        let pixels = try rgbaPixels(of: image)
        XCTAssertEqual(pixels[(50 * 100 + 50) * 4 + 3], 0)
        XCTAssertEqual(pixels[3], 0)
        XCTAssertGreaterThan(pixels[(50 * 100 + 80) * 4], 180)
        XCTAssertEqual(pixels[(50 * 100 + 80) * 4 + 3], 255)
    }

    func testTransparentDiscCenterRendersDarkInBothStyles() throws {
        let face = try XCTUnwrap(PlayerBackdropImaging.decodedImage(data: transparentDiscPNG(), maxPixel: 200))
        for isCompactDisc in [false, true] {
            let renderer = ImageRenderer(content: ImmersiveVinylRecord(
                palette: .fallback, isSpinning: false, reduceMotion: true,
                diameter: 200, face: face, isCompactDisc: isCompactDisc
            ) { _ in Color.red })
            let rendered = try XCTUnwrap(renderer.uiImage?.cgImage)
            let pixels = try rgbaPixels(of: rendered)
            let center = (rendered.height / 2 * rendered.width + rendered.width / 2) * 4
            XCTAssertLessThan(pixels[center], 45)
            XCTAssertLessThan(pixels[center + 1], 45)
            XCTAssertLessThan(pixels[center + 2], 45)
            XCTAssertEqual(pixels[center + 3], 255)
        }
    }

    func testCDSpreadsTheAlbumAcrossTheDiscAndKeepsItsCenterEmpty() throws {
        var surfaceRed: [UInt8] = []
        for isCompactDisc in [false, true] {
            let renderer = ImageRenderer(content: ImmersiveVinylRecord(
                palette: .fallback, isSpinning: false, reduceMotion: true,
                diameter: 200, face: nil, isCompactDisc: isCompactDisc
            ) { _ in Color.red })
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            let pixels = try rgbaPixels(of: image)
            let center = (100 * image.width + 100) * 4
            XCTAssertLessThan(pixels[center], 45)
            XCTAssertLessThan(pixels[center + 1], 45)
            XCTAssertLessThan(pixels[center + 2], 45)
            surfaceRed.append(pixels[(100 * image.width + 165) * 4])
        }
        XCTAssertGreaterThan(Int(surfaceRed[1]) - Int(surfaceRed[0]), 120)
    }

    private func transparentDiscPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: 200, height: 200))
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: 70, y: 70, width: 60, height: 60))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func makeJPEG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(PlayerBackdropImaging.jpegData(image, quality: 0.9))
    }

    func testTwelveMegapixelPhotoIsStoredAtScreenSizeAndDecodesQuickly() throws {
        let original = try makeJPEG(width: 4032, height: 3024)
        let maxPixel = PlayerBackdropPixelPolicy.storagePixel(forDisplayLongSide: 2868)

        let importStart = Date()
        let id = try XCTUnwrap(PlayerBackdropImageStore.importImage(original, maxPixel: maxPixel))
        let importSeconds = Date().timeIntervalSince(importStart)
        defer { PlayerBackdropImageStore.remove(id: id) }

        XCTAssertTrue(PlayerBackdropImageStore.exists(id: id))
        XCTAssertTrue(LibraryArtworkContentIDPolicy.isValid(id))
        let stored = try XCTUnwrap(PlayerBackdropImageStore.data(id: id))
        XCTAssertLessThan(stored.count, original.count)
        XCTAssertEqual(PlayerBackdropImaging.contentID(for: stored), id)

        let decodeStart = Date()
        let url = try XCTUnwrap(PlayerBackdropImageStore.fileURL(id: id))
        let decoded = try XCTUnwrap(PlayerBackdropImaging.decodedImage(url: url, maxPixel: maxPixel))
        let decodeSeconds = Date().timeIntervalSince(decodeStart)
        XCTAssertEqual(max(decoded.width, decoded.height), maxPixel)
        XCTAssertEqual(min(decoded.width, decoded.height), maxPixel * 3 / 4)
        // 计时只记下来看，不做断言：编译机常年高负载，计时断言会假失败。
        print("🖼 backdrop import 12MP=\(importSeconds)s decode=\(decodeSeconds)s")

        // 同一张图再导入一次得到同一个 id，不重复占空间。
        XCTAssertEqual(PlayerBackdropImageStore.importImage(original, maxPixel: maxPixel), id)
    }

    func testUnreadableDataIsRejected() {
        XCTAssertNil(PlayerBackdropImageStore.importImage(Data("not an image".utf8), maxPixel: 2_048))
        XCTAssertNil(PlayerBackdropImageStore.importImage(Data(), maxPixel: 2_048))
    }

    func testTransferredImageMustMatchItsID() throws {
        let jpeg = try makeJPEG(width: 640, height: 360)
        let id = PlayerBackdropImaging.contentID(for: jpeg)
        XCTAssertNil(PlayerBackdropImageStore.storeProcessed(jpeg, expectedID: String(repeating: "0", count: 64)))
        XCTAssertEqual(PlayerBackdropImageStore.storeProcessed(jpeg, expectedID: id), id)
        PlayerBackdropImageStore.remove(id: id)
        XCTAssertFalse(PlayerBackdropImageStore.exists(id: id))
    }

    func testCoverBlurIsASmallStaticBitmap() throws {
        let data = try makeJPEG(width: 1_200, height: 1_200)
        let cover = try XCTUnwrap(PlayerBackdropImaging.decodedImage(data: data, maxPixel: 1_200))
        let blurred = try XCTUnwrap(PlayerBackdropImaging.blurredBackdrop(from: cover))
        XCTAssertLessThanOrEqual(max(blurred.width, blurred.height), PlayerBackdropPixelPolicy.blurSourcePixel)
        XCTAssertGreaterThan(blurred.width, 0)
    }

    /// 铺满封面的延伸底图：封面下沿那一条接上它的镜像，接缝处是封面最下面的颜色，两头是往上一点的颜色。
    func testFullBleedExtensionMirrorsTheBottomEdgeAroundTheSeam() throws {
        let side = 400
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // CGContext 原点在左下：先铺橙色，再在最下面 10% 画一道红。
        context.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(red: 0.9, green: 0.08, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side / 10))
        let cover = try XCTUnwrap(context.makeImage())

        let extended = try XCTUnwrap(PlayerBackdropImaging.fullBleedExtension(from: cover, fraction: 0.4))
        XCTAssertLessThanOrEqual(extended.width, 96)
        // 上下两半各是封面高度的 0.4，按同一比例缩小。
        XCTAssertEqual(Double(extended.height), Double(extended.width) * 0.8, accuracy: 2)

        let pixels = try rgbaPixels(of: extended)
        func green(row: Int) -> UInt8 { pixels[(row * extended.width + extended.width / 2) * 4 + 1] }
        let seam = extended.height / 2
        XCTAssertLessThan(green(row: seam), green(row: 1))
        XCTAssertLessThan(green(row: seam), green(row: extended.height - 2))
    }

    func testControlBackdropKeepsArtworkColorAndCanBeDisabled() throws {
        let suite = "PlayerBackdropColor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let song = Song(id: suite, title: "Artwork", fileFormat: .mp3, filePath: "", sourceID: "test")
        let cover = try XCTUnwrap(ImageRenderer(content: Color(red: 1, green: 0, blue: 0).frame(width: 200, height: 200)).uiImage?.cgImage)
        let combined = try XCTUnwrap(PlayerBackdropImaging.fullBleedExtension(from: cover, fraction: 0.3, aspectRatio: 0.8))
        let key = FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, aspectRatio: 0.8)
        PlayerBackdropMemoryCache.shared.insert(combined, forKey: key)
        for isLight in [false, true] {
            for softens in [false, true] {
                defaults.set(softens, forKey: PlayerAppearancePreferences.fullBleedMiddleSofteningKey)
                let view = ZStack {
                    Color(red: 0, green: 1, blue: 0)
                    FullBleedArtworkExtension(song: song, coverRevision: 0,
                        artworkRect: CGRect(x: 0, y: 0, width: 200, height: 250),
                        pageSize: CGSize(width: 200, height: 400), isLight: isLight,
                        strength: 0.7, usesIncreasedContrast: false, allowsLoading: false)
                }.frame(width: 200, height: 400)
                    .environment(SourceManager(sourcesProvider: { [] }))
                    .defaultAppStorage(defaults)
                let image = try XCTUnwrap(ImageRenderer(content: view).uiImage?.cgImage)
                let pixels = try rgbaPixels(of: image)
                // 两个方向各取一行，其中只有控制区会被封面延伸覆盖。
                let samples = [40, 360].map { row in Array(pixels[(row * 200 + 100) * 4..<(row * 200 + 100) * 4 + 4]) }
                if softens {
                    XCTAssertTrue(samples.contains { $0[0] > 170 && $0[1] < 100 && $0[2] < 100 })
                } else {
                    XCTAssertTrue(samples.allSatisfy { $0[0] < 10 && $0[1] > 100 && $0[2] < 10 })
                }
            }
        }
    }

    func testFullBleedSamplingMatchesPortraitAndLandscapeCrop() throws {
        let data = try makeJPEG(width: 800, height: 400)
        let image = try XCTUnwrap(PlayerBackdropImaging.decodedImage(data: data, maxPixel: 800))
        let portrait = try XCTUnwrap(PlayerBackdropImaging.fullBleedViewport(from: image, aspectRatio: 0.8))
        let landscape = try XCTUnwrap(PlayerBackdropImaging.fullBleedViewport(from: image, aspectRatio: 1.6))
        XCTAssertEqual(portrait.width, 320)
        XCTAssertEqual(portrait.height, 400)
        XCTAssertEqual(landscape.width, 400)
        XCTAssertEqual(landscape.height, 250)
        let softenedTop = try XCTUnwrap(PlayerBackdropImaging.fullBleedTopSoftening(from: image))
        XCTAssertEqual(softenedTop.width, softenedTop.height)
        let extensionImage = try XCTUnwrap(PlayerBackdropImaging.fullBleedExtension(
            from: image, fraction: 0.3, aspectRatio: 0.8
        ))
        XCTAssertEqual(Double(extensionImage.height) / Double(extensionImage.width), 0.75, accuracy: 0.03)
    }

    func testFullBleedCacheSeparatesOrientationAndFadeRegion() {
        let song = Song(id: "softening-test", title: "Artwork", fileFormat: .mp3, filePath: "", sourceID: "test")
        let portrait = FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, aspectRatio: 0.8)
        let landscape = FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, edge: .trailing, aspectRatio: 1.6)
        XCTAssertNotEqual(portrait, landscape)
        XCTAssertNotEqual(portrait, FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, aspectRatio: 1))
        XCTAssertNotEqual(portrait, FullBleedArtworkExtensionImages.cacheKey(song: song, coverRevision: 0, aspectRatio: 0.8, fraction: 0.5))
    }

    func testArtworkKeepsCircleRoundAcrossRotationFrames() throws {
        let portrait = CGRect(x: 0, y: 0, width: 320, height: 400)
        let landscape = CGRect(x: 0, y: 0, width: 480, height: 300)
        for step in 0...10 {
            let progress = CGFloat(step) / 10
            let rect = CGRect(x: 0, y: 0,
                              width: portrait.width + (landscape.width - portrait.width) * progress,
                              height: portrait.height + (landscape.height - portrait.height) * progress)
            let artwork = ZStack {
                Color.black
                Circle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 160, height: 160)
            }
            .modifier(LyricsArtworkFlight(rect: rect, cornerRadius: 0, shadow: .init(),
                                          bottomFade: 0, trailingFade: 0, renderSize: 512))
            .frame(width: rect.width, height: rect.height)
            let image = try XCTUnwrap(ImageRenderer(content: artwork).uiImage?.cgImage)
            let pixels = try rgbaPixels(of: image)
            var xs: [Int] = []
            var ys: [Int] = []
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let offset = (y * image.width + x) * 4
                    if pixels[offset] > 220 && pixels[offset + 1] < 30 {
                        xs.append(x)
                        ys.append(y)
                    }
                }
            }
            let width = try XCTUnwrap(xs.max()) - XCTUnwrap(xs.min()) + 1
            let height = try XCTUnwrap(ys.max()) - XCTUnwrap(ys.min()) + 1
            XCTAssertEqual(width, height, accuracy: 2, "Rotation frame \(step)")
            XCTAssertEqual(Double(width), Double(max(rect.width, rect.height) * 160 / 512), accuracy: 3)
        }
    }

    /// 方形卡片框里长方形封面整张放进去，四条边都在。铺满的封面位改成盖满(见下一条)。
    func testRectangularArtworkKeepsEveryEdgeInCards() throws {
        for sourceSize in [CGSize(width: 120, height: 240), CGSize(width: 240, height: 120)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
                UIColor.darkGray.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: sourceSize.width, height: 12))
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: sourceSize.height - 12, width: sourceSize.width, height: 12))
                UIColor.green.setFill()
                context.fill(CGRect(x: 0, y: 12, width: 12, height: sourceSize.height - 24))
                UIColor.yellow.setFill()
                context.fill(CGRect(x: sourceSize.width - 12, y: 12, width: 12, height: sourceSize.height - 24))
            }
            for rect in [CGRect(x: 0, y: 0, width: 320, height: 320)] {
                let top: CGFloat = 0
                let bottom: CGFloat = 0
                let trailing: CGFloat = 0
                let artwork = UncroppedArtwork(image: source) {
                    Image(uiImage: source).resizable().scaledToFill()
                }
                .modifier(LyricsArtworkFlight(rect: rect, cornerRadius: 0, shadow: .init(),
                    bottomFade: bottom, trailingFade: trailing, renderSize: 512, topContentInset: top))
                .frame(width: rect.width, height: rect.height)
                let renderer = ImageRenderer(content: artwork)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "rectangular-cover-\(Int(sourceSize.width))x\(Int(sourceSize.height))-\(Int(rect.width))x\(Int(rect.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                let pixels = try rgbaPixels(of: image)
                let visible = CGRect(x: 0, y: top, width: rect.width * (1 - trailing),
                                     height: rect.height * (1 - bottom) - top)
                let fitted = ArtworkContentLayout.fittedRect(imageSize: sourceSize, in: visible)
                let edgeInset = 6 * fitted.width / sourceSize.width
                let samples: [(CGPoint, [Int])] = [
                    (CGPoint(x: fitted.midX, y: fitted.minY + edgeInset), [255, 0, 0]),
                    (CGPoint(x: fitted.midX, y: fitted.maxY - edgeInset), [0, 0, 255]),
                    (CGPoint(x: fitted.minX + edgeInset, y: fitted.midY), [0, 255, 0]),
                    (CGPoint(x: fitted.maxX - edgeInset, y: fitted.midY), [255, 255, 0]),
                ]
                for (point, expected) in samples {
                    let offset = (Int(point.y) * image.width + Int(point.x)) * 4
                    for channel in 0..<3 {
                        XCTAssertEqual(Double(pixels[offset + channel]), Double(expected[channel]), accuracy: 10,
                                       "\(sourceSize) in \(rect.size), edge at \(point)")
                    }
                }
            }
        }
    }

    /// 铺满的封面位里长方形封面和方封面一样盖满整个槽位，包括接近方形的铺满槽位(手机横屏、封面下歌词选
    /// 「自动」时的方形槽位)：槽位四角是封面本身(细条纹清楚)，不是垫在底下的模糊底(一片匀色)。
    /// 封面像素多少不影响：源图只有 120×240，照样按槽位放大。
    func testRectangularArtworkFillsEveryFullBleedSlot() throws {
        for sourceSize in [CGSize(width: 120, height: 240), CGSize(width: 240, height: 120)] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let source = UIGraphicsImageRenderer(size: sourceSize, format: format).image { context in
                UIColor.black.setFill()
                context.fill(CGRect(origin: .zero, size: sourceSize))
                UIColor.white.setFill()
                for x in stride(from: 0, to: Int(sourceSize.width), by: 4) {
                    context.fill(CGRect(x: CGFloat(x), y: 0, width: 2, height: sourceSize.height))
                }
            }
            // (槽位, 上沿让开的高度, 下沿渐隐, 尾侧渐隐)
            let slots: [(CGRect, CGFloat, CGFloat, CGFloat)] = [
                (CGRect(x: 0, y: 0, width: 320, height: 400), 120, 0.15, 0),
                (CGRect(x: 0, y: 0, width: 320, height: 320), 120, 0.4, 0),
                (CGRect(x: 0, y: 0, width: 480, height: 300), 0, 0, 0.15),
                (CGRect(x: 0, y: 0, width: 394, height: 402), 0, 0, 0.36),
            ]
            for (rect, top, bottom, trailing) in slots {
                let artwork = UncroppedArtwork(image: source) {
                    Image(uiImage: source).resizable().scaledToFill()
                }
                .modifier(LyricsArtworkFlight(rect: rect, cornerRadius: 0, shadow: .init(),
                    bottomFade: bottom, trailingFade: trailing, renderSize: 512,
                    topContentInset: top, contentFill: 1))
                .frame(width: rect.width, height: rect.height)
                let renderer = ImageRenderer(content: artwork)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage?.cgImage)
                let attachment = XCTAttachment(image: UIImage(cgImage: image))
                attachment.name = "full-bleed-cover-\(Int(sourceSize.width))x\(Int(sourceSize.height))-\(Int(rect.width))x\(Int(rect.height))"
                attachment.lifetime = .keepAlways
                add(attachment)
                let pixels = try rgbaPixels(of: image)
                // 四角各取 24×24 一块，避开下沿与尾侧渐隐那一截。
                let right = Int(rect.width * (1 - trailing)) - 30
                let lower = Int(rect.height * (1 - bottom)) - 30
                for corner in [(6, 6), (right, 6), (6, lower), (right, lower)] {
                    var values: [Int] = []
                    for y in corner.1..<(corner.1 + 24) {
                        for x in corner.0..<(corner.0 + 24) {
                            values.append(Int(pixels[(y * image.width + x) * 4]))
                        }
                    }
                    let contrast = (values.max() ?? 0) - (values.min() ?? 0)
                    XCTAssertGreaterThan(contrast, 150,
                                         "\(sourceSize) in \(rect.size): corner \(corner) shows the blurred backdrop, not the cover")
                }
            }
        }
    }

    func testAudiobookProgressMovesTrackWithoutShrinkingScrubArea() async throws {
        let suite = "AudiobookProgress-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(PlayerTrackThickness.standard.rawValue, forKey: PlayerAppearancePreferences.progressThicknessKey)

        func trackDisplacement(_ chapter: ProgressSlider.TrackStyle) async throws -> Double {
            var centered = chapter
            centered.verticalOffset = 0
            func slider(_ style: ProgressSlider.TrackStyle) -> some View {
                ProgressSlider(value: 80, total: 200,
                               fillTint: Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1),
                               trackStyle: style, onSeek: { _ in })
                    .frame(width: 200)
            }
            let pair = VStack(spacing: 0) {
                slider(centered)
                slider(chapter)
            }
            .environment(ThemeService())
            .defaultAppStorage(defaults)
            .transaction { $0.disablesAnimations = true }
            .ignoresSafeArea()
            let host = UIHostingController(rootView: pair)
            let fitted = host.sizeThatFits(in: CGSize(width: 200, height: 200))
            XCTAssertEqual(fitted.height, 88, accuracy: 0.5)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: fitted)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true; window.rootViewController = nil }
            try await Task.sleep(for: .milliseconds(150))
            host.view.layoutIfNeeded()
            for y in [CGFloat(1), CGFloat(43), CGFloat(45), CGFloat(87)] {
                XCTAssertNotNil(host.view.hitTest(CGPoint(x: 100, y: y), with: nil))
            }
            let format = UIGraphicsImageRendererFormat()
            format.scale = window.screen.scale
            let rendered = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let image = try XCTUnwrap(rendered.cgImage)
            XCTAssertEqual(Double(image.height) / Double(format.scale), 88, accuracy: 0.5)
            let pixels = try rgbaPixels(of: image)
            func center(in range: Range<Int>) throws -> Double {
                let rows = range.filter { row in
                    let offset = (row * image.width + Int(40 * format.scale)) * 4
                    return pixels[offset] > 180 && pixels[offset + 1] < 30 && pixels[offset + 3] > 180
                }
                return Double(try XCTUnwrap(rows.first) + XCTUnwrap(rows.last)) / (2 * Double(format.scale))
            }
            let split = Int(44 * format.scale)
            let displacement = try center(in: 0..<split) - (center(in: split..<image.height) - 44)
            if abs(displacement - 6) > 0.5 {
                let attachment = XCTAttachment(image: rendered)
                attachment.name = "Progress track pair offset \(chapter.verticalOffset)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            return displacement
        }

        for selected in NowPlayingProgressStyle.allCases {
            for follows in [false, true] {
                let chapter = AudiobookProgressBar.trackStyle(selected: selected, glows: false,
                                                              followsProgressStyle: follows, trackColor: .clear)
                let displacement = try await trackDisplacement(chapter)
                XCTAssertEqual(displacement, 6, accuracy: 0.5,
                               "style=\(selected), follows=\(follows)")
            }
        }
    }

    func testMiddleSofteningDoesNotChangeTopAndSwitchesIndependently() throws {
        let suite = "PlayerSoftening-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: PlayerAppearancePreferences.fullBleedTopSofteningKey)
        func render(_ softens: Bool) throws -> [UInt8] {
            defaults.set(softens, forKey: PlayerAppearancePreferences.fullBleedMiddleSofteningKey)
            let view = PreviewFullBleedArtwork(width: 200, height: 250, topSafeArea: 0,
                                               appearance: .init(colorScheme: .dark, contrast: .standard)) {
                Color.red
            }.defaultAppStorage(defaults)
            return try rgbaPixels(of: XCTUnwrap(ImageRenderer(content: view).uiImage?.cgImage))
        }
        let on = try render(true)
        let off = try render(false)
        let top = (80 * 200 + 100) * 4
        let bottom = (245 * 200 + 100) * 4
        XCTAssertTrue(on[top] == off[top])
        XCTAssertNotEqual(on, off)
        XCTAssertEqual(off[bottom + 3], 255)
        XCTAssertFalse(defaults.bool(forKey: PlayerAppearancePreferences.fullBleedTopSofteningKey))
        XCTAssertEqual(SettingsCatalog.byID["appearance.fullBleedMiddleSoftening"]?.page, .playerStyle)
    }

    private func rgbaPixels(of image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    func testCustomImageListStaysLocalAndRemovingDeletesTheFile() throws {
        let suite = "PlayerBackdropImagingTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        let first = try XCTUnwrap(PlayerBackdropImageStore.importImage(try makeJPEG(width: 800, height: 600), maxPixel: 1_280))
        let second = try XCTUnwrap(PlayerBackdropImageStore.importImage(try makeJPEG(width: 600, height: 800), maxPixel: 1_280))
        defer {
            PlayerBackdropImageStore.remove(id: first)
            PlayerBackdropImageStore.remove(id: second)
        }

        store.update { $0.source = .customImages }
        XCTAssertEqual(store.effectiveSource, .coverAmbient)
        store.appendCustomImages([first, second, first])
        XCTAssertEqual(store.customImageIDs, [first, second])
        XCTAssertEqual(store.effectiveSource, .customImages)
        XCTAssertEqual(defaults.stringArray(forKey: PlayerBackdropSettings.customImagesStorageKey), [first, second])

        // 同步的那份设置里只有来源与轮播，没有图片列表。
        let synced = try XCTUnwrap(defaults.data(forKey: PlayerBackdropSettings.storageKey))
        XCTAssertFalse(String(decoding: synced, as: UTF8.self).contains(first))

        store.removeCustomImage(first)
        XCTAssertEqual(store.customImageIDs, [second])
        XCTAssertFalse(PlayerBackdropImageStore.exists(id: first))

        let reloaded = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        XCTAssertEqual(reloaded.customImageIDs, [second])
        XCTAssertEqual(reloaded.settings.source, .customImages)
    }
}

@MainActor
@Observable
private final class HomeCarouselTestData {
    var songs: [Song]
    var direction: LayoutDirection = .leftToRight

    init(songs: [Song]) { self.songs = songs }
}

@MainActor
private final class PlayerRotationProbeController: UIHostingController<PlayerRotationProbeView> {
    var animatedTransitions: [Bool] = []
    var completedTransitions = 0

    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        animatedTransitions.append(coordinator.isAnimated)
        coordinator.animateAlongsideTransition(in: view, animation: nil) { [weak self] _ in
            self?.completedTransitions += 1
        }
    }
}

@Observable
private final class PlayerCoverLyricsFixture {
    var visible = false
}

private struct PlayerCoverLyricsProbeView: View {
    let fixture: PlayerCoverLyricsFixture
    let probe: PlayerLyricsLifecycleProbe.State
    let player: AudioPlayerService
    let lyrics: [LyricLine]
    let defaults: UserDefaults

    var body: some View {
        VStack {
            Color.cyan.frame(height: 80)
            if fixture.visible {
                PlayerLyricsViewportSlot(collapsesChromeOnScroll: true)
            } else {
                Color.cyan
            }
            Color.cyan.frame(height: 120)
        }
        .modifier(PlayerLyricsViewportOverlay(isActive: true, isVisible: fixture.visible) { _ in
            LyricsScrollView(lyrics: lyrics, lyricsWritingDirection: .leftToRight, lyricsRevision: 0,
                isResolvingLyrics: false, player: player, songID: "switch-lyrics",
                isSceneActive: fixture.visible, isScrapingCurrentSong: false, canTranscribeAudio: false,
                isScrapeActionUnavailable: true, onAutomaticScrape: {}, onTranscribeAudio: {},
                onBackgroundTap: {}, onShareLyricLine: { _ in }, translatedTextByLineID: [:],
                translationActivity: .idle)
                .defaultAppStorage(defaults)
                .background(PlayerLyricsLifecycleProbe(state: probe))
        })
        .animation(.easeInOut(duration: 0.25), value: fixture.visible)
    }
}

private struct PlayerRotationProbeView: View {
    let lyricsProbe: PlayerLyricsLifecycleProbe.State
    let player: AudioPlayerService
    let lyrics: [LyricLine]
    let defaults: UserDefaults

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if geometry.size.width > geometry.size.height {
                    HStack {
                        Color.cyan.frame(width: 160)
                        PlayerLyricsViewportSlot()
                    }
                } else {
                    VStack {
                        Color.cyan.frame(height: 80)
                        PlayerLyricsViewportSlot(collapsesChromeOnScroll: true)
                        Color.cyan.frame(height: 120)
                    }
                }
            }
            .modifier(PlayerLyricsViewportOverlay(isActive: true) { _ in
                LyricsScrollView(
                    lyrics: lyrics, lyricsWritingDirection: .leftToRight, lyricsRevision: 0,
                    isResolvingLyrics: false, player: player, songID: "rotation-lyrics",
                    isSceneActive: true, isScrapingCurrentSong: false, canTranscribeAudio: false,
                    isScrapeActionUnavailable: true, onAutomaticScrape: {}, onTranscribeAudio: {},
                    onBackgroundTap: {}, onShareLyricLine: { _ in },
                    translatedTextByLineID: [:], translationActivity: .idle
                )
                .defaultAppStorage(defaults)
                .background(PlayerLyricsLifecycleProbe(state: lyricsProbe))
            })
        }
        .background(Color.cyan)
        .environment(\.colorScheme, .light)
        .ignoresSafeArea()
    }
}

@MainActor
private func playerLyricsScrollView(in view: UIView) -> UIScrollView? {
    if let scroll = view as? UIScrollView { return scroll }
    return view.subviews.lazy.compactMap { playerLyricsScrollView(in: $0) }.first
}

private struct PlayerLyricsLifecycleProbe: UIViewRepresentable {
    @MainActor
    final class State {
        var mountCount = 0
        var unmountCount = 0
        weak var view: UIView?
    }

    let state: State

    func makeCoordinator() -> State { state }

    func makeUIView(context: Context) -> UIView {
        state.mountCount += 1
        let view = UIView()
        view.backgroundColor = .systemTeal
        state.view = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: State) {
        coordinator.unmountCount += 1
    }
}
