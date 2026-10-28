import Foundation
import Observation

/// 一本书每条开头、结尾各跳过多少秒。
public struct SpokenWordIntroOutro: Codable, Equatable, Hashable, Sendable {
    public static let off = SpokenWordIntroOutro(introSeconds: 0, outroSeconds: 0)

    public let introSeconds: Int
    public let outroSeconds: Int

    public init(introSeconds: Int, outroSeconds: Int) {
        self.introSeconds = max(0, introSeconds)
        self.outroSeconds = max(0, outroSeconds)
    }

    public var isEmpty: Bool { introSeconds == 0 && outroSeconds == 0 }
}

/// 开播位置落在片头里就从片头结束处开始，进入片尾则当作听完。
/// 已知时长的条目须比「片头 + 片尾 + 10 秒」长，避免把短章节的正文跳掉。
public enum SpokenWordIntroOutroPolicy {
    public static let choices = [0, 5, 10, 15, 20, 30, 45, 60, 90, 120, 180, 240, 300]

    /// 开始播一条时从哪里起。`resume` 是续播位置(没有就是 nil);返回 nil 表示从头。
    public static func startPosition(
        resume: TimeInterval?,
        duration: TimeInterval,
        skip: SpokenWordIntroOutro
    ) -> TimeInterval? {
        let intro = TimeInterval(skip.introSeconds)
        guard intro > 0 else { return resume }
        // 短序言、预告等保留正文，不能因为整本书的设置跳到片尾里。
        if duration.isFinite, duration > 0,
           duration <= intro + TimeInterval(skip.outroSeconds) + 10 { return resume }
        guard let resume, resume.isFinite, resume >= intro else { return intro }
        return resume
    }

    /// 播到 `position` 时是不是该跳过片尾了。
    public static func shouldSkipOutro(
        position: TimeInterval,
        duration: TimeInterval,
        skip: SpokenWordIntroOutro
    ) -> Bool {
        let outro = TimeInterval(skip.outroSeconds)
        guard outro > 0, position.isFinite, position >= 0, duration.isFinite,
              duration > TimeInterval(skip.introSeconds) + outro + 10 else { return false }
        return duration - position <= outro
    }
}

/// 本机按书覆盖服务端设置。显式的 0/0 表示不跳过，nil 才表示跟随服务端。
@MainActor
@Observable
public final class SpokenWordIntroOutroPreferences {
    public static let shared = SpokenWordIntroOutroPreferences()
    public static let didChange = Notification.Name("primuse.spokenWordIntroOutroDidChange")
    public static let storageKey = "primuse.spokenWord.introOutroOverrides.v1"

    private var overrides: [String: SpokenWordIntroOutro]
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: [Int]] ?? [:]
        overrides = stored.compactMapValues { pair in
            guard pair.count == 2 else { return nil }
            return SpokenWordIntroOutro(introSeconds: pair[0], outroSeconds: pair[1])
        }
    }

    public func override(forBookID bookID: String) -> SpokenWordIntroOutro? {
        overrides[bookID]
    }

    public func settings(forBookID bookID: String, server: SpokenWordIntroOutro?) -> SpokenWordIntroOutro? {
        overrides[bookID] ?? server
    }

    public func set(_ settings: SpokenWordIntroOutro?, forBookID bookID: String) {
        guard !bookID.isEmpty, overrides[bookID] != settings else { return }
        overrides[bookID] = settings
        persist()
    }

    public func carryBookState(renames: [String: String]) {
        let original = overrides
        for oldID in renames.keys.sorted() {
            guard let newID = renames[oldID], !newID.isEmpty,
                  overrides[newID] == nil, let value = original[oldID] else { continue }
            overrides[newID] = value
        }
        if overrides != original { persist() }
    }

    private func persist() {
        if overrides.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(overrides.mapValues { [$0.introSeconds, $0.outroSeconds] }, forKey: Self.storageKey)
        }
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// 服务端按书设的片头 / 片尾秒数,开播时要同步拿到,所以记在本机:扫描时整源换一遍,
/// 开播一本书时再按这本刷新。只留不为零的;键是「源 id → 服务端书 id」。
public enum SpokenWordServerIntroOutroCache {
    public static let storageKey = "primuse.spokenWord.serverIntroOutro.v1"
    private static let lock = NSLock()

    public static func settings(
        sourceID: String,
        bookID: String,
        in defaults: UserDefaults = .standard
    ) -> SpokenWordIntroOutro? {
        lock.withLock {
            guard let pair = table(in: defaults)[sourceID]?[bookID], pair.count == 2 else { return nil }
            let settings = SpokenWordIntroOutro(introSeconds: pair[0], outroSeconds: pair[1])
            return settings.isEmpty ? nil : settings
        }
    }

    /// 一个源的整份(扫描拿到的全部书)。
    public static func replace(
        sourceID: String,
        with settings: [String: SpokenWordIntroOutro],
        in defaults: UserDefaults = .standard
    ) {
        lock.withLock {
            var all = table(in: defaults)
            let kept = settings.filter { !$0.value.isEmpty }.mapValues { [$0.introSeconds, $0.outroSeconds] }
            guard all[sourceID] ?? [:] != kept else { return }
            all[sourceID] = kept.isEmpty ? nil : kept
            write(all, to: defaults)
        }
    }

    /// 一本书的;返回有没有变。
    @discardableResult
    public static func update(
        _ settings: SpokenWordIntroOutro,
        sourceID: String,
        bookID: String,
        in defaults: UserDefaults = .standard
    ) -> Bool {
        lock.withLock {
            var all = table(in: defaults)
            var books = all[sourceID] ?? [:]
            let value = settings.isEmpty ? nil : [settings.introSeconds, settings.outroSeconds]
            guard books[bookID] != value else { return false }
            books[bookID] = value
            all[sourceID] = books.isEmpty ? nil : books
            write(all, to: defaults)
            return true
        }
    }

    private static func table(in defaults: UserDefaults) -> [String: [String: [Int]]] {
        defaults.dictionary(forKey: storageKey) as? [String: [String: [Int]]] ?? [:]
    }

    private static func write(_ table: [String: [String: [Int]]], to defaults: UserDefaults) {
        if table.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(table, forKey: storageKey)
        }
    }
}
