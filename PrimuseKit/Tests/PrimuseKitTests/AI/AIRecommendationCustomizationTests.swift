import Foundation
import Testing
@testable import PrimuseKit

@Suite("Recommendation focuses edited on the recommendations page")
struct AIRecommendationIntentCustomizationTests {
    private typealias Overrides = AIRecommendationIntentPresetOverridePolicy

    private func options(
        custom: String = "",
        hidden: String = "",
        overrides: String = ""
    ) -> [AIRecommendationIntentOption] {
        AIRecommendationIntentCatalog.options(
            customRawValue: custom,
            hiddenPresetsRawValue: hidden,
            presetOverridesRawValue: overrides
        )
    }

    @Test("Without edits the catalog lists no focus, the built-ins and then custom focuses")
    func defaultCatalog() throws {
        let custom = try #require(AIRecommendationIntentStoragePolicy.makeIntent(title: "90s Rock", prompt: "nineties rock"))
        let list = options(custom: AIRecommendationIntentStoragePolicy.encode([custom]))
        #expect(list.first?.source == .defaultSelection)
        #expect(list.first?.prompt == nil)
        #expect(list.dropFirst().prefix(5).map(\.id)
            == AIRecommendationIntentPreset.userManagedCases.map(\.selectionID))
        let continuity = try #require(list.first { $0.id == AIRecommendationIntentPreset.familiarContinuity.selectionID })
        #expect(continuity.prompt == AIRecommendationIntentPreset.familiarContinuity.semanticIntent)
        #expect(continuity.detail == AIRecommendationIntentPreset.familiarContinuity.localizedDetail)
        #expect(continuity.isModifiedPreset == false)
        #expect(list.last?.source == .custom(custom.id))
        #expect(list.last?.prompt == "nineties rock")
    }

    @Test("An edited built-in keeps its place and selection id and sends the new prompt")
    func editedPreset() throws {
        let preset = AIRecommendationIntentPreset.adjacentDiscovery
        let raw = Overrides.setting(preset, title: "  Neighbours  ", prompt: "artists near my\nfavourites", in: "")
        let list = options(overrides: raw)
        let edited = try #require(list.first { $0.id == preset.selectionID })
        #expect(edited.title == "Neighbours")
        #expect(edited.prompt == "artists near my favourites")
        #expect(edited.detail == "artists near my favourites")
        #expect(edited.isModifiedPreset)
        #expect(list.firstIndex(of: edited) == options().firstIndex { $0.id == preset.selectionID })

        let restored = Overrides.removing(preset, in: raw)
        #expect(restored.isEmpty)
        #expect(options(overrides: restored).first { $0.id == preset.selectionID }?.isModifiedPreset == false)
    }

    @Test("Fields matching the built-in are not stored, so an unchanged save leaves nothing behind")
    func unchangedFieldsAreDropped() {
        let preset = AIRecommendationIntentPreset.catalogRewind
        #expect(Overrides.setting(
            preset,
            title: preset.localizedTitle,
            prompt: preset.semanticIntent ?? "",
            in: ""
        ).isEmpty)
        let promptOnly = Overrides.setting(preset, title: preset.localizedTitle, prompt: "older classics", in: "")
        #expect(Overrides.override(for: preset, in: promptOnly)
            == AIRecommendationIntentPresetOverride(title: nil, prompt: "older classics"))
        #expect(Overrides.setting(.balanced, title: "X", prompt: "Y", in: "").isEmpty)
    }

    @Test("Overrides for focuses this version does not know survive a round trip")
    func unknownOverridesSurvive() {
        let raw = #"{"futureFocus":{"prompt":"new"},"recentCatalog":{"title":"  "}}"#
        let decoded = Overrides.decode(raw)
        #expect(decoded["futureFocus"]?.prompt == "new")
        #expect(decoded["recentCatalog"] == nil)
        let updated = Overrides.setting(.genreExploration, title: "", prompt: "wide", in: raw)
        #expect(Overrides.decode(updated)["futureFocus"]?.prompt == "new")
        #expect(Overrides.decode(updated)["genreExploration"]?.prompt == "wide")
    }

    @Test("Editing a custom focus keeps its id and position and refuses a duplicate name")
    func editCustomFocus() throws {
        let first = try #require(AIRecommendationIntentStoragePolicy.makeIntent(title: "Jazz", prompt: "jazz"))
        let second = try #require(AIRecommendationIntentStoragePolicy.makeIntent(title: "Folk", prompt: "folk"))
        let intents = [first, second]
        let updated = try #require(AIRecommendationIntentStoragePolicy.updating(
            id: first.id, title: "Cool Jazz", prompt: "cool jazz", in: intents
        ))
        #expect(updated.map(\.id) == [first.id, second.id])
        #expect(updated[0].title == "Cool Jazz")
        #expect(AIRecommendationIntentStoragePolicy.updating(id: first.id, title: "folk", prompt: "x", in: intents) == nil)
        #expect(AIRecommendationIntentStoragePolicy.updating(id: first.id, title: "Jazz", prompt: "  ", in: intents) == nil)
        #expect(AIRecommendationIntentStoragePolicy.updating(id: UUID(), title: "New", prompt: "x", in: intents) == nil)
    }

    @Test("Name conflicts ignore case and the focus being edited")
    func titleConflicts() throws {
        let list = options(overrides: Overrides.setting(.familiarContinuity, title: "Comfort", prompt: "", in: ""))
        let comfort = try #require(list.first { $0.title == "Comfort" })
        #expect(AIRecommendationIntentCatalog.hasTitleConflict("comfort ", excludingID: nil, in: list))
        #expect(!AIRecommendationIntentCatalog.hasTitleConflict("Comfort", excludingID: comfort.id, in: list))
        #expect(!AIRecommendationIntentCatalog.hasTitleConflict("Something else", excludingID: nil, in: list))
    }

    @Test("Hidden built-ins leave the catalog")
    func hiddenPresets() {
        let hidden = AIRecommendationIntentPresetVisibilityPolicy.hiding(.recentCatalog, in: "")
        let ids = options(hidden: hidden).map(\.id)
        #expect(!ids.contains(AIRecommendationIntentPreset.recentCatalog.selectionID))
        #expect(ids.first == AIRecommendationIntentSelectionPolicy.defaultSelectionID)
    }
}

@Suite("Recommendation scenes configured on the recommendations page")
struct AIRecommendationSceneConfigurationTests {
    private typealias Policy = AIRecommendationSceneConfigurationPolicy

    @Test("Defaults keep the original page: every scene, 12 songs, global refresh, music videos")
    func defaults() {
        let configuration = Policy.decode("")
        #expect(configuration.visibleScenes == AIRecommendationScene.allCases)
        let settings = configuration.settings(for: .driving)
        #expect(settings == .default)
        #expect(settings.songCount == 12)
        #expect(settings.refreshInterval == nil)
        #expect(settings.showsMusicVideos)
        #expect(settings.candidatePoolSize == 36)
        #expect(settings.minimumResults == 10)
        #expect(Policy.encode(configuration).isEmpty)
    }

    @Test("Larger loads widen the local pool and the completeness threshold")
    func songCountSizing() {
        let twenty = AIRecommendationSceneSettings(songCount: 20)
        let thirty = AIRecommendationSceneSettings(songCount: 30)
        #expect(twenty.candidatePoolSize == 60)
        #expect(twenty.minimumResults == 16)
        #expect(thirty.candidatePoolSize == 90)
        #expect(thirty.minimumResults == 24)
        #expect(AIRecommendationSceneSettings(songCount: 500).songCount == AIRecommendationRequest.maximumSongSelections)
        #expect(AIRecommendationSceneSettings(songCount: 0).songCount == 1)
        #expect(AIRecommendationSceneSettings(refreshInterval: .automatic).refreshInterval == nil)
    }

    @Test("Per-scene settings round-trip and stay separate")
    func roundTrip() {
        var configuration = AIRecommendationSceneConfiguration()
        configuration.setSettings(
            AIRecommendationSceneSettings(songCount: 30, refreshInterval: .daily, showsMusicVideos: false),
            for: .driving
        )
        configuration.setVisible(false, for: .bedtime)
        let decoded = Policy.decode(Policy.encode(configuration))
        #expect(decoded == configuration)
        #expect(decoded.settings(for: .driving).songCount == 30)
        #expect(decoded.settings(for: .driving).refreshInterval == .daily)
        #expect(decoded.settings(for: .driving).showsMusicVideos == false)
        #expect(decoded.settings(for: .focus) == .default)
        #expect(!decoded.visibleScenes.contains(.bedtime))

        configuration.setSettings(.default, for: .driving)
        configuration.setVisible(true, for: .bedtime)
        #expect(Policy.encode(configuration).isEmpty)
    }

    @Test("Stored values from other versions decode safely")
    func tolerantDecoding() {
        let raw = #"{"hiddenScenes":["future","focus","focus"],"sceneSettings":{"workout":{"songCount":20,"refreshInterval":"weekly"},"future":{"showsMusicVideos":false}}}"#
        let configuration = Policy.decode(raw)
        #expect(configuration.hiddenScenes == ["focus", "future"])
        #expect(!configuration.isVisible(.focus))
        #expect(configuration.settings(for: .workout).songCount == 20)
        #expect(configuration.settings(for: .workout).refreshInterval == nil)
        #expect(configuration.settings(for: .workout).showsMusicVideos)
        #expect(Policy.decode("not json") == AIRecommendationSceneConfiguration())
        // An unknown scene's settings travel along for the newer version that wrote them.
        #expect(Policy.decode(Policy.encode(configuration)).sceneSettings["future"]?.showsMusicVideos == false)
    }

    @Test("The last visible scene cannot be hidden and a hidden selection falls back")
    func visibility() {
        var configuration = AIRecommendationSceneConfiguration()
        for scene in AIRecommendationScene.allCases where scene != .relaxation {
            configuration.setVisible(false, for: scene)
        }
        #expect(configuration.visibleScenes == [.relaxation])
        #expect(!configuration.canHide(.relaxation))
        configuration.setVisible(false, for: .relaxation)
        #expect(configuration.visibleScenes == [.relaxation])
        #expect(configuration.resolvedSelection(.driving) == .relaxation)
        #expect(configuration.resolvedSelection(.relaxation) == .relaxation)

        let allHidden = Policy.decode(#"{"hiddenScenes":["automatic","driving","focus","workout","relaxation","bedtime"]}"#)
        #expect(allHidden.visibleScenes == AIRecommendationScene.allCases)
    }

    @Test("Asking for more than 12 songs uses its own reuse slot; 12 or fewer keeps the old one")
    func reuseSlotFollowsSongCount() {
        func request(_ maximumResults: Int) -> AIRecommendationRequest {
            AIRecommendationRequest(
                scene: .focus,
                languageCode: "en",
                preferences: [],
                candidates: (0..<60).map { AIRecommendationCandidate(songID: "s\($0)", title: "T", artist: "A") },
                maximumResults: maximumResults,
                minimumResults: 5
            )
        }
        let twelve = AIRecommendationReusePolicy.slotKey(surface: .library, sceneSelection: .focus, request: request(12))
        let ten = AIRecommendationReusePolicy.slotKey(surface: .library, sceneSelection: .focus, request: request(10))
        let thirty = AIRecommendationReusePolicy.slotKey(surface: .library, sceneSelection: .focus, request: request(30))
        #expect(twelve == ten)
        #expect(!twelve.contains("n12"))
        #expect(thirty != twelve)
        #expect(thirty.hasSuffix("n30"))
    }
}
