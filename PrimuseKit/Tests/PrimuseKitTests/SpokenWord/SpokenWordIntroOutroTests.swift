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

    @Test("Short chapters keep their body and invalid clocks cannot finish a chapter")
    func shortChapterAndInvalidClock() {
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 60, skip: skip) == nil)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: 12, duration: 60, skip: skip) == 12)
        #expect(SpokenWordIntroOutroPolicy.startPosition(resume: nil, duration: 61, skip: skip) == 30)
        for position in [Double.nan, .infinity, -.infinity, -1] {
            #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: position, duration: 1800, skip: skip))
        }
        #expect(!SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1780, duration: .nan, skip: skip))
        #expect(SpokenWordIntroOutroPolicy.shouldSkipOutro(position: 1780, duration: 1800, skip: skip))
    }

    @Test("Local overrides survive relaunch and explicitly disabling beats the server")
    @MainActor
    func localOverrides() throws {
        let suite = "SpokenWordIntroOutroPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SpokenWordIntroOutroPreferences(defaults: defaults)
        #expect(preferences.settings(forBookID: "book", server: skip) == skip)
        preferences.set(.off, forBookID: "book")
        let reloaded = SpokenWordIntroOutroPreferences(defaults: defaults)
        #expect(reloaded.settings(forBookID: "book", server: skip) == .off)
        #expect(reloaded.settings(forBookID: "another-book", server: skip) == skip)
        #expect(reloaded.settings(forBookID: "another-book", server: nil) == nil)
        reloaded.set(nil, forBookID: "book")
        #expect(reloaded.settings(forBookID: "book", server: skip) == skip)
        #expect(defaults.object(forKey: SpokenWordIntroOutroPreferences.storageKey) == nil)
    }

    @Test("Book regrouping carries local settings without replacing a destination decision")
    @MainActor
    func renamedBooks() throws {
        let suite = "SpokenWordIntroOutroRenamesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SpokenWordIntroOutroPreferences(defaults: defaults)
        preferences.set(skip, forBookID: "folder")
        preferences.set(.off, forBookID: "other")
        preferences.carryBookState(renames: ["folder": "album"])
        #expect(preferences.override(forBookID: "album") == skip)
        preferences.carryBookState(renames: ["album": "other"])
        #expect(preferences.override(forBookID: "other") == .off)
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
