import Foundation
import Testing
@testable import PrimuseKit

struct CarPlayLayoutEditorTests {
    @Test func podcastTabIsOptionalAndSurvivesSaving() throws {
        #expect(!CarPlayMainTab.defaults.contains { $0.kind == .podcast })
        #expect(CarPlayMainTab.Kind.podcast.titleKey == "listening_space_podcast")
        var configuration = CarPlayLayoutConfiguration()
        configuration.tabs = CarPlayMainTab.defaults + [.init(id: "podcasts", kind: .podcast)]
        let restored = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored.tabs.last?.kind == .podcast)
        #expect(restored.tabs.last?.isValid == true)
    }

    @Test func retiredSplitLayoutKeepsContentAndUsesSupportedPresentation() throws {
        let data = Data(#"{"visualStyle":"split","browseStyle":"list","customBlocks":[{"id":"favorite","kind":"custom","style":"list","items":[{"id":"p","kind":"playlist","targetID":"commute","title":"Commute"}]}]}"#.utf8)
        let configuration = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: data)
        #expect(configuration.visualStyle == .list)
        #expect(configuration.blocks.first?.items.first?.targetID == "commute")
        #expect(CarPlayVisualStyle.allCases.map(\.rawValue) == ["list", "wall", "capsules"])
        #expect(configuration.tabs == CarPlayMainTab.defaults)
    }

    @Test func menuOrderVisibilityAndCollectionsSurviveSavingAndStyleChanges() throws {
        var configuration = CarPlayLayoutConfiguration()
        let folder = LibraryFolderNodeID(sourceID: "nas", kind: .folder, normalizedRelativePath: "Lossless")
        configuration.tabs = [
            .init(id: "music", kind: .collection, title: "Commute", content: .init(kind: .playlist, targetID: "playlist-25", title: "Playlist")),
            .init(id: "folders", kind: .collection, content: .init(kind: .folder, targetID: HomeFolderPinStorage.encode([folder]), title: "Lossless")),
            .init(id: "home", kind: .home, isVisible: false),
            .init(id: "radio", kind: .radio)
        ]
        let mutation0 = configuration.moveTab("radio", before: "music")
        #expect(mutation0)
        #expect(configuration.visibleTabs(maximumCount: 4).map(\.id) == ["radio", "music", "folders"])
        #expect(configuration.visibleTabs(maximumCount: 2).map(\.id) == ["radio", "music"])
        let expected = configuration.tabs
        for style in CarPlayVisualStyle.allCases { configuration.applyVisualStyle(style); #expect(configuration.tabs == expected) }
        configuration.apply(.focus)
        #expect(configuration.tabs == expected)
        let restored = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(configuration))
        #expect(restored.tabs == expected)
        #expect(restored.tabs[2].content?.folderID == folder)
    }

    @Test func menuCapacityCannotHideLastTabOrEnableTooManyTabs() {
        var configuration = CarPlayLayoutConfiguration()
        let mutation1 = configuration.setTabVisible("tab.radio", visible: false, maximumCount: 4)
        #expect(mutation1)
        let mutation2 = configuration.setTabVisible("tab.radio", visible: true, maximumCount: 3)
        #expect(!mutation2)
        let mutation3 = configuration.setTabVisible("tab.playlists", visible: false, maximumCount: 4)
        #expect(mutation3)
        let mutation4 = configuration.setTabVisible("tab.library", visible: false, maximumCount: 4)
        #expect(mutation4)
        let before = configuration
        let mutation5 = configuration.setTabVisible("tab.home", visible: false, maximumCount: 4)
        #expect(!mutation5)
        let mutation6 = configuration.moveTab("tab.home", before: "deleted")
        #expect(!mutation6)
        #expect(configuration == before)
        configuration.tabs = []
        #expect(configuration.visibleTabs(maximumCount: 4).map(\.kind) == [.home])
        let invalid = CarPlayMainTab(id: "bad", kind: .collection, content: .init(kind: .folder, targetID: "bad", title: "Missing"))
        configuration.tabs = [invalid, .init(id: "valid", kind: .songs), .init(id: "valid", kind: .radio)]
        #expect(configuration.visibleTabs(maximumCount: 4).map(\.kind) == [.songs])
    }

    @Test func visualPresetsPreserveContentsVisibilityAndOrder() throws {
        var configuration = CarPlayLayoutConfiguration()
        var block = CarPlayLayoutBlock(id: "favorite", kind: .custom)
        block.items = [.init(id: "saved", kind: .folder, targetID: "opaque-folder", title: "Lossless")]
        block.isVisible = false
        block.itemLimit = 60
        configuration.blocks = [block, .init(id: "radio", kind: .radio)]
        for style in CarPlayVisualStyle.allCases {
            configuration.applyVisualStyle(style)
            #expect(configuration.blocks.map(\.id) == ["favorite", "radio"])
            #expect(configuration.blocks[0].items == block.items)
            #expect(!configuration.blocks[0].isVisible)
            #expect(configuration.blocks[0].itemLimit == 60)
            let restored = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(configuration))
            #expect(restored == configuration)
        }
    }

    @Test func oldBlocksDefaultToVisibleAndSiriVisibilityIsIndependent() throws {
        let block = try JSONDecoder().decode(CarPlayLayoutBlock.self, from: Data(#"{"id":"old","kind":"shortcuts","style":"list"}"#.utf8))
        #expect(block.isVisible)
        #expect(!block.usesCustomContent)
        var configuration = CarPlayLayoutConfiguration()
        #expect(!configuration.showsSiri)
        var siri = CarPlayLayoutBlock(id: "siri", kind: .siri)
        siri.isVisible = false
        configuration.blocks = [block, siri]
        #expect(!configuration.showsSiri)
        #expect(configuration.blocks[0].isVisible)
        configuration.blocks[1].isVisible = true
        #expect(configuration.showsSiri)
    }

    @Test func legacyLayoutMigratesButExplicitlyEmptyCanvasStaysEmpty() throws {
        let migrated = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: Data(#"{"browseStyle":"cards","hiddenSections":["albums","playlists"]}"#.utf8))
        #expect(migrated.blocks.map(\.kind) == [.shortcuts, .recentlyAdded])
        #expect(migrated.blocks.allSatisfy { $0.style == .cards })
        let empty = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: Data(#"{"customBlocks":[]}"#.utf8))
        #expect(empty.blocks.isEmpty)
        #expect(try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(empty)).blocks.isEmpty)
    }

    @Test func mixedStylesAndStableContentSurvivePresetPersistence() throws {
        var config = CarPlayLayoutConfiguration()
        var custom = CarPlayLayoutBlock(id: "custom", kind: .custom, style: .cards)
        let folder = LibraryFolderNodeID(sourceID: "cloud", kind: .folder, normalizedRelativePath: "opaque/directory")
        custom.items = [
            .init(id: "playlist", kind: .playlist, targetID: "playlist-id", title: "Commute"),
            .init(id: "folder", kind: .folder, targetID: HomeFolderPinStorage.encode([folder]), title: "Music"),
            .init(id: "track", kind: .song, targetID: "song-id", title: "One Song")
        ]
        config.blocks = [custom, .init(id: "recent", kind: .recentlyAdded, style: .list)]
        let saved = CarPlaySavedLayout(name: "  My Drive  ", configuration: config)
        let restored = try JSONDecoder().decode(CarPlaySavedLayout.self, from: JSONEncoder().encode(saved))
        #expect(restored.name == "My Drive")
        #expect(restored.configuration.blocks.map(\.style) == [.cards, .list])
        #expect(restored.configuration.blocks[0].items[1].folderID == folder)
        config.apply(.focus)
        #expect(config.blocks[0].items == custom.items)
        #expect(config.minimalNowPlaying)
    }

    @Test func movingBlocksAndItemsPreservesOrderAndRejectsStaleDropsAtomically() {
        var config = CarPlayLayoutConfiguration()
        var first = CarPlayLayoutBlock(id: "a", kind: .custom)
        first.items = [.init(id: "1", kind: .song, targetID: "s1", title: "One"), .init(id: "2", kind: .song, targetID: "s2", title: "Two")]
        var second = CarPlayLayoutBlock(id: "b", kind: .custom)
        second.items = [.init(id: "3", kind: .song, targetID: "s3", title: "Three")]
        config.blocks = [first, second, .init(id: "c", kind: .albums)]
        let result1 = config.moveBlock("c", before: "a")
        #expect(result1)
        #expect(config.blocks.map(\.id) == ["c", "a", "b"])
        let result2 = config.moveItem("2", from: "a", to: "b", before: "3")
        #expect(result2)
        #expect(config.blocks[1].items.map(\.id) == ["1"])
        #expect(config.blocks[2].items.map(\.id) == ["2", "3"])
        let result3 = config.moveItem("2", from: "b", to: "b")
        #expect(result3)
        #expect(config.blocks[2].items.map(\.id) == ["3", "2"])
        let snapshot = config
        let result4 = config.moveItem("1", from: "a", to: "c")
        #expect(!result4)
        let result5 = config.moveItem("1", from: "a", to: "b", before: "removed")
        #expect(!result5)
        let result6 = config.moveBlock("a", before: "removed")
        #expect(!result6)
        #expect(config == snapshot)
    }

    @Test func fullDestinationDoesNotDeleteSourceAndLimitsAreNormalized() {
        var config = CarPlayLayoutConfiguration()
        var source = CarPlayLayoutBlock(id: "source", kind: .custom)
        source.items = [.init(id: "source-song", kind: .song, targetID: "source-song", title: "Source")]
        var full = CarPlayLayoutBlock(id: "full", kind: .custom)
        full.items = (0..<60).map { .init(id: String($0), kind: .song, targetID: String($0), title: String($0)) }
        full.columns = 100
        full.itemLimit = -1
        config.blocks = [source, full]
        let snapshot = config
        let result7 = config.moveItem("source-song", from: "source", to: "full")
        #expect(!result7)
        #expect(config == snapshot)
        #expect(config.blocks[1].columns == 6)
        #expect(config.blocks[1].itemLimit == 1)
    }

    @Test func invalidAndFutureBlocksDoNotDestroyValidContent() throws {
        let valid = CarPlayLayoutBlock(id: "valid", kind: .custom)
        let blockJSON = try #require(String(data: JSONEncoder().encode(valid), encoding: .utf8))
        let data = Data("{\"customBlocks\":[{\"kind\":\"future\"},\(blockJSON),{\"id\":3}]}".utf8)
        let config = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: data)
        #expect(config.blocks.map(\.id) == ["valid"])
    }

    @Test func undoRedoRestoresWholeCanvasAndNewEditDropsRedoBranch() {
        let initial = CarPlayLayoutConfiguration()
        var edited = initial
        edited.blocks = [.init(kind: .radio, style: .cards)]
        var history = CarPlayLayoutHistory()
        history.record(initial, replacing: edited)
        let result8 = history.undo(edited)
        #expect(result8 == initial)
        let result9 = history.redo(initial)
        #expect(result9 == edited)
        let result10 = history.undo(edited)
        #expect(result10 == initial)
        var other = initial
        other.apply(.focus)
        history.record(initial, replacing: other)
        #expect(!history.canRedo)
        let result11 = history.undo(other)
        #expect(result11 == initial)
    }

    @Test func dragPayloadRoundTripsOpaqueIdentifiersAndRejectsUnrelatedText() {
        let item = CarPlayLayoutItem(kind: .song, targetID: "source:opaque/你好+id", title: "很长的音乐名字")
        #expect(CarPlayLayoutItem.fromDragValue(item.dragValue) == item)
        #expect(CarPlayLayoutItem.fromDragValue("https://example.com") == nil)
        #expect(CarPlayLayoutItem.fromDragValue("carplay-content:not-base64") == nil)
        let invalid = CarPlayLayoutItem(kind: .song, targetID: "", title: "Missing")
        #expect(CarPlayLayoutItem.fromDragValue(invalid.dragValue) == nil)
    }
}
