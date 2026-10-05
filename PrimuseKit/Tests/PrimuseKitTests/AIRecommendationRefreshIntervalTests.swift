import Foundation
import Testing
@testable import PrimuseKit

@Suite("Recommendation refresh interval: reuse a surface's last result")
struct AIRecommendationRefreshIntervalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func request(
        _ ids: [String],
        scene: AIRecommendationScene = .focus,
        intent: String? = nil,
        unit: AIRecommendationUnit = .songs,
        playCount: Int = 3
    ) -> AIRecommendationRequest {
        AIRecommendationRequest(
            scene: scene,
            intent: intent,
            languageCode: "zh-Hans",
            preferences: [AIRecommendationPreference(title: "T", artist: "A", playCount: playCount)],
            candidates: ids.map { AIRecommendationCandidate(songID: $0, title: $0, artist: "A") },
            maximumResults: 12,
            minimumResults: 3,
            unit: unit
        )
    }

    private func entry(
        _ ids: [String],
        route: String = "builtIn",
        age: TimeInterval,
        isPartial: Bool = false
    ) -> AIRecommendationReuseEntry {
        AIRecommendationReuseEntry(
            plan: AIRecommendationPlan(
                summary: "S",
                selections: ids.map { AIRecommendationSelection(songID: $0, reason: "R \($0)") },
                isPartial: isPartial
            ),
            providerName: "Built-in",
            fallbackDepth: 0,
            route: route,
            scene: .focus,
            createdAt: now.addingTimeInterval(-age)
        )
    }

    @Test("Automatic is six hours with the built-in AI and real time with an own service")
    func automaticResolution() {
        #expect(AIRecommendationRefreshInterval.stored(nil) == .automatic)
        #expect(AIRecommendationRefreshInterval.stored("bogus") == .automatic)
        #expect(AIRecommendationRefreshInterval.stored("daily") == .daily)
        #expect(AIRecommendationRefreshInterval.automatic.resolved(usesBuiltIn: true) == .sixHours)
        #expect(AIRecommendationRefreshInterval.automatic.resolved(usesBuiltIn: false) == .realtime)
        #expect(AIRecommendationRefreshInterval.hourly.resolved(usesBuiltIn: true) == .hourly)
        #expect(AIRecommendationRefreshInterval.daily.resolved(usesBuiltIn: false) == .daily)
        #expect(AIRecommendationRefreshInterval.realtime.reuseWindow == nil)
        #expect(AIRecommendationRefreshInterval.sixHours.reuseWindow == 21_600)
    }

    @Test("Playing songs changes candidates and play counts, not the slot")
    func slotIgnoresCandidates() {
        let before = request(["a", "b", "c"], playCount: 3)
        let after = request(["b", "c", "d"], scene: .driving, playCount: 4)
        // The resolved scene moves with the clock; the slot follows the listener's choice.
        #expect(
            AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .automatic, request: before)
                == AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .automatic, request: after)
        )
        #expect(
            AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .automatic, request: before)
                != AIRecommendationReusePolicy.slotKey(surface: .library, sceneSelection: .automatic, request: before)
        )
        #expect(
            AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .automatic, request: before)
                != AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .workout, request: before)
        )
        #expect(
            AIRecommendationReusePolicy.slotKey(surface: .library, sceneSelection: .automatic, request: before)
                != AIRecommendationReusePolicy.slotKey(
                    surface: .library,
                    sceneSelection: .automatic,
                    request: request(["a", "b", "c"], intent: "new artists")
                )
        )
        #expect(
            AIRecommendationReusePolicy.slotKey(surface: .home, sceneSelection: .automatic, request: before)
                != AIRecommendationReusePolicy.slotKey(
                    surface: .home,
                    sceneSelection: .automatic,
                    request: request(["a", "b", "c"], unit: .mixed)
                )
        )
    }

    @Test("Within the interval the last plan is reused, filtered to today's candidates")
    func reuseWithinInterval() throws {
        let plan = try #require(AIRecommendationReusePolicy.reusablePlan(
            entry(["a", "b", "c", "d"], age: 5 * 3600),
            for: request(["b", "d", "e"]),
            routes: ["builtIn"],
            interval: .sixHours,
            now: now
        ))
        #expect(plan.selections.map(\.songID) == ["b", "d"])
        #expect(plan.summary == "S")
        // Fewer than the minimum after filtering is still the complete answer it was.
        #expect(plan.isPartial == false)
    }

    @Test("Expired, real-time, another service or nothing left means ask again")
    func noReuse() {
        let current = request(["a", "b", "c"])
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: 6 * 3600), for: current, routes: ["builtIn"], interval: .sixHours, now: now
        ) == nil)
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: 60), for: current, routes: ["builtIn"], interval: .realtime, now: now
        ) == nil)
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: 60), for: current, routes: ["provider:x"], interval: .daily, now: now
        ) == nil)
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["z"], age: 60), for: current, routes: ["builtIn"], interval: .daily, now: now
        ) == nil)
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: 23 * 3600), for: current, routes: ["builtIn"], interval: .daily, now: now
        ) != nil)
    }

    @Test("A clock moved back far does not keep a result forever")
    func clockMovedBack() {
        let current = request(["a"])
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: -60), for: current, routes: ["builtIn"], interval: .hourly, now: now
        ) != nil)
        #expect(AIRecommendationReusePolicy.reusablePlan(
            entry(["a"], age: -3600), for: current, routes: ["builtIn"], interval: .daily, now: now
        ) == nil)
    }

    @Test("Storing keeps the newest slots and skips empty plans")
    func storing() {
        var entries: [String: AIRecommendationReuseEntry] = [:]
        entries = AIRecommendationReusePolicy.storing(entry([], age: 0), for: "empty", in: entries)
        #expect(entries.isEmpty)
        for index in 0..<(AIRecommendationReusePolicy.maximumEntries + 3) {
            entries = AIRecommendationReusePolicy.storing(
                entry(["a"], age: TimeInterval(1000 - index)),
                for: "slot\(index)",
                in: entries
            )
        }
        #expect(entries.count == AIRecommendationReusePolicy.maximumEntries)
        #expect(entries["slot0"] == nil)
        #expect(entries["slot\(AIRecommendationReusePolicy.maximumEntries + 2)"] != nil)
    }

    @Test("Entries survive an encode and decode round trip")
    func codable() throws {
        let original = ["home": entry(["a", "b"], age: 10, isPartial: true)]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: AIRecommendationReuseEntry].self, from: data)
        #expect(decoded == original)
    }
}
