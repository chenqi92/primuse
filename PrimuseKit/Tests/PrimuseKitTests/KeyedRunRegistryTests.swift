import Foundation
import Testing
@testable import PrimuseKit

struct KeyedRunRegistryTests {
    @Test func staleRunTeardownKeepsReplacementRegistered() {
        var registry = KeyedRunRegistry<String>()
        let runA = registry.register(key: "source:mv", value: "download-a")
        // 旧 run 被取消/替换: 登记换成 B, 但 A 还在跑, 稍后才会收尾。
        let runB = registry.register(key: "source:mv", value: "download-b")

        #expect(registry.finish(key: "source:mv", runID: runA) == nil)
        #expect(registry.value(forKey: "source:mv") == "download-b")

        #expect(registry.finish(key: "source:mv", runID: runB) == "download-b")
        #expect(registry.value(forKey: "source:mv") == nil)
        #expect(registry.isEmpty)
    }

    @Test func preMintedIdentityFinishesItsOwnRun() {
        var registry = KeyedRunRegistry<String>()
        let runID = UUID()
        registry.register(key: "k", value: "v", id: runID)

        #expect(registry.run(forKey: "k")?.id == runID)
        #expect(registry.finish(key: "k", runID: UUID()) == nil)
        #expect(registry.finish(key: "k", runID: runID) == "v")
    }

    @Test func finishRemovesOnlyItsOwnRun() {
        var registry = KeyedRunRegistry<Int>()
        let first = registry.register(key: "a", value: 1)
        registry.register(key: "b", value: 2)

        #expect(registry.finish(key: "a", runID: first) == 1)
        #expect(registry.value(forKey: "a") == nil)
        #expect(registry.value(forKey: "b") == 2)
        #expect(registry.count == 1)
    }

    @Test func removeAllMatchingKeysReturnsRemovedValues() {
        var registry = KeyedRunRegistry<Int>()
        registry.register(key: "s1:one", value: 1)
        registry.register(key: "s1:two", value: 2)
        registry.register(key: "s2:three", value: 3)

        let removed = registry.removeAll { $0.hasPrefix("s1:") }.sorted()

        #expect(removed == [1, 2])
        #expect(registry.keys == ["s2:three"])
    }

    @Test func cancelAllLeavesRegistrationsInPlace() async {
        var registry = KeyedRunRegistry<Task<Void, Never>>()
        let kept = Task { try? await Task.sleep(for: .seconds(60)) }
        let cancelled = Task { try? await Task.sleep(for: .seconds(60)) }
        registry.register(key: "s1:keep", value: kept)
        let cancelledRun = registry.register(key: "s2:cancel", value: cancelled)

        registry.cancelAll { $0.hasPrefix("s2:") }

        #expect(cancelled.isCancelled)
        #expect(!kept.isCancelled)
        // 取消不等于注销: run 仍在册, 由它自己的收尾按身份移除。
        #expect(registry.count == 2)
        #expect(registry.finish(key: "s2:cancel", runID: cancelledRun) != nil)
        #expect(registry.count == 1)

        kept.cancel()
        await kept.value
        await cancelled.value
    }

    @Test func cancelAndRemoveAllUnregistersImmediately() async {
        var registry = KeyedRunRegistry<Task<Void, Never>>()
        let task = Task { try? await Task.sleep(for: .seconds(60)) }
        let runID = registry.register(key: "s1:mv", value: task)

        let removed = registry.cancelAndRemoveAll { $0.hasPrefix("s1:") }

        #expect(removed.count == 1)
        #expect(task.isCancelled)
        #expect(registry.isEmpty)
        // 迟到的收尾对已经注销的 key 无副作用。
        #expect(registry.finish(key: "s1:mv", runID: runID) == nil)

        await task.value
    }
}
