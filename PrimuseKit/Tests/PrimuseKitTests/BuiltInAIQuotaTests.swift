import Foundation
import Testing
@testable import PrimuseKit

struct BuiltInAIQuotaTests {
    private let now = Date(timeIntervalSince1970: 1_791_590_400)

    @Test func readsWhatOneCallLeft() throws {
        let json = """
        {"feature":"library_insight","plan_id":"plus","source":"testflight",
         "today":{"requests":3,"limit":60,"remaining":57,"resets_at":1791676800,"base_limit":30,"bonus":30},
         "total_today":{"requests":9,"limit":600,"remaining":591,"resets_at":1791676800},
         "credits_today":{"requests":4000,"limit":400000,"remaining":396000,"resets_at":1791676800},
         "month":null,"total_month":null,
         "bonuses":[{"kind":"testflight","plan_id":"plus","display_name":"Plus"}]}
        """
        let quota = try #require(BuiltInAIFeatureQuota.decode(Data(json.utf8)))
        #expect(quota.feature == "library_insight")
        #expect(quota.source == .testflight)
        #expect(quota.today == BuiltInAIQuotaCounter(used: 3, limit: 60, remaining: 57,
                                                     resetsAt: Date(timeIntervalSince1970: 1_791_676_800), baseLimit: 30))
        #expect(quota.today?.bonus == 30)
        #expect(quota.month == nil)
        #expect(quota.bonuses == [BuiltInAIQuotaBonus(kind: .testflight, displayName: "Plus")])
    }

    @Test func ignoresWhatItCannotRead() {
        #expect(BuiltInAIFeatureQuota.decode(Data("{}".utf8)) == nil)
        #expect(BuiltInAIFeatureQuota.decode(Data("[1]".utf8)) == nil)
    }

    @Test func readsTheUsageOverview() throws {
        let json = """
        {"plan":{"id":"anonymous_free","display_name":"匿名体验","source":"free_installation","expires_at":null,
                 "boost":{"id":"week","display_name":"上线加量周","ends_at":1792000000,"paused_features":[],
                          "base":{"daily_request_limit":300,"daily_credits":30000,"features":{"tag_cleanup":1}}}},
         "today":{"day":"2026-10-10","resets_at":1791676800,"requests":5,"request_limit":900,"remaining":895,
                  "base_request_limit":300,"credits":1200,"credit_limit":90000,"credits_remaining":88800,"base_credit_limit":30000,
                  "bonuses":[{"kind":"boost","id":"week","display_name":"上线加量周","ends_at":1792000000}],
                  "features":{
                    "tag_cleanup":{"requests":2,"limit":3,"remaining":1,"resets_at":1791676800,"base_limit":1,"bonus":2,
                                   "bonuses":[{"kind":"boost","id":"week","display_name":"上线加量周","ends_at":1792000000}]},
                    "summarize_note":{"requests":0,"limit":30,"remaining":30,"resets_at":1791676800,"name":"笔记摘要","custom":true,"bonuses":[]}}},
         "period":{"starts_at":1790812800,"ends_at":1793491200,"anchor":"calendar","requests":null,"request_limit":null,"remaining":null,
                   "features":{"audio_transcription":{"requests":1,"limit":10,"remaining":9,"resets_at":1793491200}}}}
        """
        let overview = try #require(BuiltInAIQuotaOverview.decode(usageData: Data(json.utf8), at: now))
        #expect(overview.planName == "匿名体验")
        #expect(overview.source == .free)
        #expect(overview.today?.remaining == 895)
        #expect(overview.today?.bonus == 600)
        #expect(overview.credits?.baseLimit == 30_000)
        #expect(overview.month == nil)
        #expect(overview.bonuses.map(\.kind) == [.boost])
        let rows = overview.orderedFeatures(preferredOrder: ["tag_cleanup"])
        #expect(rows.map(\.id) == ["tag_cleanup", "summarize_note"])
        #expect(rows[0].today.bonus == 2)
        #expect(rows[0].bonuses.first?.displayName == "上线加量周")
        #expect(rows[1].name == "笔记摘要")
        #expect(rows[1].bonuses.isEmpty)
    }

    /// The relay before quota feedback: only requests and limits, the boost in the plan.
    @Test func derivesRemainingAndBoostFromAnOlderRelay() throws {
        let json = """
        {"plan":{"id":"anonymous_free","display_name":"匿名体验","source":"free_installation",
                 "boost":{"display_name":"国庆加量","ends_at":1792000000,"paused_features":["recommendations"],
                          "base":{"daily_request_limit":300,"daily_credits":30000,
                                  "features":{"semantic_search":60,"recommendations":12}}}},
         "today":{"day":"2026-10-10","resets_at":1791676800,"requests":7,"request_limit":600,"credits":100,"credit_limit":60000,
                  "features":{"semantic_search":{"requests":7,"limit":120},"recommendations":{"requests":0,"limit":12}}},
         "period":null}
        """
        let overview = try #require(BuiltInAIQuotaOverview.decode(usageData: Data(json.utf8), at: now))
        #expect(overview.today == BuiltInAIQuotaCounter(used: 7, limit: 600, remaining: 593,
                                                        resetsAt: Date(timeIntervalSince1970: 1_791_676_800), baseLimit: 300))
        let search = try #require(overview.features.first { $0.id == "semantic_search" })
        #expect(search.today.remaining == 113)
        #expect(search.today.baseLimit == 60)
        #expect(search.bonuses.map(\.displayName) == ["国庆加量"])
        // Paused for today: back on the plan's own figure, no boost to show.
        let recommendations = try #require(overview.features.first { $0.id == "recommendations" })
        #expect(recommendations.today.baseLimit == nil)
        #expect(recommendations.bonuses.isEmpty)
    }

    @Test func takesTheLatestFiguresFromEachCall() throws {
        let base = BuiltInAIQuotaOverview(
            planName: "匿名体验",
            source: .free,
            today: BuiltInAIQuotaCounter(used: 1, limit: 300),
            features: [
                .init(id: "semantic_search", today: BuiltInAIQuotaCounter(used: 1, limit: 60)),
            ],
            updatedAt: now
        )
        let later = now.addingTimeInterval(60)
        let updated = base.applying(BuiltInAIFeatureQuota(
            feature: "semantic_search",
            today: BuiltInAIQuotaCounter(used: 2, limit: 60),
            totalToday: BuiltInAIQuotaCounter(used: 2, limit: 300)
        ), at: later)
        #expect(updated.features.first?.today.remaining == 58)
        #expect(updated.today?.used == 2)
        #expect(updated.planName == "匿名体验")
        #expect(updated.updatedAt == later)

        // A feature the overview did not list yet gets a row of its own.
        let withNew = updated.applying(BuiltInAIFeatureQuota(
            feature: "summarize_note",
            today: BuiltInAIQuotaCounter(used: 1, limit: 30)
        ), at: later)
        #expect(withNew.features.map(\.id) == ["semantic_search", "summarize_note"])

        let fromCall = BuiltInAIQuotaOverview(quota: BuiltInAIFeatureQuota(
            feature: "lyrics_translation",
            source: .subscription,
            today: BuiltInAIQuotaCounter(used: 4, limit: 150)
        ), at: later)
        #expect(fromCall.source == .subscription)
        #expect(fromCall.features.count == 1)
    }

    @Test func goesStaleAtTheDailyReset() {
        let resets = now.addingTimeInterval(3_600)
        let overview = BuiltInAIQuotaOverview(
            today: BuiltInAIQuotaCounter(used: 1, limit: 10, resetsAt: resets),
            updatedAt: now
        )
        #expect(!overview.isStale(now: now))
        #expect(overview.isStale(now: resets))
    }

    @Test func countsNeverGoBelowZero() {
        let counter = BuiltInAIQuotaCounter(used: 12, limit: 10, baseLimit: 20)
        #expect(counter.remaining == 0)
        #expect(counter.isExhausted)
        #expect(counter.baseLimit == nil)
        #expect(counter.bonus == 0)
        #expect(counter.fractionUsed == 1)
    }
}
