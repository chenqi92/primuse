import AppKit
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

@MainActor
final class MacLyricLineCommentsViewTests: XCTestCase {
    func testEditorRestoresTheSelectedLinesComment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let first = LyricLineCommentAnchor(text: "纸船经过小桥", occurrence: 0, timestamp: 10)
        let second = LyricLineCommentAnchor(text: "晚风停在窗边", occurrence: 0, timestamp: 20)
        try store.save(songID: "fixture", anchor: first, text: "想起从前的河岸。")
        try store.save(songID: "fixture", anchor: second, text: "另一句的评论")
        let restored = LyricLineCommentStore(directory: directory)
        let host = NSHostingView(rootView: LyricLineCommentsSheet(
            presentation: .init(songID: "fixture", anchor: first), store: restored
        ).environment(\.locale, Locale(identifier: "zh-Hans")))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTextView }.first)
        XCTAssertEqual(editor.string, "想起从前的河岸。")
        XCTAssertTrue(editor.isEditable)
        try capture(host, name: "lyric-comments-editor")
    }

    func testSavingACommentUpdatesTheVisibleRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LyricLineCommentStore(directory: directory)
        let anchor = LyricLineCommentAnchor(text: "纸船经过小桥", occurrence: 0, timestamp: 10)
        func row() -> some View {
            Text(verbatim: anchor.text).font(.title2.bold())
                .modifier(LyricLineCommentModifier(songID: "fixture", anchor: anchor, present: { _ in }, store: store))
                .padding(24).frame(width: 420)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        let host = NSHostingView(rootView: row())
        let baseline = host.fittingSize.height
        try store.save(songID: "fixture", anchor: anchor, text: "想起从前的河岸。")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(host.fittingSize.height, baseline + 10)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        try capture(host, name: "lyric-comments-row")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func capture(_ host: NSView, name: String) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class PlayerMoreMenuRegressionTests: XCTestCase {
    func testRepeatAndSubmenuLocalizationKeysResolveInMainBundle() {
        XCTAssertEqual(PlayerMoreMenuPolicy.repeatTitleKey(for: .off), "repeat")
        XCTAssertEqual(PlayerMoreMenuPolicy.repeatTitleKey(for: .all), "play_mode_repeat_all")
        XCTAssertEqual(PlayerMoreMenuPolicy.repeatTitleKey(for: .one), "play_mode_repeat_one")

        let keys = [
            PlayerMoreMenuPolicy.repeatTitleKey(for: .off),
            PlayerMoreMenuPolicy.repeatTitleKey(for: .all),
            PlayerMoreMenuPolicy.repeatTitleKey(for: .one),
            "repeat_behavior_off",
            "player_menu_playback_order",
            "player_menu_lyrics_display",
            "player_menu_transcript_display",
            "player_menu_audio_and_sing_along",
            "player_menu_edit_and_clips",
            "player_menu_transcript_and_edit",
        ]
        for key in keys {
            let resolved = Bundle.main.localizedString(forKey: key, value: "__MISSING__", table: nil)
            XCTAssertNotEqual(resolved, "__MISSING__", "Missing localization for \(key)")
            XCTAssertNotEqual(resolved, key, "Raw key leaked for \(key)")
        }

        let summary = PlayerMoreMenuPolicy.playbackOrderSummary(shuffleEnabled: true, repeatMode: .all)
        XCTAssertFalse(summary.contains("repeat_all"))
        XCTAssertFalse(summary.isEmpty)
    }

    func testPlayerBarMenuDeduplicatesTransportAndFallsBackToScrollWhenCapped() {
        let player = AppServices.shared.playerService
        let previousRepeat = player.repeatMode
        defer { player.repeatMode = previousRepeat }
        player.repeatMode = .all

        let barHost = NSHostingView(
            rootView: PlayerMoreMenu(surface: .playerBar, rendersInlineForTesting: true) {
                EmptyView()
            }
            .applyPrimuseEnvironments()
        )
        barHost.layoutSubtreeIfNeeded()
        let barHeight = barHost.fittingSize.height
        XCTAssertGreaterThan(barHeight, 200)
        XCTAssertLessThan(barHeight, 560)

        let queueHost = NSHostingView(
            rootView: PlayerMoreMenu(surface: .queuePanel, rendersInlineForTesting: true) {
                EmptyView()
            }
            .applyPrimuseEnvironments()
        )
        queueHost.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(queueHost.fittingSize.height, barHeight + 60)

        let cappedHost = NSHostingView(
            rootView: PlayerMoreMenu(
                surface: .queuePanel,
                initialSubpage: .playbackOrder,
                maxPopoverHeightOverride: 180,
                rendersInlineForTesting: true
            ) {
                EmptyView()
            }
            .applyPrimuseEnvironments()
        )
        cappedHost.frame = NSRect(x: 0, y: 0, width: 260, height: 180)
        cappedHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(cappedHost.fittingSize.height, 181)
        XCTAssertFalse(scrollViews(in: cappedHost).isEmpty)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { child in
            (child as? NSScrollView).map { [$0] } ?? scrollViews(in: child)
        }
    }
}
