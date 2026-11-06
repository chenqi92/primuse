import XCTest
import SwiftUI
import UIKit
import Observation
import PrimuseKit
@testable import Primuse

final class StandardLibrarySectionTabsTests: XCTestCase {
    func testSubtabsRemainVisibleWithoutTriggersAndCollapseWithEitherTrigger() {
        for pull in [false, true] {
            for doubleTap in [false, true] {
                let presentation = HomeSubtabPresentation(pullDown: pull, doubleTap: doubleTap)
                XCTAssertEqual(presentation.isVisible(enabled: true, expanded: false), !pull && !doubleTap)
                XCTAssertTrue(presentation.isVisible(enabled: true, expanded: true))
                XCTAssertFalse(presentation.isVisible(enabled: false, expanded: true))
            }
        }
    }

    func testSubtabPullIgnoresShortAndHorizontalDrags() {
        XCTAssertFalse(HomeSubtabPresentation.acceptsPull(translationX: 0, translationY: 12))
        XCTAssertFalse(HomeSubtabPresentation.acceptsPull(translationX: 60, translationY: 35))
        XCTAssertTrue(HomeSubtabPresentation.acceptsPull(translationX: 4, translationY: 35))
        XCTAssertTrue(HomeSubtabPresentation.acceptsPull(translationX: 4, translationY: -35))
    }

    @MainActor
    func testShelfSubtabsFilterBooksAndExpandFinishedWithoutChangingSavedPreference() async throws {
        let suite = "HomeShelfSubtabsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        let songs = (0..<3).map { index in
            Song(id: "subtab-book-\(index)", title: "Chapter", albumTitle: "Book \(index)",
                 artistName: "Author", duration: 300,
                 fileFormat: .m4a, filePath: "/subtabs/\(index).m4b", sourceID: suite, genre: "Audiobook")
        }
        let model = SpokenWordBooksModel()
        await model.refresh(
            songs: songs,
            positions: [songs[0].id: .init(position: 60, duration: 300, updatedAt: Date())],
            finishedAt: [songs[2].id: Date()]
        )
        let snapshot = model.snapshot
        XCTAssertEqual(snapshot.shelf.count, 1)
        XCTAssertEqual(snapshot.finished.count, 1)
        var built: Set<String> = []
        SpokenWordShelfDiagnostics.didBuildCell = { built.insert($0) }
        defer { SpokenWordShelfDiagnostics.didBuildCell = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        defer { window.isHidden = true; window.rootViewController = nil }
        for section in [SpokenWordShelfSection.shelf, .finished] {
            built = []
            let host = UIHostingController(rootView: ScrollView {
                SpokenWordShelfContent(snapshot: snapshot, showsArchived: false, section: section)
                    .padding(.horizontal, 16)
            }
                .environment(library)
                .environment(AppServices.shared.playerService)
                .environment(AppServices.shared.sourceManager)
                .environment(ThemeService())
                .defaultAppStorage(defaults))
            window.rootViewController = host
            window.isHidden = false
            try await Task.sleep(for: .milliseconds(500))
            let expected = section == .shelf ? snapshot.shelf : snapshot.finished
            XCTAssertEqual(built, Set(expected.map(\.id)))
            XCTAssertFalse(defaults.bool(forKey: "spokenWord.shelf.showsFinished"))
            attach(window, name: "home-subtabs-books-\(section.rawValue)")
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @MainActor
    func testDefaultIsOffAndRestoreDefaultsTurnsItOff() {
        withDefaults { defaults in
            let key = HomeFilterBarConfiguration.showsLibrarySectionsKey
            XCTAssertFalse(defaults.bool(forKey: key))
            defaults.set(true, forKey: key)
            defaults.set(true, forKey: HomeSubtabPresentation.pullDownKey)
            defaults.set(true, forKey: HomeSubtabPresentation.doubleTapKey)
            XCTAssertTrue(defaults.bool(forKey: key))
            HomeView.restoreDefaultSectionVisibility(defaults: defaults)
            XCTAssertFalse(defaults.bool(forKey: key))
            XCTAssertFalse(defaults.bool(forKey: HomeSubtabPresentation.pullDownKey))
            XCTAssertFalse(defaults.bool(forKey: HomeSubtabPresentation.doubleTapKey))
        }
    }

    func testMusicTabsFollowLibraryOrderAndHiddenSections() {
        let first: [LibrarySection] = [.artists, .albums, .songs, .favorites]
        let order = first + LibraryDisplayConfiguration.defaultSectionOrder.filter { !first.contains($0) }
        let visible = LibraryDisplayConfiguration.visibleSections(
            orderRawValue: LibraryDisplayConfiguration.encodeSectionOrder(order),
            hiddenRawValue: LibraryDisplayConfiguration.encodeHiddenSections([.albums, .genres])
        )
        let tabs = StandardLibrarySectionTabsPolicy.sections(
            enabled: true, mode: .standard, selection: .songs, visibleSections: visible
        )
        XCTAssertEqual(Array(tabs.prefix(3)), [.artists, .songs, .favorites])
        XCTAssertFalse(tabs.contains(.albums))
        XCTAssertFalse(tabs.contains(.genres))
        XCTAssertFalse(tabs.contains(.radio))
        XCTAssertFalse(tabs.contains(.spokenWord))
        XCTAssertFalse(tabs.contains(.podcasts))
    }

    func testDisabledMinimalAndNonMusicPagesHaveNoExtraTabs() {
        let visible: [LibrarySection] = [.favorites, .songs, .albums, .radio, .spokenWord, .podcasts]
        XCTAssertTrue(StandardLibrarySectionTabsPolicy.sections(
            enabled: false, mode: .standard, selection: nil, visibleSections: visible
        ).isEmpty)
        XCTAssertTrue(StandardLibrarySectionTabsPolicy.sections(
            enabled: true, mode: .minimal, selection: .songs, visibleSections: visible
        ).isEmpty)
        for selection in [LibrarySection.radio, .spokenWord, .podcasts] {
            XCTAssertTrue(StandardLibrarySectionTabsPolicy.sections(
                enabled: true, mode: .standard, selection: selection, visibleSections: visible
            ).isEmpty)
        }
    }

    func testSettingsSearchFindsCategoryToggleOnHomePage() {
        let id = "home.librarySectionTabs"
        XCTAssertEqual(SettingsCatalog.byID[id]?.page, .home)
        XCTAssertEqual(SettingsCatalog.byID[id]?.anchorID, id)
        for query in ["子标签", "分类", "category tabs"] {
            XCTAssertTrue(SettingsCatalog.search(query).contains { $0.id == id }, query)
        }
    }

    @MainActor
    func testLiveToggleRemovesReservedSpaceAndPreservesSelection() async throws {
        let suite = "StandardLibrarySectionTabsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let probe = SectionTabsProbe()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: SectionTabsHarness(probe: probe)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: "zh-Hans")))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(probe.height, 0, accuracy: 0.5)

        defaults.set(true, forKey: HomeFilterBarConfiguration.showsLibrarySectionsKey)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(probe.height, 42, accuracy: 0.5)
        attach(window, name: "standard-category-tabs-portrait")
        window.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(probe.height, 42, accuracy: 0.5)
        attach(window, name: "standard-category-tabs-landscape")

        defaults.set(false, forKey: HomeFilterBarConfiguration.showsLibrarySectionsKey)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(probe.height, 0, accuracy: 0.5)
        XCTAssertEqual(probe.selection, .albums)
    }

    @MainActor
    func testLibraryNavigationKeepsTabsAboveScrollingContent() async throws {
        let suite = "LibrarySectionBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set(true, forKey: HomeFilterBarConfiguration.showsLibrarySectionsKey)
        let library = MusicLibrary(storageDirectory: directory)
        await library.whenReady()
        library.addSongs((0..<24).map { index in
            Song(id: "section-bar-\(index)", title: "歌曲 \(index)",
                 albumTitle: "专辑 \(index)", artistName: "艺术家", duration: 180,
                 fileFormat: .flac, filePath: "/section-bar/\(index).flac", sourceID: "section-bar")
        })
        for _ in 0..<100 where library.visibleSongs.count != 24 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(library.visibleSongs.count, 24)
        let radio = RadioStationsStore(storeURL: directory.appendingPathComponent("radio.json"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let host = UIHostingController(rootView: LibraryView()
            .environment(library)
            .environment(SourcesStore(storageDirectoryURL: directory))
            .environment(AppServices.shared.playerService)
            .environment(radio)
            .environment(AppServices.shared.sourceManager)
            .environment(ThemeService())
            .environment(\.appNavigationMode, .standard)
            .environment(\.locale, Locale(identifier: "zh-Hans"))
            .defaultAppStorage(defaults))
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }

        func scrollViews(in view: UIView) -> [UIScrollView] {
            ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(400))
            let scrolls = scrollViews(in: window)
            let tabs = try XCTUnwrap(scrolls.first {
                $0.contentSize.width > $0.bounds.width + 1
            })
            let content = try XCTUnwrap(scrolls.max { $0.bounds.height < $1.bounds.height })
            XCTAssertGreaterThan(content.contentSize.height + content.adjustedContentInset.top
                                 + content.adjustedContentInset.bottom, content.bounds.height)
            content.setContentOffset(CGPoint(x: 0, y: -content.adjustedContentInset.top), animated: false)
            try await Task.sleep(for: .milliseconds(250))
            let tabFrame = tabs.convert(tabs.bounds, to: window)
            XCTAssertGreaterThan(tabFrame.maxY, window.safeAreaInsets.top)
            let appearance = style == .dark ? "dark" : "light"
            attach(window, name: "library-category-bar-\(appearance)-top")

            content.setContentOffset(CGPoint(x: 0, y: 180), animated: false)
            try await Task.sleep(for: .milliseconds(300))
            let scrolledTabFrame = tabs.convert(tabs.bounds, to: window)
            XCTAssertEqual(scrolledTabFrame.minY, tabFrame.minY, accuracy: 1)
            attach(window, name: "library-category-bar-\(appearance)-scrolled")
        }
    }

    private func withDefaults(_ operation: (UserDefaults) -> Void) {
        let suite = "StandardLibrarySectionTabsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        operation(defaults)
    }

    @MainActor
    private func attach(_ window: UIWindow, name: String) {
        window.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor @Observable
private final class SectionTabsProbe {
    var height: CGFloat = -1
    var selection: LibrarySection? = .albums
}

private struct SectionTabsHarness: View {
    @Bindable var probe: SectionTabsProbe

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                StandardLibrarySectionTabs(selection: probe.selection) { probe.selection = $0 }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { probe.height = $0 }
            Color.clear
        }
        .background(Color(uiColor: .systemBackground))
        .environment(\.appNavigationMode, .standard)
    }
}
