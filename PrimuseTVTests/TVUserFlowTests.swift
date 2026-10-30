#if os(tvOS)
import Foundation
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import PrimuseTV

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
#endif
