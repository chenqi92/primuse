import Foundation
import Testing
@testable import PrimuseKit

@Suite("诊断日志限幅")
struct DiagnosticLogSamplerTests {
    @Test("窗口内前若干条写完整细节")
    func firstEntriesAreDetailed() {
        var sampler = DiagnosticLogSampler(detailLimit: 3, summaryInterval: 10)
        let now = Date()

        for expected in 1...3 {
            let decision = sampler.record(key: "a", now: now)
            #expect(decision.detailed)
            #expect(decision.count == expected)
            #expect(!decision.summarize)
        }

        let fourth = sampler.record(key: "a", now: now)
        #expect(!fourth.detailed)
        #expect(fourth.count == 4)
    }

    @Test("细节省略后只按间隔写计数")
    func suppressedEntriesSummarizeOnInterval() {
        var sampler = DiagnosticLogSampler(detailLimit: 2, summaryInterval: 5)
        let now = Date()
        var summarized: [Int] = []

        for _ in 1...20 {
            let decision = sampler.record(key: "a", now: now)
            if decision.summarize { summarized.append(decision.count) }
        }

        #expect(summarized == [5, 10, 15, 20])
    }

    @Test("窗口过去以后额度重新发放")
    func windowRenewsQuota() {
        var sampler = DiagnosticLogSampler(detailLimit: 2, summaryInterval: 50, windowDuration: 300)
        let start = Date()

        for _ in 1...5 { _ = sampler.record(key: "a", now: start) }
        #expect(!sampler.record(key: "a", now: start).detailed)

        // 窗口内不重置
        let withinWindow = sampler.record(key: "a", now: start.addingTimeInterval(299))
        #expect(!withinWindow.detailed)
        #expect(withinWindow.count == 7)

        let afterWindow = sampler.record(key: "a", now: start.addingTimeInterval(301))
        #expect(afterWindow.detailed)
        #expect(afterWindow.count == 1)
    }

    @Test("持续失败不会把窗口一直续下去")
    func continuousFailuresDoNotSlideTheWindow() {
        var sampler = DiagnosticLogSampler(detailLimit: 1, summaryInterval: 50, windowDuration: 100)
        let start = Date()

        // 每 60 秒来一条: 窗口按第一条起算, 第 120 秒才该换窗口。
        #expect(sampler.record(key: "a", now: start).detailed)
        #expect(!sampler.record(key: "a", now: start.addingTimeInterval(60)).detailed)
        #expect(sampler.record(key: "a", now: start.addingTimeInterval(120)).detailed)
    }

    @Test("不同故障各算各的")
    func keysAreIndependent() {
        var sampler = DiagnosticLogSampler(detailLimit: 1, summaryInterval: 50)
        let now = Date()

        #expect(sampler.record(key: "status#500", now: now).detailed)
        #expect(!sampler.record(key: "status#500", now: now).detailed)
        #expect(sampler.record(key: "status#503", now: now).detailed)
        #expect(sampler.count(forKey: "status#500") == 2)
        #expect(sampler.count(forKey: "status#503") == 1)
        #expect(sampler.count(forKey: "never-seen") == 0)
    }

    @Test("重置之后重新开始")
    func resetClearsEveryWindow() {
        var sampler = DiagnosticLogSampler(detailLimit: 1, summaryInterval: 50)
        let now = Date()
        _ = sampler.record(key: "a", now: now)
        _ = sampler.record(key: "a", now: now)

        sampler.reset()

        #expect(sampler.count(forKey: "a") == 0)
        #expect(sampler.record(key: "a", now: now).detailed)
    }

    @Test("退化参数不会写出无效判断")
    func degenerateParametersStayUsable() {
        var noDetail = DiagnosticLogSampler(detailLimit: 0, summaryInterval: 0)
        let now = Date()
        let first = noDetail.record(key: "a", now: now)
        #expect(!first.detailed)
        // summaryInterval 至少是 1, 每一条都写计数摘要而不是除零。
        #expect(first.summarize)

        var negative = DiagnosticLogSampler(detailLimit: -5, summaryInterval: 3, windowDuration: -1)
        let decision = negative.record(key: "a", now: now)
        #expect(!decision.detailed)
        #expect(decision.count == 1)
    }
}
