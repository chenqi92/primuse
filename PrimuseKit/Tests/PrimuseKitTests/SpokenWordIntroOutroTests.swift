import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word: skipping intros and outros")
struct SpokenWordIntroOutroTests {
    private let skip = SpokenWordIntroOutro(introSeconds: 30, outroSeconds: 20)

    @Test("The start lands after the intro unless the resume is already past it")
    func start() {
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 1800, skip: skip) == 30)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: 12, duration: 1800, skip: skip) == 30)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: 600, duration: 1800, skip: skip) == 600)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 0, skip: skip) == 30)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 1800, skip: .off) == nil)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: 40, duration: 1800, skip: .off) == 40)
        // 片头比整条还长:不跳。
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 25, skip: skip) == nil)
    }

    @Test("The outro is skipped inside its window on items long enough to have one")
    func outro() {
        #expect(SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1781, duration: 1800, skip: skip))
        #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1700, duration: 1800, skip: skip))
        // 30 + 20 + 10 = 60 秒以内的不跳。
        #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 55, duration: 60, skip: skip))
        #expect(SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 55, duration: 61, skip: skip))
        #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1790, duration: 0, skip: skip))
        #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1790, duration: 1800, skip: .off))
    }

    @Test("Negative seconds from the server count as none")
    func negative() {
        #expect(SpokenWordIntroOutro(introSeconds: -5, outroSeconds: -1).isEmpty)
    }

    @Test("The cache keeps non-zero books per source and reports changes")
    func cache() throws {
        let suite = "SpokenWordServerIntroOutroCacheTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        typealias Cache = SpokenWordServerIntroOutroCache
        Cache.replace(sourceID: "s1", with: ["b1": skip, "b2": .off], in: defaults)
        #expect(Cache.settings(sourceID: "s1", bookID: "b1", in: defaults) == skip)
        #expect(Cache.settings(sourceID: "s1", bookID: "b2", in: defaults) == nil)
        #expect(Cache.settings(sourceID: "s2", bookID: "b1", in: defaults) == nil)
        #expect(!Cache.update(skip, sourceID: "s1", bookID: "b1", in: defaults))
        let longer = SpokenWordIntroOutro(introSeconds: 45, outroSeconds: 20)
        #expect(Cache.update(longer, sourceID: "s1", bookID: "b1", in: defaults))
        #expect(Cache.settings(sourceID: "s1", bookID: "b1", in: defaults) == longer)
        #expect(Cache.update(.off, sourceID: "s1", bookID: "b1", in: defaults))
        #expect(Cache.settings(sourceID: "s1", bookID: "b1", in: defaults) == nil)
        #expect(defaults.object(forKey: SpokenWordServerIntroOutroCache.storageKey) == nil)
    }
}
