#if os(tvOS)
import Foundation
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import PrimuseTV

@MainActor
final class TVSettingsStackBudgetTests: XCTestCase {
    func testSettingsBodyLeavesRoomForSwiftUIOnDeviceStack() {
        // tvOS devices have a roughly 1 MiB main stack; nested builders need
        // room for several copies as well as Swift's type metadata lookup.
        let bytes = MemoryLayout<TVSettingsView.Body>.size
        print("TVSettingsView.Body size: \(bytes) bytes")
        XCTAssertLessThan(bytes, 16 * 1024)
    }

    func testSectionDefersContentUntilItsOwnBodyIsEvaluated() {
        var evaluations = 0
        let section = TVSettingsSection("Settings") {
            let _ = evaluations += 1
            Text("Setting")
        }
        XCTAssertEqual(evaluations, 0)
        withExtendedLifetime(section.body) {
            XCTAssertEqual(evaluations, 1)
        }
    }

    func testOpeningSettingsRepeatedlyUpdatesConditionalRows() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVSettingsRendering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "TVSettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudSyncChannel.masterDefaultsKey)
        defaults.set(false, forKey: TVStore.spokenWordSmartRewindEnabledKey)
        defaults.set(false, forKey: PlayerAppearancePreferences.showsLyricsInterludeKey)
        let replayGain = TVReplayGainSettings.shared
        let translation = LyricsTranslationSettingsStore.shared
        let romanization = LyricsRomanizationSettingsStore.shared
        let saved = (replayGain.enabled, translation.isEnabled, romanization.isAutoGenerationEnabled)
        defer {
            replayGain.enabled = saved.0
            translation.isEnabled = saved.1
            romanization.isAutoGenerationEnabled = saved.2
        }
        replayGain.enabled = false
        translation.isEnabled = false
        romanization.isAutoGenerationEnabled = false

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let store = TVStore(sourcesStore: SourcesStore(storageDirectoryURL: directory), library: library,
                            defaults: defaults,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        let appearance = TVAppearanceState(defaults: defaults)
        let intelligence = MusicIntelligenceService()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let presentation = SettingsPresentation()
        let settings = AnyView(TVSettingsView().environment(store).environment(appearance)
            .environment(intelligence).environment(TVThemeState.shared).defaultAppStorage(defaults))
        let host = UIHostingController(rootView: SettingsPresenter(presentation: presentation, settings: settings))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            store.engine.stop()
        }

        for pass in 0..<3 {
            presentation.isPresented = true
            host.view.frame = window.bounds
            try await settle(host)
            let presented = try XCTUnwrap(host.presentedViewController)
            try await settle(presented)
            let scroll = try XCTUnwrap(scrollView(in: presented.view))
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height)
            if pass == 0 {
                let collapsedHeight = scroll.contentSize.height
                replayGain.enabled = true
                translation.isEnabled = true
                romanization.isAutoGenerationEnabled = true
                defaults.set(true, forKey: TVStore.spokenWordSmartRewindEnabledKey)
                defaults.set(true, forKey: PlayerAppearancePreferences.showsLyricsInterludeKey)
                try await settle(presented)
                XCTAssertGreaterThan(scroll.contentSize.height, collapsedHeight + 100,
                                     "Deferred sections must still observe conditional settings")
            }
            appearance.select(pass == 1 ? .light : .dark)
            scroll.setContentOffset(CGPoint(x: 0, y: scroll.contentSize.height - scroll.bounds.height), animated: false)
            try await settle(presented)
            if pass == 0 {
                let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
                let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Settings expanded - bottom"
                attachment.lifetime = .keepAlways
                add(attachment)
                scroll.setContentOffset(.zero, animated: false)
                try await settle(presented)
                let top = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let topAttachment = XCTAttachment(image: top)
                topAttachment.name = "Settings expanded - top"
                topAttachment.lifetime = .keepAlways
                add(topAttachment)
            }
            presentation.isPresented = false
            try await settle(host)
            XCTAssertNil(host.presentedViewController)
        }
    }

    private final class SettingsPresentation: ObservableObject {
        @Published var isPresented = false
    }

    private struct SettingsPresenter: View {
        @ObservedObject var presentation: SettingsPresentation
        let settings: AnyView

        var body: some View {
            Color.clear.fullScreenCover(isPresented: $presentation.isPresented) { settings }
                .transaction { $0.disablesAnimations = true }
        }
    }

    private func settle(_ host: UIViewController) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }
}

final class TVUserFlowPolicyTests: XCTestCase {
    // 电视端选目录与手机、Mac 共用 PrimuseKit 的 SourceDirectorySelectionPolicy。
    func testScanSelectionDropsNestedRootsBeforeNetworkTraversal() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.normalizedSelections([
                "/Music/Albums/Live",
                "/Music",
                "/Music/Albums",
                "/Podcasts",
                "/Podcasts/2026/",
            ], for: .smb),
            ["/Music", "/Podcasts"]
        )
    }

    func testRootScanSelectionDominatesEveryChild() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.normalizedSelections(["/Music", "/", "Radio"], for: .smb),
            ["/"]
        )
    }

    func testFolderAddedUnderSelectedParentReadsAsIncluded() {
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.selectionState(
                of: "/Music/New",
                in: ["/Music"],
                ancestors: ["/", "/Music"],
                for: .smb
            ),
            .included(by: "/Music")
        )
        XCTAssertEqual(
            SourceDirectorySelectionPolicy.selectionState(of: "/New", in: ["/"], for: .synology),
            .included(by: "/")
        )
    }

    func testTVEditPolicyRejectsProviderSpecificForms() {
        var cloud = MusicSource(name: "Cloud", type: .oneDrive)
        cloud.authType = .oauth
        var s3 = MusicSource(name: "S3", type: .s3)
        s3.authType = .password

        XCTAssertFalse(TVSourceEditPolicy.canEdit(cloud))
        XCTAssertFalse(TVSourceEditPolicy.canEdit(s3))
    }

    func testTVEditPolicyAllowsAddressBackedAPIKeySource() {
        var jellyfin = MusicSource(name: "Jellyfin", type: .jellyfin)
        jellyfin.authType = .apiKey

        XCTAssertTrue(TVSourceEditPolicy.canEdit(jellyfin))
    }

    func testCountFormattingUsesRequestedLocale() {
        XCTAssertEqual(TVFmt.count(12_345, locale: Locale(identifier: "de_DE")), "12.345")
        XCTAssertEqual(TVFmt.count(12_345, locale: Locale(identifier: "en_US")), "12,345")
    }
}

@MainActor
final class TVLibraryInsightEditingTests: XCTestCase {
    private var subjects: [LibraryInsightSubject] {
        [
            .album(title: "Blue Train", artist: "John Coltrane", year: 1957, genres: [], tracks: []),
            .artist(name: "John Coltrane", genres: [], albums: [], tracks: [])
        ]
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TVLibraryInsightEditingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testManualAlbumAndArtistIntrosSurviveReloadWithoutAI() async throws {
        let directory = try makeDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let store = LibraryInsightStore()
        for subject in subjects {
            store.saveEdit(subject, summary: "  A personal introduction.\n\nSecond paragraph.  ",
                           tags: LibraryInsightEditing.tags(fromText: "Jazz，Hard bop、Jazz"),
                           aiDraft: nil, library: library)
        }
        guard case .success = await library.persistNowAndWait() else {
            return XCTFail("The edited introductions did not persist")
        }
        let reopened = MusicLibrary(storageDirectory: directory)
        for subject in subjects {
            let record = try XCTUnwrap(store.record(for: subject, in: reopened))
            XCTAssertEqual(record.kind, subject.kind)
            XCTAssertEqual(record.summary, "A personal introduction.\n\nSecond paragraph.")
            XCTAssertEqual(record.tags, ["Jazz", "Hard bop"])
            XCTAssertTrue(record.isUserEdited)
            XCTAssertTrue(record.isWorthKeeping)
        }
    }

    func testEditingGeneratedIntrosPreservesTagsAndMarksUserContent() async throws {
        let directory = try makeDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let store = LibraryInsightStore()
        for subject in subjects {
            let previous = LibraryInsightRecord(
                id: store.recordID(for: subject), kind: subject.kind,
                albumTitle: subject.albumTitle, artistName: subject.artistName,
                summary: "Generated introduction", tags: ["Jazz"], aiKnown: true,
                aiProviderName: "Test", isUserEdited: false, updatedAt: Date()
            )
            library.saveLibraryInsightRecord(previous)
            store.saveEdit(subject, summary: previous.summary, tags: previous.tags, aiDraft: nil, library: library)
            XCTAssertEqual(store.record(for: subject, in: library), previous)
            store.saveEdit(subject, summary: "My revised introduction", tags: previous.tags, aiDraft: nil, library: library)
            let edited = try XCTUnwrap(store.record(for: subject, in: library))
            XCTAssertEqual(edited.summary, "My revised introduction")
            XCTAssertEqual(edited.tags, ["Jazz"])
            XCTAssertTrue(edited.isUserEdited)
            XCTAssertTrue(edited.isWorthKeeping)
            XCTAssertGreaterThan(edited.updatedAt, previous.updatedAt)
        }
        _ = await library.persistNowAndWait()
    }

    func testClearingBothFieldsLeavesDeletionForSync() async throws {
        let directory = try makeDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let store = LibraryInsightStore()
        for subject in subjects {
            store.saveEdit(subject, summary: "My introduction", tags: ["Jazz"], aiDraft: nil, library: library)
            store.saveEdit(subject, summary: " \n ", tags: [], aiDraft: nil, library: library)
            XCTAssertNil(store.record(for: subject, in: library))
            XCTAssertTrue(try XCTUnwrap(library.storedLibraryInsightRecord(id: store.recordID(for: subject))).isDeleted)
        }
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Deletion did not persist") }
        let reopened = MusicLibrary(storageDirectory: directory)
        for subject in subjects {
            XCTAssertNil(store.record(for: subject, in: reopened))
        }
    }

    func testEditorPrefillsBothFieldsAndKeepsUnsavedTypingLocal() async throws {
        let directory = try makeDirectory()
        let library = MusicLibrary(storageDirectory: directory)
        let store = LibraryInsightStore()
        for subject in subjects {
            store.saveEdit(subject, summary: "First paragraph.\n\nSecond paragraph.", tags: ["Jazz", "Hard bop"],
                           aiDraft: nil, library: library)
            _ = await library.persistNowAndWait()
            let record = try XCTUnwrap(store.record(for: subject, in: library))
            let controller = UIHostingController(rootView: AnyView(TVLibraryInsightEditor(subject: subject, record: record, library: library)))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
            window.rootViewController = controller
            window.isHidden = false
            defer {
                controller.rootView = AnyView(EmptyView())
                window.isHidden = true
                window.rootViewController = nil
            }
            controller.view.frame = window.bounds
            controller.view.layoutIfNeeded()
            await Task.yield()
            controller.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            let image = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = "TV \(subject.kind.rawValue) intro editor"
            attachment.lifetime = .keepAlways
            add(attachment)
            let fields = textFields(in: controller.view)
            XCTAssertEqual(fields.count, 2)
            let summary = try XCTUnwrap(fields.first { $0.text?.contains("First paragraph.") == true },
                                       "Text field values: \(fields.map { $0.text ?? "nil" })")
            XCTAssertTrue(summary.text?.contains("Second paragraph.") == true)
            XCTAssertTrue(fields.contains { $0.text == "Jazz, Hard bop" })
            summary.text = "Unsaved draft"
            summary.sendActions(for: .editingChanged)
            await Task.yield()
            XCTAssertEqual(store.record(for: subject, in: library), record)
            controller.rootView = AnyView(EmptyView())
            controller.view.layoutIfNeeded()
            window.isHidden = true
            window.rootViewController = nil
            await Task.yield()
        }
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}

@MainActor
final class TVListeningReturnRenderingTests: XCTestCase {
    func testRadioReturnRevealsStationBeyondFirstPageInOriginalFolder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "TVListeningReturn.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = TVStore(
            sourcesStore: SourcesStore(storageDirectoryURL: directory),
            library: MusicLibrary(storageDirectory: directory), defaults: defaults,
            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        )
        addTeardownBlock { @MainActor [weak store] in
            for _ in 0..<20 where store != nil {
                try await Task.sleep(for: .milliseconds(100))
            }
            if store == nil { try? FileManager.default.removeItem(at: directory) }
        }
        store.radioStations = (0..<120).map {
            RadioStation(id: "return-\($0)", name: "Station \($0)",
                         streamURL: "https://example.invalid/\($0).mp3", folderName: "Jazz")
        } + [RadioStation(id: "other", name: "Other", streamURL: "https://example.invalid/other.mp3", folderName: "Talk")]
        let memory = TVRadioReturnMemory()
        memory.selection = .folder("jazz")
        memory.stationID = "return-95"
        memory.restoresAfterPlayer = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: TVRadioPageView(memory: memory).environment(store))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            store.engine.stop()
        }
        var focusedFrame = CGRect.zero
        var offset: CGFloat = 0
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            focusedFrame = UIFocusSystem(for: host.view)?.focusedItem?.frame ?? .zero
            offset = verticalScroll(in: host.view)?.contentOffset.y ?? 0
            if offset > 1000, focusedFrame.height > 200 { break }
        }
        try await Task.sleep(for: .milliseconds(400))
        focusedFrame = UIFocusSystem(for: host.view)?.focusedItem?.frame ?? .zero
        // SwiftUI 的焦点项不是 UIView；同时检查深处的滚动位置与卡片焦点，避免把首屏回退当成恢复。
        XCTAssertGreaterThan(offset, 1000)
        XCTAssertGreaterThan(focusedFrame.width, 200)
        XCTAssertGreaterThan(focusedFrame.height, 200)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        })
        attachment.name = "Radio return to station 95"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(memory.selection, .folder("jazz"))
        XCTAssertFalse(memory.restoresAfterPlayer)
    }

    private func verticalScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.contentSize.height > scroll.bounds.height { return scroll }
        return view.subviews.lazy.compactMap { self.verticalScroll(in: $0) }.first
    }
}

#endif
