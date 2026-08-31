import Foundation
import CryptoKit
import PrimuseKit

/// 歌词翻译缓存 — 内存 dict + disk JSON。Apple Translation 离线翻译, 翻译
/// 速度快但仍 ~10ms / 行 + 触发系统语言模型加载, 翻过的存下来下次秒出。
///
/// Key 设计包含 provider 版本、实际源语言、目标语言和原文。短歌词在不同
/// 语言里可能长得完全一样，不能让一个自动识别结果污染另一种语言的缓存。
@MainActor
final class LyricsTranslationCache {
    static let shared = LyricsTranslationCache()

    enum ProviderNamespace: String, Sendable {
        case system
        case intelligent
    }

    private struct Persisted: Codable {
        var schemaVersion: Int?
        var entries: [String: String]  // key → translated text
        /// negative cache: key → 失败时的 Date。系统翻译失败或用户取消语言包
        /// 下载后短时间内不应反复弹出；冷却到期后允许自动恢复。
        var negativeEntries: [String: Date]?
        /// 语言对级冷却不包含歌词文本，切歌或重建播放器后也不会立即重试
        /// 同一个失败的系统 Translation session。
        var pairNegativeEntries: [String: Date]?
        var insertionOrder: [String]?
    }

    private var entries: [String: String] = [:]
    private var negativeEntries: [String: Date] = [:]
    private var pairNegativeEntries: [String: Date] = [:]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    /// 内存条目上限 — 超过这个数量按插入顺序丢最早的 (简化 LRU)。
    private static let maxEntries = 5000
    private static let schemaVersion = 2
    private static let systemProviderVersion = "apple-translation-v2"
    private static let intelligentProviderVersion = "intelligent-translation-v1"
    /// 翻译失败的冷却时间。避免同一次播放期间反复抢占系统展示链，同时不会把
    /// 临时资源错误或用户取消下载长期视为不支持。
    private static let negativeTTL: TimeInterval = 10 * 60

    private var insertionOrder: [String] = []

    private init() {
        let appSupport = FileManager.default
            .primuseDirectoryURL(for: .applicationSupportDirectory)
        let dir = appSupport.appendingPathComponent("Primuse/LyricsTranslation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("cache.json")
        load()
    }

    /// 取一行的翻译。命中返回 translated, 未缓存返回 nil 让调用方触发翻译。
    func translation(
        for source: String,
        sourceLang: String?,
        targetLang: String,
        provider: ProviderNamespace = .system
    ) -> String? {
        let k = Self.makeKey(
            text: source,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: provider
        )
        return entries[k]
    }

    /// 这一行仍处于失败冷却期时别再调用 session.translate，
    /// 系统大概率还会回同样的"无法翻译"。
    func isMarkedFailed(source: String, sourceLang: String?, targetLang: String) -> Bool {
        let k = Self.makeKey(
            text: source,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: .system
        )
        guard let when = negativeEntries[k] else { return false }
        if Date().timeIntervalSince(when) > Self.negativeTTL {
            negativeEntries[k] = nil
            return false
        }
        return true
    }

    /// 批量标记翻译失败行 — 一首歌 batch translate throw 后调一次, 比逐行
    /// markFailed 更省事。
    func markFailed(sources: [String], sourceLang: String?, targetLang: String) {
        guard !sources.isEmpty else { return }
        let now = Date()
        for s in sources {
            let k = Self.makeKey(
                text: s,
                sourceLang: sourceLang,
                targetLang: targetLang,
                provider: .system
            )
            negativeEntries[k] = now
        }
        scheduleSave()
    }

    func isPairMarkedFailed(sourceLang: String?, targetLang: String) -> Bool {
        let key = Self.makePairKey(sourceLang: sourceLang, targetLang: targetLang)
        guard let when = pairNegativeEntries[key] else { return false }
        if Date().timeIntervalSince(when) > Self.negativeTTL {
            pairNegativeEntries[key] = nil
            return false
        }
        return true
    }

    func markPairFailed(sourceLang: String?, targetLang: String) {
        let key = Self.makePairKey(sourceLang: sourceLang, targetLang: targetLang)
        pairNegativeEntries[key] = Date()
        scheduleSave()
    }

    func clearPairFailure(sourceLang: String?, targetLang: String) {
        let key = Self.makePairKey(sourceLang: sourceLang, targetLang: targetLang)
        guard pairNegativeEntries.removeValue(forKey: key) != nil else { return }
        scheduleSave()
    }

    /// 写入翻译。同步写内存, debounced 写盘 (避免连续翻译多行频繁 IO)。
    func setTranslation(
        _ translated: String,
        for source: String,
        sourceLang: String?,
        targetLang: String,
        provider: ProviderNamespace = .system
    ) {
        let k = Self.makeKey(
            text: source,
            sourceLang: sourceLang,
            targetLang: targetLang,
            provider: provider
        )
        if entries[k] == nil {
            insertionOrder.append(k)
            if insertionOrder.count > Self.maxEntries {
                let drop = insertionOrder.removeFirst()
                entries[drop] = nil
            }
        }
        entries[k] = translated
        negativeEntries[k] = nil
        scheduleSave()
    }

    /// 批量写入 — 翻译完一首歌的所有行后一次性调, 比逐行 setTranslation 少
    /// 触发 scheduleSave 多次。
    func bulkSet(
        _ pairs: [(source: String, sourceLang: String?, translated: String)],
        targetLang: String,
        provider: ProviderNamespace = .system
    ) {
        for (s, sourceLang, translated) in pairs {
            let k = Self.makeKey(
                text: s,
                sourceLang: sourceLang,
                targetLang: targetLang,
                provider: provider
            )
            if entries[k] == nil {
                insertionOrder.append(k)
            }
            entries[k] = translated
            negativeEntries[k] = nil
        }
        // LRU 收割
        while insertionOrder.count > Self.maxEntries {
            let drop = insertionOrder.removeFirst()
            entries[drop] = nil
        }
        scheduleSave()
    }

    /// 清空所有翻译缓存 — 用户在 settings 里点 "Clear" 时。
    func clearAll() {
        entries.removeAll()
        insertionOrder.removeAll()
        negativeEntries.removeAll()
        pairNegativeEntries.removeAll()
        try? FileManager.default.removeItem(at: fileURL)
    }

    var count: Int { entries.count }

    // MARK: - Private

    private static func makeKey(
        text: String,
        sourceLang: String?,
        targetLang: String,
        provider: ProviderNamespace
    ) -> String {
        let providerVersion = provider == .system
            ? systemProviderVersion : intelligentProviderVersion
        let source = sourceLang.map(cacheLanguageIdentity) ?? "auto"
        let target = cacheLanguageIdentity(targetLang)
        let raw = "\(providerVersion)|\(source)|\(target)|\(text)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func makePairKey(sourceLang: String?, targetLang: String) -> String {
        let source = sourceLang.map(cacheLanguageIdentity) ?? "auto"
        let target = cacheLanguageIdentity(targetLang)
        let raw = "\(systemProviderVersion)|pair|\(source)|\(target)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheLanguageIdentity(_ raw: String) -> String {
        let identity = LyricTranslationGroupingPolicy.languageIdentity(raw)
        return LyricTranslationGroupingPolicy.representsSameTranslationLanguage(identity, "fa")
            ? "fa"
            : identity
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        // 写盘前把过期的 negative entry 顺手清掉, 不然会无限增长。
        let cutoff = Date().addingTimeInterval(-Self.negativeTTL)
        negativeEntries = negativeEntries.filter { $0.value > cutoff }
        pairNegativeEntries = pairNegativeEntries.filter { $0.value > cutoff }
        let snapshot = Persisted(
            schemaVersion: Self.schemaVersion,
            entries: entries,
            negativeEntries: negativeEntries,
            pairNegativeEntries: pairNegativeEntries,
            insertionOrder: insertionOrder
        )
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            plog("⚠️ LyricsTranslationCache save failed: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Persisted.self, from: data) else {
            return
        }
        guard decoded.schemaVersion == Self.schemaVersion else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
        entries = decoded.entries
        var seen = Set<String>()
        insertionOrder = (decoded.insertionOrder ?? entries.keys.sorted()).filter {
            entries[$0] != nil && seen.insert($0).inserted
        }
        for key in entries.keys.sorted() where seen.insert(key).inserted {
            insertionOrder.append(key)
        }
        while insertionOrder.count > Self.maxEntries {
            entries[insertionOrder.removeFirst()] = nil
        }
        // 载入时筛掉超过 TTL 的 negative entry, 避免老条目永远占位。
        let cutoff = Date().addingTimeInterval(-Self.negativeTTL)
        negativeEntries = (decoded.negativeEntries ?? [:]).filter { $0.value > cutoff }
        pairNegativeEntries = (decoded.pairNegativeEntries ?? [:]).filter { $0.value > cutoff }
    }
}
