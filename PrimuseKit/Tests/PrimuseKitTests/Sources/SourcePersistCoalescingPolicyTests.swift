import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source persist coalescing")
struct SourcePersistCoalescingPolicyTests {
    @Test("A terminal commit always writes")
    func finalCommitAlwaysPersists() {
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: true,
            isBackgrounded: false,
            secondsSinceLastPersist: 0
        ))
    }

    @Test("Leaving the foreground always writes")
    func backgroundingAlwaysPersists() {
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: true,
            secondsSinceLastPersist: 0
        ))
    }

    @Test("Intermediate counts inside the window are coalesced")
    func intermediateWithinWindowIsCoalesced() {
        #expect(!SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: 0.2
        ))
        // 中间 flush 每 1.5 s 一次, 但页提交可以更密。
        #expect(!SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: 0.74
        ))
    }

    @Test("An elapsed window writes again")
    func elapsedWindowPersists() {
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: SourcePersistCoalescingPolicy.debounceInterval
        ))
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: 5
        ))
    }

    @Test("A backgrounded scene writes through even inside the window")
    func backgroundedSceneWritesThroughInsideTheWindow() {
        // 场景离开前台之后, 还在收尾的扫描任务可能再发布一次计数; 那一次
        // 不能再挂一个没人来关的窗口。
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: true,
            secondsSinceLastPersist: 0.01
        ))
    }

    @Test("A caller-supplied window is honoured")
    func customIntervalIsHonoured() {
        #expect(!SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: 1,
            debounceInterval: 3
        ))
        #expect(SourcePersistCoalescingPolicy.shouldPersistNow(
            isFinalCommit: false,
            isBackgrounded: false,
            secondsSinceLastPersist: 3,
            debounceInterval: 3
        ))
    }
}
