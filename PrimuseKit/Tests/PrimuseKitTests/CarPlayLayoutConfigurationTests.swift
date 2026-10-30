import Foundation
import Testing
@testable import PrimuseKit

struct CarPlayLayoutConfigurationTests {
    @Test func olderLayoutsGainFiveButtonsWithoutChangingTheirPresentation() throws {
        let config = try JSONDecoder().decode(CarPlayLayoutConfiguration.self, from: Data(#"{"browseStyle":"covers","minimalNowPlaying":true}"#.utf8))
        #expect(config.nowPlayingButtons(isSpokenWord: false) == [.shuffle, .repeatMode, .like, .audioQuality, .queue])
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
        #expect(config.visibleNowPlayingButtons(isSpokenWord: true, isLiveRadio: false, supportsPlaybackRate: false) == [.queue, .audioQuality, .like])
        #expect(config.visibleNowPlayingButtons(isSpokenWord: true, isLiveRadio: false, supportsPlaybackRate: true) == [.queue, .playbackRate, .audioQuality, .like])
        #expect(config.visibleNowPlayingButtons(isSpokenWord: false, isLiveRadio: true, supportsPlaybackRate: true).isEmpty)
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
        #expect(CarPlayLayoutConfiguration.load(from: defaults) == CarPlayLayoutConfiguration())
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
}
