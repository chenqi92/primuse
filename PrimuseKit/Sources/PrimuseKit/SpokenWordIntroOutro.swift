import Foundation

/// 一本书每条开头、结尾各跳过多少秒。Ting Reader 在服务端按书记着(网页端「编辑书籍」里填)。
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

/// 跳片头片尾的规则,和 Ting Reader 网页端播放器一致:开播位置落在片头里就从片头结束处开始;
/// 播到离结尾不到片尾秒数就当这条听完、接下一条,但这条要比「片头 + 片尾 + 10 秒」长才跳。
public enum SpokenWordIntroOutroPolicy {
    /// 开始播一条时从哪里起。`resume` 是续播位置(没有就是 nil);返回 nil 表示从头。
    public static func startPosition(
        resume: TimeInterval?,
        duration: TimeInterval,
        skip: SpokenWordIntroOutro
    ) -> TimeInterval? {
        let intro = TimeInterval(skip.introSeconds)
        guard intro > 0, !(duration.isFinite && duration > 0 && intro >= duration - 1) else { return resume }
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
        guard outro > 0, position.isFinite, duration.isFinite,
              duration > TimeInterval(skip.introSeconds) + outro + 10 else { return false }
        return duration - position <= outro
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
