import XCTest
import SwiftUI
import UIKit
import Observation
import PrimuseKit
@testable import Primuse

final class StandardLibrarySectionTabsTests: XCTestCase {
    @MainActor
    func testDefaultIsOffAndRestoreDefaultsTurnsItOff() {
        withDefaults { defaults in
            let key = HomeFilterBarConfiguration.showsLibrarySectionsKey
            XCTAssertFalse(defaults.bool(forKey: key))
            defaults.set(true, forKey: key)
            XCTAssertTrue(defaults.bool(forKey: key))
            HomeView.restoreDefaultSectionVisibility(defaults: defaults)
            XCTAssertFalse(defaults.bool(forKey: key))
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
        let image = UIGraphicsImageRenderer(size: window.bounds.size, format: format).image { context in
            window.layer.render(in: context.cgContext)
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
