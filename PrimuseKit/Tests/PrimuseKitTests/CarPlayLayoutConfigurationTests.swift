import Foundation
import Testing
@testable import PrimuseKit

struct CarPlayLayoutConfigurationTests {
    @Test func recommendedLayoutHasCompactShortcutsAndBoundedArtworkRows() throws {
        let configuration = CarPlayLayoutConfiguration.recommended
        #expect(configuration.blocks.map(\.kind) == [.shortcuts, .recentlyPlayed, .forYou, .playlists])
        #expect(configuration.blocks.first?.style == .list)
        #expect(configuration.blocks.first?.itemLimit == 4)
        #expect(configuration.blocks.dropFirst().allSatisfy { $0.style == .covers && $0.columns == 2 && $0.itemLimit == 6 })
        #expect(configuration.visibleTabs(maximumCount: 4).count == 4)
        #expect(try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(configuration)) == configuration)
    }

    @Test func olderLayoutsGainFiveButtonsWithoutChangingTheirPresentation() throws {
        let config = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: Data(#"{"browseStyle":"covers","minimalNowPlaying":true}"#.utf8))
        #expect(config.nowPlayingButtons(isSpokenWord: false) == [.shuffle, .repeatMode, .like, .audioQuality, .audioBitRate])
        #expect(config.nowPlayingButtons(isSpokenWord: true) == [.skipBackward, .playbackRate, .skipForward, .like, .audioQuality])
        #expect(config.browseStyle == .covers)
        #expect(config.visibleNowPlayingButtons(isSpokenWord: false, isLiveRadio: false, supportsPlaybackRate: true).isEmpty)
    }

    @Test func buttonDecodingKeepsKnownActionsAndHonorsEmptySelection() throws {
        let data = Data(#"{"customNowPlayingButtons":["queue","future","audioQuality","queue","like","album","shuffle","repeatMode"],"customSpokenWordButtons":[]}"#.utf8)
        let config = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: data)
        #expect(config.nowPlayingButtons(isSpokenWord: false) == [.queue, .audioQuality, .like, .album, .shuffle])
        #expect(config.nowPlayingButtons(isSpokenWord: true).isEmpty)
        let restored = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(config))
        #expect(restored == config)
    }

    @Test func playbackContextFiltersUnavailableActionsWithoutChangingSavedButtons() {
        var config = CarPlayLayoutConfiguration()
        config.customSpokenWordButtons = [.queue, .playbackRate, .shuffle, .repeatMode, .audioQuality, .like]
        #expect(config.visibleNowPlayingButtons(isSpokenWord: true, isLiveRadio: false, supportsPlaybackRate: false) == [.audioQuality, .like])
        #expect(config.visibleNowPlayingButtons(isSpokenWord: true, isLiveRadio: false, supportsPlaybackRate: true) == [.playbackRate, .audioQuality, .like])
        #expect(config.visibleNowPlayingButtons(isSpokenWord: false, isLiveRadio: true, supportsPlaybackRate: true).isEmpty)
    }

    @Test func playbackDisplayChoicesRoundTripAndOldLayoutsPreservePhoneLyricsPreference() throws {
        let old = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: Data("{}".utf8))
        #expect(old.lyricsPosition == .followPhone)
        #expect(old.topRightAction == .queue)
        #expect(!old.lyricsPosition.isEnabled(phoneEnabled: false))
        #expect(old.lyricsPosition.isEnabled(phoneEnabled: true))
        var config = old
        config.lyricsPosition = .title
        config.topRightAction = .audioInfo
        config.customNowPlayingButtons = [.audioFormat, .audioBitRate, .audioResolution, .queue]
        #expect(try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: JSONEncoder().encode(config)) == config)
        let unknown = try JSONDecoder().decode(CarPlayLayoutConfiguration.self,
            from: Data(#"{"lyricsPosition":"future","topRightAction":"future"}"#.utf8))
        #expect(unknown.lyricsPosition == .followPhone)
        #expect(unknown.topRightAction == .queue)
    }

    @Test func queueDeduplicationPreservesSavedChoiceForOtherTopRightActions() {
        var config = CarPlayLayoutConfiguration()
        config.setNowPlayingButtons([.queue, .audioQuality], isSpokenWord: false)
        #expect(config.visibleNowPlayingButtons(isSpokenWord: false, isLiveRadio: false, supportsPlaybackRate: true) == [.audioQuality])
        for action in [CarPlayTopRightAction.album, .audioInfo, .more, .hidden] {
            config.topRightAction = action
            #expect(config.visibleNowPlayingButtons(isSpokenWord: false, isLiveRadio: false, supportsPlaybackRate: true) == [.queue, .audioQuality])
        }
        #expect(config.customNowPlayingButtons == [.queue, .audioQuality])
    }

    @Test func changingPresetsPreservesSeparateButtonChoices() {
        var config = CarPlayLayoutConfiguration()
        config.setNowPlayingButtons([.audioQuality, .like], isSpokenWord: false)
        config.setNowPlayingButtons([.queue, .skipBackward], isSpokenWord: true)
        config.apply(.focus)
        config.apply(.quickPlay)
        #expect(config.nowPlayingButtons(isSpokenWord: false) == [.audioQuality, .like])
        #expect(config.nowPlayingButtons(isSpokenWord: true) == [.queue, .skipBackward])
        #expect(config.matchingPreset == .quickPlay)
    }

    @Test func switchingPresetsPreservesPinnedCollectionsAndRestoresPresentation() {
        var config = CarPlayLayoutConfiguration()
        let folder = LibraryFolderNodeID(sourceID: "nas", kind: .folder, normalizedRelativePath: "/Music/Live")
        config.pinnedPlaylistIDs = ["commute", "favorites"]
        config.folderIDs = [folder]
        config.sectionOrder.reverse()
        config.opensNowPlayingAfterSelection = false

        config.apply(.focus)
        #expect(config.visibleSections == [.shortcuts])
        #expect(config.opensNowPlayingOnConnect)
        #expect(config.opensNowPlayingAfterSelection)
        #expect(config.minimalNowPlaying)
        #expect(config.pinnedPlaylistIDs == ["commute", "favorites"])
        #expect(config.folderIDs == [folder])
        #expect(config.matchingPreset == .focus)

        config.apply(.artwork)
        #expect(config.browseStyle == .cards)
        #expect(!config.playsCollectionsDirectly)
        #expect(!config.opensNowPlayingOnConnect)
        #expect(!config.minimalNowPlaying)
        config.browseStyle = .covers
        #expect(config.matchingPreset == nil)
    }

    @Test func decodingFutureOptionsKeepsKnownOrderAndUnavailablePins() throws {
        let data = Data(#"{"browseStyle":"future","sectionOrder":["albums","future","albums","shortcuts"],"hiddenSections":["future","playlists"],"pinnedPlaylistIDs":["offline","offline","active"],"opensNowPlayingAfterSelection":false}"#.utf8)
        let config = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: data)
        #expect(config.browseStyle == .list)
        #expect(config.visibleSections == [.albums, .shortcuts, .recentlyAdded])
        #expect(config.pinnedPlaylistIDs == ["offline", "active"])
        #expect(!config.opensNowPlayingAfterSelection)
    }

    @Test func persistenceRoundTripAndCorruptionFallback() throws {
        let suite = "CarPlayLayoutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = CarPlayLayoutConfiguration()
        config.apply(.artwork)
        config.sectionOrder = [.recentlyAdded, .shortcuts, .albums, .playlists]
        config.hiddenSections = []
        config.save(to: defaults)
        #expect(CarPlayLayoutConfiguration.load(from: defaults) == config)
        defaults.set(Data("broken".utf8), forKey: CarPlayLayoutConfiguration.storageKey)
        #expect(CarPlayLayoutConfiguration.load(from: defaults) == .recommended)
    }

    @Test func hiddenSectionsStayHiddenAndShortcutLimitCountsFolders() {
        var config = CarPlayLayoutConfiguration()
        config.hiddenSections = Set(CarPlayHomeSection.allCases)
        #expect(config.visibleSections.isEmpty)
        config.pinnedPlaylistIDs = (0..<11).map(String.init)
        #expect(config.canAddShortcut)
        config.folderIDs = [.init(sourceID: "drive", kind: .folder, normalizedRelativePath: "opaque-id")]
        #expect(!config.canAddShortcut)
    }

    @Test func homeBlockOffersSeeAllOnlyWhenSomethingIsLeftOut() {
        #expect(CarPlayHomeMorePolicy.probeLimit(for: 6) == 7)
        #expect(CarPlayHomeMorePolicy.probeLimit(for: -3) == 1)
        // 取到第 7 个：这一块后面还有。
        #expect(CarPlayHomeMorePolicy.hasMore(fetchedCount: 7, itemLimit: 6, shownCount: 6))
        // 刚好 6 个、全放下了：没有更多。
        #expect(!CarPlayHomeMorePolicy.hasMore(fetchedCount: 6, itemLimit: 6, shownCount: 6))
        #expect(!CarPlayHomeMorePolicy.hasMore(fetchedCount: 3, itemLimit: 6, shownCount: 3))
        // 首页总行数不够，只放下一部分。
        #expect(CarPlayHomeMorePolicy.hasMore(fetchedCount: 5, itemLimit: 6, shownCount: 2))
        #expect(!CarPlayHomeMorePolicy.hasMore(fetchedCount: 0, itemLimit: 6, shownCount: 0))
    }
}
